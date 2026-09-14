// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {UAssetHelper} from "./helpers/UAssetHelper.sol";
import {OutrunL2OracleBackedSYUpgradeable} from "../../src/yield/OutrunL2OracleBackedSYUpgradeable.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {PositionMockToken, PositionSettableOracle} from "./mocks/PositionMocks.sol";

/// @title L2OracleRateBreakerUpgradeableTest
/// @notice Rate-anchor deviation breaker on the L2 oracle-backed SY base: the anchor is seeded
///         from the oracle's first reading at init, every `exchangeRate()` reading must stay
///         inside [anchor x (1e4 - maxDropBps) / 1e4, anchor x (3600x1e4 + min(riseBpsPerHour x
///         elapsedSeconds, riseCapBps x 3600)) / (3600x1e4)] — the rise allowance accrues
///         CONTINUOUSLY per elapsed second, not in whole-hour steps — and the anchor only
///         advances to in-band readings (permissionless commit) or through the owner's
///         explicit reset.
/// @dev Uses `PositionSettableOracle` because the breaker's zero-reading path needs an oracle
///      that RETURNS zero rather than reverting on it.
contract L2OracleRateBreakerUpgradeableTest is UAssetHelper {
    // Mirror declarations for vm.expectEmit (events are matched by full signature, not source).
    // The indexed layout must mirror the source events too: a value the source writes to a topic
    // must be emitted to a topic here, or the topic/data comparison fails.
    event RateAnchorCommitted(uint256 indexed anchor, uint256 timestamp);
    event RateAnchorReset(uint256 indexed oldAnchor, uint256 indexed newAnchor);
    event SetRateBreakerParams(uint16 maxDropBps, uint16 riseBpsPerHour, uint16 maxRiseCapBps);

    address internal owner = address(0xA11CE);
    address internal nonOwner = address(0xB0B);
    address internal treasury = address(0xFEE);

    uint256 internal constant ANCHOR = 1e18;
    // Defaults baked in by __L2OracleBackedSY_init; mirrored here so band assertions stay explicit.
    uint256 internal constant DEFAULT_MAX_DROP_BPS = 10;
    uint256 internal constant DEFAULT_RISE_BPS_PER_HOUR = 5;
    uint256 internal constant DEFAULT_RISE_CAP_BPS = 200;

    PositionMockToken internal token;
    PositionSettableOracle internal oracle;
    OutrunL2StakedTokenSYUpgradeable internal sy;
    // Chain timestamp at the moment the SY (and its anchor) was initialized.
    uint256 internal anchorTs;

    function setUp() external {
        vm.warp(1 days);
        token = new PositionMockToken();
        oracle = new PositionSettableOracle();
        oracle.setExchangeRate(ANCHOR);
        sy = _deploySy();
        anchorTs = block.timestamp;
    }

    // --------------------------------------------------------------------------
    // Init: anchor seeding
    // --------------------------------------------------------------------------

    /// @notice The anchor equals the oracle's first reading, whatever it was (not a constant).
    function test_InitSeedsAnchorFromFirstReading() external {
        oracle.setExchangeRate(1.1e18);
        OutrunL2StakedTokenSYUpgradeable other = _deploySy();
        assertEq(other.exchangeRate(), 1.1e18, "first reading is in-band against itself");

        // At elapsed 0 the rise allowance is 0, so the anchorRate in the revert data pins the
        // seeded anchor to exactly the first reading.
        uint256 slightlyHigher = 1.1e18 + 1;
        oracle.setExchangeRate(slightlyHigher);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutrunL2OracleBackedSYUpgradeable.RateDeviationExceeded.selector, slightlyHigher, 1.1e18, 0
            )
        );
        other.exchangeRate();
    }

    /// @notice A zero first reading means the feed is unusable and must fail the deploy.
    function test_RevertWhen_InitialOracleReadingIsZero() external {
        oracle.setExchangeRate(0);
        // Implementation creation is a non-reverting external call, so it must happen before
        // vm.expectRevert (which binds to the next call); the revert under test is the proxy's
        // initialize call.
        OutrunL2StakedTokenSYUpgradeable implementation = new OutrunL2StakedTokenSYUpgradeable();
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.ZeroRateAnchor.selector);
        _deploySyProxy(implementation);
    }

    /// @notice A first reading above uint96 max cannot be stored as the anchor: exactly 2^96
    ///      would narrow to anchor == 0 (band silently disabled), so the guard fires on the raw
    ///      uint256 reading BEFORE the narrowing cast.
    function test_RevertWhen_InitialReadingAboveUint96Max() external {
        OutrunL2StakedTokenSYUpgradeable implementation = new OutrunL2StakedTokenSYUpgradeable();
        oracle.setExchangeRate(1 << 96);
        vm.expectRevert(abi.encodeWithSelector(OutrunL2OracleBackedSYUpgradeable.RateAnchorOverflow.selector, 1 << 96));
        _deploySyProxy(implementation);

        oracle.setExchangeRate(3 << 96);
        vm.expectRevert(abi.encodeWithSelector(OutrunL2OracleBackedSYUpgradeable.RateAnchorOverflow.selector, 3 << 96));
        _deploySyProxy(implementation);
    }

    /// @notice The boundary reading uint96 max itself stores exactly — the guard rejects only
    ///      what the narrowing cast would corrupt.
    function test_InitialReadingAtUint96MaxStoresExactly() external {
        oracle.setExchangeRate(type(uint96).max);
        OutrunL2StakedTokenSYUpgradeable other = _deploySy();
        assertEq(other.exchangeRate(), type(uint96).max, "uint96-max first reading is its own anchor");
    }

    // --------------------------------------------------------------------------
    // Band at elapsed = 0
    // --------------------------------------------------------------------------

    function test_EqualReadingPassesAtZeroElapsed() external {
        assertEq(sy.exchangeRate(), ANCHOR);
    }

    /// @notice At elapsed 0 the rise allowance is 0: any strictly higher reading reverts instantly.
    function test_RevertWhen_StrictlyHigherReadingAtZeroElapsed() external {
        uint256 higher = ANCHOR + 1;
        oracle.setExchangeRate(higher);
        _expectRateDeviation(higher, ANCHOR, 0);
        sy.exchangeRate();
    }

    /// @notice A reading inside [−maxDropBps, 0] bps passes at elapsed 0 (both bounds inclusive).
    function test_ReadingsWithinDropBandPassAtZeroElapsed() external {
        oracle.setExchangeRate(_applyBps(ANCHOR, -10)); // exactly minRate: inclusive bound
        assertEq(sy.exchangeRate(), _applyBps(ANCHOR, -10));
        oracle.setExchangeRate(_applyBps(ANCHOR, -5));
        assertEq(sy.exchangeRate(), _applyBps(ANCHOR, -5));
    }

    // --------------------------------------------------------------------------
    // Rise allowance: per-hour accumulation, cap
    // --------------------------------------------------------------------------

    /// @notice One elapsed hour buys exactly riseBpsPerHour bps of headroom (boundary inclusive).
    function test_RiseWithinTimeAccumulatedAllowancePasses() external {
        vm.warp(anchorTs + 1 hours);
        uint256 rate = _applyBps(ANCHOR, 5);
        oracle.setExchangeRate(rate);
        assertEq(sy.exchangeRate(), rate);
    }

    function test_RevertWhen_RiseBeyondTimeAccumulatedAllowance() external {
        vm.warp(anchorTs + 1 hours);
        uint256 rate = _applyBps(ANCHOR, 6);
        oracle.setExchangeRate(rate);
        _expectRateDeviation(rate, ANCHOR, DEFAULT_RISE_BPS_PER_HOUR);
        sy.exchangeRate();
    }

    /// @notice The accumulated allowance stops at riseCapBps no matter how much time passes.
    function test_RiseAllowanceCapsAtMaxRiseCap() external {
        // 40 hours x 5 bps = 200 bps: exactly the cap.
        vm.warp(anchorTs + 40 hours);
        uint256 atCap = _applyBps(ANCHOR, 200);
        oracle.setExchangeRate(atCap);
        assertEq(sy.exchangeRate(), atCap, "+200 bps at 40h is exactly the capped allowance");

        uint256 overCap = _applyBps(ANCHOR, 250);
        oracle.setExchangeRate(overCap);
        _expectRateDeviation(overCap, ANCHOR, DEFAULT_RISE_CAP_BPS);
        sy.exchangeRate();

        // Uncapped, 100 hours would allow 500 bps; the cap keeps the allowance at 200.
        vm.warp(anchorTs + 100 hours);
        oracle.setExchangeRate(atCap);
        assertEq(sy.exchangeRate(), atCap, "capped allowance still admits +200 bps at 100h");
        oracle.setExchangeRate(overCap);
        _expectRateDeviation(overCap, ANCHOR, DEFAULT_RISE_CAP_BPS);
        sy.exchangeRate();
    }

    /// @notice The rise allowance accrues per second: at 30 min it is exactly 2.5 bps (5 bps x
    ///      1800/3600). The exact boundary passes to the wei and one wei above reverts; the
    ///      revert reports the floored whole-bps allowance (2).
    function test_ContinuousRiseAccruesSubHour() external {
        vm.warp(anchorTs + 1800); // 30 minutes
        // Exactly +2.5 bps of the anchor.
        uint256 boundary = _maxRiseRate(ANCHOR, DEFAULT_RISE_BPS_PER_HOUR, DEFAULT_RISE_CAP_BPS, 1800);
        oracle.setExchangeRate(boundary);
        assertEq(sy.exchangeRate(), boundary, "+2.5 bps at 30min is exactly the continuous allowance");

        uint256 beyond = boundary + 1;
        oracle.setExchangeRate(beyond);
        _expectRateDeviation(beyond, ANCHOR, DEFAULT_RISE_BPS_PER_HOUR * 1800 / 3600);
        sy.exchangeRate();
    }

    /// @notice One second before the hour the allowance is 5 x 3599/3600 bps: +4 bps fits, and
    ///      the exact-formula boundary is still enforced to the wei (no whole-hour truncation).
    function test_ContinuousRiseJustBelowOneHour() external {
        vm.warp(anchorTs + 3599); // 1 hour - 1 second
        uint256 within = _applyBps(ANCHOR, 4);
        oracle.setExchangeRate(within);
        assertEq(sy.exchangeRate(), within, "+4 bps fits inside 5 x 3599/3600 bps");

        uint256 boundary = _maxRiseRate(ANCHOR, DEFAULT_RISE_BPS_PER_HOUR, DEFAULT_RISE_CAP_BPS, 3599);
        uint256 beyond = boundary + 1;
        oracle.setExchangeRate(beyond);
        _expectRateDeviation(beyond, ANCHOR, DEFAULT_RISE_BPS_PER_HOUR * 3599 / 3600);
        sy.exchangeRate();
    }

    /// @notice The drop side never earns a time allowance: conversion rates only grow.
    function test_DropSideHasNoTimeAllowance() external {
        vm.warp(anchorTs + 100 hours);
        oracle.setExchangeRate(_applyBps(ANCHOR, -10));
        assertEq(sy.exchangeRate(), _applyBps(ANCHOR, -10), "-10 bps still passes after 100h");

        uint256 beyond = _applyBps(ANCHOR, -11);
        oracle.setExchangeRate(beyond);
        _expectRateDeviation(beyond, ANCHOR, DEFAULT_MAX_DROP_BPS);
        sy.exchangeRate();
    }

    /// @notice A zero oracle reading is a lower-band breach, not a returned zero.
    function test_RevertWhen_ZeroOracleReading() external {
        oracle.setExchangeRate(0);
        _expectRateDeviation(0, ANCHOR, DEFAULT_MAX_DROP_BPS);
        sy.exchangeRate();
    }

    /// @notice Generalizes the band-boundary math to randomized non-default parameters: the
    ///      suite's `_maxRiseRate` / `_applyBps` mirrors reproduce the contract's exact
    ///      operation order, and the pass/revert boundary is exact to the wei on both sides
    ///      for every configuration.
    function testFuzz_BandBoundaryExactUnderNonDefaultParams(
        uint256 riseBpsPerHour,
        uint256 maxRiseCapBps,
        uint256 maxDropBps,
        uint256 elapsedSeconds
    ) external {
        riseBpsPerHour = bound(riseBpsPerHour, 1, 1e4);
        maxRiseCapBps = bound(maxRiseCapBps, 1, 1e4);
        maxDropBps = bound(maxDropBps, 1, 1e4);
        elapsedSeconds = bound(elapsedSeconds, 0, 90 days);

        vm.prank(owner);
        sy.setRateBreakerParams(uint16(maxDropBps), uint16(riseBpsPerHour), uint16(maxRiseCapBps));
        vm.warp(anchorTs + elapsedSeconds);

        uint256 maxRate = _maxRiseRate(ANCHOR, riseBpsPerHour, maxRiseCapBps, elapsedSeconds);
        uint256 minRate = _applyBps(ANCHOR, -int256(maxDropBps));
        // Rise allowance reported in the revert data, floored to whole bps. Flooring before
        // the cap is safe: 3600 divides the cap term exactly, so floor-then-min equals the
        // contract's min-then-floor.
        uint256 uncappedBps = riseBpsPerHour * elapsedSeconds / 3600;
        uint256 allowedRiseBps = uncappedBps > maxRiseCapBps ? maxRiseCapBps : uncappedBps;

        // Rise side: the exact boundary passes; one wei above reverts with the floored
        // whole-bps allowance.
        oracle.setExchangeRate(maxRate);
        assertEq(sy.exchangeRate(), maxRate, "exact rise boundary passes");
        oracle.setExchangeRate(maxRate + 1);
        _expectRateDeviation(maxRate + 1, ANCHOR, allowedRiseBps);
        sy.exchangeRate();

        // Drop side: the exact boundary passes; one below reverts with maxDropBps. When
        // maxDropBps == 1e4 collapses minRate to 0, the zero-reading branch fires instead
        // (with the same allowedBps) and minRate - 1 would underflow, so that configuration
        // is asserted via the zero branch explicitly.
        if (minRate == 0) {
            oracle.setExchangeRate(0);
            _expectRateDeviation(0, ANCHOR, maxDropBps);
            sy.exchangeRate();
        } else {
            oracle.setExchangeRate(minRate);
            assertEq(sy.exchangeRate(), minRate, "exact drop boundary passes");
            oracle.setExchangeRate(minRate - 1);
            _expectRateDeviation(minRate - 1, ANCHOR, maxDropBps);
            sy.exchangeRate();
        }
    }

    // --------------------------------------------------------------------------
    // commitRateAnchor (permissionless, in-band only)
    // --------------------------------------------------------------------------

    /// @notice Anyone may commit, but only to an in-band reading; a fresh anchor resets the rise
    ///      allowance to zero (the conservative direction).
    function test_CommitRateAnchorIsPermissionlessAdvancesAnchorAndEmits() external {
        vm.warp(anchorTs + 2 hours);
        uint256 risenRate = _applyBps(ANCHOR, 5); // inside the 2h x 5 bps = 10 bps allowance
        oracle.setExchangeRate(risenRate);
        assertEq(sy.exchangeRate(), risenRate, "pre-commit sanity: in-band");

        vm.prank(nonOwner);
        vm.expectEmit(true, false, false, true);
        emit RateAnchorCommitted(risenRate, block.timestamp);
        sy.commitRateAnchor();

        // Post-commit band: the old anchor stays in-band (5 bps drop < 10 bps drop bound)...
        oracle.setExchangeRate(ANCHOR);
        assertEq(sy.exchangeRate(), ANCHOR);
        // ...while the rise allowance is back to 0 at elapsed 0 even though the clock is at 2h+.
        uint256 aboveNewAnchor = _applyBps(risenRate, 5);
        oracle.setExchangeRate(aboveNewAnchor);
        _expectRateDeviation(aboveNewAnchor, risenRate, 0);
        sy.exchangeRate();
    }

    function test_RevertWhen_CommitOutsideBand() external {
        uint256 outOfBand = _applyBps(ANCHOR, 500);
        oracle.setExchangeRate(outOfBand);
        _expectRateDeviation(outOfBand, ANCHOR, 0);
        sy.commitRateAnchor();
    }

    /// @notice A reading above uint96 max reverts with `RateAnchorOverflow` before any band
    ///      check: a committing 2^96 would narrow to anchor == 0 and disable the band.
    function test_RevertWhen_CommitReadingAboveUint96Max() external {
        oracle.setExchangeRate(1 << 96);
        vm.expectRevert(abi.encodeWithSelector(OutrunL2OracleBackedSYUpgradeable.RateAnchorOverflow.selector, 1 << 96));
        sy.commitRateAnchor();

        oracle.setExchangeRate(3 << 96);
        vm.expectRevert(abi.encodeWithSelector(OutrunL2OracleBackedSYUpgradeable.RateAnchorOverflow.selector, 3 << 96));
        sy.commitRateAnchor();
    }

    /// @notice A zero reading on the commit path passes the uint96 overflow guard (zero is never
    ///      oversized) and then hits the zero branch inside the band check: fail-closed with the
    ///      full `RateDeviationExceeded` args, never committed as an anchor.
    function test_RevertWhen_CommitReadingIsZero() external {
        oracle.setExchangeRate(0);
        _expectRateDeviation(0, ANCHOR, DEFAULT_MAX_DROP_BPS);
        sy.commitRateAnchor();
    }

    /// @notice Regression (griefing via whole-hour truncation): a keep-current commit followed
    ///      seconds later by a +1 wei reading must still pass — the allowance accrues per
    ///      second, so 12 s already buys ~0.0167 bps, far more than the ~1e-14 bps that a
    ///      +1 wei bump on a 1e18 anchor represents.
    function test_TinyRiseShortlyAfterCommitPasses() external {
        vm.warp(anchorTs + 2 hours);
        // Anchor advances to the current reading (ANCHOR) and the elapsed clock resets to 0.
        sy.commitRateAnchor();

        vm.warp(block.timestamp + 12);
        oracle.setExchangeRate(ANCHOR + 1);
        assertEq(sy.exchangeRate(), ANCHOR + 1, "+1 wei 12 s after a commit passes");
    }

    /// @notice A commit may also move the anchor DOWN to any reading inside the drop bound; the
    ///      band then re-bases on the lower anchor with elapsed 0, so the old anchor (now above
    ///      the new one) is out of band until the rise allowance re-accrues.
    function test_CommitDownwardInBandReadingRebasesAnchor() external {
        uint256 lower = _applyBps(ANCHOR, -5); // inside the -10 bps drop bound
        oracle.setExchangeRate(lower);
        vm.prank(nonOwner);
        vm.expectEmit(true, false, false, true);
        emit RateAnchorCommitted(lower, block.timestamp);
        sy.commitRateAnchor();

        oracle.setExchangeRate(ANCHOR);
        _expectRateDeviation(ANCHOR, lower, 0);
        sy.exchangeRate();

        oracle.setExchangeRate(lower);
        assertEq(sy.exchangeRate(), lower, "the lower anchor itself is in-band at elapsed 0");
    }

    // --------------------------------------------------------------------------
    // resetRateAnchor (owner-only recovery)
    // --------------------------------------------------------------------------

    function test_RevertWhen_ResetRateAnchorByNonOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        sy.resetRateAnchor();
    }

    /// @notice The owner can adopt an out-of-band reading (feed-regime change); afterwards that
    ///      same reading is in-band at elapsed 0. The owner never injects an arbitrary value.
    function test_ResetAdoptsOutOfBandReadingAndEmits() external {
        uint256 newRegime = ANCHOR * 3 / 2;
        oracle.setExchangeRate(newRegime);
        _expectRateDeviation(newRegime, ANCHOR, 0);
        sy.exchangeRate();

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RateAnchorReset(ANCHOR, newRegime);
        sy.resetRateAnchor();

        assertEq(sy.exchangeRate(), newRegime, "post-reset the adopted reading is in-band");
    }

    function test_RevertWhen_ResetWithZeroReading() external {
        oracle.setExchangeRate(0);
        vm.prank(owner);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.ZeroRateAnchor.selector);
        sy.resetRateAnchor();
    }

    /// @notice The reset path has no band check of its own, so it is where an oversized reading
    ///      would do the most damage: unguarded, uint96(2^96) truncates to anchor == 0 and the
    ///      anchor == 0 defensive skip would silently disable the band. The guard reverts first
    ///      and the band stays enforced against the pre-reset anchor.
    function test_RevertWhen_ResetReadingAboveUint96Max() external {
        vm.startPrank(owner);
        oracle.setExchangeRate(1 << 96);
        vm.expectRevert(abi.encodeWithSelector(OutrunL2OracleBackedSYUpgradeable.RateAnchorOverflow.selector, 1 << 96));
        sy.resetRateAnchor();

        oracle.setExchangeRate(3 << 96);
        vm.expectRevert(abi.encodeWithSelector(OutrunL2OracleBackedSYUpgradeable.RateAnchorOverflow.selector, 3 << 96));
        sy.resetRateAnchor();
        vm.stopPrank();

        uint256 outOfBand = _applyBps(ANCHOR, 500);
        oracle.setExchangeRate(outOfBand);
        _expectRateDeviation(outOfBand, ANCHOR, 0);
        sy.exchangeRate();
    }

    // --------------------------------------------------------------------------
    // setRateBreakerParams (owner-only, 1..10000 bps each)
    // --------------------------------------------------------------------------

    function test_RevertWhen_SetRateBreakerParamsByNonOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        sy.setRateBreakerParams(100, 100, 500);
    }

    /// @notice Every parameter must satisfy 1 <= p <= 10000; both boundaries are enforced.
    function test_RevertWhen_InvalidRateBreakerParamsBoundaries() external {
        vm.startPrank(owner);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.InvalidRateBreakerParams.selector);
        sy.setRateBreakerParams(0, 5, 200);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.InvalidRateBreakerParams.selector);
        sy.setRateBreakerParams(10001, 5, 200);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.InvalidRateBreakerParams.selector);
        sy.setRateBreakerParams(10, 0, 200);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.InvalidRateBreakerParams.selector);
        sy.setRateBreakerParams(10, 10001, 200);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.InvalidRateBreakerParams.selector);
        sy.setRateBreakerParams(10, 5, 0);
        vm.expectRevert(OutrunL2OracleBackedSYUpgradeable.InvalidRateBreakerParams.selector);
        sy.setRateBreakerParams(10, 5, 10001);
        // Both inclusive bounds are valid parameter values.
        sy.setRateBreakerParams(1, 1, 1);
        sy.setRateBreakerParams(10000, 10000, 10000);
        vm.stopPrank();
    }

    /// @notice A valid parameter update immediately widens (or narrows) the enforced band.
    function test_SetRateBreakerParamsChangesBandAndEmits() external {
        vm.warp(anchorTs + 1 hours);

        // Under the defaults (5 bps/h, 10 bps drop) a +50 bps reading is out of band.
        uint256 risen = _applyBps(ANCHOR, 50);
        oracle.setExchangeRate(risen);
        _expectRateDeviation(risen, ANCHOR, DEFAULT_RISE_BPS_PER_HOUR);
        sy.exchangeRate();

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit SetRateBreakerParams(100, 100, 500);
        sy.setRateBreakerParams(100, 100, 500);

        assertEq(sy.exchangeRate(), risen, "+50 bps now inside the widened rise allowance");
        oracle.setExchangeRate(_applyBps(ANCHOR, -50));
        assertEq(sy.exchangeRate(), _applyBps(ANCHOR, -50), "-50 bps now inside the widened drop bound");

        uint256 beyondDrop = _applyBps(ANCHOR, -101);
        oracle.setExchangeRate(beyondDrop);
        _expectRateDeviation(beyondDrop, ANCHOR, 100);
        sy.exchangeRate();
    }

    // --------------------------------------------------------------------------
    // Oracle swap keeps the anchor
    // --------------------------------------------------------------------------

    /// @notice setExchangeRateOracle does not touch the anchor: the new oracle's reading is still
    ///      band-checked against the OLD anchor until the owner explicitly resets it.
    function test_OracleSwapPreservesAnchorUntilExplicitReset() external {
        PositionSettableOracle newOracle = new PositionSettableOracle();
        newOracle.setExchangeRate(1.3e18);

        vm.prank(owner);
        sy.setExchangeRateOracle(address(newOracle));

        _expectRateDeviation(1.3e18, ANCHOR, 0);
        sy.exchangeRate();

        vm.prank(owner);
        sy.resetRateAnchor();
        assertEq(sy.exchangeRate(), 1.3e18, "explicit reset adopts the new oracle's reading");
    }

    // --------------------------------------------------------------------------
    // Propagation: the breaker's revert must fail position pricing closed
    // --------------------------------------------------------------------------

    /// @notice An out-of-band reading reverts the SY rate through the IStandardizedYield surface
    ///      and the staking position's pricing view with it — no position can be priced off a
    ///      broken feed.
    function test_RevertWhen_OutOfBandReadingBreaksSyAndPositionPricing() external {
        OutrunStakingPositionUpgradeable position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(_deployUAsset(owner)), treasury)
            )
        );

        uint256 outOfBand = _applyBps(ANCHOR, 500);
        oracle.setExchangeRate(outOfBand);
        _expectRateDeviation(outOfBand, ANCHOR, 0);
        IStandardizedYield(address(sy)).exchangeRate();
        _expectRateDeviation(outOfBand, ANCHOR, 0);
        position.previewStake(10e18);

        oracle.setExchangeRate(ANCHOR);
        assertEq(position.previewStake(10e18), 10e18, "in-band reading restores pricing");
    }

    // --------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------

    /// @dev Deploys the SY behind a proxy against the oracle's CURRENT reading; callers set the
    ///      desired first reading before calling (setting it here would consume any pending
    ///      vm.expectRevert on the rate-setting call itself).
    function _deploySy() internal returns (OutrunL2StakedTokenSYUpgradeable) {
        return _deploySyProxy(new OutrunL2StakedTokenSYUpgradeable());
    }

    /// @dev Deploys the proxy for a pre-created implementation so expectRevert can attach to the
    ///      initialize call alone (implementation creation is a separate non-reverting call).
    function _deploySyProxy(OutrunL2StakedTokenSYUpgradeable implementation)
        internal
        returns (OutrunL2StakedTokenSYUpgradeable)
    {
        return OutrunL2StakedTokenSYUpgradeable(payable(ProxyTestHelper.deploy(address(implementation), _syInitCall())));
    }

    function _syInitCall() internal view returns (bytes memory) {
        return abi.encodeCall(
            OutrunL2StakedTokenSYUpgradeable.initialize,
            ("SY Token", "SYT", owner, address(token), address(oracle), address(token), 18)
        );
    }

    /// @dev Applies +/- bps with the contract's exact integer math (value * (1e4 +/- bps) / 1e4)
    ///      so boundary comparisons line up to the wei.
    function _applyBps(uint256 value, int256 bps) internal pure returns (uint256) {
        if (bps >= 0) {
            return value * (1e4 + uint256(bps)) / 1e4;
        }
        return value * (1e4 - uint256(-bps)) / 1e4;
    }

    /// @dev Mirrors the contract's continuous rise arithmetic exactly (bps-seconds term, cap,
    ///      single final division) so boundary assertions line up to the wei.
    function _maxRiseRate(uint256 anchorValue, uint256 riseBpsPerHour, uint256 maxRiseCapBps, uint256 elapsedSeconds)
        internal
        pure
        returns (uint256)
    {
        uint256 uncappedTerm = riseBpsPerHour * elapsedSeconds;
        uint256 capTerm = maxRiseCapBps * 3600;
        uint256 cappedSecondsTerm = uncappedTerm > capTerm ? capTerm : uncappedTerm;
        return anchorValue * (3600 * 1e4 + cappedSecondsTerm) / (3600 * 1e4);
    }

    function _expectRateDeviation(uint256 rate, uint256 anchorRate, uint256 allowedBps) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                OutrunL2OracleBackedSYUpgradeable.RateDeviationExceeded.selector, rate, anchorRate, allowedBps
            )
        );
    }
}
