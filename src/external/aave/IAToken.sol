// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAToken {
  function UNDERLYING_ASSET_ADDRESS() external view returns (address);

  function scaledBalanceOf(address user) external view returns (uint256);

  function getScaledUserBalanceAndSupply(address user) external view returns (uint256, uint256);

  function scaledTotalSupply() external view returns (uint256);

  function getPreviousIndex(address user) external view returns (uint256);
}