// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun Peg Stability Module (PSM) interface
 * @notice 1:1 face-value swaps between one bound reserve asset and one family uAsset: `mint` takes
 *      reserve and mints uAsset, `redeem` takes uAsset and pays out reserve. The 1:1 face-value rate is
 *      a structural constant — no oracle, no price feed, no slippage parameter — so the only discount is
 *      the configurable fees `tin`/`tout`. User amounts are always rounded down (floor, protocol-favored
 *      side) and the fee is exported as the difference between the input face value and the user amount.
 *      Each instance binds exactly one reserve at initialization (NATIVE sentinel for the native
 *      currency); the binding is immutable — there is no setter and no registry.
 */
interface IPSM {
    /**
     * @notice Emitted by {mint} after reserve is swapped for uAsset successfully.
     * @param reserveToken Bound reserve token taken in (NATIVE sentinel for the native currency).
     * @param to Receiver of the minted uAsset.
     * @param amountIn Reserve amount taken in, in the reserve token's own decimals.
     * @param amountOut uAsset minted to `to`, in 18 decimals.
     * @param feeIn Mint-side fee in 18-dec face value: input face value minus `amountOut`.
     */
    event SwapMintForUAsset(
        address indexed reserveToken, address indexed to, uint256 amountIn, uint256 amountOut, uint256 feeIn
    );

    /**
     * @notice Emitted by {redeem} after uAsset is swapped for reserve successfully.
     * @param reserveToken Bound reserve token paid out (NATIVE sentinel for the native currency).
     * @param to Receiver of the reserve payout.
     * @param amountIn uAsset burned, in 18 decimals.
     * @param amountOut Reserve amount paid to `to`, in the reserve token's own decimals.
     * @param feeOut Redeem-side fee in 18-dec face value: burned face value minus the face value paid out.
     */
    event SwapRedeemForReserve(
        address indexed reserveToken, address indexed to, uint256 amountIn, uint256 amountOut, uint256 feeOut
    );

    /**
     * @notice Emitted by {setFees} after both fees are updated.
     * @param tin New mint-side fee.
     * @param tout New redeem-side fee.
     */
    event SetFees(uint256 tin, uint256 tout);

    /**
     * @notice Emitted by {setStockCap} after the stock cap is updated.
     * @param stockCap New stock cap.
     */
    event SetStockCap(uint256 stockCap);

    /**
     * @notice Emitted by {sweepFees} after accumulated fees are paid out successfully.
     * @param reserveToken Bound reserve token paid out (NATIVE sentinel for the native currency).
     * @param to Receiver of the payout: the immutable `feeRecipient` bound at initialization.
     * @param amountOut Reserve amount paid to `to`, in the reserve token's own decimals, floor-rounded.
     */
    event FeesSwept(address indexed reserveToken, address indexed to, uint256 amountOut);

    /**
     * @notice Thrown by {initialize}, {mint}, {redeem}, or {sweepFees} when a required address or
     *      amount is zero.
     */
    error ZeroInput();

    /**
     * @notice Thrown by {initialize} or {setFees} when either fee sits outside [0, 1%]
     *      (18-dec point terms: [0, 1e16]).
     */
    error FeeOutOfRange();

    /**
     * @notice Thrown by {mint} when the swap would push this instance's net minted face value above the
     *      stock cap.
     */
    error StockCapExceeded();

    /**
     * @notice Thrown by {initialize} and {_authorizeUpgrade} when the bound uAsset does not use 18 decimals.
     * @dev PSM face-value math is hardcoded to 18 decimals (reserve amounts are scaled to 18-dec face value
     *      and uAsset mint/burn amounts are 18-dec face value). A non-18-dec uAsset would silently mis-scale
     *      every swap by 10**delta and brick the stockCap accounting.
     */
    error UAssetDecimalsMismatch(uint8 expected, uint8 actual);

    /**
     * @notice Thrown by {mint} when `msg.value` does not equal `amountIn` on the native leg, or is nonzero on an ERC20 leg.
     */
    error NativeAmountMismatch();

    /**
     * @notice Thrown by {redeem} or {sweepFees} when a native payout call fails.
     */
    error NativeTransferFailed();

