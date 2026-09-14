// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {GenesisGateLib} from "../../src/libraries/GenesisGateLib.sol";
import {OutrunExchangeOracleAdapter} from "../../src/libraries/oracle/OutrunExchangeOracleAdapter.sol";
import {IExchangeRateOracle} from "../../src/libraries/oracle/interfaces/IExchangeRateOracle.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {MockAggregator} from "../support/mocks/MockOracleWarningsMocks.sol";
import {
    MockSYWithRateControl,
    MockERC20ForAdversarial,
    MockUAssetForAdversarial,
    ReentrantPositionSY,
    ReenteringGenesisLauncher,
    DonatingGenesisLauncher
} from "./mocks/AdversarialMocks.sol";
import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";
import {MockUAsset} from "./mocks/PositionTestMocks.sol";
import {PositionMockToken} from "./mocks/PositionMocks.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {CommonTestHelpers} from "./helpers/CommonTestHelpers.sol";
import {PositionRefModel} from "./helpers/PositionRefModel.sol";

// ============================================================
//                    ADVERSARIAL TEST SUITE
// ============================================================

/**
 * @title AdversarialTests
 * @notice Adversarial surface of the open-term CDP position: input-guard full table (zero
 *         addresses, minStake boundary, dust), non-owner access, oracle fail-closed on every
 *         pricing read, genesis-gate abuse (partial consumption, transfer-back, donation,
 *         launcher revert, kill switch), and redeem funding shortfalls. There is no
 *         liquidation surface: every borrower's exit is the owner-only redeem.
 */
