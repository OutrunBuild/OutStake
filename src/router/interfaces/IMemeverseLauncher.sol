// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title MemeverseLauncher interface
 */
interface IMemeverseLauncher {
    function genesis(uint256 verseId, uint256 amountInUPT, address user) external;
}