    /**
     * @notice Initializes the PSM instance, binding the family uAsset, the single reserve, the
     *      owner, and the fee sweep recipient, and setting the initial stock cap and fees.
     * @dev All parameters are validated with the same bounds as the runtime setters: the stock cap
     *      must be > 0 and fees must sit in [0, 1%]. Reverts ZeroInput for a zero
     *      uAsset/owner/feeRecipient or a zero stock cap, FeeOutOfRange for a fee outside [0, 1%],
     *      and UAssetDecimalsMismatch for a bound uAsset that does not use 18 decimals. The reserve
     *      leg reads `decimals()` once (the NATIVE sentinel skips the read) and reverts with
     *      `UAssetDecimalsMismatch` when it exceeds 18; a non-ERC20 reserve reverts on the read.
     * @param uAsset_ Family uAsset swapped against the bound reserve.
     * @param reserveToken_ The single reserve this instance serves (NATIVE sentinel for the native currency).
     * @param owner_ Initial owner address.
     * @param feeRecipient_ Recipient of {sweepFees} payouts; immutable after initialization (no setter).
     * @param stockCap_ Initial stock cap (18-dec face value).
     * @param tin_ Initial mint-side fee.
     * @param tout_ Initial redeem-side fee.
     */
    function initialize(
        address uAsset_,
        address reserveToken_,
        address owner_,
        address feeRecipient_,
        uint256 stockCap_,
        uint256 tin_,
        uint256 tout_
    ) external;

    /**
     * @notice Updates both swap fees. Owner-only.
     * @dev Fees are 18-dec point values (1e18 = 100%); each must sit in [0, 1%] or the call reverts
     *      FeeOutOfRange. No per-step amplitude limit applies.
     * @param tin_ New mint-side fee.
     * @param tout_ New redeem-side fee.
     */
    function setFees(uint256 tin_, uint256 tout_) external;

    /**
     * @notice Updates the stock cap (net minted ceiling). Owner-only.
     * @dev The cap must stay > 0 — the PSM has no "cap off" state, so a zero value reverts ZeroInput.
     * @param stockCap_ New stock cap (18-dec face value).
     */
    function setStockCap(uint256 stockCap_) external;

    /**
     * @notice Swaps the bound reserve for uAsset at 1:1 face value, net of the mint fee `tin`.
     * @dev `msg.value` must equal `amountIn` for the native leg and be zero for an ERC20 leg (pulled via
     *      transferFrom). Reverts ZeroInput for a zero receiver/amount or an amount that floors to a
     *      zero output, NativeAmountMismatch when `msg.value` mismatches the leg requirements, and
     *      StockCapExceeded when the swap would push net minted above the stock cap. There is no
     *      per-swap flow cap: the effective single-swap ceiling is the remaining stock-cap headroom
     *      (`stockCap - netUAssetMinted`).
     * @param to Receiver of the minted uAsset.
     * @param amountIn Reserve amount to swap in, in the bound reserve token's own decimals.
     * @return amountOut uAsset minted to `to`, in 18 decimals, floor-rounded after the fee.
     */
    function mint(address to, uint256 amountIn) external payable returns (uint256 amountOut);

    /**
     * @notice Swaps uAsset for the bound reserve at 1:1 face value, net of the redeem fee `tout`.
     * @dev `msg.value` must be zero — the native currency is an output leg only, enforced structurally
     *      by the non-payable signature. The caller must have approved this PSM for `amountIn` uAsset.
     *      Reverts ZeroInput for a zero receiver/amount or a payout that floors to zero reserve units,
     *      and NativeTransferFailed when a native payout call fails. There is no per-swap flow cap: the
     *      hard bound on a single redeem is the reserve balance actually held by this PSM.
     * @param to Receiver of the reserve payout.
     * @param amountIn uAsset amount to burn, in 18 decimals.
     * @return amountOut Reserve amount paid to `to`, in the bound reserve token's own decimals, floor-rounded.
     */
    function redeem(address to, uint256 amountIn) external returns (uint256 amountOut);

