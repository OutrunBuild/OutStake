// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {GenesisGateLib} from "../../src/libraries/GenesisGateLib.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {
    MockGenesisLauncher,
    MockGenesisPartialLauncher,
    MockGenesisEmptyLauncher,
    MockGenesisTransferBackLauncher,
    MockGenesisRevertingLauncher
} from "./mocks/LauncherMocks.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";
import {PositionMockToken, PositionSettableOracle} from "./mocks/PositionMocks.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {CommonTestHelpers} from "./helpers/CommonTestHelpers.sol";
import {PositionRefModel} from "./helpers/PositionRefModel.sol";

/**
 * @title OutrunStakingPositionUpgradeableTest
 * @notice Behavioral matrix for the open-term CDP staking position: per-second virtual interest
 *         math against an independent reference implementation, value-parity minting
 *         (`stakeForGenesis` is the only mint entrypoint: minted debt equals the collateral value
 *         at the mint-time rate), the genesis physical gate (SP balance conservation, launcher
 *         hand-off, kill switch), two-leg redeem (principal burn + interest transfer), zero-fee
 *         duty semantics, the owner-governed parameter surface, the view family, and input guards.
 *         There is no liquidation, no LTV surface, and no free-borrowing entrypoint.
 * @dev Fixture: 18/18 decimals, MockSY rate default 1e18. Interest follows the RAY
 *      compounding closed form (`rmul(rpow(duty, dt), rate)`): the reference segment table
 *      (inherited from `PositionRefModel`, genesis segment starting at RAY) evaluates the
 *      same closed form as production, so every reference-computed interest value is
 *      wei-exact. Interest coverage (the uAsset a caller needs beyond minted principal) is funded
 *      from the test contract's own minter record, mirroring how real callers buy interest
 *      coverage on the open market — interest is circulating supply and is never minted by accrual.
 */
