//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IWeETH {
    function wrap(uint256 _eETHAmount) external returns (uint256);

    function unwrap(uint256 _weETHAmount) external returns (uint256);
}