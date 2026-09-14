// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PositionGhostModel} from "./helpers/PositionGhostModel.sol";
import {PositionRefModel} from "./helpers/PositionRefModel.sol";

import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {CommonTestHelpers} from "./helpers/CommonTestHelpers.sol";
import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";

/**
 * @title OutrunStakingPositionFuzzTest
 * @notice Randomized genesis-open/redeem/warp sequences against the open-term CDP position
 *         with per-step property checks: every mint equals the collateral value at the mint-time
 *         rate (value parity, two floored stages), per-position interest matches an independent
 *         reference implementation wei for wei, redeem legs decompose the repayment exactly
 *         (principal burn + interest transfer), the backing invariant holds per position at its
 *         mint-time rate, and the SP's SY balance decomposes into position collateral (exactly
 *         without donations, or with the delta equal to cumulative donations in the donation
 *         flow).
 * @dev Deterministic LCG-driven sequences so each fuzz run exercises a different interleaving;
 *      runs default to 256. Ghost state (per-position principal/snapshot and the rate
 *      segment table) mirrors the spec formulas, not the contract internals.
 */
contract OutrunStakingPositionFuzzTest is PositionGhostModel, CommonTestHelpers {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal treasury = address(0xFEE);

    uint256 internal constant DUTY = SPTestDefaults.DUTY;
    // Absolute duty cap (15% annual per-second RAY value); mirrors the production cap.
    uint256 internal constant DUTY_CAP = SPTestDefaults.DUTY_CAP;
    // Random-walk step for duty changes (~0.3% annual equivalent); stays far inside (RAY, DUTY_CAP].
    uint256 internal constant DUTY_STEP = 1e17;
    uint256 internal constant VERSE_ID = 42;
    MockERC20 internal underlying;
    MockSY internal sy;
    MockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    MockGenesisLauncher internal genesisLauncher;

    // Absolute-timestamp tracking: the reference model and every warp go through `warpAt`
    // instead of the chain register; `_warp`/`warpAt` provided by `CommonTestHelpers`.

    // Mint-time collateral values (syAmount x rate, 18/18) per position id, for the backing
    // invariant check (each position is checked against its own mint-time rate).
    mapping(uint256 => uint256) internal ghostMintCollateral;

    function setUp() external {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        uAsset.setMintingCap(address(position), type(uint256).max);
        uAsset.setMintingCap(address(this), type(uint256).max);
        // Genesis-gate fixture: a full-consumption launcher wired as the SP's target.
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
        // Participants get generous balances and allowances so only the properties under test can
        // fail (interest coverage mirrors open-market acquisition).
        uAsset.mint(user, 1e30);
        vm.prank(user);
        uAsset.approve(address(position), type(uint256).max);

        _seedGenesisSegment(warpAt, DUTY);
    }

    /// @notice Collateral value reference: SY -> canonical asset -> uAsset, both floors, 18/18.
    function _refCollateral(uint256 syAmount, uint256 rate) internal pure returns (uint256) {
        return syAmount * rate / 1e18;
    }

    // ==========================================================================
    // Property checks run after every step
    // ==========================================================================

    /// @dev SY conservation: without donations the SP balance decomposes exactly; with donations
    ///      the balance is at least the decomposition and the delta is exactly the donations.
    function _checkSyConservation() internal view {
        uint256 decomposed = _decomposedSyByIds();
        uint256 balance = sy.balanceOf(address(position));
        if (donatedCum == 0) {
            assertEq(balance, decomposed, "strict SY conservation");
        } else {
            assertGe(balance, decomposed, "balance must cover the decomposition");
            assertEq(balance - decomposed, donatedCum, "excess equals cumulative donations");
        }
    }

    /// @dev Minter-ledger row: amountInMinted == sum of active principal debt, exactly.
    function _checkMinterLedgerRow() internal view {
        uint256 total = _ghostMinterTotalByIds();
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, total, "minter ledger row equals active principal debt");
    }

    /// @dev Per-position accrual matches the reference for every active position: pendingInterest
    ///      is the unsettled increment only (the settled accrued residual is excluded), and
    ///      positionDebt decomposes into principal + settled accrued + that increment.
    function _checkAccrualAgainstReference() internal view {
        for (uint256 i = 0; i < ghostIds.length; ++i) {
            uint256 id = ghostIds[i];
            (address positionOwner,,,,) = position.positions(id);
            if (positionOwner == address(0)) continue;
            // Pure view with no settlement between the two checks: one read serves both.
            uint256 pending = position.pendingInterest(id);
            assertEq(
                pending,
                _refInterest(ghostPrincipal[id], _refUnit(warpAt) - ghostLastUnit[id]),
                "pending interest matches the reference"
            );
            assertEq(
                position.positionDebt(id),
                ghostPrincipal[id] + ghostAccrued[id] + pending,
                "position debt decomposes into principal, settled, and pending interest"
            );
        }
    }

    /// @dev Backing invariant: every active position's principal debt never exceeds its mint-time
    ///      collateral value (value-parity floors at open; the rate never moves in this suite).
    function _checkBackingInvariant() internal view {
        for (uint256 i = 0; i < ghostIds.length; ++i) {
            uint256 id = ghostIds[i];
            (address positionOwner,, uint256 principal,,) = position.positions(id);
            if (positionOwner == address(0)) continue;
            assertLe(principal, ghostMintCollateral[id], "mint-time backing invariant");
        }
    }

    // ==========================================================================
    // Randomized sequence drivers
    // ==========================================================================

    /// @notice Random genesis-open/redeem/warp sequences with strict conservation (no donations).
    function testFuzz_SequencePreservesParityAccrualAndTwoLegConservation(uint256 seed, uint8 rawSteps) external {
        _runSequence(seed, rawSteps, false);
    }

    /// @notice Same randomized sequences plus a SY donation flow: the balance stays at or above
    ///         the decomposition with the difference exactly equal to cumulative donations.
    function testFuzz_DonationFlowConservationTracksExcess(uint256 seed, uint8 rawSteps) external {
        _runSequence(seed, rawSteps, true);
    }

    /// @dev Shared sequence driver: both fuzz entrypoints run the same op dispatch and the same
    ///      per-step checks. `withDonation` only widens the op bound from 0..5 to 0..6 so the
    ///      donation leg (op == 6) is reachable; the 0..5 mapping is identical either way.
    function _runSequence(uint256 seed, uint8 rawSteps, bool withDonation) internal {
        uint8 steps = uint8(bound(rawSteps, 4, 12));
        for (uint256 i = 0; i < steps; ++i) {
            seed = _nextRandom(seed);
            uint8 op = uint8(_pick(seed, 0, withDonation ? 6 : 5));
            if (op == 0) {
                _warpTime(seed);
            } else if (op == 1 || op == 2) {
                _stakeForGenesisRandom(seed);
            } else if (op == 3) {
                _partialRedeemRandom(seed);
            } else if (op == 4) {
                _fullRedeemRandom(seed);
            } else if (op == 5) {
                _changeDuty(seed);
            } else {
                _donateSy(seed);
            }
            _checkSyConservation();
            _checkMinterLedgerRow();
            _checkAccrualAgainstReference();
            _checkBackingInvariant();
        }
    }

    /// @notice Across rates (including rate increases) and dust amounts, the minted debt never
    ///         exceeds the collateral value, preview == execution, and dust deliberately diverges
    ///         (quote 0 vs executor revert).
    function testFuzz_ValueParityHoldsAcrossRatesAndDust(uint96 syAmount, uint104 rawRate) external {
        uint256 rate = bound(rawRate, 1e17, 5e18);
        sy.setExchangeRate(rate);
        syAmount = uint96(bound(syAmount, 1, 1e24));

        uint256 previewed = position.previewStake(syAmount);
        uint256 collateral = _refCollateral(syAmount, rate);
        assertLe(previewed, collateral, "minted debt never exceeds collateral value");

        sy.mintShares(user, syAmount);
        vm.startPrank(user);
        sy.approve(address(position), syAmount);
        if (previewed == 0) {
            vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
            position.stakeForGenesis(syAmount, user, VERSE_ID, 0);
            vm.stopPrank();
            return;
        }
        uint256 positionId = position.stakeForGenesis(syAmount, user, VERSE_ID, 0);
        vm.stopPrank();
        (,, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(principalDebt, previewed, "genesis minted the previewed amount");
    }

    /// @notice Partial redeem legs decompose the repayment exactly: ceiled pro-rata legs, the
    ///         burn reduces the minter ledger by the same amount, and only the interest moves.
    function testFuzz_PartialRedeemLegsDecomposeRepayment(uint96 syAmount, uint96 rawRedeem, uint16 rawSeconds)
        external
    {
        syAmount = uint96(bound(syAmount, 2e18, 1e24));
        uint256 syRedeemed = bound(rawRedeem, 1, uint256(syAmount) - 1);
        uint256 principal = _openGenesis(user, syAmount);
        uint256 positionId = position.idCounter();
        // The open settles the rate at the opening second; the snapshot is the settled value.
        uint256 unitAtOpen = position.rate();

        _warp(bound(rawSeconds, 0, 600));
        uint256 settledInterest = _refInterest(principal, _refUnit(warpAt) - unitAtOpen);

        uint256 expectedPrincipal = SPTestDefaults.ceilDiv(principal * syRedeemed, syAmount);
        if (expectedPrincipal >= principal) {
            vm.prank(user);
            vm.expectRevert(IOutrunStakeManager.PartialRedeemMustLeaveDebt.selector);
            position.redeem(positionId, syRedeemed, user, address(sy), 0);
            return;
        }
        uint256 expectedInterest = SPTestDefaults.ceilDiv(settledInterest * syRedeemed, syAmount);

        uint256 treasuryBefore = uAsset.balanceOf(treasury);
        (, uint256 burnedBefore) = uAsset.mintingStatusTable(address(position));
        vm.prank(user);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, syRedeemed, user, address(sy), 0);
        assertEq(burned, expectedPrincipal, "principal leg is the ceiled share");
        assertEq(paid, expectedInterest, "interest leg is the ceiled share");
        assertEq(uAsset.balanceOf(treasury) - treasuryBefore, expectedInterest, "treasury received the interest leg");
        (, uint256 burnedAfter) = uAsset.mintingStatusTable(address(position));
        assertEq(burnedBefore - burnedAfter, expectedPrincipal, "ledger reduced by the principal leg only");
    }

    /// @notice Zero-fee fuzz: at duty 1e27 the rate never advances and interest never accrues,
    ///         across warps and partial/full redeems.
    function testFuzz_ZeroFeeDutyNeverAccrues(uint16 rawSeconds, uint96 rawRedeem) external {
        vm.prank(owner);
        position.setDuty(SPTestDefaults.ZERO_FEE_DUTY);

        uint256 syAmount = 10e18;
        uint256 principal = _openGenesis(user, syAmount);
        uint256 positionId = position.idCounter();

        _warp(bound(rawSeconds, 0, 365 days));
        assertEq(position.rate(), 1e27, "zero-fee rate frozen");
        assertEq(position.pendingInterest(positionId), 0, "zero pending interest");

        uint256 syRedeemed = bound(rawRedeem, 1, syAmount);
        if (syRedeemed == syAmount) {
            vm.prank(user);
            (uint256 burned, uint256 paid,) = position.redeem(positionId, syRedeemed, user, address(sy), 0);
            assertEq(burned, principal, "full principal leg");
            assertEq(paid, 0, "zero interest leg");
        } else {
            uint256 expectedPrincipal = SPTestDefaults.ceilDiv(principal * syRedeemed, syAmount);
            if (expectedPrincipal >= principal) return; // legitimate contract rejection
            vm.prank(user);
            (uint256 burned, uint256 paid,) = position.redeem(positionId, syRedeemed, user, address(sy), 0);
            assertEq(burned, expectedPrincipal, "partial principal leg");
            assertEq(paid, 0, "zero interest leg");
        }
        assertEq(uAsset.balanceOf(treasury), 0, "treasury received nothing under zero fee");
    }

    // ==========================================================================
    // Sequence operations
    // ==========================================================================

    /// @notice Opens a genesis position for `who` and returns the value-parity minted principal.
    function _openGenesis(address who, uint256 amount) internal returns (uint256 principal) {
        sy.mintShares(who, amount);
        vm.startPrank(who);
        sy.approve(address(position), amount);
        uint256 positionId = position.stakeForGenesis(amount, who, VERSE_ID, 0);
        vm.stopPrank();
        (,, principal,,) = position.positions(positionId);
    }

    function _warpTime(uint256 seed) internal {
        _warp(_pick(_nextRandom(seed), 1, 600));
    }

    /// @dev Genesis open with the SP-side conservation asserted per call: the SP's uAsset balance
    ///      is identical before and after (the mint is consumed inside the transaction), the
    ///      launcher allowance is zero, and the ghost model records the mint-time collateral value.
    function _stakeForGenesisRandom(uint256 seed) internal {
        uint256 amount = _pick(_nextRandom(seed), 2e18, 100e18);
        uint256 spUAssetBefore = uAsset.balanceOf(address(position));
        uint256 rate = sy.exchangeRate();

        sy.mintShares(user, amount);
        vm.startPrank(user);
        sy.approve(address(position), amount);
        uint256 positionId = position.stakeForGenesis(amount, user, VERSE_ID, 0);
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(position)), spUAssetBefore, "SP uAsset balance conserved");
        assertEq(uAsset.allowance(address(position), address(genesisLauncher)), 0, "launcher allowance cleared");

        (,, uint256 minted,,) = position.positions(positionId);
        // Value parity at the mint rate: minted <= collateral, exactly the two-floor quote.
        assertLe(minted, _refCollateral(amount, rate), "mint-time backing ceiling");
        ghostIds.push(positionId);
        ghostPrincipal[positionId] = minted;
        ghostMintCollateral[positionId] = _refCollateral(amount, rate);
        ghostLastUnit[positionId] = _refUnit(warpAt);
        ghostAccrued[positionId] = 0;
        _settleGhostSegment(warpAt);
    }

    function _partialRedeemRandom(uint256 seed) internal {
        uint256 positionId = _randomActiveId(_nextRandom(seed));
        if (positionId == 0) return;
        (, uint256 syStaked, uint256 principal,,) = position.positions(positionId);
        if (syStaked < 2) return;
        uint256 syRedeemed = _pick(_nextRandom(seed), 1, syStaked - 1);

        uint256 settledInterest = _refSettledInterest(positionId, warpAt);
        uint256 expectedPrincipal = SPTestDefaults.ceilDiv(principal * syRedeemed, syStaked);
        // A partial whose ceiled principal leg would exhaust the debt is a legitimate contract
        // rejection: skip it instead of calling (assertions must not hide behind a catch).
        if (expectedPrincipal >= principal) return;
        uint256 expectedInterest = SPTestDefaults.ceilDiv(settledInterest * syRedeemed, syStaked);

        vm.prank(user);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, syRedeemed, user, address(sy), 0);
        assertEq(burned, expectedPrincipal, "partial principal leg");
        assertEq(paid, expectedInterest, "partial interest leg");
        ghostPrincipal[positionId] = principal - burned;
        ghostAccrued[positionId] = settledInterest - expectedInterest; // residual stays booked
        ghostLastUnit[positionId] = _refUnit(warpAt);
        _settleGhostSegment(warpAt);
    }

    function _fullRedeemRandom(uint256 seed) internal {
        uint256 positionId = _randomActiveId(_nextRandom(seed));
        if (positionId == 0) return;
        (, uint256 syStaked,,,) = position.positions(positionId);
        uint256 principal = ghostPrincipal[positionId];
        uint256 settledInterest = _refSettledInterest(positionId, warpAt);

        uint256 treasuryBefore = uAsset.balanceOf(treasury);
        (, uint256 ledgerBefore) = uAsset.mintingStatusTable(address(position));
        vm.prank(user);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, syStaked, user, address(sy), 0);
        assertEq(burned, principal, "full redeem principal leg");
        assertEq(paid, settledInterest, "full redeem interest leg");
        assertEq(uAsset.balanceOf(treasury) - treasuryBefore, settledInterest, "treasury interest delta");
        (, uint256 ledgerAfter) = uAsset.mintingStatusTable(address(position));
        assertEq(ledgerBefore - ledgerAfter, principal, "ledger delta equals the burn");

        delete ghostPrincipal[positionId];
        delete ghostLastUnit[positionId];
        delete ghostAccrued[positionId];
        _settleGhostSegment(warpAt);
    }

    function _changeDuty(uint256 seed) internal {
        uint256 current = position.duty();
        // One bounded step: the setter rejects sub-RAY duties and duties above the cap. The walk
        // may cross the zero-fee sentinel (1e27) — a legal rate — so only sub-RAY is skipped.
        uint256 raw = _pick(_nextRandom(seed), 1, 2 * DUTY_STEP);
        (uint256 newDuty, bool skip) = _dutyStepCandidate(current, raw, DUTY_STEP, DUTY_CAP);
        if (skip) return;

        vm.prank(owner);
        position.setDuty(newDuty);
        // Segment boundary, recorded only after the setter succeeds so the ghost table never
        // diverges from the contract: settle pending seconds at the old duty, then the new duty applies.
        segments.push(Segment({startAt: warpAt, unitAtStart: _refUnit(warpAt), duty: newDuty}));
    }

    function _donateSy(uint256 seed) internal {
        uint256 amount = _pick(_nextRandom(seed), 1, 10e18);
        sy.mintShares(user, amount);
        vm.startPrank(user);
        sy.transfer(address(position), amount);
        vm.stopPrank();
        donatedCum += amount;
    }

    // ==========================================================================
    // PRNG and small helpers
    // ==========================================================================

    function _nextRandom(uint256 seed) internal pure returns (uint256) {
        // Deliberately wrapping LCG: fuzzed seeds span the full uint256 domain.
        unchecked {
            return seed * 6364136223846793005 + 1442695040888963407;
        }
    }

    // ---- PositionGhostModel virtual overrides (fuzz suite) ----

    function _ghostIsActive(uint256 positionId) internal view override returns (bool) {
        (address positionOwner,,,,) = position.positions(positionId);
        return positionOwner != address(0);
    }

    function _ghostSyStaked(uint256 positionId) internal view override returns (uint256) {
        (, uint256 syStaked,,,) = position.positions(positionId);
        return syStaked;
    }

    function _ghostPrincipalDebt(uint256 positionId) internal view override returns (uint256) {
        (,, uint256 principal,,) = position.positions(positionId);
        return principal;
    }
}

