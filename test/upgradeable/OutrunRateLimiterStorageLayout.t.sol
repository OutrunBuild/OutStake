// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {OutrunRateLimiterHarness} from "./mocks/OutrunRateLimiterHarness.sol";

/// @notice Freezes the persisted storage layout of the rate-limiter ledger.
///
/// `OutrunRateLimiterStorage.rateLimits` (ERC-7201 namespace `outrun.storage.OutrunRateLimiter`)
/// stores each destination's `RateLimit` as a mapping value that must survive UUPS upgrades. That
/// value packs exactly two slots:
///
///     slot0 = amountInFlight:uint192 | lastUpdated:uint64
///     slot1 = limit:uint192          | window:uint64
///
/// The assertions below pin field order and width against the raw storage words, so any future
/// reorder/resize/insertion of the struct fields breaks this test instead of silently misreading
/// persisted in-flight state after an upgrade. See the IMMUTABLE STORAGE LAYOUT comment on
/// `OutrunRateLimiterUpgradeable.sol::RateLimit`.
contract OutrunRateLimiterStorageLayoutTest is Test {
    function test_RateLimitMappingValueIsTwoSlotPackedLayout() external {
        OutrunRateLimiterHarness limiter = new OutrunRateLimiterHarness();

        uint32 dstEid = 101;
        uint192 limit = uint192(1e24);
        uint64 window = 7 days;

        OutrunRateLimiterUpgradeable.RateLimitConfig[] memory configs =
            new OutrunRateLimiterUpgradeable.RateLimitConfig[](1);
        configs[0] = OutrunRateLimiterUpgradeable.RateLimitConfig({dstEid: dstEid, limit: limit, window: window});

        // First write onto a fresh entry only sets limit/window (window was 0, so the checkpoint
        // inside _checkAndUpdateRateLimit early-returns), leaving lastUpdated untouched. A second
        // write re-checkpoints the now-configured entry and stamps lastUpdated with the current
        // block.timestamp, which vm.warp has set to a deterministic value. Asserting against the
        // compile-time constant (never against block.timestamp read in the test itself, which is
        // unreliable under via_ir cheatcode lifting) pins a NONZERO lastUpdated in slot0's high 64.
        vm.warp(1_700_000_000);
        limiter.setRateLimits(configs);
        vm.warp(1_700_000_000 + 1 days);
        limiter.setRateLimits(configs);
        uint64 expectedLastUpdated = uint64(1_700_000_000 + 1 days);

        // rateLimits is the first (only) field of OutrunRateLimiterStorage -> its mapping occupies
        // the namespace base slot. A uint32 key's value slot is keccak256(abi.encode(key, slot)).
        bytes32 baseSlot = _erc7201("outrun.storage.OutrunRateLimiter");
        bytes32 valueSlot = keccak256(abi.encode(uint256(dstEid), baseSlot));
        bytes32 slot0 = vm.load(address(limiter), valueSlot);
        bytes32 slot1 = vm.load(address(limiter), bytes32(uint256(valueSlot) + 1));

        // The struct must occupy EXACTLY two slots: slot0/slot1 are full 256-bit packs, so any
        // appended or inserted field would spill into slot2 and trip the empty check below (a
        // tail append would otherwise pass the four field assertions while silently widening the
        // persisted layout).
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint256(vm.load(address(limiter), bytes32(uint256(valueSlot) + 2))), 0, "slot2 must stay empty");

        // slot0 = amountInFlight:uint192 (low) | lastUpdated:uint64 (high).
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint192(uint256(slot0)), 0, "amountInFlight must sit in the low 192 bits of slot0");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(
            uint64(uint256(slot0) >> 192), expectedLastUpdated, "lastUpdated must sit in the high 64 bits of slot0"
        );

        // slot1 = limit:uint192 (low) | window:uint64 (high).
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint192(uint256(slot1)), limit, "limit must sit in the low 192 bits of slot1");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint64(uint256(slot1) >> 192), window, "window must sit in the high 64 bits of slot1");
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
