// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Lido L2 stETH interface
 * @notice Lido's L2 stETH token that converts between stETH token units and wrappable wstETH share units;
 *      OutrunL2WrappableWstETHSY wraps and unwraps through it and consumes its quotes for deposit previews,
 *      redemption previews, and `exchangeRate()`.
 */
interface IL2StETH {
    /**
     * @notice Converts wrappable/share units into L2 stETH token units.
     * @dev OutrunL2WrappableWstETHSY calls this when redeeming SY into the L2 stETH token.
     * @param wrappableTokenAmount The amount of wrappable/share units to convert.
     * @return The amount of L2 stETH token units returned.
     */
    function wrap(uint256 wrappableTokenAmount) external returns (uint256);

    /**
     * @notice Converts L2 stETH token units into wrappable/share units.
     * @dev OutrunL2WrappableWstETHSY calls this when depositing L2 stETH into SY.
     * @param wrapperTokenAmount The amount of L2 stETH token units to convert.
     * @return The amount of wrappable/share units returned.
     */
    function unwrap(uint256 wrapperTokenAmount) external returns (uint256);

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
