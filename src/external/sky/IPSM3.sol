// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

interface IPSM3 {
    /**
     *  @dev    Swaps a specified amount of assetIn for assetOut in the PSM. The amount swapped is
     *          converted based on the current value of the two assets used in the swap. This
     *          function will revert if there is not enough balance in the PSM to facilitate the
     *          swap. Both assets must be supported in the PSM in order to succeed.
     *  @param  assetIn      Address of the ERC-20 asset to swap in.
     *  @param  assetOut     Address of the ERC-20 asset to swap out.
     *  @param  amountIn     Amount of the asset to swap in.
     *  @param  minAmountOut Minimum amount of the asset to receive.
     *  @param  receiver     Address of the receiver of the swapped assets.
     *  @param  referralCode Referral code for the swap.
     *  @return amountOut    Resulting amount of the asset that will be received in the swap.
     */
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountOut);

    /**
     *  @dev    Swaps a derived amount of assetIn for a specific amount of assetOut in the PSM. The
     *          amount swapped is converted based on the current value of the two assets used in
     *          the swap. This function will revert if there is not enough balance in the PSM to
     *          facilitate the swap. Both assets must be supported in the PSM in order to succeed.
     *  @param  assetIn      Address of the ERC-20 asset to swap in.
     *  @param  assetOut     Address of the ERC-20 asset to swap out.
     *  @param  amountOut    Amount of the asset to receive from the swap.
     *  @param  maxAmountIn  Max amount of the asset to use for the swap.
     *  @param  receiver     Address of the receiver of the swapped assets.
     *  @param  referralCode Referral code for the swap.
     *  @return amountIn     Resulting amount of the asset swapped in.
     */
    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountIn);

    /**
     * @dev    View function that returns the exact amount of assetOut that would be received for a
     *         given amount of assetIn in a swap. The amount returned is converted based on the
     *         current value of the two assets used in the swap.
     * @param  assetIn   Address of the ERC-20 asset to swap in.
     * @param  assetOut  Address of the ERC-20 asset to swap out.
     * @param  amountIn  Amount of the asset to swap in.
     * @return amountOut Amount of the asset that will be received in the swap.
     */
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external view returns (uint256 amountOut);

    /**
     * @dev    View function that returns the exact amount of assetIn that would be required to
     *         receive a given amount of assetOut in a swap. The amount returned is
     *         converted based on the current value of the two assets used in the swap.
     * @param  assetIn   Address of the ERC-20 asset to swap in.
     * @param  assetOut  Address of the ERC-20 asset to swap out.
     * @param  amountOut Amount of the asset to receive from the swap.
     * @return amountIn  Amount of the asset that is required to receive amountOut.
     */
    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external view returns (uint256 amountIn);
}