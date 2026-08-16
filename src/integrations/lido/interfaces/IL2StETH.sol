// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Lido L2 stETH interface
 * @notice Lido's L2 stETH token that converts between stETH token units and wrappable wstETH share units;
 *      OutrunL2WrappableWstETHSY wraps and unwraps through it and consumes its quotes for deposit previews,
 *      redemption previews, and `exchangeRate()`.
 * @dev Direction warning: on L2 stETH is the wrapper of wstETH (Lido LIP-22), so the names below run the
 *      OPPOSITE way to mainnet wstETH and to this repo's IWstETH (IWstETH.wrap: stETH -> wstETH).
 *      Here wrap() converts wstETH share units into stETH token units, and unwrap() converts stETH token
 *      units back into wstETH share units. Do not read these names by mainnet analogy.
 */
interface IL2StETH {
    /**
     * @notice Converts wrappable/share units into L2 stETH token units.
     * @dev OutrunL2WrappableWstETHSY calls this when redeeming SY into the L2 stETH token.
     * @param sharesAmount The amount of wrappable/share (wstETH) units to convert.
     * @return The amount of L2 stETH token units returned.
     */
    function wrap(uint256 sharesAmount) external returns (uint256);

    /**
     * @notice Converts L2 stETH token units into wrappable/share units.
     * @dev OutrunL2WrappableWstETHSY calls this when depositing L2 stETH into SY.
     * @param tokenAmount The amount of L2 stETH token units to convert.
     * @return The amount of wrappable/share units returned.
     */
    function unwrap(uint256 tokenAmount) external returns (uint256);

    /**
     * @notice Quotes token amount for a share amount.
     * @dev OutrunL2WrappableWstETHSY consumes this for `exchangeRate()` and redemption previews.
     * @param sharesAmount The amount of shares to convert.
     * @return The corresponding token amount.
     */
    function getTokensByShares(uint256 sharesAmount) external view returns (uint256);

    /**
     * @notice Quotes share amount for a token amount.
     * @dev OutrunL2WrappableWstETHSY consumes this for deposit previews.
     * @param tokenAmount The amount of tokens to convert.
     * @return The corresponding share amount.
     */
    function getSharesByTokens(uint256 tokenAmount) external view returns (uint256);
}
