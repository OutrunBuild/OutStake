// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

/**
 * @title Sky Peg Stability Module (PSM3) interface
 * @notice Sky's Peg Stability Module that swaps between USDC, USDS, and sUSDS; OutrunL2StakedUsdsSY swaps
 *      through it for deposits/redemptions and previews. `previewSwapExactIn` additionally serves as the
 *      deviation-guard reference for `exchangeRate()`, whose rate source is the SSR `IRateProviderLike`
 *      (see rateProvider()).
 */
interface IPSM3 {
    /// @notice Swaps an exact amount of `assetIn` for as much `assetOut` as the PSM returns.
    /// @dev OutrunL2StakedUsdsSY calls this with `minAmountOut = 0`; slippage is enforced by the
    ///      SYBase deposit/redeem wrapper (minSharesOut / minTokenOut), not at this call. The returned
    ///      `amountOut` is consumed as the deposit or redemption output.
    /// @param assetIn Address of the ERC-20 asset to swap in.
    /// @param assetOut Address of the ERC-20 asset to swap out.
    /// @param amountIn Amount of the asset to swap in.
    /// @param minAmountOut Minimum amount of the asset to receive.
    /// @param receiver Address of the receiver of the swapped assets.
    /// @param referralCode Referral code for the swap.
    /// @return amountOut Resulting amount of the asset that will be received in the swap.
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountOut);

    /// @notice Quotes `assetOut` for an exact `assetIn` swap.
    /// @dev OutrunL2StakedUsdsSY consumes this for deposit/redemption previews and as the PSM-side
    ///      deviation-guard reference in `exchangeRate()` (rate source is `IRateProviderLike`, not this quote).
    /// @param assetIn Address of the ERC-20 asset to swap in.
    /// @param assetOut Address of the ERC-20 asset to swap out.
    /// @param amountIn Amount of the asset to swap in.
    /// @return amountOut Amount of the asset that will be received in the swap.
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    /// @notice Returns the PSM3 rate provider (SSR cross-chain mirror, 1e27).
    /// @return The rate provider address (immutable in canonical PSM3).
    function rateProvider() external view returns (address);
}
