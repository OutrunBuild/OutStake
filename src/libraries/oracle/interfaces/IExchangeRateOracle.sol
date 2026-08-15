// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Exchange rate oracle interface
 * @notice Source of the canonical-asset-per-SY exchange rate scaled by 1e18 for SY position accounting.
 *      Implemented by OutrunExchangeOracleAdapter (a thin Chainlink-style feed wrapper that normalizes the raw
 *      answer to 1e18 and fails closed on non-positive or stale answers); consumed by
 *      OutrunL2OracleBackedSYUpgradeable, whose `exchangeRate()` forwards to `getExchangeRate()`. Declares the
 *      revert surface implementers share: InvalidOracleAnswer (non-positive answer), ZeroNormalizedRate (a
 *      non-standard feed with more than 18 decimals whose answer is too small to survive 1e18 normalization),
 *      StaleOracleAnswer, and the L2 sequencer errors SequencerDown / SequencerGracePeriodNotOver.
 */
interface IExchangeRateOracle {
    /// @notice Returns the current exchange rate, scaled by 1e18 (asset per SY), for SY accounting.
    /// @dev Implementations MUST return a 1e18-scaled value: position accounting divides the rate by a hardcoded
    ///      1e18 (SYUtils.ONE), so any other scale silently breaks stake/wrap accounting. This interface does not
    ///      add freshness, bounds, fallback, or multi-source guarantees.
    /// @return The current exchange rate value (1e18-scaled).
    function getExchangeRate() external view returns (uint256);

    /// @dev Reverts when the underlying oracle answer is non-positive.
    error InvalidOracleAnswer();
    /// @dev Reverts when the normalized exchange rate truncates to zero — a non-standard feed whose
    ///      decimals exceed 18 and whose answer is too small to survive normalization.
    error ZeroNormalizedRate();
    /// @dev Reverts when the answer's `updatedAt` is zero, older than the configured staleness window, or ahead
    /// of the current block timestamp (feed clock ahead of the chain).
    error StaleOracleAnswer();
    /// @dev Reverts when the L2 sequencer uptime feed reports the sequencer as down. Per the Chainlink
    ///      convention a non-zero answer means DOWN — `answer == 0` means UP (the inverse of the naive guess).
    error SequencerDown();
    /// @dev Reverts during the post-recovery grace window, or when recovery cannot yet be verified
    ///      (`startedAt == 0` never recorded, or `startedAt` ahead of chain time).
    error SequencerGracePeriodNotOver();
}
