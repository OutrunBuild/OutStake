// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {PSMMockReserveERC20} from "../psm/mocks/PSMMocks.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {PositionGhostModel} from "./helpers/PositionGhostModel.sol";
import {PositionRefModel} from "./helpers/PositionRefModel.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";

/**
 * @title PositionHandler
 * @notice Invariant handler driving the CDP surface: genesis opens (`stakeForGenesis` with the
 *         SP-side conservation asserted per call), partial/full redeem, time warps, duty segments,
 *         and (optionally) SY donations and PSM reserve swaps on a real uAsset.
 * @dev Ghost bookkeeping (rate segments, per-position principal/snapshot, cumulative
 *      interest paid, cumulative donations, mint-time collateral values for the backing
 *      invariant) is an independent reference model of the spec formulas — it never reads
 *      contract internals to predict itself. There is no liquidation surface: the backing
 *      invariant (principal <= mint-time collateral value) replaces the ladder checks.
 */
contract PositionHandler is PositionGhostModel {
    uint256 internal constant VERSE_ID = 42;
    // Absolute duty cap (15% annual per-second RAY value); mirrors the production cap.
    uint256 internal constant DUTY_CAP = SPTestDefaults.DUTY_CAP;
    // Random-walk step for duty changes (~0.3% annual equivalent); stays far inside (RAY, DUTY_CAP].
    uint256 internal constant DUTY_STEP = 1e17;

    OutrunStakingPositionUpgradeable public position;
    MockSY public sy;
    IUniversalAssets public uAsset;
    IERC20 public immutable uAssetToken; // ERC20 view surface (IUniversalAssets has no balanceOf)
    // Full-consumption launcher wired as the SP's genesis target so the runs can drive
    // `stakeForGenesis` opens.
    MockGenesisLauncher public genesisLauncher;
    address public actor;
    address public governance;
    address public immutable treasuryAddress;
    // Donation mode adds the donateSy op; backing ghost checks only hold in 18/18 decimals runs.
    bool public donationsEnabled;
    bool public backingChecksEnabled;
    // Optional PSM leg for the joint run (address(0) disables the PSM ops).
    OutrunPSMUpgradeable public psm;
    PSMMockReserveERC20 public reserveToken;
    // PSM redeem execution proof: how many redeem samples ran, how many passed the
    // reserve-aware guard (funded), and how many completed. All start at zero so the
    // accounting invariant below holds from the first call.
    uint256 public psmRedeemCalls;
    uint256 public psmRedeemFunded;
    uint256 public psmRedeemSuccess;

    // Absolute-timestamp tracker: the ghost model and every warp go through this variable instead
    // of the chain register (same defensive pattern the block-based handler used for vm.roll
    // under via_ir).
    uint256 public currentTimestamp;

    mapping(uint256 => uint256) internal ghostMintCollateral; // collateral value at mint (18/18 runs)
    uint256 public interestToTreasuryCum;

    constructor(
        OutrunStakingPositionUpgradeable position_,
        MockSY sy_,
        IUniversalAssets uAsset_,
        address actor_,
        address governance_,
        bool donationsEnabled_,
        bool backingChecksEnabled_
    ) {
        position = position_;
        sy = sy_;
        uAsset = uAsset_;
        uAssetToken = IERC20(address(uAsset_));
        actor = actor_;
        governance = governance_;
        treasuryAddress = address(0xFEE);
        donationsEnabled = donationsEnabled_;
        backingChecksEnabled = backingChecksEnabled_;
        currentTimestamp = block.timestamp; // first read of this call: reliable
        _seedGenesisSegment(currentTimestamp, position_.duty());
        // Genesis-gate fixture (runs during setUp): wire a full-consumption launcher so the
        // `stakeForGenesis` op below is live from the first fuzzed call.
        genesisLauncher = new MockGenesisLauncher(address(uAsset_));
        vm.prank(governance_);
        position_.setGenesisLauncher(address(genesisLauncher));
    }

    /// @notice Wires the optional PSM leg (joint CDP+PSM runs only).
    function setPsm(OutrunPSMUpgradeable psm_, PSMMockReserveERC20 reserveToken_) external {
        psm = psm_;
        reserveToken = reserveToken_;
    }

    /// @notice Reference pending interest for an active position (ghost model, not the contract):
    ///         only the extrapolated increment since the position's last settlement snapshot (the
    ///         booked accrued residual is excluded, mirroring the contract view).
    function refPendingInterest(uint256 positionId) external view returns (uint256) {
        return _refInterest(ghostPrincipal[positionId], _refUnit(currentTimestamp) - ghostLastUnit[positionId]);
    }

    /// @notice Ghost-recorded collateral value at the position's mint (0 when not recorded).
    function ghostMintCollateralOf(uint256 positionId) external view returns (uint256) {
        return ghostMintCollateral[positionId];
    }

    // Handler-specific helpers (ghost unit/interest live in PositionGhostModel)

    // ---- PositionGhostModel virtual overrides (handler) ----

    function _ghostIsActive(uint256 positionId) internal view override returns (bool) {
        (address owner,,,,) = position.positions(positionId);
        return owner != address(0);
    }

    function _ghostSyStaked(uint256 positionId) internal view override returns (uint256) {
        (, uint256 syStaked,,,) = position.positions(positionId);
        return syStaked;
    }

    function _ghostPrincipalDebt(uint256 positionId) internal view override returns (uint256) {
        (,, uint256 principal,,) = position.positions(positionId);
        return principal;
    }

    // --------------------------------------------------------------------------
    // Handler ops
    // --------------------------------------------------------------------------

    /// @notice Genesis open: drives `stakeForGenesis`, asserting the SP-side uAsset conservation
    ///         (balance identical before and after the call; launcher allowance zero) and
    ///         recording the ghost model with the mint-time collateral value.
    function stakeForGenesisSy(uint128 seed) external {
        uint256 amount = uint256(bound(seed, 2e18, 100e18));
        uint256 spUAssetBefore = uAssetToken.balanceOf(address(position));

        sy.mintShares(actor, amount);
        vm.startPrank(actor);
        sy.approve(address(position), amount);
        uint256 positionId = position.stakeForGenesis(amount, actor, VERSE_ID, 0);
        vm.stopPrank();

        assertEq(uAssetToken.balanceOf(address(position)), spUAssetBefore, "SP uAsset balance conserved");
        assertEq(uAssetToken.allowance(address(position), address(genesisLauncher)), 0, "launcher allowance cleared");

        (,, uint256 minted,,) = position.positions(positionId);
        if (backingChecksEnabled) {
            // Collateral value reference in 18/18 decimals: SY -> asset -> uAsset is the identity
            // rescale, so collateral = floor(amount x rate / 1e18).
            ghostMintCollateral[positionId] = amount * sy.exchangeRate() / 1e18;
            assertLe(minted, ghostMintCollateral[positionId], "mint-time backing ceiling");
        }
        ghostIds.push(positionId);
        ghostPrincipal[positionId] = minted;
        ghostLastUnit[positionId] = _refUnit(currentTimestamp);
        ghostAccrued[positionId] = 0;
        _settleGhostSegment(currentTimestamp);
    }

    function warpTime(uint128 seed) external {
        currentTimestamp += uint256(bound(seed, 1, 600));
        vm.warp(currentTimestamp);
    }

    /// @notice Partial redeem with the ceiled pro-rata legs checked against the ghost model.
    function partialRedeem(uint128 seed) external {
        uint256 positionId = _randomActiveId(seed);
        if (positionId == 0) return;
        (, uint256 syStaked,,,) = position.positions(positionId);
        if (syStaked < 2) return;
        uint256 syRedeemed = 1 + uint256(seed) % (syStaked - 1);

        uint256 principal = ghostPrincipal[positionId];
        uint256 settledInterest = _refSettledInterest(positionId, currentTimestamp);
        uint256 expectedPrincipal = (principal * syRedeemed + syStaked - 1) / syStaked;
        // A partial that would exhaust the principal is a legitimate contract rejection; skip it
        // rather than catching it (assertions must not hide behind a catch clause).
        if (expectedPrincipal >= principal) return;
        uint256 expectedInterest = (settledInterest * syRedeemed + syStaked - 1) / syStaked;

        vm.prank(actor);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, syRedeemed, actor, address(sy), 0);
        assertEq(burned, expectedPrincipal, "partial principal leg");
        assertEq(paid, expectedInterest, "partial interest leg");
        ghostPrincipal[positionId] = principal - burned;
        ghostAccrued[positionId] = settledInterest - expectedInterest; // residual stays booked
        ghostLastUnit[positionId] = _refUnit(currentTimestamp);
        interestToTreasuryCum += paid;
        _settleGhostSegment(currentTimestamp);
    }

    function fullRedeem(uint128 seed) external {
        uint256 positionId = _randomActiveId(seed);
        if (positionId == 0) return;
        (, uint256 syStaked,,,) = position.positions(positionId);
        uint256 principal = ghostPrincipal[positionId];
        uint256 settledInterest = _refSettledInterest(positionId, currentTimestamp);

        uint256 treasuryBefore = uAssetToken.balanceOf(treasuryAddress);
        vm.prank(actor);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, syStaked, actor, address(sy), 0);
        assertEq(burned, principal, "full redeem principal leg");
        assertEq(paid, settledInterest, "full redeem interest leg");
        assertEq(uAssetToken.balanceOf(treasuryAddress) - treasuryBefore, paid, "interest leg reached the treasury");
        interestToTreasuryCum += paid;
        delete ghostPrincipal[positionId];
        delete ghostLastUnit[positionId];
        delete ghostAccrued[positionId];
        _settleGhostSegment(currentTimestamp);
    }

    /// @notice Moves the duty within one bounded step, keeping the ghost segment table in
    ///         sync with the contract's segmented settlement. The walk may cross the zero-fee
    ///         sentinel (1e27) — a legal rate — so only sub-RAY candidates are skipped.
    function adjustDuty(uint128 seed) external {
        uint256 current = position.duty();
        uint256 raw = uint256(bound(seed, 1, 2 * DUTY_STEP));
        (uint256 candidate, bool skip) = _dutyStepCandidate(current, raw, DUTY_STEP, DUTY_CAP);
        // Mirror the setter guards (sub-RAY, 15% cap) so a skipped candidate
        // never desyncs the ghost table; the segment is cut only after the setter succeeds.
        if (skip) return;

        vm.prank(governance);
        position.setDuty(candidate);
        segments.push(Segment({startAt: currentTimestamp, unitAtStart: _refUnit(currentTimestamp), duty: candidate}));
    }

    /// @notice Attempts a duty that must revert (sub-RAY or above the cap); every attempt must
    ///         revert, which is what keeps the rate monotone and bounded by construction.
    function attemptDutyViolation(uint128 seed) external {
        uint256 mode = uint256(seed) % 2;
        uint256 candidate;
        if (mode == 0) {
            candidate = uint256(seed) % RAY; // sub-RAY (negative-rate domain, zero included)
        } else {
            candidate = DUTY_CAP + 1 + (uint256(seed) % 1e27); // above the cap
        }
        vm.prank(governance);
        (bool ok,) = address(position).call(abi.encodeCall(position.setDuty, (candidate)));
        assertFalse(ok, "out-of-domain duty must revert");
    }

    /// @notice Donation mode only: third-party SY transfers into the SP add to the excess ledger.
    function donateSy(uint128 seed) external {
        if (!donationsEnabled) return;
        uint256 amount = uint256(bound(seed, 1, 10e18));
        sy.mintShares(actor, amount);
        vm.startPrank(actor);
        sy.transfer(address(position), amount);
        vm.stopPrank();
        donatedCum += amount;
    }

    // --------------------------------------------------------------------------
    // Optional PSM leg (joint CDP+PSM runs): reserve-path supply flow
    // --------------------------------------------------------------------------

    function psmMint(uint128 seed) external {
        if (address(psm) == address(0)) return;
        uint256 amount = uint256(bound(seed, 1e18, 1000e18));
        reserveToken.mint(actor, amount);
        vm.prank(actor);
        psm.mint(actor, amount);
    }

    function psmRedeem(uint128 seed) external {
        if (address(psm) == address(0)) return;
        uint256 amount = uint256(bound(seed, 1e18, 100e18));
        psmRedeemCalls++;
        if (uAssetToken.balanceOf(actor) < amount) return;
        // Reserve-side executability: the payout is funded only by prior psmMint inflow (the joint
        // setUp leaves the PSM reserve at zero), so preview the payout and skip explicitly when
        // unfunded instead of running into a payout-transfer revert that the fuzzer silently skips.
        // A zero quote means dust that would revert on execution, so it also skips.
        uint256 payout = psm.quoteRedeem(amount);
        if (payout == 0) return;
        if (payout > reserveToken.balanceOf(address(psm))) return;
        psmRedeemFunded++;
        // try/catch instead of a bare call so a funded attempt that reverts still leaves funded++
        // on record: a bare revert would roll the counter back and the accounting invariant below
        // could never fail. The prank sets msg.sender for the try call.
        vm.prank(actor);
        try psm.redeem(actor, amount) {
            psmRedeemSuccess++;
        } catch {}
    }
}

