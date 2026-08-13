// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @dev Stand-in for a Chainlink-style feed. Only `decimals()` and `latestRoundData()` are read by
/// OutrunExchangeOracleAdapter (via address cast); the `setLatest*` setters drive test scenarios.
/// Unused Chainlink accessors are intentionally omitted — AggregatorInterface declares only the
/// consumed members, and this mock mirrors that surface.
/// This mock also doubles as the sequencer uptime feed in adapter tests. When writing sequencer
/// recovery scenarios (answer == 0 means the sequencer is up), do NOT use `setLatestAnswer`:
/// it pins startedAt to now, which always trips SequencerGracePeriodNotOver. Use the
/// three-argument `setLatestRoundData` with a startedAt far enough in the past instead.
contract MockAggregator {
    int256 internal latestOracleAnswer;
    uint256 internal latestOracleUpdatedAt;
    uint256 internal latestOracleStartedAt;
    uint8 internal immutable decimalsValue;

    constructor(uint8 decimals_) {
        decimalsValue = decimals_;
    }

    /// @dev Writes answer and sets startedAt = updatedAt = block.timestamp (a fresh, up-to-date round).
    function setLatestAnswer(int256 answer) external {
        latestOracleAnswer = answer;
        latestOracleStartedAt = block.timestamp;
        latestOracleUpdatedAt = block.timestamp;
    }

    /// @dev Writes answer and sets startedAt = updatedAt = the given timestamp (a round aged to that time).
    function setLatestRoundData(int256 answer, uint256 updatedAt) external {
        latestOracleAnswer = answer;
        latestOracleStartedAt = updatedAt;
        latestOracleUpdatedAt = updatedAt;
    }

    /// @dev Writes answer and both timestamps exactly as given. Sequencer recovery tests must use this
    /// overload with startedAt in the past — a fresh startedAt keeps the adapter inside its grace window.
    function setLatestRoundData(int256 answer, uint256 startedAt, uint256 updatedAt) external {
        latestOracleAnswer = answer;
        latestOracleStartedAt = startedAt;
        latestOracleUpdatedAt = updatedAt;
    }

    function decimals() external view returns (uint8) {
        return decimalsValue;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, latestOracleAnswer, latestOracleStartedAt, latestOracleUpdatedAt, 1);
    }
}