    /**
     * @notice Pays out the current accumulated fee surplus to the immutable `feeRecipient`.
     * @dev Permissionless — anyone may call it; the recipient is fixed at initialization. The
     *      sweepable amount is the bound-reserve face value held minus this instance's net minted
     *      uAsset face value (the authoritative measure under mixed foreign redemptions: once net
     *      minted saturates to zero, principal left behind by foreign redemptions becomes
     *      sweepable together with the fees), floored to whole reserve units — sub-unit face dust
     *      (6-dec reserves) stays in the PSM. The sweep only drains the surplus: `netUAssetMinted`
     *      and the stock-cap headroom are untouched, so reserve cover stays >= 100% of net minted.
     *      Reverts ZeroInput when the sweepable amount is zero and NativeTransferFailed when a
     *      native payout call fails.
     * @return amountOut Reserve amount paid to `feeRecipient`, in the bound reserve token's own decimals.
     */
    function sweepFees() external returns (uint256 amountOut);

    /**
     * @notice Deterministic preview of {sweepFees}: the fee surplus currently sweepable.
     * @dev Returns the same value {sweepFees} would pay out (identity with execution), in the
     *      bound reserve token's own decimals; returns 0 where {sweepFees} would revert ZeroInput.
     * @return amountOut Sweepable reserve amount, floored to whole reserve units.
     */
    function sweepableFees() external view returns (uint256 amountOut);

    /**
     * @notice Deterministic preview of {mint} for a reserve amount.
     * @dev Fee math only: the quote depends solely on the input, the fee, and the bound reserve
     *      decimals — never on time, reserves held, or caps (the zero-oracle property as a static surface).
     *      Zero-output note: a dust input whose face value floors to zero after the fee quotes 0 without
     *      reverting, while {mint} reverts ZeroInput on the same input — a deliberate quote/execution
     *      divergence; callers must treat a 0 quote as non-executable.
     * @param amountIn Reserve amount to preview, in the bound reserve token's own decimals.
     * @return amountOut uAsset the swap would mint, in 18 decimals.
     */
    function quoteMint(uint256 amountIn) external view returns (uint256 amountOut);

    /**
     * @notice Deterministic preview of {redeem} for a uAsset amount.
     * @dev Fee math only, same determinism contract as {quoteMint}. Zero-output note: dust inputs quote
     *      0 without reverting while {redeem} reverts ZeroInput — the same deliberate divergence as
     *      {quoteMint}; callers must treat a 0 quote as non-executable.
     * @param amountIn uAsset amount to preview burning, in 18 decimals.
     * @return amountOut Reserve amount the swap would pay out, in the bound reserve token's own decimals.
     */
    function quoteRedeem(uint256 amountIn) external view returns (uint256 amountOut);

    /**
     * @notice Returns the family uAsset bound to this instance at initialization.
     * @return uAsset address of the bound uAsset.
     */
    function uAsset() external view returns (address);

    /**
     * @notice Returns the single reserve token bound to this instance at initialization.
     * @return reserveToken address of the bound reserve (NATIVE sentinel for the native currency).
     */
    function reserveToken() external view returns (address);

    /**
     * @notice Returns the recipient of {sweepFees} payouts, bound at initialization.
     * @return feeRecipient address of the fee sweep recipient.
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Returns the mint-side fee.
     * @return tin Current mint fee as an 18-dec point value.
     */
    function tin() external view returns (uint256);

    /**
     * @notice Returns the redeem-side fee.
     * @return tout Current redeem fee as an 18-dec point value.
     */
    function tout() external view returns (uint256);

    /**
     * @notice Returns the stock cap on this instance's net minted face value.
     * @return stockCap Current stock cap in 18-dec face value.
     */
    function stockCap() external view returns (uint256);

    /**
     * @notice Returns this instance's net minted face value: cumulative reserveMint output minus
     *      cumulative reserveBurn input, in 18 decimals, saturating at zero — when cumulative
     *      burns (which may include foreign-minted uAsset, e.g. from the CDP path) exceed local
     *      mints, the value clamps to zero instead of going negative. Indexers must not treat it
     *      as an unconstrained difference.
     * @return netUAssetMinted Current net minted amount (never below zero).
     */
    function netUAssetMinted() external view returns (uint256);
}