/**
 * @notice Single source for the six CDP-side handler selectors shared by the strict and joint
 *         runs: suites extend it with their own ops instead of restating it.
 */
function _baseStrictSelectors(PositionHandler h) pure returns (bytes4[] memory) {
    bytes4[] memory selectors = new bytes4[](6);
    selectors[0] = h.stakeForGenesisSy.selector;
    selectors[1] = h.warpTime.selector;
    selectors[2] = h.partialRedeem.selector;
    selectors[3] = h.fullRedeem.selector;
    selectors[4] = h.adjustDuty.selector;
    selectors[5] = h.attemptDutyViolation.selector;
    return selectors;
}

/**
 * @title OutrunStakingPositionInvariantTest
 * @notice Core invariant suite on the mock stack (18/18 decimals, strict conservation — no
 *         third-party SY transfers; the handler's opener is the genesis gate, so the
 *         minter-ledger row covers genesis mints): SY-holdings decomposition, the
 *         minter-ledger principal row, the interest row (treasury receipts, never the minter
 *         ledger), accrual against the reference model, the backing invariant (mint-time
 *         collateral value per position), and id monotonicity.
 */
contract OutrunStakingPositionInvariantTest is StdInvariant, PositionRefModel {
    address internal owner = address(0xA11CE);
    address internal actor = address(0xB0B);
    address internal treasury = address(0xFEE);

    PositionHandler internal handler;
    OutrunStakingPositionUpgradeable internal position;
    MockSY internal sy;
    MockUAsset internal uAsset;
    MockERC20 internal underlying;

    function setUp() public virtual {
        _setUpWith(18, 18, false);
    }

    /// @notice Shared deployment for decimals variants and donation mode.
    function _setUpWith(uint8 canonicalAssetDecimals, uint8 uAssetDecimals, bool donationsEnabled) internal {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();
        // Both decimals knobs must be set before initialize caches them; SY decimals track the
        // canonical domain in this fixture.
        sy.setDecimals(canonicalAssetDecimals, canonicalAssetDecimals);
        uAsset.setUAssetDecimals(uAssetDecimals);
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );

        uAsset.setMintingCap(address(position), type(uint128).max);
        uAsset.setMintingCap(address(this), type(uint128).max);
        // Interest coverage, mirroring open-market acquisition.
        uAsset.mint(actor, 1e30);
        vm.prank(actor);
        uAsset.approve(address(position), type(uint256).max);

        // Both 18/18-gated ops (mint-time backing ghost checks) key off the same
        // decimals pair: their reference math assumes the identity decimal rescale.
        bool sameDecimals = canonicalAssetDecimals == 18 && uAssetDecimals == 18;
        handler = new PositionHandler(
            position, sy, IUniversalAssets(address(uAsset)), actor, owner, donationsEnabled, sameDecimals
        );
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _strictModeSelectors()}));
    }

    function _strictModeSelectors() internal view virtual returns (bytes4[] memory) {
        return _baseStrictSelectors(handler);
    }

    /// @notice SP SY balance == sum(active positions.syStaked).
    ///         Virtual: the donation-mode run overrides it with the >= + exact-delta relation.
    function invariant_spSyBalanceDecomposesExactly() public view virtual {
        assertEq(sy.balanceOf(address(position)), _decomposedSy(), "strict SY conservation");
    }

    /// @notice First reconciliation row: the SP minter's amountInMinted equals the sum of active
    ///         position principal debt (accrued interest never enters the minter ledger).
    function invariant_minterLedgerEqualsPrincipalDebt() external view {
        uint256 total = _ghostMinterTotalByCounter(position);
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, total, "minter ledger row equals active principal debt");
    }

    /// @notice Interest row: the treasury's uAsset balance equals every interest leg ever paid
    ///         (redeem pays the only interest leg), and the total supply change comes
    ///         only from principal mint/burn — interest is transfer-only by construction.
    function invariant_treasuryBalanceEqualsCumulativeInterestLegs() external view {
        assertEq(uAsset.balanceOf(treasury), handler.interestToTreasuryCum(), "treasury receipts match interest legs");
    }

    /// @notice Accrual row: every active position's pending interest (the unsettled increment)
    ///         equals the reference model, and positionDebt decomposes into principal + settled
    ///         accrued + that increment.
    function invariant_pendingInterestMatchesReference() external view {
        uint256 lastIssuedId = position.idCounter();
        for (uint256 positionId = 1; positionId <= lastIssuedId; ++positionId) {
            (address positionOwner,, uint256 principalDebt, uint256 accruedInterest,) = position.positions(positionId);
            if (positionOwner == address(0)) continue;
            // Pure view with no settlement between the two checks: one read serves both.
            uint256 pending = position.pendingInterest(positionId);
            assertEq(pending, handler.refPendingInterest(positionId), "pending interest matches the reference model");
            assertEq(
                position.positionDebt(positionId),
                principalDebt + accruedInterest + pending,
                "position debt decomposes into principal, settled, and pending interest"
            );
        }
    }

    /// @notice Backing invariant: every position's principal debt never exceeds its mint-time
    ///         collateral value (18/18 runs; the ghost records the collateral value at the mint
    ///         block, so later rate moves do not apply).
    function invariant_backingAtMintTime() external view {
        uint256 lastIssuedId = position.idCounter();
        for (uint256 positionId = 1; positionId <= lastIssuedId; ++positionId) {
            uint256 collateral = handler.ghostMintCollateralOf(positionId);
            if (collateral == 0) continue; // not recorded (cross-decimals runs skip this check)
            (address positionOwner,, uint256 minted,,) = position.positions(positionId);
            if (positionOwner == address(0)) continue;
            assertLe(minted, collateral, "mint-time backing invariant");
        }
    }

    /// @notice Duty domain: the duty never leaves [1e27, DUTY_CAP] — sub-RAY (negative-rate)
    ///         and above-cap sets always revert, and the zero-fee sentinel itself is reachable
    ///         (no ratchet blocks it).
    function invariant_dutyStaysInDomain() external view {
        // Read-only pin of the current duty domain: any duty in [1e27, DUTY_CAP] is legal state.
        uint256 duty = position.duty();
        assertGe(duty, 1e27, "duty never sub-RAY");
        assertLe(duty, SPTestDefaults.DUTY_CAP, "duty never above the cap");
    }

    /// @notice Position ids are monotonic and never reused; deleted ids stay empty holes.
    function invariant_positionIdMonotonic() external view {
        uint256 lastIssuedId = position.idCounter();
        for (uint256 positionId = 1; positionId <= lastIssuedId; ++positionId) {
            (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(positionId);
            if (positionOwner == address(0)) {
                assertEq(syStaked, 0, "a hole must be fully empty");
                assertEq(principalDebt, 0, "a hole carries no debt");
            }
        }
    }

    function _decomposedSy() internal view returns (uint256) {
        return _decomposedSyByCounter(position);
    }
}

