//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface ISlisUSD {
    function deposit(uint256 amount) external;

    function convertToShares(uint256 asset) external view returns (uint256);

    function convertToAssets(uint256 share) external view returns (uint256);
}