//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Ether.fi weETH interface
 * @notice Ether.fi's wrapped eETH token; OutrunWeETHSY wraps eETH into weETH on deposit and unwraps back to
 *      eETH on redemption.
 */
interface IWeETH {
    /**
     * @notice Wraps eETH into weETH.
     * @dev OutrunWeETHSY calls this after it holds eETH and consumes the return value as minted SY shares.
     * @param _eETHAmount The amount of eETH to wrap.
     * @return The amount of weETH minted.
     */
    function wrap(uint256 _eETHAmount) external returns (uint256);

    /**
     * @notice Unwraps weETH into eETH.
     * @dev OutrunWeETHSY calls this on redemption when eETH is the requested output.
     * @param _weETHAmount The amount of weETH to unwrap.
     * @return The amount of eETH returned.
     */
    function unwrap(uint256 _weETHAmount) external returns (uint256);
}
