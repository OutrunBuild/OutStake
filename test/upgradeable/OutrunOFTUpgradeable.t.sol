// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @title Rate limiter replenish property tests
/// @notice Stateless fuzz tests pinning OutrunRateLimiterUpgradeable's linear-decay replenish
///     math and over-cap residual healing against the reference model of
///     docs/audits/2026-08-19/05-invariants.md §3 (properties RL-2 and RL-3).
contract OutrunRateLimiterReplenishPropertyTest is Test {
    OutrunRateLimiterHarness internal limiter;

    uint32 internal constant DST_EID = 1;

    function setUp() external {
        limiter = new OutrunRateLimiterHarness();
    }

    /// @dev [RL-2a] The decay after an outflow must match the reference model exactly:
    ///      decay = floor(limit * dt / window), clamped by the stored amount, so
    ///      inFlight == fill - min(fill, decay) and canBeSent == limit - inFlight.
    function testFuzz_DecayFormulaExact(uint192 limit, uint64 window, uint256 fillSeed, uint256 dt) external {
        limit = uint192(bound(uint256(limit), 1, type(uint192).max));
        window = uint64(bound(uint256(window), 1, 10 * 365 days));
        uint256 fill = bound(fillSeed, 1, uint256(limit));
        dt = bound(dt, 0, 10 * 365 days);

        _configure(limit, window);
        limiter.outflow(DST_EID, fill);
        vm.warp(block.timestamp + dt);

        (uint256 inFlight, uint256 canBeSent) = limiter.getAmountCanBeSent(DST_EID);

        // Reference model: decay floors, and the stored amount clamps it from above.
        uint256 decay = Math.mulDiv(uint256(limit), dt, window);
        uint256 expectedInFlight = fill - Math.min(fill, decay);
        assertEq(inFlight, expectedInFlight, "[RL-2a] decayed in-flight must match the reference model");
        assertEq(canBeSent, uint256(limit) - expectedInFlight, "[RL-2a] capacity must equal limit minus in-flight");
    }

    /// @dev [RL-2c] The in-flight amount must reach zero exactly at the recovery point
    ///      recovery = ceilDiv(fill * window / limit): one time unit before it the residual is
    ///      still positive, at it the bucket is fully replenished.
    function testFuzz_RecoveryPointExact(uint192 limit, uint64 window, uint256 fillSeed) external {
        limit = uint192(bound(uint256(limit), 1, 1e30));
        window = uint64(bound(uint256(window), 1, 365 days));
        uint256 fill = bound(fillSeed, 1, uint256(limit));

        _configure(limit, window);
        limiter.outflow(DST_EID, fill);

        uint256 recovery = Math.ceilDiv(fill * window, uint256(limit));

        // One unit before the recovery point the decay has not fully consumed the fill yet.
        vm.warp(block.timestamp + recovery - 1);
        (uint256 inFlight,) = limiter.getAmountCanBeSent(DST_EID);
        assertGt(inFlight, 0, "[RL-2c] in-flight must still be positive one unit before the recovery point");

        // At the recovery point the bucket is empty and the full limit is sendable again.
        vm.warp(block.timestamp + 1);
        (uint256 recoveredInFlight, uint256 canBeSent) = limiter.getAmountCanBeSent(DST_EID);
        assertEq(recoveredInFlight, 0, "[RL-2c] in-flight must be zero at the recovery point");
        assertEq(canBeSent, uint256(limit), "[RL-2c] capacity must be fully replenished at the recovery point");
    }

    /// @dev [RL-2a extreme parameters] With the storage-ceiling limit fully consumed, the decay
    ///      product limit * dt must not overflow or panic ((2^192 - 1) * (2^64 - 1) < 2^256) and
    ///      capacity conservation inFlight + canBeSent == limit must still hold.
    function testFuzz_ReplenishAtExtremeParameters(uint64 window, uint256 dt) external {
        window = uint64(bound(uint256(window), 1, 10 * 365 days));
        dt = bound(dt, 0, 10 * 365 days);
        uint192 limit = type(uint192).max;

        _configure(limit, window);
        limiter.outflow(DST_EID, uint256(limit));
        vm.warp(block.timestamp + dt);

        (uint256 inFlight, uint256 canBeSent) = limiter.getAmountCanBeSent(DST_EID);
        assertEq(
            inFlight + canBeSent,
            uint256(limit),
            "[RL-2a] extreme parameters: in-flight plus capacity must equal the limit"
        );
    }

    /// @dev [RL-3b, RV-017 exact boundary] After the limit is lowered below the stored in-flight
    ///      amount, the over-cap residual must heal exactly at
    ///      recovery = ceilDiv(fill * window / newLimit): capacity is fully blocked right after
    ///      the reconfig, the residual is not fully decayed one unit before recovery, and is
    ///      fully replenished at recovery.
    ///      Deviation note: one unit before recovery the residual may already have partially
    ///      freed capacity (in-flight can drop below the new limit), so the assertable
    ///      pre-boundary property is "not yet healed" rather than canBeSent == 0.
    function testFuzz_ResidualHealsAtExactBoundary(uint192 oldLimit, uint192 newLimit, uint64 window, uint256 fillSeed)
        external
    {
        oldLimit = uint192(bound(uint256(oldLimit), 2, 1e30));
        newLimit = uint192(bound(uint256(newLimit), 1, uint256(oldLimit) - 1));
        window = uint64(bound(uint256(window), 1, 365 days));
        uint256 fill = bound(fillSeed, uint256(newLimit) + 1, uint256(oldLimit));

        _configure(oldLimit, window);
        limiter.outflow(DST_EID, fill);

        // The reconfig checkpoints with the old parameters at the same timestamp, so the stored
        // in-flight is carried over unchanged into the new (lower) limit regime.
        _configure(newLimit, window);
        (uint256 inFlight, uint256 canBeSent) = limiter.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, fill, "[RL-3b] reconfig must carry the stored in-flight over unchanged");
        assertEq(canBeSent, 0, "[RL-3b] over-cap residual must fully block capacity right after the reconfig");

        uint256 recovery = Math.ceilDiv(fill * window, uint256(newLimit));

        vm.warp(block.timestamp + recovery - 1);
        (inFlight, canBeSent) = limiter.getAmountCanBeSent(DST_EID);
        assertGt(inFlight, 0, "[RL-3b] residual must not be fully decayed one unit before the recovery point");
        assertLt(canBeSent, uint256(newLimit), "[RL-3b] capacity must not be fully restored before the recovery point");

        vm.warp(block.timestamp + 1);
        (inFlight, canBeSent) = limiter.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0, "[RL-3b] residual must be fully decayed at the recovery point");
        assertEq(canBeSent, uint256(newLimit), "[RL-3b] capacity must equal the new limit at the recovery point");
    }

    /// @dev Configures the rate limit for DST_EID with a single entry.
    function _configure(uint192 limit, uint64 window) internal {
        OutrunRateLimiterUpgradeable.RateLimitConfig[] memory configs =
            new OutrunRateLimiterUpgradeable.RateLimitConfig[](1);
        configs[0] = OutrunRateLimiterUpgradeable.RateLimitConfig({dstEid: DST_EID, limit: limit, window: window});
        limiter.setRateLimits(configs);
    }
}