/**
 * @title OutrunStakingPositionDonationInvariantTest
 * @notice Donation-flow variant: with third-party SY transfers into the SP, the balance stays at
 *         or above the decomposition and the excess equals the cumulative donated amount.
 */
contract OutrunStakingPositionDonationInvariantTest is OutrunStakingPositionInvariantTest {
    function setUp() public override {
        _setUpWith(18, 18, true);
    }

    function _strictModeSelectors() internal view override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        bytes4[] memory base = super._strictModeSelectors();
        for (uint256 i = 0; i < base.length; ++i) {
            selectors[i] = base[i];
        }
        selectors[6] = handler.donateSy.selector;
        return selectors;
    }

    /// @notice Overrides the strict run: balance >= decomposition with the exact donation delta.
    function invariant_spSyBalanceDecomposesExactly() public view override {
        uint256 balance = sy.balanceOf(address(position));
        assertGe(balance, _decomposedSy(), "balance covers the decomposition");
        assertEq(balance - _decomposedSy(), handler.donatedCum(), "excess equals cumulative donations");
    }
}

/**
 * @title OutrunPositionPsmJointInvariantTest
 * @notice Cross-module joint invariant on a real T1 uAsset with both supply paths live: the CDP
 *         (genesis mints) and a real PSM (reserve mint/burn). The PSM row of the three-row
 *         reconciliation stays (0, 0) — the reserve path never touches the minter debt ledger —
 *         while the CDP row holds exactly, even as PSM swaps move totalSupply.
 */