contract OutrunStakingPositionUpgradeableTest is CommonTestHelpers, PositionRefModel {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal other = address(0x0DD);
    address internal treasury = address(0xFEE);
    address internal newTreasury = address(0x7EE);

    uint256 internal constant DUTY = SPTestDefaults.DUTY;
    // Absolute duty cap (15% annual per-second RAY value); mirrors the production cap.
    uint256 internal constant DUTY_CAP = SPTestDefaults.DUTY_CAP;
    // Zero-fee sentinel duty (1e27): the v1 prod default; debt freezes and interest never accrues.
    uint256 internal constant ZERO_FEE_DUTY = SPTestDefaults.ZERO_FEE_DUTY;
    uint256 internal constant VERSE_ID = 42;
    uint256 internal constant MAX_UINT128 = type(uint128).max;

    MockERC20 internal underlying;
    MockSY internal sy;
    MockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    // Wired in setUp as the SP's genesis launcher; kill-switch tests rewire it per case.
    MockGenesisLauncher internal genesisLauncher;

    // `warpAt`/`_warp` provided by `CommonTestHelpers`.

    /// @notice Deploys the mock stack behind a proxy with the default parameter family.
    function setUp() external {
        underlying = new MockERC20("Underlying", "UND");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        position = _deployPosition(
            new OutrunStakingPositionUpgradeable(), owner, address(sy), address(uAsset), treasury, 1, DUTY
        );
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
        // The SP mints through its own record; the test contract's record funds interest coverage.
        uAsset.setMintingCap(address(position), type(uint128).max);
        uAsset.setMintingCap(address(this), type(uint128).max);
        // Genesis segment: the cumulative rate starts at RAY (1e27) at the init timestamp.
        _seedGenesisSegment(warpAt, DUTY);
    }

    // ==========================================================================
    // Section 1: interest math (virtual accrual, per-second reference comparison)
    // ==========================================================================

    // RAY compounding reference (`Segment`/`_refUnit`/`_refInterest`) is inherited from
    // `PositionRefModel`; `_setDuty` below keeps the segment table in sync with the
    // contract's segmented settlement, and `_secondsToAccrue` binary-searches the crossing.

    /// @notice First span in seconds at which the compounding reference interest on `principal`
    ///         (measured from the current reference unit) reaches `target`.
    /// @dev Binary search over the segment-table extrapolation, so long crossings (tens of
    ///      millions of seconds at the interest-test duty) resolve in ~60 reference evaluations
    ///      instead of a per-second walk. Callers invoke it at the opening timestamp so the
    ///      current reference unit equals the position snapshot.
    function _secondsToAccrue(uint256 principal, uint256 target) internal view returns (uint256 seconds_) {
        uint256 snap = _refUnit(warpAt);
        uint256 lo = 0;
        uint256 hi = 1;
        while (_refInterest(principal, _refUnit(warpAt + hi) - snap) < target) {
            hi *= 2;
        }
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_refInterest(principal, _refUnit(warpAt + mid) - snap) >= target) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    /// @notice Owner duty change that keeps the reference segment table in sync: settles pending
    ///         seconds at the old duty before the new duty applies, exactly like production.
    function _setDuty(uint256 newDuty) internal {
        vm.prank(owner);
        position.setDuty(newDuty);
        segments.push(Segment({startAt: warpAt, unitAtStart: _refUnit(warpAt), duty: newDuty}));
    }

    /// @notice Opens a genesis position for `who` at the given rate, returning the new id and the
    ///         value-parity minted amount read back from the position.
    function _stakeAtRate(address who, uint256 amountInSY, uint256 rate)
        internal
        returns (uint256 positionId, uint256 mintedUAsset)
    {
        sy.setExchangeRate(rate);
        sy.mintShares(who, amountInSY);
        vm.startPrank(who);
        sy.approve(address(position), amountInSY);
        positionId = position.stakeForGenesis(amountInSY, who, VERSE_ID, 0);
        vm.stopPrank();
        (,, uint256 principalDebt,,) = position.positions(positionId);
        mintedUAsset = principalDebt;
    }

    /// @notice Mints `amount` uAsset to `who` from the test's minter record and approves the SP.
    function _fundUAsset(address who, uint256 amount) internal {
        uAsset.mint(who, amount);
        vm.prank(who);
        uAsset.approve(address(position), amount);
    }

    /// @notice pendingInterest and positionDebt match the per-second reference at every warped
    ///         second, including a principal whose two-stage division actually truncates.
    function test_InterestMatchesReferenceEverySecond() external {
        // Rate 1e18+1 with 10e18 SY: collateral = 10e18+10, minted at value parity (odd, so the
        // staged floors leave non-zero remainders instead of dividing cleanly).
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18 + 1);
        assertEq(principal, 10e18 + 10, "odd principal fixture");

        uint256 settledUnitAtOpen = position.rate();
        uint256 openAt = warpAt;
        for (uint256 n = 1; n <= 30; ++n) {
            _warp(1);
            uint256 expected = _refInterest(principal, _refUnit(openAt + n) - settledUnitAtOpen);
            assertEq(position.pendingInterest(positionId), expected, "per-second pending interest");
            assertEq(position.positionDebt(positionId), principal + expected, "debt = principal + pending");
        }

        // Settlement through a full redeem books exactly the extrapolated amount.
        _warp(70); // 100 seconds total
        uint256 expectedInterest = _refInterest(principal, _refUnit(warpAt) - settledUnitAtOpen);
        (uint256 principalPortion, uint256 interestPortion,) = position.previewRedeem(positionId, 10e18, address(sy));
        assertEq(principalPortion, principal, "full redeem principal leg");
        assertEq(interestPortion, expectedInterest, "full redeem interest leg equals the reference");

        _fundUAsset(user, principal + expectedInterest);
        vm.startPrank(user);
        position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();
        // lastRate snapshotted the settled unit at open, so the settled span is exactly the
        // 100 post-open seconds.
        assertEq(position.rate(), _refUnit(warpAt), "rate advanced 100 seconds");
    }

    /// @notice A position opened N seconds after the last settlement touchpoint accrues nothing
    ///         for those N seconds: lastRate snapshots the settled unit at the opening second.
    function test_InterestAccruesFromOpenTimestampOnly() external {
        _warp(40);
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        (,,,, uint256 lastRateUnit) = position.positions(positionId);
        assertEq(lastRateUnit, _refUnit(warpAt), "open snapshots the settled unit");

        _warp(60);
        assertEq(
            position.pendingInterest(positionId),
            _refInterest(principal, _refUnit(warpAt) - lastRateUnit),
            "pre-open seconds produce no interest"
        );
    }

    /// @notice setDuty settles pending seconds at the old duty before the new duty applies;
    ///         interest over mixed segments equals the reference on the segment-table delta.
    function test_DutyChangesApplySegmented() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);

        _warp(40); // 40 seconds at the interest-test duty
        _setDuty(DUTY + 1e17); // raise the duty
        _warp(60); // 60 seconds at the raised duty
        _setDuty(DUTY); // back to the interest-test duty
        _warp(10); // 10 seconds at the interest-test duty

        assertEq(
            position.pendingInterest(positionId),
            _refInterest(principal, _refUnit(warpAt) - openSnap),
            "segmented accrual equals the reference on the segment-table delta"
        );
    }

    /// @notice Preview and execution agree in the same second: previewRedeem's legs equal redeem's
    ///         returned legs wei for wei.
    function test_PreviewMatchesExecutionSameSecond() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(33);
        uint256 expectedInterest = _refInterest(principal, _refUnit(warpAt) - openSnap);

        (uint256 principalPortion, uint256 interestPortion,) = position.previewRedeem(positionId, 10e18, address(sy));
        _fundUAsset(user, principal + expectedInterest);
        vm.startPrank(user);
        (uint256 burned, uint256 interestPaid, uint256 syOut) = position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();
        assertEq(burned, principalPortion, "principal leg preview == execution");
        assertEq(interestPaid, interestPortion, "interest leg preview == execution");
        assertEq(syOut, 10e18, "SY output preview == execution");
    }

    /// @notice Settlement touchpoints are idempotent within the same second, the stored rate
    ///         never moves backwards, and the view family extrapolates without writing.
    function test_RateSettlementIdempotentAndViewsDoNotWrite() external {
        (uint256 positionId,) = _stakeAtRate(user, 10e18, 1e18);
        uint256 unitAfterStake = position.rate();
        _warp(25);

        uint256 extrapolated = position.currentRate();
        assertEq(extrapolated, _refUnit(warpAt), "currentRate extrapolates");
        // Read-only family must not move the stored settlement state.
        position.pendingInterest(positionId);
        position.positionDebt(positionId);
        assertEq(position.rate(), unitAfterStake, "views left rate untouched");

        // Multiple write touchpoints in the same second settle once (delta == 0 is a no-op).
        _setDuty(DUTY + 1e17);
        _setDuty(DUTY);
        assertEq(position.rate(), extrapolated, "same-second touchpoints settle exactly once");
        assertEq(position.rateLastSettledAt(), warpAt, "last-settled timestamp tracks the touchpoint");
        assertEq(position.currentRate(), position.rate(), "no pending extrapolation in-second");
    }

    /// @notice Interest is simple: booked accrued interest never compounds, and interest is linear
    ///         in the principal up to the single floor loss (at most 1 wei).
    function test_SimpleInterestNoCompoundingAndLinearInPrincipal() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(10);
        uint256 booked = _refInterest(principal, _refUnit(warpAt) - openSnap);

        // Book the accrued interest with a small partial redeem (10%), then accrue more: the new
        // pending amount runs on the reduced principal only — the booked balance never capitalizes.
        // The caller funds repay cover from its own record (the genesis mint went to the launcher).
        _fundUAsset(user, principal);
        vm.startPrank(user);
        position.redeem(positionId, 1e18, user, address(sy), 0);
        vm.stopPrank();
        (,,, uint256 accruedAfter,) = position.positions(positionId);
        assertEq(
            accruedAfter, booked - SPTestDefaults.ceilDiv(booked, 10), "partial redeem settled then reduced accrued"
        );

        (,, uint256 newPrincipal,, uint256 redeemSnap) = position.positions(positionId);
        _warp(10);
        // The view returns only the unsettled increment accrued since the redeem settlement,
        // running on the reduced principal; the settled balance never compounds.
        assertEq(
            position.pendingInterest(positionId),
            _refInterest(newPrincipal, _refUnit(warpAt) - redeemSnap),
            "post-partial accrual runs on the reduced principal only"
        );

        // Linearity on-chain: doubling the collateral doubles the interest within 1 wei of the floor.
        (uint256 singleId,) = _stakeAtRate(other, 10e18, 1e18);
        (uint256 doubledId,) = _stakeAtRate(other, 20e18, 1e18);
        _warp(1);
        uint256 singleInterest = position.pendingInterest(singleId);
        uint256 doubledInterest = position.pendingInterest(doubledId);
        assertLe(doubledInterest, 2 * singleInterest + 1, "interest at most doubles (plus floor dust)");
        assertGe(doubledInterest, 2 * singleInterest - 1, "interest at least doubles (minus floor dust)");
    }

    /// @notice previewStake quotes exactly what stakeForGenesis mints in the same block: both run
    ///         the shared value-parity path, so the quote-actual pair cannot drift even at a
    ///         non-identity rate.
    function test_PreviewStakeMatchesStakeMintSameBlock() external {
        sy.setExchangeRate(1e18 + 7); // non-identity rate so the staged floor chain actually runs
        uint256 quote = position.previewStake(10e18);
        assertGt(quote, 0, "fixture is above the dust threshold");

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        uint256 positionId = position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();
        (,, uint256 minted,,) = position.positions(positionId);
        assertEq(minted, quote, "genesis minted exactly the quoted amount");
    }

    /// @notice currentRate is exactly the value the next settlement touchpoint will store: the
    ///         view extrapolation and the settling write share one closed form, so they cannot drift.
    function test_CurrentRateEqualsNextSettlementValue() external {
        (uint256 positionId,) = _stakeAtRate(user, 10e18, 1e18);
        uint256 unitAtOpen = position.rate();
        assertEq(position.currentRate(), unitAtOpen, "no pending increment in the opening second");

        _warp(37);
        uint256 extrapolated = position.currentRate();
        assertEq(extrapolated, _refUnit(warpAt), "extrapolation matches the reference closed form");

        // A settlement touchpoint at this exact timestamp stores precisely the extrapolated value,
        // and the position's pending interest was quoted off that same value all along.
        _setDuty(DUTY + 1e17); // settles under the old duty, then applies the new
        assertEq(position.rate(), extrapolated, "settlement stored the extrapolated value");
        assertEq(position.currentRate(), position.rate(), "view and storage re-converge in-second");

        // The next segment runs at the raised duty and the equality survives a second touchpoint.
        _warp(3);
        uint256 nextExtrapolated = position.currentRate();
        assertEq(nextExtrapolated, _refUnit(warpAt), "new-duty segment extrapolates");
        _setDuty(DUTY); // settles under the raised duty first
        assertEq(position.rate(), nextExtrapolated, "second touchpoint stored the same value");
        (,,,, uint256 lastRateUnit) = position.positions(positionId);
        assertEq(lastRateUnit, unitAtOpen, "position snapshot untouched by SP-level settlements");
    }

    // ==========================================================================
    // Section 1.5: value-parity mint (no LTV scaling segment)
    // ==========================================================================

    /// @notice Value parity, not unit parity: at a 1.15 rate, 1 SY mints 1.15 uAsset.
    function test_ValueParityMintScalesWithExchangeRate() external {
        (uint256 positionId, uint256 minted) = _stakeAtRate(user, 1e18, 1.15e18);
        assertEq(minted, 1.15e18, "1 SY at 1.15 mints 1.15 uAsset");
        (,, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(principalDebt, minted, "principal debt equals the minted amount");
    }

    /// @notice Backing invariant at mint: principalDebt <= syStaked x rate, enforced by the two
    ///         floors even when the collateral value does not divide cleanly.
    function test_MintDebtNeverExceedsCollateralValue() external {
        (uint256 positionId, uint256 minted) = _stakeAtRate(user, 10e18, 1e18 + 1);
        assertEq(minted, 10e18 + 10, "two-stage floor mint");
        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(positionOwner, user, "position owner");
        assertEq(syStaked, 10e18, "collateral recorded");
        assertLe(principalDebt, syStaked * (1e18 + 1) / 1e18, "mint-time backing invariant");
    }

    // ==========================================================================
    // Section 1.6: stakeForGenesis (only mint entrypoint, behind the physical gate)
    // ==========================================================================

    /// @notice Happy path: the genesis open mints at value parity and hands the mint to the
    ///         launcher in full — the SP's uAsset balance is conserved (identical before and after
    ///         the call), the launcher allowance is fully consumed, and the minter ledger records
    ///         the mint like any other mint.
    function test_StakeForGenesisRoundtripPhysicalGate() external {
        uint256 amountInSY = 10e18;
        uint256 expectedMinted = 10e18; // value parity at the 1e18 identity rate
        uint256 spUAssetBefore = uAsset.balanceOf(address(position));
        (, uint256 amountInMintedBefore) = uAsset.mintingStatusTable(address(position));

        sy.mintShares(user, amountInSY);
        vm.startPrank(user);
        sy.approve(address(position), amountInSY);
        vm.expectEmit(true, true, false, true);
        emit IOutrunStakeManager.Stake(1, user, amountInSY, expectedMinted);
        vm.expectEmit(true, true, false, true);
        emit IOutrunStakeManager.StakeForGenesis(1, user, VERSE_ID, expectedMinted);
        uint256 positionId = position.stakeForGenesis(amountInSY, user, VERSE_ID, expectedMinted);
        vm.stopPrank();

        (
            address positionOwner,
            uint256 syStaked,
            uint256 principalDebt,
            uint256 accruedInterest,
            uint256 lastRateUnit
        ) = position.positions(positionId);
        assertEq(positionOwner, user, "genesisUser owns the position");
        assertEq(syStaked, amountInSY, "SY collateral recorded");
        assertEq(principalDebt, expectedMinted, "principal debt equals the minted uAsset");
        assertEq(accruedInterest, 0, "fresh position has no settled interest");
        assertEq(lastRateUnit, position.rate(), "lastRate snapshot settled at the opening block");
        assertEq(sy.balanceOf(user), 0, "caller paid the staked SY");
        assertEq(sy.balanceOf(address(position)), amountInSY, "SP holds the staked SY");
        assertEq(uAsset.balanceOf(user), 0, "the mint never reaches the position owner");

        // Conservation assertion: the SP's uAsset balance is identical before and after the call
        // (mint -> launcher consumption closes within the transaction).
        assertEq(uAsset.balanceOf(address(position)), spUAssetBefore, "SP uAsset balance conserved");
        assertEq(uAsset.allowance(address(position), address(genesisLauncher)), 0, "launcher allowance fully consumed");
        (, uint256 amountInMintedAfter) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMintedAfter - amountInMintedBefore, expectedMinted, "minter ledger records the genesis mint");
        (uint256 lastVerseId, uint128 lastAmount, address lastUser) = genesisLauncher.snapshot();
        assertEq(lastVerseId, VERSE_ID, "verseId forwarded unchanged");
        assertEq(lastAmount, uint128(expectedMinted), "launcher received uint128(minted)");
        assertEq(lastUser, user, "genesis user credited");
        assertEq(uAsset.balanceOf(address(genesisLauncher)), expectedMinted, "launcher holds exactly the minted amount");
    }

    /// @notice Pre-donated uAsset dust on the SP stays outside the post-assertion domain: the
    ///         gate asserts a return to the pre-mint baseline, not to zero, so a fully consumed
    ///         genesis succeeds while the SP still holds the dust.
    function test_StakeForGenesisDustExcludedFromPostAssertion() external {
        uint256 dust = 123;
        uAsset.mint(address(position), dust); // donated from the test contract's minter record
        uint256 spUAssetBefore = uAsset.balanceOf(address(position));
        assertEq(spUAssetBefore, dust, "dust fixture");

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(position)), spUAssetBefore, "balance back at the dust baseline");
    }

    /// @notice The launcher gate is the kill switch: the zero default disables the entrypoint and
    ///         an owner reset to zero re-disables it, both before any funds move.
    function test_RevertWhen_StakeForGenesisLauncherNotSet() external {
        vm.prank(owner);
        position.setGenesisLauncher(address(0));

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        vm.expectRevert(IOutrunStakeManager.GenesisLauncherNotSet.selector);
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();

        assertEq(sy.balanceOf(address(position)), 0, "no SY entered on the rejected entry");
        assertEq(position.idCounter(), 0, "no position was created");

        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
        vm.prank(user);
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        assertEq(position.idCounter(), 1, "rewired launcher re-enables the entry");
    }

    /// @notice Zero SY amount, zero owner, and a below-minStake amount are all rejected before
    ///         any funds move.
    function test_RevertWhen_StakeForGenesisZeroAndMinStakeInputs() external {
        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stakeForGenesis(0, user, VERSE_ID, 0);
        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stakeForGenesis(10e18, address(0), VERSE_ID, 0);

        vm.prank(owner);
        position.setMinStake(5e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.MinStakeInsufficient.selector, 5e18));
        position.stakeForGenesis(5e18 - 1, user, VERSE_ID, 0);
        _assertGenesisRevertedCleanly();
    }

    /// @notice Dust that floors the mint to zero is rejected — no zero-debt position is created
    ///         (minStake 1 admits the 1-wei fixture at rate 1e18).
    function test_RevertWhen_StakeForGenesisDustRoundsToZero() external {
        sy.setExchangeRate(1e18 - 1); // floor(1 x (1e18-1) / 1e18) = 0
        sy.mintShares(user, 1);
        vm.startPrank(user);
        sy.approve(address(position), 1);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        position.stakeForGenesis(1, user, VERSE_ID, 0);
        vm.stopPrank();
        _assertGenesisRevertedCleanly();
    }

    /// @notice The caller's floor: a mint below `minUAssetMinted` reverts with the actual/minimum
    ///         payload before any SY moves or a position is written.
    function test_RevertWhen_StakeForGenesisBelowMinUAssetMinted() external {
        uint256 minted = 10e18;
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunStakeManager.InsufficientUAssetMinted.selector, minted, minted + 1)
        );
        position.stakeForGenesis(10e18, user, VERSE_ID, minted + 1);
        _assertGenesisRevertedCleanly();
    }

    /// @notice A mint above the launcher's uint128 domain reverts InvalidParam before the SY
    ///         transfer and before any allowance is granted.
    function test_RevertWhen_StakeForGenesisMintsAboveUint128Max() external {
        uint256 amountInSY = MAX_UINT128 + 1; // value parity: minted == amountInSY at the identity rate
        sy.mintShares(user, amountInSY);
        vm.startPrank(user);
        sy.approve(address(position), amountInSY);
        vm.expectRevert(IOutrunStakeManager.InvalidParam.selector);
        position.stakeForGenesis(amountInSY, user, VERSE_ID, 0);
        vm.stopPrank();
        _assertGenesisRevertedCleanly();
    }

    /// @notice A mint of exactly type(uint128).max passes the bound and is forwarded in full.
    function test_StakeForGenesisAtUint128MaxSucceeds() external {
        uint256 amountInSY = MAX_UINT128; // value parity at the identity rate
        sy.mintShares(user, amountInSY);
        vm.startPrank(user);
        sy.approve(address(position), amountInSY);
        uint256 positionId = position.stakeForGenesis(amountInSY, user, VERSE_ID, MAX_UINT128);
        vm.stopPrank();

        (,, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(principalDebt, MAX_UINT128, "principal debt equals exactly the uint128 cap");
        (, uint128 lastAmount,) = genesisLauncher.snapshot();
        assertEq(lastAmount, type(uint128).max, "launcher received exactly the uint128 cap");
    }

    /// @notice A launcher consuming only half trips the post-assertion with both residual
    ///         dimensions (balance and allowance) and the whole transaction reverts: no position,
    ///         no mint, no SY pull.
    function test_RevertWhen_StakeForGenesisLauncherConsumesHalf() external {
        MockGenesisPartialLauncher partialLauncher = new MockGenesisPartialLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(partialLauncher));
        uint256 minted = 10e18;

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisGateLib.GenesisUAssetNotConsumed.selector,
                minted / 2, // residual balance over the pre-mint baseline
                minted / 2 // residual allowance left untouched by the half pull
            )
        );
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();
        _assertGenesisRevertedCleanly();
    }

    /// @notice A launcher that consumes none of the approved uAsset trips the post-assertion with
    ///         both residual dimensions at the full minted amount (the balance never leaves and
    ///         the allowance is untouched) and rolls everything back.
    function test_RevertWhen_StakeForGenesisLauncherConsumesNothing() external {
        // Create the launcher first: a `new` inside the call arguments would consume the prank.
        MockGenesisEmptyLauncher emptyLauncher = new MockGenesisEmptyLauncher();
        vm.prank(owner);
        position.setGenesisLauncher(address(emptyLauncher));
        uint256 minted = 10e18;

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        vm.expectRevert(abi.encodeWithSelector(GenesisGateLib.GenesisUAssetNotConsumed.selector, minted, minted));
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();
        _assertGenesisRevertedCleanly();
    }

    /// @notice A launcher that pulls in full and transfers part back trips the balance dimension
    ///         (the allowance is fully consumed).
    function test_RevertWhen_StakeForGenesisLauncherTransfersBack() external {
        MockGenesisTransferBackLauncher transferBackLauncher = new MockGenesisTransferBackLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(transferBackLauncher));
        uint256 minted = 10e18;

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        vm.expectRevert(abi.encodeWithSelector(GenesisGateLib.GenesisUAssetNotConsumed.selector, minted / 10, 0));
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();
        _assertGenesisRevertedCleanly();
    }

    /// @notice A launcher-side revert is a dependency boundary: it rolls the whole transaction
    ///         back with the launcher's own error and leaves no position and no mint behind.
    function test_StakeForGenesisRollsBackWhenLauncherReverts() external {
        MockGenesisRevertingLauncher revertingLauncher = new MockGenesisRevertingLauncher();
        vm.prank(owner);
        position.setGenesisLauncher(address(revertingLauncher));

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        vm.expectRevert(MockGenesisRevertingLauncher.GenesisLauncherReverted.selector);
        position.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();
        _assertGenesisRevertedCleanly();
    }

    // ==========================================================================
    // Section 2: redeem (two-leg debt repayment)
    // ==========================================================================

    /// @notice A full redeem splits the repayment exactly: the interest leg only moves circulating
    ///         uAsset to the treasury, the principal leg burns and clears the minter ledger, and
    ///         the position is deleted.
    function test_RedeemFullPaysTwoLegsExactly() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(100);
        uint256 expectedInterest = _refInterest(principal, _refUnit(warpAt) - openSnap);

        _fundUAsset(user, principal + expectedInterest);
        uint256 supplyAfterFunding = uAsset.totalSupply();

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit IOutrunStakeManager.Redeem(positionId, user, 10e18, principal, expectedInterest, user, address(sy), 10e18);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();

        assertEq(burned, principal, "principal leg equals the whole principal");
        assertEq(paid, expectedInterest, "interest leg equals the settled interest");
        assertEq(uAsset.balanceOf(treasury), expectedInterest, "treasury received the interest leg");
        // Only the burn shrinks supply: the interest leg is a pure holder-to-holder transfer.
        assertEq(uAsset.totalSupply(), supplyAfterFunding - principal, "supply shrank by the burn only");
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, 0, "minter ledger cleared by the principal leg");

        (address positionOwner, uint256 syStaked, uint256 principalDebt, uint256 accrued, uint256 lastUnit) =
            position.positions(positionId);
        assertEq(positionOwner, address(0), "full redeem deletes the position");
        assertEq(syStaked, 0, "deleted position collateral");
        assertEq(principalDebt, 0, "deleted position principal");
        assertEq(accrued, 0, "deleted position accrued");
        assertEq(lastUnit, 0, "deleted position snapshot");
    }

    /// @notice A partial redeem ceils both legs pro-rata and leaves a live position that keeps
    ///         accruing on the reduced principal.
    function test_RedeemPartialCeilsBothLegs() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(50);
        uint256 settledInterest = _refInterest(principal, _refUnit(warpAt) - openSnap);

        uint256 syRedeemed = 3e18; // 30% partial
        uint256 expectedPrincipal = SPTestDefaults.ceilDiv(principal * syRedeemed, 10e18);
        uint256 expectedInterest = SPTestDefaults.ceilDiv(settledInterest * syRedeemed, 10e18);
        (uint256 quotedPrincipal, uint256 quotedInterest,) = position.previewRedeem(positionId, syRedeemed, address(sy));
        assertEq(quotedPrincipal, expectedPrincipal, "ceiled principal quote");
        assertEq(quotedInterest, expectedInterest, "ceiled interest quote");

        _fundUAsset(user, expectedPrincipal + expectedInterest);
        vm.startPrank(user);
        (uint256 burned, uint256 paid, uint256 syOut) = position.redeem(positionId, syRedeemed, user, address(sy), 0);
        vm.stopPrank();
        assertEq(burned, expectedPrincipal, "partial principal leg");
        assertEq(paid, expectedInterest, "partial interest leg");
        assertEq(syOut, syRedeemed, "partial SY output");
        assertEq(uAsset.balanceOf(treasury), expectedInterest, "treasury received the partial interest");

        (address positionOwner, uint256 syStaked, uint256 principalDebt, uint256 liveAccrued, uint256 redeemSnap) =
            position.positions(positionId);
        assertEq(positionOwner, user, "partial redeem keeps the position alive");
        assertEq(syStaked, 7e18, "collateral reduced by the redeemed share");
        assertEq(principalDebt, principal - expectedPrincipal, "principal reduced by the ceiled leg");
        assertGt(principalDebt, 0, "partial redeem leaves debt");

        _warp(20);
        // pendingInterest is only the unsettled increment since the redeem settlement, running on
        // the reduced principal (the settled residual never compounds).
        uint256 pending = position.pendingInterest(positionId);
        assertEq(
            pending,
            _refInterest(principalDebt, _refUnit(warpAt) - redeemSnap),
            "interest continues on the reduced principal"
        );

        // Debt counts the settled residual and the unsettled increment exactly once. Only a
        // settlement moves principal/accrued, so the fields captured above are still live here.
        uint256 debt = position.positionDebt(positionId);
        assertEq(debt, principalDebt + liveAccrued + pending, "debt = principal + settled interest + pending increment");
    }

    /// @notice A partial redeem whose ceiled principal leg would consume the whole principal is
    ///         rejected (both executor and preview).
    function test_RevertWhen_PartialRedeemExhaustsPrincipal() external {
        // Sub-par rate: principal (10e18 - 10) sits below the staked SY, so a near-full partial
        // ceils onto the whole principal and must go through a full redeem instead.
        (uint256 positionId,) = _stakeAtRate(user, 10e18, 1e18 - 1);
        uint256 syRedeemed = 10e18 - 1;
        vm.expectRevert(IOutrunStakeManager.PartialRedeemMustLeaveDebt.selector);
        position.previewRedeem(positionId, syRedeemed, address(sy));
        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.PartialRedeemMustLeaveDebt.selector);
        position.redeem(positionId, syRedeemed, user, address(sy), 0);
    }

    /// @notice Only the recorded owner may redeem; missing positions are denied the same way.
    function test_RevertWhen_NonOwnerOrMissingPositionRedeems() external {
        (uint256 positionId,) = _stakeAtRate(user, 10e18, 1e18);
        vm.prank(other);
        vm.expectRevert(IOutrunStakeManager.PositionAccessDenied.selector);
        position.redeem(positionId, 1e18, other, address(sy), 0);
        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.PositionAccessDenied.selector);
        position.redeem(positionId + 100, 1e18, user, address(sy), 0);
    }

    /// @notice Zero and over-sized redeem inputs are rejected with the exact payload.
    function test_RevertWhen_RedeemZeroOrExcessInputs() external {
        (uint256 positionId,) = _stakeAtRate(user, 10e18, 1e18);
        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.redeem(positionId, 0, user, address(sy), 0);
        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.redeem(positionId, 1e18, address(0), address(sy), 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.ExceedsPositionBalance.selector, 10e18 + 1, 10e18));
        position.redeem(positionId, 10e18 + 1, user, address(sy), 0);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.ExceedsPositionBalance.selector, 11e18, 10e18));
        position.previewRedeem(positionId, 11e18, address(sy));
    }

    /// @notice Direct SY output enforces minTokenOut locally; other tokens go through SY.redeem.
    ///         The direct-SY path never reads the exchange rate.
    function test_RedeemTokenOutPathsAndSlippage() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        _fundUAsset(user, principal);
        vm.startPrank(user);

        // Underlying output routes through SY.redeem 1:1 in this mock.
        (,, uint256 tokenOut) = position.redeem(positionId, 4e18, other, address(underlying), 4e18);
        vm.stopPrank();
        assertEq(tokenOut, 4e18, "adapter output amount");
        assertEq(underlying.balanceOf(other), 4e18, "receiver got the underlying");
        assertEq(sy.balanceOf(address(position)), 6e18, "remaining collateral stays staked");

        // Direct SY output below the caller's minimum reverts with the local error.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.InsufficientTokenOut.selector, 1e18, 2e18));
        position.redeem(positionId, 1e18, user, address(sy), 2e18);

        // The direct-SY exit works even when the rate feed is broken: no rate is read.
        sy.setExchangeRate(0);
        vm.prank(user);
        (,, uint256 syOut) = position.redeem(positionId, 1e18, user, address(sy), 0);
        assertEq(syOut, 1e18, "SY exit is oracle-independent");
    }

    /// @notice A shared-allowance shortfall on either leg reverts the whole redeem atomically.
    function test_RevertWhen_RedeemAllowanceShortfallRevertsAtomically() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(20);
        uint256 interest = _refInterest(principal, _refUnit(warpAt) - openSnap);
        _fundUAsset(user, interest); // balance covers everything, allowance will not

        vm.startPrank(user);
        uAsset.approve(address(position), principal); // the interest leg consumes part of it first
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(position), principal - interest, principal
            )
        );
        position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();

        // Nothing moved: position intact, treasury empty, ledger unchanged.
        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(positionOwner, user, "position survived the failed redeem");
        assertEq(syStaked, 10e18, "collateral untouched");
        assertEq(principalDebt, principal, "principal untouched");
        assertEq(uAsset.balanceOf(treasury), 0, "treasury received nothing");
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, principal, "minter ledger untouched");
    }

    /// @notice A zero interest leg skips its transfer entirely — approving exactly the principal
    ///         is enough for a same-block full redeem.
    function test_RedeemSkipsZeroInterestLeg() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        _fundUAsset(user, principal); // principal cover only: no interest balance at all
        vm.startPrank(user);
        (uint256 burned, uint256 paid,) = position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();
        assertEq(burned, principal, "principal leg burned");
        assertEq(paid, 0, "zero interest leg skipped");
        assertEq(uAsset.allowance(user, address(position)), 0, "whole allowance consumed by the burn leg");
    }

    // ==========================================================================
    // Section 3: duty domain (zero-fee sentinel, sub-RAY rejection, cap)
    // ==========================================================================

    /// @notice Zero-fee semantics: at duty 1e27 the rate never advances, pending interest stays
    ///         zero across warps, and redeem carries no interest leg.
    function test_ZeroFeeDutyFreezesRateAndInterest() external {
        OutrunStakingPositionUpgradeable zeroFeePosition = _deployPosition(
            new OutrunStakingPositionUpgradeable(), owner, address(sy), address(uAsset), treasury, 1, ZERO_FEE_DUTY
        );
        vm.prank(owner);
        zeroFeePosition.setGenesisLauncher(address(genesisLauncher));
        uAsset.setMintingCap(address(zeroFeePosition), type(uint128).max);

        sy.mintShares(user, 10e18);
        vm.startPrank(user);
        sy.approve(address(zeroFeePosition), 10e18);
        uint256 positionId = zeroFeePosition.stakeForGenesis(10e18, user, VERSE_ID, 0);
        vm.stopPrank();

        _warp(365 days);
        assertEq(zeroFeePosition.rate(), 1e27, "zero-fee rate never advances");
        assertEq(zeroFeePosition.currentRate(), 1e27, "extrapolation equals the frozen rate");
        assertEq(zeroFeePosition.pendingInterest(positionId), 0, "no pending interest under zero fee");
        (,, uint256 principalDebt, uint256 accruedInterest,) = zeroFeePosition.positions(positionId);
        assertEq(principalDebt, 10e18, "principal frozen");
        assertEq(accruedInterest, 0, "nothing settled");

        uAsset.mint(user, principalDebt);
        vm.startPrank(user);
        uAsset.approve(address(zeroFeePosition), principalDebt);
        (uint256 burned, uint256 paid,) = zeroFeePosition.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();
        assertEq(burned, principalDebt, "principal leg exact");
        assertEq(paid, 0, "interest leg identically zero");
        assertEq(uAsset.balanceOf(treasury), 0, "treasury received nothing");
    }

    /// @notice setDuty accepts the zero-fee sentinel: moving an interest-bearing SP to 1e27
    ///         freezes the rate from the change second on, with prior seconds settled at the old
    ///         duty.
    function test_SetDutyAcceptsZeroFeeSentinel() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(10);
        uint256 interestBefore = _refInterest(principal, _refUnit(warpAt) - openSnap);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IOutrunStakeManager.SetDuty(DUTY, ZERO_FEE_DUTY);
        position.setDuty(ZERO_FEE_DUTY);
        assertEq(position.duty(), ZERO_FEE_DUTY, "zero-fee sentinel accepted");

        _warp(1000);
        assertEq(position.rate(), _refUnit(warpAt - 1000), "rate frozen at the change second");
        assertEq(position.pendingInterest(positionId), interestBefore, "no post-change accrual");
    }

    /// @notice setDuty is directly settable within the 15% cap; the RAY sentinel is legal now.
    function test_SetDutyCapAndDirectSet() external {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.DutyCap.selector, DUTY_CAP + 1));
        position.setDuty(DUTY_CAP + 1);
        vm.expectEmit(false, false, false, true);
        emit IOutrunStakeManager.SetDuty(DUTY, DUTY_CAP);
        position.setDuty(DUTY_CAP); // direct jump to the cap is legal
        vm.expectEmit(false, false, false, true);
        emit IOutrunStakeManager.SetDuty(DUTY_CAP, ZERO_FEE_DUTY);
        position.setDuty(ZERO_FEE_DUTY); // the zero-fee sentinel is legal
        vm.stopPrank();
        assertEq(position.duty(), ZERO_FEE_DUTY, "sentinel set");
    }

    /// @notice Duty lower-bound rejection: the whole sub-RAY range (zero input through RAY - 1,
    ///         i.e. the negative-rate domain) reverts; RAY itself is the legal zero-fee sentinel,
    ///         the smallest duty above RAY stays accepted, and rejected sets change nothing (pause
    ///         is the circuit breaker, not a negative rate).
    function test_RevertWhen_DutySubRay() external {
        uint256 dutyBefore = position.duty();
        vm.startPrank(owner);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.setDuty(0);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.setDuty(1);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.setDuty(1e27 - 1);
        vm.stopPrank();
        assertEq(position.duty(), dutyBefore, "rejected sub-RAY sets change nothing");
        vm.prank(owner);
        position.setDuty(1e27);
        assertEq(position.duty(), 1e27, "zero-fee sentinel accepted");
        vm.prank(owner);
        position.setDuty(1e27 + 1);
        assertEq(position.duty(), 1e27 + 1, "smallest above-sentinel duty accepted");
        vm.prank(owner);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.setDuty(1e27 - 1);
        assertEq(position.duty(), 1e27 + 1, "rejected sets change nothing");
    }

    /// @notice Initialize enforces the same duty domain as the setter: sub-RAY reverts, the RAY
    ///         sentinel deploys (covers the init path via the existing proxy-deploy fixture), and
    ///         the smallest duty above RAY deploys.
    function test_InitializeDutyDomain() external {
        OutrunStakingPositionUpgradeable impl = new OutrunStakingPositionUpgradeable();
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, 0);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, 1);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, 1e27 - 1);
        OutrunStakingPositionUpgradeable zeroFee =
            _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, 1e27);
        assertEq(zeroFee.duty(), 1e27, "zero-fee sentinel initializes");
        OutrunStakingPositionUpgradeable aboveFloor =
            _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, 1e27 + 1);
        assertEq(aboveFloor.duty(), 1e27 + 1, "smallest above-sentinel duty initializes");
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.DutyCap.selector, DUTY_CAP + 1));
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, DUTY_CAP + 1);
    }

    /// @notice Over a full-year window the compounding extrapolation matches the reference
    ///         closed form exactly and long-window interest is positive.
    function test_DutyLongWindowAccruesPositive() external {
        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(365 days); // one full year at the interest-test duty
        assertEq(position.currentRate(), _refUnit(warpAt), "year-long extrapolation matches the reference");
        uint256 pending = position.pendingInterest(positionId);
        assertGt(pending, 0, "long-window interest is positive");
        assertEq(
            pending, _refInterest(principal, _refUnit(warpAt) - openSnap), "year-long interest matches the reference"
        );
    }

    /// @notice setGenesisLauncher accepts any address including zero and emits the old/new pair;
    ///         zero is the legal kill-switch state that disables the entrypoint.
    function test_SetGenesisLauncherAcceptsAnyAddressIncludingZero() external {
        assertEq(position.genesisLauncher(), address(genesisLauncher), "launcher wired in setUp");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IOutrunStakeManager.SetGenesisLauncher(address(genesisLauncher), address(0));
        position.setGenesisLauncher(address(0));
        vm.stopPrank();
        assertEq(position.genesisLauncher(), address(0), "zero re-disables the entrypoint");
    }

    /// @notice setMinStake is bidirectional above zero and gates both stakeForGenesis and previewStake.
    function test_SetMinStakeGatesStakeBidirectionally() external {
        vm.startPrank(owner);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.setMinStake(0);
        vm.expectEmit(false, false, false, true);
        emit IOutrunStakeManager.SetMinStake(5e18);
        position.setMinStake(5e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.MinStakeInsufficient.selector, 5e18));
        position.previewStake(5e18 - 1);
        sy.mintShares(user, 5e18 - 1);
        vm.startPrank(user);
        sy.approve(address(position), 5e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.MinStakeInsufficient.selector, 5e18));
        position.stakeForGenesis(5e18 - 1, user, VERSE_ID, 0);
        vm.stopPrank();

        vm.prank(owner);
        position.setMinStake(1);
        (, uint256 minted) = _stakeAtRate(user, 1e18, 1e18);
        assertEq(minted, 1e18, "lowered threshold re-allows small stakes at value parity");
    }

    /// @notice setProtocolTreasury redirects subsequent interest legs.
    function test_SetProtocolTreasuryRedirectsInterestLegs() external {
        vm.prank(owner);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.setProtocolTreasury(address(0));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IOutrunStakeManager.SetProtocolTreasury(newTreasury);
        position.setProtocolTreasury(newTreasury);

        (uint256 positionId, uint256 principal) = _stakeAtRate(user, 10e18, 1e18);
        uint256 openSnap = _refUnit(warpAt);
        _warp(10);
        uint256 interest = _refInterest(principal, _refUnit(warpAt) - openSnap);
        _fundUAsset(user, principal + interest);
        vm.startPrank(user);
        position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();
        assertEq(uAsset.balanceOf(treasury), 0, "old treasury bypassed");
        assertEq(uAsset.balanceOf(newTreasury), interest, "new treasury received the interest leg");
    }

    /// @notice Every setter and the circuit breaker are owner-only.
    function test_RevertWhen_NonOwnerCallsSetters() external {
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        position.setDuty(DUTY);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        position.setGenesisLauncher(other);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        position.setMinStake(2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        position.setProtocolTreasury(other);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        position.pause();
        vm.stopPrank();
    }

    /// @notice initialize validates zero-value guards and the duty domain (no ratchet at init:
    ///         there is no prior value). The implementation is created once up front so each
    ///         expectRevert attaches to the initialize call itself, not to a (non-reverting)
    ///         contract creation.
    function test_RevertWhen_InitializeValidatesParameterTable() external {
        OutrunStakingPositionUpgradeable impl = new OutrunStakingPositionUpgradeable();
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, address(0), address(sy), address(uAsset), treasury, 1, DUTY);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(0), address(uAsset), treasury, 1, DUTY);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(0), treasury, 1, DUTY);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(uAsset), address(0), 1, DUTY);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 0, DUTY);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.DutyCap.selector, DUTY_CAP + 1));
        _deployPosition(impl, owner, address(sy), address(uAsset), treasury, 1, DUTY_CAP + 1);
    }

    // ==========================================================================
    // Section 5: view family and input guards
    // ==========================================================================

    /// @notice Missing ids report zero debt across the view family.
    function test_MissingPositionViewsReportZero() external {
        assertEq(position.pendingInterest(7), 0, "pending for missing id");
        assertEq(position.positionDebt(7), 0, "debt for missing id");
        (address positionOwner, uint256 syStaked, uint256 principalDebt, uint256 accrued, uint256 lastUnit) =
            position.positions(7);
        assertEq(positionOwner, address(0), "missing owner");
        assertEq(syStaked, 0, "missing collateral");
        assertEq(principalDebt, 0, "missing principal");
        assertEq(accrued, 0, "missing accrued");
        assertEq(lastUnit, 0, "missing snapshot");
    }

    /// @notice The parameter/interest view family returns the initialized bindings.
    function test_ParameterViewsReturnInitializedValues() external {
        assertEq(position.SY(), address(sy), "SY view");
        assertEq(position.uAsset(), address(uAsset), "uAsset view");
        assertEq(position.protocolTreasury(), treasury, "treasury view");
        assertEq(position.minStake(), 1, "minStake view");
        assertEq(position.duty(), DUTY, "duty view");
        assertEq(position.genesisLauncher(), address(genesisLauncher), "genesisLauncher wired in setUp");
        assertEq(position.rate(), 1e27, "rate starts at RAY");
        assertEq(position.rateLastSettledAt(), warpAt, "init timestamp is the first settlement baseline");
    }

    /// @notice stakeForGenesis rejects dust (zero minted debt) while previewStake deliberately
    ///         returns 0 for the same input, and input guards run before any transfer.
    function test_StakeDustDivergenceAndInputGuards() external {
        // At rate 1e18 - 1 with minStake 1: collateral floors to 0.
        sy.setExchangeRate(1e18 - 1);
        assertEq(position.previewStake(1), 0, "quote deliberately returns 0 on dust");
        sy.mintShares(user, 1);
        vm.startPrank(user);
        sy.approve(address(position), 1);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        position.stakeForGenesis(1, user, VERSE_ID, 0);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stakeForGenesis(0, user, VERSE_ID, 0);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stakeForGenesis(1, address(0), VERSE_ID, 0);
        vm.stopPrank();
        assertEq(sy.balanceOf(address(position)), 0, "no SY entered on rejected stakes");
        assertEq(position.idCounter(), 0, "no position created");
    }

    // ==========================================================================
    // Helpers
    // ==========================================================================

    /// @dev Asserts a rejected genesis call left nothing behind: no position (and no consumed
    ///      position id), no mint, and no SY pull.
    function _assertGenesisRevertedCleanly() internal view {
        (address positionOwner,,,,) = position.positions(1);
        assertEq(positionOwner, address(0), "no position may exist");
        assertEq(position.idCounter(), 0, "no position id was consumed");
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, 0, "no mint entered the minter ledger");
        assertEq(uAsset.totalSupply(), 0, "no uAsset was minted");
        assertEq(sy.balanceOf(address(position)), 0, "no SY entered the SP");
    }

    /// @dev Reuses a pre-created implementation so expectRevert can attach to the initialize call.
    function _deployPosition(
        OutrunStakingPositionUpgradeable impl,
        address owner_,
        address sy_,
        address uAsset_,
        address treasury_,
        uint256 minStake_,
        uint256 duty_
    ) internal returns (OutrunStakingPositionUpgradeable) {
        return OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(impl),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize, (owner_, sy_, uAsset_, treasury_, minStake_, duty_)
                )
            )
        );
    }
}