contract AdversarialTests is CommonTestHelpers {
    bytes4 internal constant POSITION_ACCESS_DENIED_SELECTOR = bytes4(keccak256("PositionAccessDenied()"));
    bytes4 internal constant ZERO_EXCHANGE_RATE_SELECTOR = bytes4(keccak256("ZeroExchangeRate()"));
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = bytes4(keccak256("EnforcedPause()"));

    MockERC20ForAdversarial internal underlying;
    MockSYWithRateControl internal sy;
    MockUAssetForAdversarial internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    MockGenesisLauncher internal genesisLauncher;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE);
    address internal alice = address(0xA11CE1);
    address internal attacker = address(0xDEAD);

    function setUp() external {
        underlying = new MockERC20ForAdversarial("Mock Asset", "mAST");
        sy = new MockSYWithRateControl(address(underlying));
        uAsset = new MockUAssetForAdversarial();

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        uAsset.setMintingCap(address(position), type(uint256).max);
        uAsset.setMintingCap(address(this), type(uint256).max);
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
    }

    /// @notice Opens a 10e18-SY genesis position for `who` at the current (default 1e18) rate.
    function _stakeTenSy(address who) internal returns (uint256 positionId, uint256 principal) {
        return _stakeTenSyForGenesis(address(sy), address(position), address(genesisLauncher), who);
    }

    /// @notice A zero exchange rate must fail closed at the single rate-reading home before any
    ///         transfer or state write on every pricing entrypoint.
    function test_RevertWhen_ExchangeRateIsZeroStakeFailsClosed() external {
        sy.setExchangeRate(0);
        sy.mintShares(alice, 10e18);
        vm.startPrank(alice);
        sy.approve(address(position), 10e18);
        vm.expectRevert(ZERO_EXCHANGE_RATE_SELECTOR);
        position.stakeForGenesis(10e18, alice, 42, 0);
        vm.stopPrank();

        vm.expectRevert(ZERO_EXCHANGE_RATE_SELECTOR);
        position.previewStake(10e18);

        // Nothing moved: no SY pulled, no position created.
        assertEq(sy.balanceOf(address(position)), 0, "no SY entered the SP");
        assertEq(position.idCounter(), 0, "no position was created");
    }

    /// @notice Only the recorded owner may redeem; anyone else is denied without state changes.
    function test_RevertWhen_NonOwnerRedeems() external {
        (uint256 positionId,) = _stakeTenSy(alice);
        vm.prank(attacker);
        vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
        position.redeem(positionId, 10e18, attacker, address(sy), 0);
    }

    /// @notice The SP-level pause freezes both user entrypoints while views stay usable.
    function test_RevertWhen_PausedStakeIsBlockedAndViewsStayUsable() external {
        (uint256 positionId,) = _stakeTenSy(alice);

        vm.prank(owner);
        position.pause();

        vm.prank(alice);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.stakeForGenesis(10e18, alice, 42, 0);
        vm.prank(alice);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.redeem(positionId, 10e18, alice, address(sy), 0);

        // Views are not gated by the pause.
        assertEq(position.previewStake(10e18), 10e18, "preview stays available while paused");
        assertEq(position.positionDebt(positionId), 10e18, "debt view stays available while paused");
    }

    /// @notice Zero-address and zero/dust input guards across every user entrypoint.
    function test_RevertWhen_ZeroAndDustInputsOnEveryEntrypoint() external {
        sy.mintShares(alice, 10e18);
        vm.startPrank(alice);
        sy.approve(address(position), 10e18);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stakeForGenesis(0, alice, 42, 0);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stakeForGenesis(1e18, address(0), 42, 0);
        vm.stopPrank();

        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.previewStake(0);

        (uint256 positionId,) = _stakeTenSy(alice);
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.redeem(positionId, 0, alice, address(sy), 0);
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.redeem(positionId, 1e18, address(0), address(sy), 0);
    }

    /// @notice The minStake boundary: exactly the threshold passes, one wei below reverts.
    function test_MinStakeBoundaryIsInclusive() external {
        vm.prank(owner);
        position.setMinStake(1e18);

        sy.mintShares(alice, 1e18);
        vm.startPrank(alice);
        sy.approve(address(position), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.MinStakeInsufficient.selector, 1e18));
        position.stakeForGenesis(1e18 - 1, alice, 42, 0);
        uint256 positionId = position.stakeForGenesis(1e18, alice, 42, 0);
        vm.stopPrank();
        assertGt(positionId, 0, "exact-threshold stake succeeds");
        (,, uint256 principal,,) = position.positions(positionId);
        assertEq(principal, 1e18, "threshold stake mints at value parity");
    }

    /// @notice No third party can touch another borrower's position: without liquidation, a
    ///         stranger's only interaction with a live position is a read-only revert (redeem
    ///         denies) and zero value extraction — repeated with deep pockets.
    function test_StrangerCannotTouchLivePosition() external {
        (uint256 positionId,) = _stakeTenSy(alice);
        uAsset.mint(attacker, 1e24);
        vm.startPrank(attacker);
        uAsset.approve(address(position), 1e24);
        for (uint256 i = 0; i < 5; ++i) {
            vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
            position.redeem(positionId, 10e18, attacker, address(sy), 0);
        }
        vm.stopPrank();

        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(positionOwner, alice, "owner unchanged");
        assertEq(syStaked, 10e18, "collateral unchanged");
        assertEq(principalDebt, 10e18, "debt unchanged at value parity");
        assertEq(uAsset.balanceOf(attacker), 1e24, "attacker extracted nothing");
        assertEq(sy.balanceOf(attacker), 0, "attacker got no SY");
    }

    /// @notice The owner can always exit at face value through the SY path: redeeming the full
    ///         stake retires the exact value-parity debt and returns all collateral, even after
    ///         the rate moved (settlement is face-value, never re-priced).
    function test_OwnerAlwaysExitsAtFaceValue() external {
        (uint256 positionId, uint256 principal) = _stakeTenSy(alice);
        sy.setExchangeRate(0.94e18); // rate drop changes external value, not settlement
        assertEq(principal, 10e18, "value-parity principal");

        uAsset.mint(alice, principal);
        vm.startPrank(alice);
        uAsset.approve(address(position), principal);
        (uint256 burned, uint256 paid, uint256 syOut) = position.redeem(positionId, 10e18, alice, address(sy), 0);
        vm.stopPrank();

        assertEq(burned, principal, "principal leg exact");
        assertEq(paid, 0, "same-block exit carries no interest");
        assertEq(syOut, 10e18, "full collateral returned");
        assertEq(sy.balanceOf(alice), 10e18, "owner holds the collateral");
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, 0, "debt fully retired");
    }

    /// @notice An owner with insufficient balance (not allowance) fails atomically on the repay
    ///         leg and the position survives.
    function test_RevertWhen_RedeemerBalanceShortfallRevertsAtomically() external {
        (uint256 positionId,) = _stakeTenSy(alice);
        vm.startPrank(alice);
        uAsset.approve(address(position), type(uint256).max); // allowance fine, balance zero
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10e18));
        position.redeem(positionId, 10e18, alice, address(sy), 0);
        vm.stopPrank();

        (address positionOwner,,,,) = position.positions(positionId);
        assertEq(positionOwner, alice, "position survived the failed redeem");
        assertEq(sy.balanceOf(alice), 0, "no SY left the SP");
    }
}

