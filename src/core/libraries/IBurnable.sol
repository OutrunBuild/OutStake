// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

 /**
  * @title Burnable interface
  */
interface IBurnable {
    /**
     * @notice Burn the token by self.
     * @param amount - The amount of the token to burn
     */
	  function burn(uint256 amount) external;

    /**
     * @notice Burn the token by others.
     * @param account - The address of account
     * @param amount - The amount of the token to burn
     */
	  function burn(address account, uint256 amount) external;
}