/// @title Invariant test handler for the rate limiter
/// @notice Drives OutrunRateLimiterHarness with bounded random sequences of sends, warps and
///     reconfigs while maintaining a handler-side reference model of the limiter state for the
///     invariant assertions (docs/audits/2026-08-19/05-invariants.md §3, properties RL-1 and RL-3).
contract RateLimiterSequenceHandler is Test {
    /// @dev The accounting baseline of an epoch: the settled stored amount and the (limit,
    ///      window) pair in force from the epoch's start (reconfig or deployment) onwards.
    struct EpochBaseline {
        uint64 ts;
        uint256 stored;
        uint192 limit;
        uint64 window;
    }

    OutrunRateLimiterHarness public limiter;

    uint32 internal constant DST_EID = 1;

    EpochBaseline[] internal baselines;

    uint256 public ghostEpoch;
    uint256 public ghostSentSinceEpoch;

    /// @dev Set when limiter.outflow reverts with anything other than RateLimitExceeded; hard-failed
    ///      by invariant_noUnexpectedRevert (an in-handler assert would only be soft).
    bool public ghostUnexpectedRevertSeen;

    /// @dev Handler-side reference model, computed ONLY from handler arithmetic (full-precision
    ///      mulDiv + its own event tracking). Never read back from the contract: any contract-side
    ///      stored inflation, half-update on revert, or settlement divergence diverges from the
    ///      model and fails the hard invariants below [RL-1c/RL-1d/RL-3c enforcement].
    uint256 public modelStored;
    uint64 public modelLastTs;
    uint192 public modelLimit; // current-epoch limit
    uint64 public modelWindow; // current-epoch window

    constructor() {
        limiter = new OutrunRateLimiterHarness();

        OutrunRateLimiterUpgradeable.RateLimitConfig[] memory configs =
            new OutrunRateLimiterUpgradeable.RateLimitConfig[](1);
        configs[0] =
            OutrunRateLimiterUpgradeable.RateLimitConfig({dstEid: DST_EID, limit: 1_000_000e18, window: 1 days});
        limiter.setRateLimits(configs);

        modelStored = 0;
        // The initial setRateLimits above configures a previously-unconfigured destination, so
        // its amount == 0 checkpoint is a no-op (window == 0 early return) and the contract's
        // lastUpdated stays 0; the model mirrors that "never written" state instead of now.
        modelLastTs = 0;
        modelLimit = 1_000_000e18;
        modelWindow = 1 days;

        // Epoch 0 baseline: nothing is in flight at deployment time.
        baselines.push(EpochBaseline({ts: uint64(block.timestamp), stored: 0, limit: 1_000_000e18, window: 1 days}));
    }

    /// @dev Reference decay at the CURRENT epoch parameters: stored - min(stored, mulDiv(L, dt, W)).
    function _modelDecay(uint256 stored, uint256 dt) internal view returns (uint256) {
        uint256 decay = Math.mulDiv(modelLimit, dt, modelWindow);
        return stored > decay ? stored - decay : 0;
    }

    /// @notice Sends a bounded random amount, covering both the accepted and the rejected path.
    /// @dev amountSeed is bounded to [0, 4 * currentLimit] so the fuzzer exercises sends above
    ///      the remaining capacity (RateLimitExceeded) as well as accepted sends.
    function send(uint256 amountSeed) external {
        OutrunRateLimiterUpgradeable.RateLimit memory before = limiter.rateLimits(DST_EID);
        uint256 amount = bound(amountSeed, 0, uint256(before.limit) * 4);

        try limiter.outflow(DST_EID, amount) {
            // Accepted: advance the model at full precision, mirroring the contract's write
            // (view-decayed stored + amount, timestamped now) without reading it back.
            modelStored = _modelDecay(modelStored, block.timestamp - modelLastTs) + amount;
            modelLastTs = uint64(block.timestamp);
            ghostSentSinceEpoch += amount;
        } catch (bytes memory reason) {
            // [RL-1c] Rejected sends must leave state untouched. NO model advance and NO in-handler
            // assert (fail_on_revert=false makes it soft): the hard check is
            // invariant_contractStateMatchesModel, which compares the untouched contract slot
            // against the unmoved model. RateLimitExceeded is the ONLY legal revert reason — any
            // other (including a Panic) is recorded here and hard-failed by
            // invariant_noUnexpectedRevert (review LR-007).
            if (bytes4(reason) != OutrunRateLimiterUpgradeable.RateLimitExceeded.selector) {
                ghostUnexpectedRevertSeen = true;
            }
        }
    }

    /// @notice Warps time forward by a bounded random delta.
    /// @dev The model is lazy like the contract: a pure time warp advances no state.
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 30 days));
    }

    /// @notice Reconfigures the limit and window to bounded random values.
    /// @dev The reconfig's pre-update checkpoint settles the stored in-flight under the OLD
    ///      parameters, so the stored amount can only stay equal or decrease.
    function reconfig(uint256 limitSeed, uint256 windowSeed) external {
        uint192 newLimit = uint192(bound(limitSeed, 1, type(uint192).max));
        uint64 newWindow = uint64(bound(windowSeed, 1, 10 * 365 days));

        // Settle the model at the OLD parameters first, mirroring _setRateLimits' old-param
        // checkpoint, then switch the epoch [RL-3c: the settle is computed by handler math; any
        // contract-side inflation diverges and fails invariant_contractStateMatchesModel].
        modelStored = _modelDecay(modelStored, block.timestamp - modelLastTs);
        modelLastTs = uint64(block.timestamp);
        modelLimit = newLimit;
        modelWindow = newWindow;

        OutrunRateLimiterUpgradeable.RateLimitConfig[] memory configs =
            new OutrunRateLimiterUpgradeable.RateLimitConfig[](1);
        configs[0] = OutrunRateLimiterUpgradeable.RateLimitConfig({dstEid: DST_EID, limit: newLimit, window: newWindow});
        limiter.setRateLimits(configs);

        // A reconfig starts a new accounting epoch: throughput accounting restarts from the
        // settled stored amount at the current timestamp.
        ghostEpoch++;
        baselines.push(
            EpochBaseline({ts: uint64(block.timestamp), stored: modelStored, limit: newLimit, window: newWindow})
        );
        ghostSentSinceEpoch = 0;
    }

    /// @notice Returns the accounting baseline of an epoch.
    /// @param epoch Epoch index (0 = deployment, n = after the n-th reconfig)
    function epochBaseline(uint256 epoch) external view returns (EpochBaseline memory) {
        return baselines[epoch];
    }
}

