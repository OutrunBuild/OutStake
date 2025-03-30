//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IMETHStaking {
    function ethToMETH(uint256 ethAmount) external view returns (uint256);

    function mETHToETH(uint256 mETHAmount) external view returns (uint256);

    function stake(uint256 minMETHAmount) external payable;
}