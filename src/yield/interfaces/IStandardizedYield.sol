// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Standardized Yield (SY) core interface
 * @notice ERC20-compatible yield wrapper: `deposit` mints SY shares from a supported input token, `redeem` burns
 *      shares for a supported output token, and `exchangeRate` reports the 1e18-scaled canonical asset per SY
 *      used for position accounting. Implemented by SYBaseUpgradeable (base of every Outrun SY adapter) and
 *      consumed by OutrunRouter and OutrunStakingPositionUpgradeable.
 */
interface IStandardizedYield is IERC20Metadata {
    /**
     * @notice Reverts when a deposit uses a token outside the adapter's supported input set.
     */
    error SYInvalidTokenIn(address token);

    error SYInvalidTokenOut(address token);

    error SYZeroAddress();

    error SYZeroDeposit();

    error SYZeroRedeem();

    error SYInsufficientSharesOut(uint256 actualSharesOut, uint256 requiredSharesOut);

    error SYInsufficientTokenOut(uint256 actualTokenOut, uint256 requiredTokenOut);

    /// @dev Emitted when a supported input token is deposited and SY shares are minted to `receiver`.
    event Deposit(
        address indexed caller,
        address indexed receiver,
        address indexed tokenIn,
        uint256 amountDeposited,
        uint256 amountSyOut
    );

    /// @dev Emitted when SY shares are burned and a supported output token is delivered to `receiver`.
    event Redeem(
        address indexed caller,
        address indexed receiver,
        address indexed tokenOut,
        uint256 amountSyToRedeem,
        uint256 amountTokenOut
    );

    /// @dev See `assetInfo()` for how an implementation exposes its canonical asset metadata.
    enum AssetType {
        TOKEN,
        LIQUIDITY
    }

    /**
     * @notice Mints SY shares by depositing a supported input token.
     * @dev Pulls `amountTokenToDeposit` from `msg.sender` unless `tokenIn` is the native token sentinel. Mints
     * shares to `receiver` and reverts if output is below `minSharesOut`.
     * @param receiver Shares recipient address.
     * @param tokenIn Address of the input token, or the native token sentinel when supported.
     * @param amountTokenToDeposit Amount of input token funded by `msg.sender`.
     * @param minSharesOut Minimum acceptable shares minted.
     * @return amountSharesOut Amount of shares minted.
     */
    function deposit(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        returns (uint256 amountSharesOut);

    /**
     * @notice Redeems SY shares into a supported output token.
     * @dev Delivers `tokenOut` to `receiver` and reverts if output is below `minTokenOut`. When
     * `burnFromInternalBalance` is true, shares are burned from the SY contract's own balance; router flows use
     * this after transferring the caller's SY to the SY contract.
     * @param receiver Recipient address.
     * @param amountSharesToRedeem Amount of shares to burn.
     * @param tokenOut Address of the output token, or the native token sentinel when supported.
     * @param minTokenOut Minimum acceptable output token amount.
     * @param burnFromInternalBalance Whether to burn from `address(this)` instead of `msg.sender`.
     * @return amountTokenOut Amount of output token redeemed.
     */
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);

    /**
     * @notice `exchangeRate * syBalance / 1e18` must return the canonical asset balance of the account.
     * @dev Returns canonical asset per SY, scaled by 1e18. The returned asset balance is in
     * `assetInfo().assetDecimals`, not `uAsset.decimals()`. Position accounting consumes this through SYUtils
     * conversion helpers for stake, draw, wrap redeem, keeper redeem, and harvest calculations.
     * @return res The current canonical-asset-per-SY exchange rate scaled by 1e18.
     */
    function exchangeRate() external view returns (uint256 res);

    /**
     * @notice returns the address of the yield-bearing Token
     * @dev This is the primary external token contract held or interacted with by the SY implementation; it is
     * not necessarily the same address as the canonical asset returned by `assetInfo()`.
     * @return The configured yield-bearing token address.
     */
    function yieldBearingToken() external view returns (address);

    /**
     * @notice returns all tokens that can mint this SY
     * @dev Each returned token address is expected to satisfy `isValidTokenIn(token)`.
     * @return res The list of supported deposit token addresses.
     */
    function getTokensIn() external view returns (address[] memory res);

    /**
     * @notice returns all tokens that can be redeemed by this SY
     * @dev Each returned token address is expected to satisfy `isValidTokenOut(token)`.
     * @return res The list of supported redemption token addresses.
     */
    function getTokensOut() external view returns (address[] memory res);

    /**
     * @notice Returns whether `token` is accepted by `deposit`.
     * @dev Defines the deposit token boundary for this adapter, including native-token sentinel support when any.
     * @param token The token to validate.
     * @return True when `token` is supported for deposits.
     */
    function isValidTokenIn(address token) external view returns (bool);

    /**
     * @notice Returns whether `token` is accepted by `redeem`.
     * @dev Defines the redemption token boundary for this adapter, including native-token sentinel support when any.
     * @param token The token to validate.
     * @return True when `token` is supported for redemptions.
     */
    function isValidTokenOut(address token) external view returns (bool);

    /**
     * @notice Quotes shares minted for a deposit preview.
     * @dev Quote-only and follows the same token validation rules as `deposit`; it does not pull tokens, mint
     * shares, or reserve the quoted rate.
     * @param tokenIn The token that would be deposited.
     * @param amountTokenToDeposit The amount of `tokenIn` to preview.
     * @return amountSharesOut The quoted share output.
     */
    function previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        external
        view
        returns (uint256 amountSharesOut);

    /**
     * @notice Quotes token output for a redemption preview.
     * @dev Quote-only and follows the same token validation rules as `redeem`; it does not burn shares, transfer
     * tokens, or reserve the quoted rate.
     * @param tokenOut The token that would be received.
     * @param amountSharesToRedeem The amount of shares to preview redeeming.
     * @return amountTokenOut The quoted redemption output.
     */
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        external
        view
        returns (uint256 amountTokenOut);

    /// @notice Returns information used to interpret the canonical asset.
    /// @dev The canonical asset metadata is for accounting and display boundaries. L2 adapters may report an
    ///     asset that is not deployed on the current chain.
    /// @return assetType the type of the asset (0 for ERC20 tokens, 1 for AMM liquidity tokens)
    /// @return assetAddress the address of the asset
    /// @return assetDecimals the decimals of the asset
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals);
}
