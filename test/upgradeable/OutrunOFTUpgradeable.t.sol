// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MessagingFee, OFTLimit, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {OutrunOFTUpgradeable} from "../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {OutrunRateLimiterHarness} from "./mocks/OutrunRateLimiterHarness.sol";
import {MockLzEndpoint, OutrunUpgradeableOftHarness} from "./mocks/OFTMocks.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";

contract OutrunOFTUpgradeableTest is Test {
    OutrunUpgradeableOftHarness internal oft;
    MockLzEndpoint internal endpoint;

    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    uint32 internal constant DST_EID = 101;

    function setUp() external {
        endpoint = new MockLzEndpoint();

        // Deploy the harness (OutrunOFTUpgradeable child) for debit/credit/outflow tests.
        OutrunUpgradeableOftHarness implementation = new OutrunUpgradeableOftHarness(18, address(endpoint));
        oft = OutrunUpgradeableOftHarness(
            ProxyTestHelper.deploy(
                address(implementation),
                abi.encodeCall(OutrunUpgradeableOftHarness.initialize, ("Outrun OFT", "OFT", owner))
            )
        );

        // Mint tokens on the harness for debit/credit/outflow tests.
        oft.exposedCredit(user, 100e18, 0);
    }

    function test_RevertWhenLocalDecimalsCannotRepresentFullSharedDecimalRange() external {
        vm.expectRevert(abi.encodeWithSignature("InvalidDecimalConversionRate()"));
        new OutrunUpgradeableOftHarness(64, address(endpoint));
    }

    function test_AllowsLargestRepresentableLocalDecimalValue() external {
        OutrunUpgradeableOftHarness maximumPrecisionOft = new OutrunUpgradeableOftHarness(63, address(endpoint));

        assertEq(maximumPrecisionOft.decimalConversionRate(), 1e57);
    }

    function testTokenAndApprovalRequiredUseLocalToken() external {
        assertEq(oft.token(), address(oft));
        assertFalse(oft.approvalRequired());
    }

    function testUnconfiguredPeerDebitIsNotRateLimited() external {
        vm.prank(user);
        (uint256 sent, uint256 received) = oft.exposedDebit(user, 25e18, 0, DST_EID);

        OutrunRateLimiterUpgradeable.RateLimit memory rateLimit = oft.rateLimits(DST_EID);
        assertEq(sent, 25e18);
        assertEq(received, 25e18);
        assertEq(oft.balanceOf(user), 75e18);
        assertEq(oft.outflowCalls(), 1);
        assertEq(rateLimit.amountInFlight, 0);
        assertEq(rateLimit.lastUpdated, 0);
        assertEq(rateLimit.limit, 0);
        assertEq(rateLimit.window, 0);
    }

    function testQuoteLimitReflectsConfiguredRateLimit() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        (OFTLimit memory oftLimit,,) = oft.quoteOFT(_sendParam(100e18));
        assertEq(oftLimit.maxAmountLD, 15e18);
    }

    function testPausedTokenBlocksNewOutboundDebit() external {
        vm.prank(owner);
        oft.pause();

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oft.exposedDebit(user, 25e18, 0, DST_EID);
    }

    function testPausedTokenBlocksNewOutboundSend() external {
        vm.prank(owner);
        oft.setPeer(DST_EID, bytes32(uint256(uint160(address(oft)))));

        vm.prank(owner);
        oft.pause();

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oft.send(_sendParam(25e18), MessagingFee({nativeFee: 0, lzTokenFee: 0}), user);
    }

    function testPausedTokenAllowsInboundCredit() external {
        vm.prank(owner);
        oft.pause();

        uint256 received = oft.exposedCredit(user, 25e18, DST_EID);

        assertEq(received, 25e18);
        assertEq(oft.balanceOf(user), 125e18);
    }

    function testAmountCanBeSentResetsWhenWindowElapsed() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        vm.warp(block.timestamp + 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, 40e18);
    }

    /// @dev Locks the mid-window decay branch of the rate limiter. After a partial
    ///      window the in-flight amount must decay proportionally:
    ///      decay = (limit * elapsed) / window. With limit = 40e18, window = 1 day,
    ///      a 25e18 debit, then a 12-hour warp: decay = 40e18 * 12h / 24h = 20e18,
    ///      so inFlight = 25e18 - 20e18 = 5e18 and canBeSent = 40e18 - 5e18 = 35e18.
    ///      This warps to half the window (not the full window) so the decay formula
    ///      actually runs instead of hitting the full-window early return.
    function testPartialWindowDecayReducesInFlightExactly() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        // Half the window: the decay branch runs (0 < elapsed < window).
        vm.warp(block.timestamp + 12 hours);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 5e18);
        assertEq(canBeSent, 35e18);
    }

    /// @dev Locks the unchecked-subtraction guard's false branch: when decay fully
    ///      consumes the in-flight amount but the window has not fully elapsed,
    ///      in-flight clamps to zero (no underflow). With limit = 40e18, window =
    ///      1 day, a 5e18 debit, then an 18-hour warp: decay = 40e18 * 18h / 24h =
    ///      30e18, which exceeds the 5e18 in-flight, so currentAmountInFlight stays
    ///      0 and canBeSent = 40e18 - 0 = 40e18.
    function testMidWindowFullDecayClampsInFlightToZero() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 5e18, 0, DST_EID);

        // 18h of a 24h window: decay (30e18) exceeds in-flight (5e18) but the
        // window has not fully elapsed, so the decay formula still runs.
        vm.warp(block.timestamp + 18 hours);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, 40e18);
    }

    /// @dev Locks the reconfig checkpoint: when a destination already has in-flight tokens,
    ///      setting a new limit/window must first settle the in-flight amount under the OLD
    ///      decay parameters before the new ones take effect. With limit = 40e18, window =
    ///      1 day, a 25e18 debit, then a 12-hour warp, then reconfiguring to limit = 80e18,
    ///      window = 4 days: the checkpoint decays 40e18 * 12h / 24h = 20e18 under the old
    ///      parameters, so inFlight = 25e18 - 20e18 = 5e18 and lastUpdated moves to the
    ///      reconfig timestamp; the view then reports canBeSent = 80e18 - 5e18 = 75e18.
    function testReconfigCheckpointsInFlightAtOldWindow() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        // The warp between debit and reconfig is what makes the checkpoint observable:
        // it creates elapsed time that must be settled under the old window first.
        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 80e18, 4 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 5e18);
        assertEq(canBeSent, 75e18);

        OutrunRateLimiterUpgradeable.RateLimit memory rateLimit = oft.rateLimits(DST_EID);
        assertEq(rateLimit.amountInFlight, 5e18);
        assertEq(rateLimit.lastUpdated, block.timestamp);
        assertEq(rateLimit.window, 4 days);
    }

    /// @dev Locks the owner-lowered-limit over-cap branch: when a destination already has in-flight
    ///      tokens and the owner sets a new limit below the in-flight amount, canBeSent clamps to
    ///      zero, any non-zero outflow reverts RateLimitExceeded, and a reconfig amount == 0
    ///      checkpoint does not record a new outflow beyond the stored in-flight.
    function testOwnerLoweredLimitBlocksOutflowAndPreservesOverCapInvariant() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        // Lower the limit below the in-flight amount (25e18): over-cap state. The reconfig's
        // amount == 0 checkpoint settles the in-flight under the old parameters first.
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 10e18, 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 25e18);
        assertEq(canBeSent, 0);

        // Any non-zero outflow (above the dust quantum) must be rejected while over cap.
        vm.prank(user);
        vm.expectRevert(OutrunRateLimiterUpgradeable.RateLimitExceeded.selector);
        oft.exposedDebit(user, 1e12, 0, DST_EID);

        // A further reconfig's amount == 0 checkpoint must not mint a new outflow record:
        // the stored in-flight is preserved (and decays back under the limit over time).
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 5e18, 1 days);

        (inFlight,) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 25e18);
    }

    /// @dev RV-017 regression: an owner-lowered limit below in-flight must survive a full window.
    ///      The full-window early return is only valid when amountInFlight <= limit; in the over-cap
    ///      state the residual max(amountInFlight - limit, 0) must persist and decay at the new rate
    ///      (decay = limit * elapsed / window) instead of being zeroed. With limit 40e18/1d, a 25e18
    ///      debit, then a reconfig to 10e18/1d: at a full window decay = 10e18 so inFlight = 25e18 -
    ///      10e18 = 15e18 and canBeSent stays 0 (outflow reverts); only after 25e18/10e18 = 2.5
    ///      windows does the residual clear and canBeSent return to 10e18.
    function testOwnerLoweredLimitPreservesOverCapAcrossFullWindow() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        // Lower the limit below the 25e18 in-flight: over-cap state (checkpoint keeps in-flight).
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 10e18, 1 days);

        // One full window: decay (10e18) is not enough to clear the residual; must not report (0, 10e18).
        vm.warp(block.timestamp + 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 15e18);
        assertEq(canBeSent, 0);

        // A non-zero outflow must still be rejected while the over-cap residual is in flight.
        vm.prank(user);
        vm.expectRevert(OutrunRateLimiterUpgradeable.RateLimitExceeded.selector);
        oft.exposedDebit(user, 10e18, 0, DST_EID);

        // After the residual fully decays (25/10 = 2.5 windows) capacity is restored before a new send.
        vm.warp(block.timestamp + 1.5 days);

        (uint256 clearedInFlight, uint256 clearedCanBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(clearedInFlight, 0);
        assertEq(clearedCanBeSent, 10e18);
    }

    function testRemoveLimitRestoresSharedDecimalEnvelope() external {
        vm.warp(block.timestamp + 1);

        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        OutrunRateLimiterUpgradeable.RateLimit memory beforeRemoval = oft.rateLimits(DST_EID);
        assertEq(beforeRemoval.amountInFlight, 25e18);
        assertEq(beforeRemoval.lastUpdated, block.timestamp);

        vm.prank(owner);
        oft.removeOutboundRateLimit(DST_EID);

        OutrunRateLimiterUpgradeable.RateLimit memory removedRateLimit = oft.rateLimits(DST_EID);
        assertEq(removedRateLimit.amountInFlight, 0);
        assertEq(removedRateLimit.lastUpdated, 0);
        assertEq(removedRateLimit.limit, 0);
        assertEq(removedRateLimit.window, 0);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, uint256(type(uint64).max) * oft.decimalConversionRate());

        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        (inFlight, canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, 40e18);
    }

    /// @dev RV-002 regression: a configured per-destination limit above the LayerZero uint64
    ///      shared-decimals wire envelope must report the envelope-capped capacity
    ///      (uint64.max * decimalConversionRate) rather than the raw configured limit, which
    ///      could not be SD-encoded in a single send (AmountSDOverflowed on _toSD).
    function testConfiguredLimitAboveEnvelopeReportsEnvelopeCappedAmount() external {
        uint256 envelope = uint256(type(uint64).max) * oft.decimalConversionRate();

        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, type(uint192).max, 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, envelope);
    }

    /// @dev Non-regression: a configured limit below the envelope reports the raw rate-limited
    ///      remaining capacity unchanged (no envelope cap or dust perturbation at this range).
    function testGetAmountCanBeSentBelowEnvelopePreservesRawCapacity() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, 40e18);
    }

    /// @dev RV-002 consistency: with a limit above the envelope, quoteOFT's maxAmountLD and
    ///      getAmountCanBeSent's amountCanBeSent must both report the envelope-bounded capacity.
    function testQuoteOFTMatchesGetterWhenLimitAboveEnvelope() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, type(uint192).max, 1 days);

        (OFTLimit memory oftLimit,,) = oft.quoteOFT(_sendParam(0));
        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);

        assertEq(inFlight, 0);
        uint256 envelope = uint256(type(uint64).max) * oft.decimalConversionRate();
        assertEq(oftLimit.maxAmountLD, envelope);
        assertEq(canBeSent, oftLimit.maxAmountLD);
    }

    /// @dev Below the envelope but NOT DCR-aligned: a configured limit of 40e18 + 1 must be reported
    ///      dusted down to the last DCR boundary (40e18) via _removeDust on both getAmountCanBeSent
    ///      and quoteOFT, instead of exposing the raw 40e18 + 1 that could not be SD-encoded.
    function testGetAmountCanBeSentDustsNonAlignedBelowEnvelopeLimit() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18 + 1, 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, 40e18);

        (OFTLimit memory oftLimit,,) = oft.quoteOFT(_sendParam(0));
        assertEq(oftLimit.maxAmountLD, canBeSent);
        assertEq(oftLimit.maxAmountLD, 40e18);
    }

    /// @dev A configured limit exactly equal to the shared-decimals envelope (uint64.max * DCR) is
    ///      both below the uint192 storage ceiling for the 18-dec harness (1.84e31 < uint192.max) and
    ///      already DCR-aligned, so it reports the full envelope unchanged on getAmountCanBeSent and
    ///      quoteOFT. Skips the envelope-capping branch (amount == maxAmountLD, not above it).
    function testGetAmountCanBeSentExactlyAtEnvelopeReturnsEnvelope() external {
        uint256 envelope = uint256(type(uint64).max) * oft.decimalConversionRate();
        // uint192 ceiling check: only meaningful under a harness DCR that pushes envelope past
        // uint192.max; 18-dec DCR = 1e12 keeps envelope ≈ 1.84e31 well within uint192.max (≈ 6.3e57).
        assertTrue(envelope <= type(uint192).max);

        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, uint192(envelope), 1 days);

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, envelope);

        (OFTLimit memory oftLimit,,) = oft.quoteOFT(_sendParam(0));
        assertEq(oftLimit.maxAmountLD, envelope);
    }

    /// @dev With a limit above the envelope and 1e18 in flight, the in-flight amount is reported
    ///      as-is (never dusted) while the remaining capacity is still envelope-capped; dedusting
    ///      the already-DCR-aligned envelope is a no-op.
    function testGetAmountCanBeSentAboveEnvelopeWithInFlightStillCapped() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, type(uint192).max, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 1e18, 0, DST_EID);

        uint256 envelope = uint256(type(uint64).max) * oft.decimalConversionRate();

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 1e18);
        assertEq(canBeSent, envelope);
    }

    function _sendParam(uint256 amountLD) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: amountLD,
            minAmountLD: 0,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
    }

    /// @dev F-001 regression: zero-amount outbound sends are rejected by _debit before _outflow.
    function testDebitRejectsZeroAmount() external {
        vm.expectRevert(OutrunOFTUpgradeable.AmountTooSmall.selector);
        oft.exposedDebit(user, 0, 0, DST_EID);
        assertEq(oft.outflowCalls(), 0);
    }

    /// @dev F-001 regression: sub-DCR dust that round-trips to zero is also rejected.
    function testDebitRejectsDustAmount() external {
        uint256 dust = oft.decimalConversionRate() - 1;
        vm.expectRevert(OutrunOFTUpgradeable.AmountTooSmall.selector);
        oft.exposedDebit(user, dust, 0, DST_EID);
        assertEq(oft.outflowCalls(), 0);
    }

    /// @dev F-001 regression: quoteOFT signals dust as unsendable via minAmountLD.
    function testQuoteOFTMinAmountSignalsDustRejection() external {
        (OFTLimit memory oftLimit,,) = oft.quoteOFT(_sendParam(0));
        assertEq(oftLimit.minAmountLD, oft.decimalConversionRate());
    }

    /// @dev F-001 regression: a rejected dust send must not refresh rl.lastUpdated or rate-limiter state.
    function testDustDebitDoesNotRefreshRateLimitState() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        OutrunRateLimiterUpgradeable.RateLimit memory before = oft.rateLimits(DST_EID);

        vm.prank(user);
        vm.expectRevert(OutrunOFTUpgradeable.AmountTooSmall.selector);
        oft.exposedDebit(user, 0, 0, DST_EID);

        OutrunRateLimiterUpgradeable.RateLimit memory afterState = oft.rateLimits(DST_EID);
        assertEq(afterState.amountInFlight, before.amountInFlight);
        assertEq(afterState.lastUpdated, before.lastUpdated);
        assertEq(oft.outflowCalls(), 1);
    }
}