/// @title Rate limiter sequence invariant tests
/// @notice Handler-based invariant tests asserting OutrunRateLimiterUpgradeable's properties
///     over arbitrary sequences of sends, warps and reconfigs
///     (docs/audits/2026-08-19/05-invariants.md §3, properties RL-1 and RL-3).
contract OutrunRateLimiterSequenceInvariantTest is StdInvariant, Test {
    RateLimiterSequenceHandler internal handler;

    uint32 internal constant DST_EID = 1;

    function setUp() external {
        handler = new RateLimiterSequenceHandler();
        targetContract(address(handler));
    }

    /// @dev [RL-1d] The contract's reported in-flight amount must equal the reference model's
    ///      value: decay the handler-side model's stored amount from its anchor timestamp at the
    ///      current-epoch (limit, window). The model anchor is no longer taken from a contract
    ///      snapshot — the stored-accumulation side and the decay-arithmetic side are now both
    ///      hard-checked (review LR-004).
    function invariant_modelEquivalence() public view {
        uint256 stored = handler.modelStored();
        uint256 lastTs = handler.modelLastTs();
        uint256 limit = handler.modelLimit();
        uint256 window = handler.modelWindow();

        uint256 expected = stored - Math.min(stored, Math.mulDiv(limit, block.timestamp - lastTs, window));
        (uint256 viewInFlight,) = handler.limiter().getAmountCanBeSent(DST_EID);
        assertEq(viewInFlight, expected, "[RL-1d] contract in-flight must match the handler-side reference model");
    }

    /// @dev [RL-1a] Remaining capacity plus in-flight must equal the limit, clamped on the
    ///      in-flight side. The naive form inFlight + canBeSent == limit does NOT hold in the
    ///      over-cap residual state: an owner lowering the limit below the stored in-flight
    ///      leaves inFlight > limit with canBeSent == 0, so the assertable form is
    ///      canBeSent == limit - min(inFlight, limit).
    function invariant_capacityConservation() public view {
        OutrunRateLimiterUpgradeable.RateLimit memory rl = handler.limiter().rateLimits(DST_EID);
        (uint256 viewInFlight, uint256 canBeSent) = handler.limiter().getAmountCanBeSent(DST_EID);

        assertEq(
            canBeSent,
            uint256(rl.limit) - Math.min(viewInFlight, uint256(rl.limit)),
            "[RL-1a] capacity must equal limit minus the clamped in-flight amount"
        );
    }

    /// @dev [RL-1b, epoch form] Within the current epoch the total sent amount is bounded by
    ///      the replenished capacity: sent <= stored_n - stored_0 + mulDiv(L, now - t0, W).
    ///      Rationale: stored_n = stored_0 + sent - sum(decay settles), the settle intervals
    ///      partition [t0, last write] within the epoch, and floor subadditivity gives
    ///      sum(floor(L * d_i / W)) <= floor(L * (now - t0) / W), so sum(decay) <= the latter.
    function invariant_windowThroughputBound() public view {
        RateLimiterSequenceHandler.EpochBaseline memory baseline = handler.epochBaseline(handler.ghostEpoch());

        uint256 replenished = Math.mulDiv(baseline.limit, block.timestamp - baseline.ts, baseline.window);
        assertLe(
            handler.ghostSentSinceEpoch(),
            handler.modelStored() + replenished - baseline.stored,
            "[RL-1b] epoch throughput must be bounded by the replenished capacity"
        );
    }

    /// @dev [RL-1c/RL-3c hard enforcement] The stored slot and its timestamp are written only at
    ///      the same moments the model is; pointwise equality of both means any mis-accounted
    ///      accepted send, half-update on a rejected send, or old-parameter settlement drift or
    ///      inflation at a reconfig fails hard here. The (limit, window) slots are pinned too, so a
    ///      reconfig writing wrong parameters cannot escape through a momentarily-zero stock or a
    ///      zero elapsed time (review LR-006). This is NOT a tautology: the model is
    ///      maintained entirely by handler arithmetic and never reads back from the contract.
    function invariant_contractStateMatchesModel() public view {
        OutrunRateLimiterUpgradeable.RateLimit memory rl = handler.limiter().rateLimits(DST_EID);
        assertEq(rl.amountInFlight, handler.modelStored(), "[RL-3c] stored slot must equal the model (no inflation)");
        assertEq(rl.lastUpdated, handler.modelLastTs(), "[RL-1c] lastUpdated must equal the model (no half-updates)");
        assertEq(rl.limit, handler.modelLimit(), "[RL-3c] limit slot must equal the model");
        assertEq(rl.window, handler.modelWindow(), "[RL-3c] window slot must equal the model");
    }

    /// @dev [RL-1c] The ONLY legal revert reason for an outflow is RateLimitExceeded; anything
    ///      else (an arithmetic Panic included) was recorded by the handler and fails hard here.
    function invariant_noUnexpectedRevert() public view {
        assertFalse(handler.ghostUnexpectedRevertSeen(), "[RL-1c] outflow reverted with an unexpected reason");
    }
}