/**
 * @title OutrunStakingPositionPropertyTest
 * @notice Focused deterministic properties that complement the randomized sequences: partial
 *         redeem ceil behavior, interest continuity across a partial redeem, and rate-change
 *         segmentation on a live position.
 */
contract OutrunStakingPositionPropertyTest is CommonTestHelpers, PositionRefModel {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);

    // `warpAt`/`_warp` provided by `CommonTestHelpers`; RAY compounding reference
    // (`Segment`/`_refUnit`/`_refInterest`) provided by `PositionRefModel`.

    MockERC20 internal underlying;
    MockSY internal sy;
    MockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    MockGenesisLauncher internal genesisLauncher;

    // `warpAt`/`_warp` provided by `CommonTestHelpers`.

    function setUp() external {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), address(0xFEE))
            )
        );
        uAsset.setMintingCap(address(position), type(uint256).max);
        uAsset.setMintingCap(address(this), type(uint256).max);
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
        uAsset.mint(user, 1e27);
        vm.prank(user);
        uAsset.approve(address(position), type(uint256).max);
        // Genesis segment: the cumulative rate starts at RAY (1e27) at the init timestamp.
        _seedGenesisSegment(warpAt, SPTestDefaults.DUTY);
    }

    /// @notice Opens a genesis position for `user` and returns the id and minted principal.
    function _openGenesis(uint256 amount) internal returns (uint256 positionId, uint256 minted) {
        sy.mintShares(user, amount);
        vm.startPrank(user);
        sy.approve(address(position), amount);
        positionId = position.stakeForGenesis(amount, user, 42, 0);
        vm.stopPrank();
        (,, minted,,) = position.positions(positionId);
    }

    /// @notice A half partial redeem ceils both legs, halves the collateral, keeps positive
    ///         principal debt, and interest continues on the reduced principal.
    function test_PartialRedeemCeilsLegsAndLeavesDebt() external {
        (uint256 positionId, uint256 minted) = _openGenesis(10e18);

        uint256 half = 5e18;
        uint256 expectedPrincipal = (minted * half + 10e18 - 1) / 10e18; // ceil(principal / 2)
        (uint256 principalPortion, uint256 interestPortion,) = position.previewRedeem(positionId, half, address(sy));
        assertEq(principalPortion, expectedPrincipal, "ceiled principal leg");
        assertEq(interestPortion, 0, "same-block partial carries no interest");

        vm.prank(user);
        (uint256 principalBurned,,) = position.redeem(positionId, half, user, address(sy), 0);
        assertEq(principalBurned, expectedPrincipal, "redeemed principal leg");

        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(positionOwner, user, "partial redeem keeps the position");
        assertEq(syStaked, half, "collateral halved");
        assertEq(principalDebt, minted - expectedPrincipal, "principal reduced by the leg");
        assertGt(principalDebt, 0, "partial redeem leaves debt");

        _warp(10);
        assertEq(
            position.pendingInterest(positionId),
            _refInterest(principalDebt, _refUnit(warpAt) - RAY), // open at init so the snapshot is RAY
            "interest continues on the reduced principal"
        );
    }
}
