// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunRateLimiterUpgradeable} from "../../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";

/// @dev Test harness exposing OutrunRateLimiterUpgradeable internals so tests can drive
///      base-contract rate limit state without deploying the full OFT stack. The base
///      contract is abstract and upgradeable, which the test rules allow inheriting here.
///      No initializer is needed: the wrapped internals are not onlyInitializing-guarded.
contract OutrunRateLimiterHarness is OutrunRateLimiterUpgradeable {
    /// @notice Applies a batch of rate limit configurations.
    /// @param rateLimitConfigs Array of rate limit configs (dstEid, limit, window)
    function setRateLimits(RateLimitConfig[] memory rateLimitConfigs) external {
        _setRateLimits(rateLimitConfigs);
    }

    /// @notice Deletes the stored rate limit for a destination.
    /// @param dstEid Destination endpoint ID
    function removeRateLimit(uint32 dstEid) external {
        _deleteRateLimit(dstEid);
    }
}
