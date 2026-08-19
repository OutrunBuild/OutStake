// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Outrun cross-chain transfer rate limiter
/// @notice Rate limiter for cross-chain transfers. Uses a linear decay model: capacity refills proportionally
///      over time. When no window is configured, the limit is infinite.
abstract contract OutrunRateLimiterUpgradeable is Initializable {
    struct RateLimit {
        // Packed layout follows current LayerZero OApp RateLimiter.
        // Units: amountInFlight and limit are in LOCAL decimals (LD), i.e. the same unit as the
        // amountSentLD that _debit/_outflow record. For an 18-dec OFT (DCR = 1e12) 1 token = 1e18;
        // they are NOT the shared-decimals (SD) wire unit.
        // IMMUTABLE STORAGE LAYOUT: this struct is the persisted value of
        // OutrunRateLimiterStorage.rateLimits (ERC-7201 namespace outrun.storage.OutrunRateLimiter),
        // so the implementation the proxy points at after a UUPS upgrade keeps decoding the same
        // two slots. Once deployed the packing below is contract:
        //   slot0 = amountInFlight:uint192 | lastUpdated:uint64
        //   slot1 = limit:uint192 | window:uint64
        // Field ORDER, WIDTH, and count must never change (no reorder, resize, or insertion) or
        // previously persisted rate-limit state is silently misread. The two-slot layout is pinned
        // by test/upgradeable/OutrunRateLimiterStorageLayout.t.sol.
        uint192 amountInFlight;
        uint64 lastUpdated;
        uint192 limit;
        uint64 window;
    }

    struct RateLimitConfig {
        // Packed layout follows current LayerZero OApp RateLimiter.
        // Units: limit is in LOCAL decimals (LD), matching RateLimit.limit (see struct RateLimit).
        // Memory-only configuration struct: constructed per call in
        // OutrunOFTUpgradeable::setOutboundRateLimit and ABI-encoded into the RateLimitsChanged
        // event. It is never persisted, so it is outside the UUPS storage-layout freeze above.
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
    /// @param amountInFlight Current in-flight amount, in LD (local decimals)
    /// @param lastUpdated Timestamp of the last rate limit update
    /// @param limit Maximum amount allowed in the window, in LD (local decimals)
    /// @param window Time window in seconds for full capacity refill
    /// @return currentAmountInFlight In-flight amount after applying time-based decay, in LD
    /// @return amountCanBeSent Remaining capacity available to send, in LD
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
        // Zero in-flight already means the full limit is available; the decay below
        // would only be discarded, so short-circuit before computing it.
        if (amountInFlight == 0) return (0, limit);
        uint256 timeSinceLastUpdate;
        uint256 decay;
        unchecked {
            timeSinceLastUpdate = block.timestamp - lastUpdated;
            decay = (uint256(limit) * timeSinceLastUpdate) / window;
        }
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
    /// @param amount Amount of tokens being sent, in LD (local decimals); must match the unit of
    ///         the stored limit (for an 18-dec OFT this is 1e18 per token, not SD/1e12)
    function _outflow(uint32 dstEid, uint256 amount) internal virtual {
        OutrunRateLimiterStorage storage $ = _getOutrunRateLimiterStorage();
        RateLimit storage rl = $.rateLimits[dstEid];
        _checkAndUpdateRateLimit(rl, amount);
    }

    /// @notice Checks and updates a loaded rate limit: reverts if the outflow would exceed capacity.
    /// @dev Accepts storage directly so callers that already loaded the rate limit do not resolve it again.
    /// @param rl Stored rate limit to checkpoint and update
    /// @param amount Outflow amount to record, in LD (local decimals), compared against the
    ///         stored limit which is also in LD
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
        unchecked {
            // forge-lint: disable-next-line(unsafe-typecast)
            rl.amountInFlight = uint192(currentAmountInFlight + amount);
        }
        rl.lastUpdated = uint64(block.timestamp);
    }

    /// @notice Deletes the stored rate limit for a destination, removing all capacity constraints.
    /// @dev `delete` 清空整条记录（amountInFlight/lastUpdated/limit/window 一并归零）。与 `_setRateLimits` 的 checkpoint 保留 in-flight 语义不同，删除后重新 setOutboundRateLimit 从零会计、满额开始，不可当作“暂停限流但保留会计”。
    /// @param dstEid Destination endpoint ID
    function _deleteRateLimit(uint32 dstEid) internal {
        delete _getOutrunRateLimiterStorage().rateLimits[dstEid];
    }
}
