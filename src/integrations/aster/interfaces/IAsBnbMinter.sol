//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Aster asBNB minter interface (BSC)
 * @notice asBNB is Aster's yield-bearing token minted from slisBNB, Lista's liquid-staked BNB token.
 * @dev "token"/"token-side" throughout this interface means the slisBNB input asset returned by `token()`,
 *      never the asBNB minted output.
 */
interface IAsBnbMinter {
    /**
     * @notice Returns the asBNB token wired to the minter.
     * @dev OutrunAsBNBSY checks this during initialization to bind the configured yield-bearing token.
     * @return The asBNB token address.
     */
    function asBnb() external view returns (address);

    /**
     * @notice Returns the slisBNB token accepted by the minter.
     * @dev OutrunAsBNBSY checks this during initialization to bind its supported token set.
     * @return The slisBNB token address.
     */
    function token() external view returns (address);

    /**
     * @notice Returns the yield proxy used by the minter.
     * @dev OutrunAsBNBSY reads this to reach the Lista stake manager used for local conversion previews.
     * @return The yield proxy address.
     */
    function yieldProxy() external view returns (address);

    /**
     * @notice Mints asBNB from slisBNB.
     * @dev Called by OutrunAsBNBSY after it holds slisBNB. A zero return is treated locally as a queued Aster
     * request and requires the yield proxy status check.
     * @param amountIn The slisBNB amount to deposit.
     * @return The asBNB amount minted, or zero when Aster queues the request.
     */
    function mintAsBnb(uint256 amountIn) external returns (uint256);

    /**
     * @notice Mints asBNB from native BNB.
     * @dev Called by OutrunAsBNBSY with `msg.value` as the BNB deposit. A zero return is treated locally as a
     * queued Aster request and requires the yield proxy status check.
     * @return The asBNB amount minted, or zero when Aster queues the request.
     */
    function mintAsBnb() external payable returns (uint256);

    /**
     * @notice Quotes the token-side asset value represented by an asBNB amount.
     * @dev OutrunAsBNBSY consumes this only for `exchangeRate()` reads, combining the asBNB-to-slisBNB quote with
     *      Lista's `convertSnBnbToBnb`; deposit previews use `convertToAsBnb`, with native BNB first quoted via
     *      `convertBnbToSnBnb`.
     * @param asBNBAmount The asBNB amount to convert.
     * @return The corresponding slisBNB amount (the asset returned by `token()`).
     */
    function convertToTokens(uint256 asBNBAmount) external view returns (uint256);

    /**
     * @notice Quotes the asBNB amount represented by a token-side amount.
     * @dev OutrunAsBNBSY consumes this for slisBNB deposit previews and does not assert the upstream rate source.
     * @param tokenAmount The slisBNB amount to convert (the asset returned by `token()`).
     * @return The corresponding asBNB amount.
     */
    function convertToAsBnb(uint256 tokenAmount) external view returns (uint256);
}
