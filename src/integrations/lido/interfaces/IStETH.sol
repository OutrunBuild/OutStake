//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Lido stETH interface
 * @notice Lido's liquid-staked ETH on Ethereum mainnet; OutrunWstETHSY stakes native ETH via `submit` and
 *      quotes share/pooled-ETH conversions for deposit and redemption previews.
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
     * @dev OutrunWstETHSY consumes this after Lido submit returns shares and for stETH redemption previews.
     * @param shareAmount The share amount to convert.
     * @return The corresponding pooled ETH amount.
     */
    function getPooledEthByShares(uint256 shareAmount) external view returns (uint256);

    /**
     * @notice Stakes native ETH into stETH.
     * @dev OutrunWstETHSY calls this for native ETH deposits before wrapping the resulting stETH value.
     * @param referral The referral address supplied to Lido.
     * @return The share amount minted by the submit call.
     */
    function submit(address referral) external payable returns (uint256);
}