/**
 * @title PositionReentrancyTest
 * @notice Reentrancy surface: a malicious SY that calls back from its transfer/transferFrom seam
 *         cannot nest a second position entrypoint (transient guard), and CEI holds — the
 *         position state is already applied/deleted when the repay legs run (probed inside the
 *         uAsset repay call).
 */
contract PositionReentrancyTest is CommonTestHelpers, PositionRefModel {
    bytes4 internal constant GUARD_SELECTOR = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE);
    address internal alice = address(0xA11CE1);

    MockERC20ForAdversarial internal underlying;
    ReentrantPositionSY internal sy;
    MockUAsset internal uAsset; // full mock: probes position state during repay
    OutrunStakingPositionUpgradeable internal position;
    MockGenesisLauncher internal genesisLauncher;

    // Absolute-timestamp tracker (same defensive pattern as the position suites: every warp goes
    // through this variable instead of the chain register).
    // `_warp`/`warpAt` provided by `CommonTestHelpers`

    function setUp() external {
        underlying = new MockERC20ForAdversarial("Mock Asset", "mAST");
        sy = new ReentrantPositionSY(address(underlying));
        uAsset = new MockUAsset();
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        uAsset.setMintingCap(address(position), type(uint256).max);
        uAsset.setMintingCap(address(this), type(uint256).max);
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
        // Genesis segment: the cumulative rate starts at RAY (1e27) at the init timestamp.
        _seedGenesisSegment(warpAt, SPTestDefaults.DUTY);
    }

    /// @notice Opens a 10e18-SY genesis position for `who` at the default rate.
    function _stakeTenSy(address who) internal returns (uint256 positionId, uint256 principal) {
        return _stakeTenSyForGenesis(address(sy), address(position), address(genesisLauncher), who);
    }

    /// @dev Asserts the recorded reentrancy attempt was blocked by the transient guard.
    function _assertReentrancyBlocked(string memory what) internal view {
        assertEq(sy.attempts(), 1, "exactly one reentrancy attempt fired");
        (bool ok, bytes memory revertData) = sy.attackOutcome();
        assertFalse(ok, what);
        assertGe(revertData.length, 4, "guard revert data present");
        // Casting to bytes4 is safe: the guard's custom error selector is the first 4 bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(revertData), GUARD_SELECTOR, "reentrant call blocked by the guard");
    }

    /// @notice Reentry from the SY pull during a genesis open is blocked; the outer open completes.
    function test_ReentrantGenesisOpenDuringSyPullIsBlocked() external {
        sy.mintShares(alice, 20e18);
        vm.startPrank(alice);
        sy.approve(address(position), 20e18);
        sy.arm(address(position), IOutrunStakeManager.stakeForGenesis.selector);
        uint256 positionId = position.stakeForGenesis(10e18, alice, 42, 0);
        vm.stopPrank();

        _assertReentrancyBlocked("nested genesis open must be blocked");
        assertGt(positionId, 0, "outer open completed");
        (,, uint256 principal,,) = position.positions(positionId);
        assertEq(principal, 10e18, "outer open minted at value parity");
        assertEq(position.idCounter(), 1, "only one position exists");
        assertEq(sy.balanceOf(address(position)), 10e18, "only the outer SY entered");
    }

    /// @notice Reentry from the SY payout during a full redeem is blocked, and CEI holds: the
    ///         position is already deleted when the repay leg runs (probed inside repay).
    function test_ReentrantRedeemDuringSyPayoutIsBlockedAndCeiHolds() external {
        (uint256 positionId, uint256 principal) = _stakeTenSy(alice);
        uAsset.probePositionDuringRepay(IOutrunStakeManager(address(position)), positionId);

        uAsset.mint(alice, principal);
        vm.startPrank(alice);
        uAsset.approve(address(position), principal);
        sy.arm(address(position), IOutrunStakeManager.redeem.selector);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, 10e18, alice, address(sy), 0);
        vm.stopPrank();

        _assertReentrancyBlocked("nested redeem must be blocked");
        assertEq(burned, principal, "outer redeem burned the principal");
        assertEq(paid, 0, "same-block redeem has no interest leg");
        (address positionOwner,,,,) = position.positions(positionId);
        assertEq(positionOwner, address(0), "position deleted by the outer redeem");
        // CEI evidence: when the repay leg executed, the position was already deleted.
        assertEq(uAsset.principalDebtDuringRepay(), 0, "position debt was applied before the repay leg");
    }

    /// @notice Reentry from the SY payout during a redeem that also carries a non-zero interest
    ///         leg is blocked: both debt legs complete before the output transfer fires.
    function test_ReentrantRedeemWithInterestLegIsBlocked() external {
        (uint256 positionId, uint256 principal) = _stakeTenSy(alice);
        _warp(20);
        // RAY compounding reference over the single segment (open at init, no duty change):
        // any non-zero leg exercises the interest-bearing payout path.
        uint256 interest = _refInterest(principal, _refUnit(warpAt) - RAY);
        uAsset.mint(alice, principal + interest);
        vm.startPrank(alice);
        uAsset.approve(address(position), principal + interest);
        sy.arm(address(position), IOutrunStakeManager.redeem.selector);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, 10e18, alice, address(sy), 0);
        vm.stopPrank();

        _assertReentrancyBlocked("nested redeem during an interest-bearing payout must be blocked");
        assertEq(burned, principal, "principal leg completed");
        assertEq(paid, interest, "interest leg completed");
    }

    /// @notice Reentry from the launcher window during a genesis open is blocked on every position
    ///      entrypoint; the launcher still consumes in full and the outer open completes with the
    ///      conservation assertions intact.
    function test_ReentrantStakeForGenesisDuringLauncherWindowIsBlocked() external {
        ReenteringGenesisLauncher launcher = new ReenteringGenesisLauncher(address(position), address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(launcher));
        uint256 spUAssetBefore = uAsset.balanceOf(address(position));

        sy.mintShares(alice, 10e18);
        vm.startPrank(alice);
        sy.approve(address(position), 10e18);
        uint256 positionId = position.stakeForGenesis(10e18, alice, 1, 0);
        vm.stopPrank();

        assertEq(launcher.firstFailure(), launcher.NO_FAILURE(), "reentrant entry was not blocked by the guard");
        assertEq(uAsset.balanceOf(address(position)), spUAssetBefore, "SP uAsset balance conserved");
        assertEq(uAsset.allowance(address(position), address(launcher)), 0, "launcher allowance fully consumed");
        (address positionOwner,,,,) = position.positions(positionId);
        assertEq(positionOwner, alice, "outer genesis open completed");
    }

    /// @notice A launcher that fully consumes but additionally donates its own pre-funded uAsset
    ///      into the SP inside the window pushes the balance above the pre-mint baseline: the
    ///      post-assertion fires on the balance dimension alone (the allowance is fully consumed)
    ///      and the whole open rolls back.
    function test_RevertWhen_LauncherDonatesUAssetDuringGenesisWindow() external {
        uint256 donated = 1e18;
        DonatingGenesisLauncher launcher = new DonatingGenesisLauncher(address(uAsset), donated);
        uAsset.mint(address(launcher), donated); // pre-fund from the test contract's minter record
        vm.prank(owner);
        position.setGenesisLauncher(address(launcher));
        uint256 supplyBefore = uAsset.totalSupply();
        uint256 spSyBefore = sy.balanceOf(address(position));

        sy.mintShares(alice, 10e18);
        vm.startPrank(alice);
        sy.approve(address(position), 10e18);
        vm.expectRevert(abi.encodeWithSelector(GenesisGateLib.GenesisUAssetNotConsumed.selector, donated, 0));
        position.stakeForGenesis(10e18, alice, 1, 0);
        vm.stopPrank();

        (address positionOwner,,,,) = position.positions(1);
        assertEq(positionOwner, address(0), "no position survived the rollback");
        assertEq(position.idCounter(), 0, "no position id was consumed");
        assertEq(uAsset.totalSupply(), supplyBefore, "the genesis mint rolled back with the call");
        assertEq(sy.balanceOf(address(position)), spSyBefore, "no SY stayed in the SP");
        assertEq(uAsset.balanceOf(address(launcher)), donated, "launcher kept exactly its pre-fund");
    }
}

