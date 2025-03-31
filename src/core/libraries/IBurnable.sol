// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

 /**
  * @title Burnable interface
  */
interface IBurnable {
    /**
     * @notice Burn the token.
     * @param account - The address of account
     * @param amount - The amount of the token to burn
     * @notice Permission control must be set
     */
	  function burn(address account, uint256 amount) external;
}