/// @dev Pins the base OutrunRateLimiterUpgradeable view semantics without the OFT override:
///      an unconfigured or deleted destination reports the infinite-capacity sentinel
///      (0, type(uint256).max), matching _checkAndUpdateRateLimit's no-limit early return.
contract OutrunRateLimiterBaseTest is Test {
    OutrunRateLimiterHarness internal rateLimiter;

    uint32 internal constant DST_EID = 201;

    function setUp() external {
        rateLimiter = new OutrunRateLimiterHarness();
    }

    /// @dev window == 0 must read as "infinite limit" in the base view,
    ///      not as zero capacity.
    function testUnconfiguredDestinationReturnsInfiniteCapacity() external {
        (uint256 inFlight, uint256 canBeSent) = rateLimiter.getAmountCanBeSent(DST_EID);

        assertEq(inFlight, 0, "unconfigured destination: no tokens in flight");
        assertEq(canBeSent, type(uint256).max, "unconfigured destination: capacity is the infinite sentinel");
    }

    /// @dev With a configured limit the decay path still applies at the base layer:
    ///      nothing in flight means the full limit is immediately sendable.
    function testConfiguredDestinationReturnsFullLimitImmediately() external {
        rateLimiter.setRateLimits(_singleConfig(100 ether, 1 hours));

        (uint256 inFlight, uint256 canBeSent) = rateLimiter.getAmountCanBeSent(DST_EID);

        assertEq(inFlight, 0, "configured destination with no outflow: no tokens in flight");
        assertEq(canBeSent, 100 ether, "configured destination with no outflow: full limit sendable");
    }

    /// @dev Deleting the limit must return the destination to the infinite-capacity sentinel.
    function testRemovedLimitReturnsInfiniteCapacity() external {
        rateLimiter.setRateLimits(_singleConfig(100 ether, 1 hours));
        rateLimiter.removeRateLimit(DST_EID);

        (uint256 inFlight, uint256 canBeSent) = rateLimiter.getAmountCanBeSent(DST_EID);

        assertEq(inFlight, 0, "removed limit: no tokens in flight");
        assertEq(canBeSent, type(uint256).max, "removed limit: capacity is the infinite sentinel again");
    }

    /// @dev Pins that the infinite-capacity early return keys on window alone, not limit.
    ///      This window == 0 && limit > 0 state is unreachable in production —
    ///      OutrunOFTUpgradeable.sol::setOutboundRateLimit rejects window == 0 — but the
    ///      base _setRateLimits allows it, mirroring _checkAndUpdateRateLimit's window-only
    ///      early exit on the accounting path.
    function testZeroWindowWithNonzeroLimitReturnsInfiniteCapacity() external {
        rateLimiter.setRateLimits(_singleConfig(100 ether, 0));

        (uint256 inFlight, uint256 canBeSent) = rateLimiter.getAmountCanBeSent(DST_EID);

        assertEq(inFlight, 0, "zero window with nonzero limit: no tokens in flight");
        assertEq(canBeSent, type(uint256).max, "zero window with nonzero limit: capacity is the infinite sentinel");
    }

    function _singleConfig(uint192 limit, uint64 window)
        internal
        pure
        returns (OutrunRateLimiterUpgradeable.RateLimitConfig[] memory configs)
    {
        configs = new OutrunRateLimiterUpgradeable.RateLimitConfig[](1);
        configs[0] = OutrunRateLimiterUpgradeable.RateLimitConfig({dstEid: DST_EID, limit: limit, window: window});
    }
}
