//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IWstETH {
    function stEthPerToken() external view returns (uint256);

    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);

    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);

    function wrap(uint256 stETHAmount) external returns (uint256);

    function unwrap(uint256 wstETHAmount) external returns (uint256);
}