/**
 * @title OracleFailClosedTest
 * @notice Oracle fail-closed on the real production read path: a Chainlink-style feed through
 *         the exchange-oracle adapter into a real L2 SY. When the feed goes stale, every pricing
 *         read of the position (previewStake, stakeForGenesis) reverts atomically with the
 *         adapter's StaleOracleAnswer, and no position is created from an unusable rate. The
 *         owner's SY-direct redeem exit never reads the rate and stays open.
 */
contract OracleFailClosedTest is CommonTestHelpers {
    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE);
    address internal alice = address(0xA11CE1);

    PositionMockToken internal token;
    MockAggregator internal feed;
    OutrunExchangeOracleAdapter internal adapter;
    OutrunL2StakedTokenSYUpgradeable internal sy;
    OutrunUniversalAssetsUpgradeable internal uAsset;
    OutrunStakingPositionUpgradeable internal position;

    function setUp() external {
        token = new PositionMockToken();
        feed = new MockAggregator(8);
        feed.setLatestAnswer(1e8); // 1.00 rate, fresh
        adapter = new OutrunExchangeOracleAdapter(address(feed), 1 hours, address(0), 0);
        sy = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("Oracle SY", "OSY", owner, address(token), address(adapter), address(token), 18)
                    )
                ))
        );
        uAsset = _deployUAsset(owner);
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        vm.startPrank(owner);
        uAsset.setMintingCap(address(position), type(uint256).max);
        vm.stopPrank();
        // Wire the launcher so the stale-rate revert (not the kill switch) is what fails the
        // pricing surface: the launcher gate intentionally runs before pricing.
        MockGenesisLauncher staleLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(staleLauncher));
    }

    /// @notice Deposits `amount` token 1:1 into SY for `who`.
    function _mintSy(address who, uint256 amount) internal {
        _mintSyFor(address(token), address(sy), who, amount);
    }

    /// @notice A stale feed fails the pricing surface closed.
    function test_RevertWhen_StaleFeedFailsStakeClosed() external {
        // Advance the clock first: the suite's initial timestamp is 1, so a naive subtraction
        // would underflow. A 2h-old round sits beyond the 1h staleness window.
        vm.warp(3 hours);
        feed.setLatestRoundData(1e8, 1 hours);
        vm.expectRevert(IExchangeRateOracle.StaleOracleAnswer.selector);
        position.previewStake(10e18);
        _mintSy(alice, 10e18);
        vm.startPrank(alice);
        sy.approve(address(position), 10e18);
        vm.expectRevert(IExchangeRateOracle.StaleOracleAnswer.selector);
        position.stakeForGenesis(10e18, alice, 42, 0);
        vm.stopPrank();
        assertEq(position.idCounter(), 0, "no position was created from a stale feed");
    }
}
