// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IExchangeRateOracle} from "./interfaces/IExchangeRateOracle.sol";
import {AggregatorInterface} from "./interfaces/AggregatorInterface.sol";
import {SYUtils} from "../SYUtils.sol";

/// @notice Thin adapter that wraps a Chainlink-style oracle (AggregatorInterface) into an IExchangeRateOracle.
/// Normalizes the oracle's raw answer to a fixed 1e18 scale (the scale SYUtils requires for position accounting).
/// Validates that the answer is positive, that the latest round was actually answered, and that it was
/// updated within the configured staleness window. Does not apply
/// deviation bounds, fallback oracle logic, or multi-source aggregation.
contract OutrunExchangeOracleAdapter is IExchangeRateOracle {
    /// @notice The underlying Chainlink-style price feed that provides the raw exchange rate answer.
    address public immutable oracle;
    /// @notice The underlying oracle's native decimal precision (captured once at construction).
    uint8 public immutable rawDecimals;
    /// @notice Maximum age allowed for the latest oracle answer. Starts at the construction value
    /// and can be reconfigured at runtime by the owner via `setMaxStaleness`.
    uint256 public maxStaleness;
    /// @notice Optional Chainlink L2 Sequencer Uptime Feed. Zero address disables this check.
    address public immutable sequencerUptimeFeed;
    /// @notice Time to wait after the sequencer comes back up before trusting oracle answers.
    uint256 public immutable sequencerGracePeriod;
    /// @notice On-chain fail-safe ceiling for any staleness window configured at construction or at
    /// runtime: `setMaxStaleness` rejects values above it, so the window can never be widened
    /// into an unbounded stale-price region.
    uint256 public constant MAX_STALENESS = 30 days;
    /// @notice Authorized manager of the staleness window (captured as the deploying address).
    /// @dev There is no timelock and no ownership-transfer path — this is a governance-layer
    /// decision. Deploy this adapter from the managing multisig so `owner` is that multisig.
    address public immutable owner;
    /// @dev 10^rawDecimals, precomputed at construction so rate reads do a plain multiply + divide.
    uint256 private immutable _rawScale;

    /// @notice Emitted when the owner reconfigures the staleness window.
    /// @param oldMaxStaleness The previous maximum allowed age (in seconds) for an oracle answer.
    /// @param newMaxStaleness The new maximum allowed age (in seconds) for an oracle answer.
    event SetMaxStaleness(uint256 oldMaxStaleness, uint256 newMaxStaleness);

    /// @notice Reverts when a staleness window outside (0, MAX_STALENESS] is configured at
    /// construction or at runtime.
    error InvalidStaleness();

    /// @notice Reverts when a zero oracle address is configured at construction.
    error InvalidOracle();

    /// @notice Reverts when a non-owner calls `setMaxStaleness`.
    error NotOwner();

    /// @notice Sets the underlying Chainlink-style oracle and captures its native decimal precision once at construction.
    /// @param _oracle The address of the Chainlink-style price feed (AggregatorInterface); must be != address(0).
    /// @param _maxStaleness Maximum allowed age (in seconds) for `latestRoundData().updatedAt`; must be
    /// > 0 and <= MAX_STALENESS.
    /// @param _sequencerUptimeFeed Optional Chainlink L2 Sequencer Uptime Feed; zero address disables this check.
    /// @param _sequencerGracePeriod Grace period after sequencer recovery before oracle answers are trusted.
    /// @dev Captures raw oracle decimals at construction. If the underlying oracle later changes its decimals
    /// (which Chainlink does not), this adapter won't track the change — that's by design for simplicity.
    // A zero _sequencerUptimeFeed is the supported sentinel that disables the optional sequencer check
    // in _validateSequencer; it is not a misconfigured address.
    constructor(address _oracle, uint256 _maxStaleness, address _sequencerUptimeFeed, uint256 _sequencerGracePeriod) {
        // The fail-safe ceiling covers every path that can set the window, so construction and
        // setMaxStaleness share the same (0, MAX_STALENESS] domain.
        if (_maxStaleness == 0 || _maxStaleness > MAX_STALENESS) revert InvalidStaleness();
        if (_oracle == address(0)) revert InvalidOracle();
        owner = msg.sender;
        oracle = _oracle;
        maxStaleness = _maxStaleness;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
        rawDecimals = AggregatorInterface(_oracle).decimals();
        // Precompute the normalization power of ten once here: immutables are not constant-folded, so
        // leaving "10 ** rawDecimals" in getExchangeRate would run an exponentiation call plus overflow
        // guard on every rate read. Computing it at construction turns the hot path into a plain multiply + divide.
        _rawScale = 10 ** rawDecimals;
    }

    /**
     * @notice Reconfigures the maximum allowed age for the latest oracle answer.
     * @param _maxStaleness The new maximum allowed age (in seconds) for `latestRoundData().updatedAt`;
     * must be > 0 and <= MAX_STALENESS (30 days).
     * @dev Callable only by `owner` (the deploying multisig). There is no timelock on this call —
     * that is a deliberate governance-layer decision; the on-chain MAX_STALENESS ceiling is the
     * only hard bound, so even a compromised owner cannot widen the window past 30 days.
     * Emits `SetMaxStaleness(old, new)`.
     */
    function setMaxStaleness(uint256 _maxStaleness) external {
        if (msg.sender != owner) revert NotOwner();
        if (_maxStaleness == 0 || _maxStaleness > MAX_STALENESS) revert InvalidStaleness();
        uint256 oldMaxStaleness = maxStaleness;
        maxStaleness = _maxStaleness;
        emit SetMaxStaleness(oldMaxStaleness, _maxStaleness);
    }

    /**
     * @notice Returns the latest oracle exchange rate scaled to the fixed 1e18 (SYUtils) scale.
     * @dev Reverts when an L2 sequencer uptime feed is configured and the sequencer is down or still in its
     * post-recovery grace window, when the underlying oracle answer is non-positive, when the latest round
     * was not answered, when the answer is stale,
     * or when normalization truncates the answer to zero (a non-standard feed with more than 18 decimals and
     * a small answer). Does not apply deviation bounds, fallback oracle logic, or multi-source aggregation.
     * @return The normalized exchange rate value.
     */
    function getExchangeRate() external view returns (uint256) {
        _validateSequencer();
        // Chainlink-style feeds expose update time only through latestRoundData().
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorInterface(oracle).latestRoundData();
        if (answer <= 0) revert InvalidOracleAnswer();
        // Incomplete round: the feed has not answered the latest round — treat the carried-forward
        // answer as stale even if its updatedAt is still inside the window.
        if (answeredInRound < roundId) revert StaleOracleAnswer();
        if (updatedAt == 0 || updatedAt > block.timestamp) revert StaleOracleAnswer();
        unchecked {
            if (block.timestamp - updatedAt > maxStaleness) revert StaleOracleAnswer();
        }
        // Normalize: (rawAnswer * SYUtils.ONE) / _rawScale.
        // Example: raw=1.05e8 (8 decimals), fixed 1e18 scale -> 1.05e8 * 1e18 / 1e8 -> 1.05e18.
        // An extreme answer whose checked multiply overflows uint256 reverts with Panic(0x11) fail-closed.
        uint256 rate = (uint256(answer) * SYUtils.ONE) / _rawScale;
        // A feed with more than 18 decimals and a small answer normalizes to zero; fail closed with a
        // named error instead of leaking rate == 0 (downstream divide-by-zero) to position accounting.
        if (rate == 0) revert ZeroNormalizedRate();
        return rate;
    }

    function _validateSequencer() internal view {
        address _sequencerUptimeFeed = sequencerUptimeFeed;
        if (_sequencerUptimeFeed == address(0)) return; // optional check: a zero feed disables it

        // Chainlink L2 Sequencer Uptime Feed encodes status inversely to the naive guess:
        // answer == 0 means the sequencer is UP (healthy); any non-zero answer means it is DOWN.
        (, int256 answer, uint256 startedAt,,) = AggregatorInterface(_sequencerUptimeFeed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        // Fail closed while recovery is unverifiable or still warming up. startedAt == 0 means recovery was
        // never recorded; startedAt > block.timestamp means the feed clock is ahead of the chain (untrustworthy).
        // Both share one error for simplicity — split it if deployment troubleshooting must tell them apart.
        if (startedAt == 0 || startedAt > block.timestamp) revert SequencerGracePeriodNotOver();
        // Even after recovery is recorded, wait out the grace window so a price updated during the downtime is not used.
        unchecked {
            if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriodNotOver();
        }
    }
}
