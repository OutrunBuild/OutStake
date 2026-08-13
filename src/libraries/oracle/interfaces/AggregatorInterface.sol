// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice Minimal view over a Chainlink-style price feed. Only the two members OutrunExchangeOracleAdapter
/// actually consumes are declared. The full official AggregatorV2V3Interface (V2 + V3 accessors + events)
/// is vendored under lib/chainlink; if a future consumer needs more accessors, add them here at that point
/// rather than speculatively — see AGENTS.md "Simplicity First".
// solhint-disable-next-line interface-starts-with-i
interface AggregatorInterface {
    /// @notice Return the number of decimals used by the answer.
    /// @dev OutrunExchangeOracleAdapter reads this once to normalize `latestRoundData().answer`.
    /// @return The decimals used to scale answer values.
    function decimals() external view returns (uint8);

    /// @notice Return round data for the latest round.
    /// @dev OutrunExchangeOracleAdapter consumes `answer` and `updatedAt` from the price feed, and `answer` and
    ///      `startedAt` from the optional sequencer uptime feed, both via this tuple.
    /// @return roundId The latest round id.
    /// @return answer The latest answer value.
    /// @return startedAt The timestamp when the latest round started.
    /// @return updatedAt The timestamp when the latest answer was updated.
    /// @return answeredInRound The round in which the latest answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
