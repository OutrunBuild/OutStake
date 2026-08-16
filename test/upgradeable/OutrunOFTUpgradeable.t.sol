// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MessagingFee, OFTLimit, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
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
                abi.encodeCall(OutrunUpgradeableOftHarness.initialize, ("Outrun OFT", "OFT", 18, owner))
            )
        );

        // Mint tokens on the harness for debit/credit/outflow tests.
        oft.exposedCredit(user, 100e18, 0);
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

    function testSetOutboundRateLimitDoesNotDispatchVirtualOutflow() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        assertEq(oft.outflowCalls(), 0);
    }

    function testDebitDispatchesVirtualOutflow() external {
        vm.prank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);

        vm.prank(user);
        oft.exposedDebit(user, 25e18, 0, DST_EID);

        assertEq(oft.outflowCalls(), 1);
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

    function testRemoveLimitRestoresSharedDecimalEnvelope() external {
        vm.startPrank(owner);
        oft.setOutboundRateLimit(DST_EID, 40e18, 1 days);
        oft.removeOutboundRateLimit(DST_EID);
        vm.stopPrank();

        (uint256 inFlight, uint256 canBeSent) = oft.getAmountCanBeSent(DST_EID);
        assertEq(inFlight, 0);
        assertEq(canBeSent, uint256(type(uint64).max) * oft.decimalConversionRate());
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

    /// @dev F-031 regression: window == 0 must read as "infinite limit" in the base view,
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
