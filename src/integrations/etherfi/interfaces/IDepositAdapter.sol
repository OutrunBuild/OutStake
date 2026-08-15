//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Ether.fi deposit adapter interface
 * @notice Ether.fi's entry point that stakes native ETH and mints weETH; OutrunWeETHSY routes native-token
 *      deposits through it and consumes the returned weETH amount as minted SY shares.
 */
interface IDepositAdapter {
    /**
     * @notice Deposits native ETH through Ether.fi and receives weETH.
     * @dev OutrunWeETHSY calls this for native-token deposits and consumes the return value as minted SY shares.
     * @param _referral The referral address passed to the upstream deposit adapter.
     * @return The amount of weETH minted for the deposit.
     */
    function depositETHForWeETH(address _referral) external payable returns (uint256);
}
