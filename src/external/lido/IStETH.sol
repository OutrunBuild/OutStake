//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IStETH {
    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256);

    function getPooledEthByShares(uint256 shareAmount) external view returns (uint256);

    function submit() external payable returns (uint256);
}