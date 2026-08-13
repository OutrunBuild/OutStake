// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

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

    /// @notice Swaps for an exact amount of `assetOut`, bounded by `maxAmountIn`.
    /// @dev Exposed for the PSM surface; current local adapters do not rely on this path for SY accounting.
    /// @param assetIn Address of the ERC-20 asset to swap in.
    /// @param assetOut Address of the ERC-20 asset to swap out.
    /// @param amountOut Amount of the asset to receive from the swap.
    /// @param maxAmountIn Max amount of the asset to use for the swap.
    /// @param receiver Address of the receiver of the swapped assets.
    /// @param referralCode Referral code for the swap.
    /// @return amountIn Resulting amount of the asset swapped in.
    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountIn);

    /// @notice Quotes `assetOut` for an exact `assetIn` swap.
    /// @dev OutrunL2StakedUsdsSY consumes this for `exchangeRate()`, deposit previews, and redemption previews.
    /// @param assetIn Address of the ERC-20 asset to swap in.
    /// @param assetOut Address of the ERC-20 asset to swap out.
    /// @param amountIn Amount of the asset to swap in.
    /// @return amountOut Amount of the asset that will be received in the swap.
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    /// @notice Quotes `assetIn` required for an exact `assetOut` swap.
    /// @dev Exposed for quoting the PSM exact-output path; current local adapters do not rely on this path for
    ///      SY accounting.
    /// @param assetIn Address of the ERC-20 asset to swap in.
    /// @param assetOut Address of the ERC-20 asset to swap out.
    /// @param amountOut Amount of the asset to receive from the swap.
    /// @return amountIn Amount of the asset that is required to receive amountOut.
    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);
}