contract OutrunPositionPsmJointInvariantTest is StdInvariant, PositionRefModel {
    address internal owner = address(0xA11CE);
    address internal psmOwner = address(0xB0B2);
    address internal actor = address(0xB0B);
    address internal treasury = address(0xFEE);

    OutrunUniversalAssetsUpgradeable internal uAsset;
    OutrunPSMUpgradeable internal psm;
    PSMMockReserveERC20 internal reserveToken;
    OutrunStakingPositionUpgradeable internal position;
    MockSY internal sy;
    MockERC20 internal underlying;
    PositionHandler internal handler;

    function setUp() external {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));

        uAsset = _deployUAsset(owner);
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        reserveToken = new PSMMockReserveERC20("Mock Reserve", "MRV", 18);
        psm = OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunPSMUpgradeable()),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize,
                    (
                        address(uAsset),
                        address(reserveToken),
                        psmOwner,
                        makeAddr("psmFeeRecipient"),
                        1_000_000e18,
                        1e15,
                        1e15
                    )
                )
            )
        );

        vm.startPrank(owner);
        uAsset.setMintingCap(address(position), type(uint128).max);
        uAsset.setMintingCap(address(this), type(uint128).max); // funds interest coverage only
        uAsset.setReserveMinter(address(psm), true);
        vm.stopPrank();

        // Actor inventory and allowances across both supply paths.
        uAsset.mint(actor, 1e27);
        reserveToken.mint(actor, 1_000_000e18);
        vm.startPrank(actor);
        uAsset.approve(address(position), type(uint256).max);
        uAsset.approve(address(psm), type(uint256).max);
        reserveToken.approve(address(psm), type(uint256).max);
        vm.stopPrank();

        // Joint run is 18/18 decimals on a real uAsset.
        handler = new PositionHandler(position, sy, IUniversalAssets(address(uAsset)), actor, owner, false, true);
        handler.setPsm(psm, reserveToken);
        targetContract(address(handler));

        bytes4[] memory base = _baseStrictSelectors(handler);
        bytes4[] memory selectors = new bytes4[](base.length + 2);
        for (uint256 i = 0; i < base.length; ++i) {
            selectors[i] = base[i];
        }
        selectors[6] = handler.psmMint.selector;
        selectors[7] = handler.psmRedeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice PSM exemption row: the reserve minter's debt-ledger record stays (0, 0) even while
    ///         its reserve path mints and burns uAsset.
    function invariant_psmRowStaysExempt() external view {
        IUniversalAssets.MintingStatus memory psmStatus = uAsset.mintingStatusTable(address(psm));
        assertEq(psmStatus.mintingCap, 0, "PSM never receives a debt-ledger cap");
        assertEq(psmStatus.amountInMinted, 0, "PSM reserve flow never enters amountInMinted");
    }

    /// @notice CDP row holds exactly while the PSM supply path moves totalSupply.
    function invariant_cdpRowHoldsWhilePsmMovesSupply() external view {
        uint256 total = _ghostMinterTotalByCounter(position);
        assertEq(
            uAsset.mintingStatusTable(address(position)).amountInMinted,
            total,
            "CDP minter row equals active principal debt"
        );
    }

    /// @notice SY conservation also holds across the joint run.
    function invariant_spSyBalanceDecomposesExactly() external view {
        uint256 total = _decomposedSyByCounter(position);
        assertEq(sy.balanceOf(address(position)), total, "strict SY conservation");
    }

    /// @notice PSM redeem leg execution proof: every funded redeem attempt succeeds, so a passing
    ///         run cannot be explained by silent reverts on the funded path; unfunded samples skip
    ///         explicitly via the reserve-aware guard above.
    function invariant_psmRedeemFundedAttemptsSucceed() external view {
        assertEq(handler.psmRedeemSuccess(), handler.psmRedeemFunded(), "funded PSM redeems all succeed");
    }

    /// @notice Liveness proof for the PSM redeem leg: with the PSM funded, the handler redeem leg
    ///         completes and records it, so funded and success both advance together.
    function test_psmRedeemLegExecutesWhenFunded() external {
        uint256 fundAmount = 1_000_000e18;
        reserveToken.mint(actor, fundAmount);
        vm.prank(actor);
        psm.mint(actor, fundAmount);
        handler.psmRedeem(uint128(42));
        handler.psmRedeem(uint128(7));
        assertGt(handler.psmRedeemFunded(), 0, "funded redeem leg sampled");
        assertEq(handler.psmRedeemSuccess(), handler.psmRedeemFunded(), "funded PSM redeems all succeed");
    }
}

/// @title Cross-decimals invariant run: canonical 18, uAsset 6
/// @notice uAsset debt is downscaled from the canonical domain (divide by 1e12 on mint); the
///         conservation/ledger/accrual rows are decimals-agnostic, so they must hold here too.
contract OutrunStakingPositionCrossDecimalsInvariantTest_18_6 is OutrunStakingPositionInvariantTest {
    function setUp() public override {
        _setUpWith(18, 6, false);
    }
}

/// @title Cross-decimals invariant run: canonical 6, uAsset 18
/// @notice uAsset debt is upscaled from the canonical domain (multiply by 1e12 on mint).
contract OutrunStakingPositionCrossDecimalsInvariantTest_6_18 is OutrunStakingPositionInvariantTest {
    function setUp() public override {
        _setUpWith(6, 18, false);
    }
}

/// @title Cross-decimals invariant run: canonical 18, uAsset 18
/// @notice Same-decimals control run: the rescaling is the identity, isolating rate-only effects.
contract OutrunStakingPositionCrossDecimalsInvariantTest_18_18 is OutrunStakingPositionInvariantTest {
    function setUp() public override {
        _setUpWith(18, 18, false);
    }
}
