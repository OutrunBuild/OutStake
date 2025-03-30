//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface ISlisBNBProvider {
    function provide(uint256 amount, address delegateTo) external returns (uint256);

    function release(address recipient, uint256 amount) external returns (uint256);
}