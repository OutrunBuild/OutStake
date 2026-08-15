// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title Lista BNB StakeManager interface (BSC mainnet ABI mirror)
/// @notice The on-chain Lista StakeManager that stakes native BNB and mints slisBNB.
/// @dev Function names mirror the upstream ABI, which uses the legacy symbol "SnBnb"; in this repo that
///      quantity is always called slisBNB (SnBnb = slisBNB, Lista's liquid-staking token for BNB).
///      These selectors are ABI-bound to the live contract and must not be renamed.
interface IListaStakeManager {
    /// @notice Stakes native BNB and mints slisBNB to the caller.
    /// @dev OutrunSlisBNBSY calls this for native BNB deposits. It returns void, so local minted amount is
    ///      measured by slisBNB balance difference.
    function deposit() external payable;

    /// @notice Requests an asynchronous withdrawal (7-day unbonding).
    /// @dev Not used by OutrunSlisBNBSY; withdrawal queuing remains outside the local adapter flow.
    /// @param amountInSnBnb The slisBNB amount to unstake, in wei.
    function requestWithdraw(uint256 amountInSnBnb) external;

    /// @notice Claims a completed withdrawal request.
    /// @dev Not used by OutrunSlisBNBSY; claim timing remains an external protocol concern.
    /// @param idx The index of the withdrawal request to claim.
    function claimWithdraw(uint256 idx) external;

    /// @notice Quotes the slisBNB output for a given BNB input.
    /// @dev OutrunSlisBNBSY consumes this for native BNB deposit previews.
    ///      OutrunAsBNBSYUpgradeable consumes this as a read-only conversion quote before calling the asBNB minter.
    /// @param amount The BNB amount to convert, in wei.
    /// @return The equivalent slisBNB amount, in wei.
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);

    /// @notice Quotes the BNB value of a given slisBNB amount.
    /// @dev OutrunSlisBNBSY consumes this for `exchangeRate()` and an init-time parity check
    ///      (1 slisBNB >= 1 BNB). Redemption is a 1:1 slisBNB pass-through and does not use this quote.
    ///      OutrunAsBNBSYUpgradeable consumes this to express asBNB value in native BNB terms for `exchangeRate()`.
    /// @param amount The slisBNB amount to convert, in wei.
    /// @return The equivalent BNB amount, in wei.
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);

    /// @notice Returns the total pooled BNB across all stakers.
    /// @dev Exposed for integration reads; OutrunSlisBNBSY does not use it for local mint/redeem accounting.
    /// @return The total pooled BNB, in wei.
    function getTotalPooledBnb() external view returns (uint256);
}