/**
 * @title OutrunStakingPositionPauseMatrixTest
 * @notice Three-level pause matrix on the real production stack (real SY + real uAsset behind
 *         proxies): SP pause freezes both user entries while views and accrual extrapolation
 *         keep working; SY pause blocks every SY movement; uAsset pause freezes the debt legs.
 * @dev Uses the settable oracle for rate control. There is no liquidation and no surplus claim:
 *      the only exits are redeem (SY direct, oracle-independent) and views.
 */
contract OutrunStakingPositionPauseMatrixTest is CommonTestHelpers {
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = bytes4(keccak256("EnforcedPause()"));

    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal treasury = address(0xFEE);

    PositionMockToken internal token;
    OutrunL2StakedTokenSYUpgradeable internal sy;
    OutrunUniversalAssetsUpgradeable internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    PositionSettableOracle internal oracle;
    MockGenesisLauncher internal pauseLauncher;

    // `warpAt`/`_warp` provided by `CommonTestHelpers`.

    function setUp() external {
        token = new PositionMockToken();
        oracle = new PositionSettableOracle();
        sy = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY Token", "SYT", owner, address(token), address(oracle), address(token), 18)
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
        uAsset.setMintingCap(address(position), type(uint128).max);
        // The test's own record funds interest coverage on the real uAsset.
        uAsset.setMintingCap(address(this), type(uint128).max);
        vm.stopPrank();
        pauseLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(pauseLauncher));
        token.mint(user, 1_000e18);
    }

    /// @notice Mints SY for `who` through the real deposit path (token -> SY 1:1).
    function _mintSy(address who, uint256 amount) internal {
        _mintSyFor(address(token), address(sy), who, amount);
    }

    /// @notice Opens a genesis position for `who` and approves the SP for future repay legs.
    function _stakeForGenesis(address who, uint256 amountInSY) internal returns (uint256 positionId) {
        _mintSy(who, amountInSY);
        vm.startPrank(who);
        sy.approve(address(position), amountInSY);
        positionId = position.stakeForGenesis(amountInSY, who, 42, 0);
        uAsset.approve(address(position), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice SP-level pause freezes both user entries; previews and accrual extrapolation
    ///         keep working and the debt keeps growing while paused.
    function test_SpPauseBlocksAllEntriesWhileViewsAndAccrualContinue() external {
        (uint256 positionId) = _stakeForGenesis(user, 10e18);
        uint256 debtBefore = position.positionDebt(positionId);

        vm.prank(owner);
        position.pause();

        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.stakeForGenesis(1e18, user, 42, 0);
        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.redeem(positionId, 1e18, user, address(sy), 0);

        // Views stay usable and interest keeps extrapolating while paused (the debt grows).
        assertEq(position.previewStake(10e18), 10e18, "preview stays available while paused");
        _warp(100);
        assertGt(position.positionDebt(positionId), debtBefore, "debt kept growing across the pause");

        vm.prank(owner);
        position.unpause();
        uAsset.mint(user, 10e18);
        vm.startPrank(user);
        uAsset.approve(address(position), 10e18);
        (,, uint256 syOut) = position.redeem(positionId, 1e18, user, address(sy), 0);
        vm.stopPrank();
        assertEq(syOut, 1e18, "unpause restores the user surface");
    }

    /// @notice SY-level pause blocks the genesis SY pull and both redeem output paths.
    function test_SyPauseBlocksEverySyMovement() external {
        (uint256 healthyId) = _stakeForGenesis(user, 10e18);
        _mintSy(user, 1e18); // pre-fund SY so the genesis attempt fails on the pause, not on balance
        vm.prank(user);
        sy.approve(address(position), 1e18); // same for the SY allowance
        // Pre-fund the repay cover so the redeem attempts reach the SY transfer step (the pause
        // guard) instead of failing on the uAsset legs first.
        uAsset.mint(user, 10e18);
        vm.prank(user);
        uAsset.approve(address(position), 10e18);

        vm.prank(owner);
        sy.pause();

        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.stakeForGenesis(1e18, user, 42, 0);
        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.redeem(healthyId, 1e18, user, address(sy), 0);
        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.redeem(healthyId, 1e18, user, address(token), 0); // adapter path is SY-gated too
        (address positionOwner,,,,) = position.positions(healthyId);
        assertEq(positionOwner, user, "position survived the blocked exits");

        vm.prank(owner);
        sy.unpause();
        vm.prank(user);
        (,, uint256 syOut) = position.redeem(healthyId, 1e18, user, address(sy), 0);
        assertEq(syOut, 1e18, "redeem restored after unpause");
    }

    /// @notice uAsset-level pause blocks the genesis mint leg and the redeem repay legs.
    function test_UAssetPauseBlocksDebtLegs() external {
        (uint256 healthyId) = _stakeForGenesis(user, 10e18);
        _mintSy(user, 1e18);
        vm.prank(user);
        sy.approve(address(position), 1e18); // the blocked genesis must fail on the uAsset mint leg
        // Pre-fund the repay cover so the redeem attempt reaches the paused repay legs (the pause
        // guard) instead of failing on a balance check first.
        uAsset.mint(user, 10e18);
        vm.prank(user);
        uAsset.approve(address(position), 10e18);

        vm.prank(owner);
        uAsset.pause();

        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.stakeForGenesis(1e18, user, 42, 0); // uAsset.mint leg
        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.redeem(healthyId, 1e18, user, address(sy), 0); // repay leg

        vm.prank(owner);
        uAsset.unpause();
        vm.prank(user);
        (,, uint256 syOut) = position.redeem(healthyId, 1e18, user, address(sy), 0);
        assertEq(syOut, 1e18, "redeem restored after unpause");
    }
}
