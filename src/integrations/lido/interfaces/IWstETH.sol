//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Lido wstETH interface
 * @notice Lido's non-rebasing wrapper over stETH; OutrunWstETHSY wraps stETH into wstETH on deposit, unwraps
 *      to stETH on redemption, and reads `stEthPerToken` as its exchange-rate source.
 */
interface IWstETH {
    /**
     * @notice Returns the stETH amount represented by one wstETH.
     * @dev OutrunWstETHSY consumes this as its local `exchangeRate()` source.
     * @return The stETH-per-wstETH exchange rate.
     */
    function stEthPerToken() external view returns (uint256);

    /**
     * @notice Wraps stETH into wstETH.
     * @dev OutrunWstETHSY calls this after it holds stETH and consumes the return value as minted SY shares.
     * @param stETHAmount The amount of stETH to wrap.
     * @return The amount of wstETH minted.
     */
    function wrap(uint256 stETHAmount) external returns (uint256);

    /**
     * @notice Unwraps wstETH into stETH.
     * @dev OutrunWstETHSY calls this on redemption when stETH is the requested output.
     * @param wstETHAmount The amount of wstETH to unwrap.
     * @return The amount of stETH returned.
     */
    function unwrap(uint256 wstETHAmount) external returns (uint256);
}
