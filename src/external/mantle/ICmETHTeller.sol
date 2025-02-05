//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";

interface ICmETHTeller {
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) external payable returns (uint256 shares);
}