// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Outrun cross-chain transfer rate limiter
/// @notice Rate limiter for cross-chain transfers. Uses a linear decay model: capacity refills proportionally
///      over time. When no window is configured, the limit is infinite.
abstract contract OutrunRateLimiterUpgradeable is Initializable {
    struct RateLimit {
        // Packed layout follows current LayerZero OApp RateLimiter.
        uint192 amountInFlight;
        uint64 lastUpdated;
        uint192 limit;
        uint64 window;
    }

    struct RateLimitConfig {
        // Packed layout follows current LayerZero OApp RateLimiter.
        uint32 dstEid;
        uint192 limit;
        uint64 window;
    }

    /// @custom:storage-location erc7201:outrun.storage.OutrunRateLimiter
    struct OutrunRateLimiterStorage {
        mapping(uint32 dstEid => RateLimit limit) rateLimits;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunRateLimiter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_RATE_LIMITER_STORAGE_LOCATION =
        0xd48bb12cf4270f606da51b56ba6371646e75d13e96dee8184b97a52adeda4000;

    event RateLimitsChanged(RateLimitConfig[] rateLimitConfigs);

    error RateLimitExceeded();

    function _getOutrunRateLimiterStorage() private pure returns (OutrunRateLimiterStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := OUTRUN_RATE_LIMITER_STORAGE_LOCATION
        }
    }

    function __OutrunRateLimiter_init() internal onlyInitializing {}

    /// @notice Returns the stored rate limit configuration for a destination.
    /// @param dstEid Destination endpoint ID
    /// @return RateLimit struct (amountInFlight, lastUpdated, limit, window)
    function rateLimits(uint32 dstEid) public view returns (RateLimit memory) {
        return _getOutrunRateLimiterStorage().rateLimits[dstEid];
    }

    /// @notice Returns how much can currently be sent to a destination given the rate limit state.
    /// @param dstEid Destination endpoint ID
    /// @return currentAmountInFlight Tokens currently in-flight
    /// @return amountCanBeSent Remaining capacity available to send
    /// @dev When window == 0 (unconfigured or deleted limit) the capacity is infinite and this returns
    ///      the type(uint256).max sentinel. Subclasses with their own amount envelope (e.g. OFT's
    ///      uint64 shared-decimals wire cap) must override to return that envelope instead.
    function getAmountCanBeSent(uint32 dstEid)
        public
        view
        virtual
        returns (uint256 currentAmountInFlight, uint256 amountCanBeSent)
    {
        RateLimit memory rl = rateLimits(dstEid);
        // window == 0 means the destination is unconfigured (or its limit was deleted): the limit is
        // infinite, matching _checkAndUpdateRateLimit's early return. The sentinel cannot collide with
        // a configured state, whose sendable amount is bounded by limit <= type(uint192).max.
        if (rl.window == 0) return (0, type(uint256).max);
        return _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
    }

    /// @notice Applies a batch of rate limit configurations, checkpointing each before updating.
    /// @param rateLimitConfigs Array of rate limit configs (dstEid, limit, window)
    function _setRateLimits(RateLimitConfig[] memory rateLimitConfigs) internal virtual {
        OutrunRateLimiterStorage storage $ = _getOutrunRateLimiterStorage();
        uint256 numConfigs = rateLimitConfigs.length;
        unchecked {
            for (uint256 i; i < numConfigs; ++i) {
                RateLimit storage rl = $.rateLimits[rateLimitConfigs[i].dstEid];
                // Checkpoint with the old limit/window before replacing them; amount == 0 settles existing in-flight
                // amount at this timestamp without recording a new outflow, preventing retroactive new-rate decay.
                _checkAndUpdateRateLimit(rl, 0);
                rl.limit = rateLimitConfigs[i].limit;
                rl.window = rateLimitConfigs[i].window;
            }
        }
        emit RateLimitsChanged(rateLimitConfigs);
    }

    /// @notice Computes current in-flight and available capacity using linear decay.
    /// @dev Capacity refills proportionally over time: decay = (limit * timeSinceLastUpdate) / window.
    /// @param amountInFlight Current in-flight amount
    /// @param lastUpdated Timestamp of the last rate limit update
    /// @param limit Maximum amount allowed in the window
    /// @param window Time window in seconds for full capacity refill
    /// @return currentAmountInFlight In-flight amount after applying time-based decay
    /// @return amountCanBeSent Remaining capacity available to send
    // slither-disable-next-line timestamp
    function _amountCanBeSent(uint192 amountInFlight, uint64 lastUpdated, uint192 limit, uint64 window)
        internal
        view
        virtual
        returns (uint256 currentAmountInFlight, uint256 amountCanBeSent)
    {
        // Computes how much capacity has refilled since the last rate limit update.
        // Decay = (limit * timeSinceLastUpdate) / window.
        // Current in-flight = max(0, previousInFlight - decay).
        // Available = limit - currentInFlight.
        // slither-disable-next-line timestamp
        uint256 timeSinceLastUpdate = block.timestamp - lastUpdated;
        if (timeSinceLastUpdate >= window) return (0, limit);
        uint256 decay = (uint256(limit) * timeSinceLastUpdate) / window;
        if (amountInFlight > decay) {
            // The guard prevents underflow.
            unchecked {
                currentAmountInFlight = amountInFlight - decay;
            }
        }
        if (limit > currentAmountInFlight) {
            // The guard prevents underflow.
            unchecked {
                amountCanBeSent = limit - currentAmountInFlight;
            }
        }
    }

    /// @notice Records an outflow against the rate limit for a destination.
    /// @param dstEid Destination endpoint ID
    /// @param amount Amount of tokens being sent
    // slither-disable-next-line timestamp
    function _outflow(uint32 dstEid, uint256 amount) internal virtual {
        _checkAndUpdateRateLimit(dstEid, amount);
    }

    /// @notice Checks and updates the rate limit for a destination: reverts if the outflow would exceed capacity.
    /// @dev Updates in-flight counter after applying time-based decay. The counter decays automatically.
    /// @param dstEid Destination endpoint ID
    /// @param amount Outflow amount to record
    // slither-disable-next-line timestamp
    function _checkAndUpdateRateLimit(uint32 dstEid, uint256 amount) internal {
        OutrunRateLimiterStorage storage $ = _getOutrunRateLimiterStorage();
        RateLimit storage rl = $.rateLimits[dstEid];
        _checkAndUpdateRateLimit(rl, amount);
    }

    /// @notice Checks and updates a loaded rate limit: reverts if the outflow would exceed capacity.
    /// @dev Accepts storage directly so callers that already loaded the rate limit do not resolve it again.
    /// @param rl Stored rate limit to checkpoint and update
    /// @param amount Outflow amount to record
    // slither-disable-next-line timestamp
    function _checkAndUpdateRateLimit(RateLimit storage rl, uint256 amount) internal {
        if (rl.window == 0) return;
        (uint256 currentAmountInFlight, uint256 amountCanBeSent) =
            _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
        if (amount > amountCanBeSent) revert RateLimitExceeded();
        // casting to uint192 is safe because currentAmountInFlight + amount is bounded by
        // max(rl.limit, the stored amountInFlight), and both are uint192. On the outflow path the
        // revert check above caps the sum at rl.limit; on the amount == 0 checkpoint path the sum
        // equals the decayed stored amountInFlight, itself already a uint192. An owner lowering
        // the limit can leave in-flight above the new limit — that over-limit state is expected
        // and decays back under the limit over time.
        // forge-lint: disable-next-line(unsafe-typecast)
        rl.amountInFlight = uint192(currentAmountInFlight + amount);
        // slither-disable-next-line timestamp
        rl.lastUpdated = uint64(block.timestamp);
    }

    /// @notice Deletes the stored rate limit for a destination, removing all capacity constraints.
    /// @param dstEid Destination endpoint ID
    function _deleteRateLimit(uint32 dstEid) internal {
        delete _getOutrunRateLimiterStorage().rateLimits[dstEid];
    }
}
