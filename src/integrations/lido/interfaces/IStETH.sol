//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Lido stETH interface
 * @notice Lido's liquid-staked ETH on Ethereum mainnet; OutrunWstETHSY stakes native ETH via
 *      WstETH.receive() and quotes share/pooled-ETH conversions for deposit and redemption previews.
 */
interface IStETH {
    /**
     * @notice Quotes shares for a pooled ETH amount.
     * @dev OutrunWstETHSY consumes this for native ETH deposit previews.
     * @param ethAmount The pooled ETH amount to convert.
     * @return The corresponding share amount.
     */
    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256);

    /**
     * @notice Quotes pooled ETH for a share amount.
     * @dev OutrunWstETHSY consumes this for stETH redemption previews.
     * @param shareAmount The share amount to convert.
     * @return The corresponding pooled ETH amount.
     */
    function getPooledEthByShares(uint256 shareAmount) external view returns (uint256);
}
