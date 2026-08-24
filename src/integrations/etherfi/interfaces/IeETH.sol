// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title Ether.fi eETH interface (minimal)
/// @notice Minimal view of Ether.fi eETH needed by OutrunWeETHSY to replicate
///      LiquidityPool's post-deposit rate (P_new/S_new) inside a view preview.
interface IeETH {
    /// @notice Total eETH shares across all holders
    function totalShares() external view returns (uint256);
}
