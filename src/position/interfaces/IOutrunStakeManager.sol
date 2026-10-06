// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun SY Stake Manager interface
 * @notice Open-term CDP positions backed by one canonical SY and one uAsset: `stakeForGenesis` is
 *      the only mint entrypoint and mints principal debt at value parity (the collateral value at
 *      the mint-time exchange rate), floating interest accrues virtually per second
 *      (timestamp-anchored, with the RAY zero-fee sentinel as the legal v1 default), and `redeem`
 *      repays debt in two legs (principal burn + interest transfer). There is no liquidation, no
 *      LTV surface, and no free-borrowing entrypoint.
 */
interface IOutrunStakeManager {
    /**
     * @notice Open-term CDP position accounting record.
     * @dev `owner` controls the redeem path. `syStaked` is collateral principal in SY units.
     * `principalDebt` is minted principal in uAsset units (the value-parity amount minted at the
     * genesis open — it equals the collateral value at the mint-time rate up to the two floored
     * conversion stages). `accruedInterest` is settled-but-unpaid interest in uAsset units,
     * written only at settlement touchpoints (redeem). `lastRate` is the SP cumulative rate
     * snapshot at this position's last interest settlement.
     */
    struct Position {
        address owner;
        uint256 syStaked;
        uint256 principalDebt;
        uint256 accruedInterest;
        uint256 lastRate;
    }

    // --------------------------------------------------------------------------
    // Errors (position-manager-local; dependency errors propagate unchanged)
    // --------------------------------------------------------------------------

    /// @dev Reverts when an input amount or address is zero at any entrypoint guard, or when a
    /// duty is sub-RAY (a negative-rate domain, zero included — the cumulative rate must never
    /// move backwards).
    error ZeroInput();
    /// @dev Reverts when a non-zero SY input is so small that the two-stage floor conversion
    /// rounds the minted uAsset down to zero. Distinct from `ZeroInput`, which means the caller
    /// passed a zero amount or zero address.
    error DustRoundedToZero();
    /// @dev Reverts when the SY `exchangeRate()` read returns zero; every pricing path fails
    /// closed with this named error at the single rate-reading home instead of a low-level
    /// division panic or a misleading dust error.
    error ZeroExchangeRate();
    /// @dev Reverts when a stake amount is below the configured `minStake`.
    error MinStakeInsufficient(uint256 minStake);
    /// @dev Reverts when a caller is not the recorded owner of a position (redeem) or the position
    /// is missing.
    error PositionAccessDenied();
    /// @dev Reverts when a requested redemption exceeds the position's staked SY.
    error ExceedsPositionBalance(uint256 requested, uint256 available);
    /// @dev Reverts when a partial redeem's ceiled principal portion would consume the entire
    /// remaining principal; the caller must use a full redeem instead.
    error PartialRedeemMustLeaveDebt();
    /// @dev Reverts when a direct-SY redemption output is below the caller's minimum.
    error InsufficientTokenOut(uint256 actual, uint256 minExpected);
    /// @dev Reverts when cached decimals diverge from live `SY.assetInfo().assetDecimals` or
    /// `uAsset.decimals()` during upgrade; indicates SY/uAsset was upgraded to a different decimals
    /// domain which would silently mis-scale all sy<->uAsset conversions by 10**delta.
    error DecimalsMismatch(uint8 cachedCanonical, uint8 currentCanonical, uint8 cachedUAsset, uint8 currentUAsset);
    /// @dev Reverts when `setDuty` or `initialize` exceeds the duty cap (15% annual equivalent
    /// per-second rate).
    error DutyCap(uint256 newDuty);
    /// @dev Reverts when the uAsset amount minted by `stakeForGenesis` is below the caller's
    /// `minUAssetMinted` floor.
    error InsufficientUAssetMinted(uint256 mintedUAsset, uint256 minMinted);
    /// @dev Reverts when the uAsset amount minted by `stakeForGenesis` exceeds the launcher's
    /// uint128 amount domain (checked before any allowance is granted to the launcher).
    error InvalidParam();
    /// @dev Reverts when `stakeForGenesis` is called while `genesisLauncher` is the zero address
    /// (deployment default, or the owner disabled the entrypoint by resetting it to zero).
    error GenesisLauncherNotSet();
    // GenesisUAssetNotConsumed is the single-source physical-gate error defined in GenesisGateLib
    // (SP reverts via GenesisGateLib.assertFullConsumption); not redeclared here to avoid dual-source drift.

    // --------------------------------------------------------------------------
    // State-changing entrypoints
    // --------------------------------------------------------------------------

    /**
     * @notice Opens a CDP position and hands the minted uAsset to the genesis launcher inside the
     * same transaction (the physical genesis gate). This is the only mint entrypoint.
     * @dev Value-parity pricing: the minted amount is the SY collateral converted
     * `SY -> canonical asset -> uAsset` with both stages floored — no LTV scaling segment — so the
     * minted debt is strictly <= the collateral value at the mint-time exchange rate (backing
     * invariant). The minted uAsset is minted to the SP itself, approved to `genesisLauncher` for
     * exactly the minted amount, and forwarded via
     * `IMemeverseLauncher.genesis(verseId, uint128(minted), positionOwner)`; after `genesis`
     * returns, the SP's uAsset balance must be back at its pre-mint baseline and the launcher
     * allowance zero, else `GenesisUAssetNotConsumed` reverts everything (the minted funds can
     * only reach the launcher within this transaction — no custody, no transfer-back, no residue).
     * Genesis-specific failure surfaces: `GenesisLauncherNotSet` when the launcher is the zero
     * address (entry disabled), `InsufficientUAssetMinted` when the mint is below the caller's
     * floor, `InvalidParam` when the mint exceeds type(uint128).max, and the mint still draws on
     * the SP's minter record (`ReachMintCap` propagates). `verseId` is an opaque launcher-assigned
     * id forwarded unchanged. The created position is an ordinary CDP position afterwards (redeem
     * two-leg repayment, per-second accrual — no extra state, no lockup).
     * @param amountInSY Amount of SY to stake. Must be > 0 and >= minStake.
     * @param positionOwner Address that will own the position (redeem rights); also the user
     * credited by the launcher.
     * @param verseId Opaque launcher-assigned identifier for the target verse; not validated here.
     * @param minUAssetMinted Minimum acceptable minted uAsset; `0` means no slippage protection.
     * @return positionId Identifier of the created position.
     */
    function stakeForGenesis(uint256 amountInSY, address positionOwner, uint256 verseId, uint256 minUAssetMinted)
        external
        returns (uint256 positionId);

    /**
     * @notice Redeems SY collateral by repaying the position's debt in two legs, at any time.
     * @dev Position-owner path, no maturity gate. Settles interest first, then splits the debt
     * pro-rata by SY share: full redeem repays the exact remaining legs; partial redeem ceils
     * both legs and must leave principal debt (`PartialRedeemMustLeaveDebt`). Repayment order:
     * the interest leg is transferred from the caller to the treasury (skipped when zero, never
     * burned, never touching the minter ledger), then the principal leg is burned via
     * `uAsset.repay(msg.sender, principalPortion)`, which also reduces the SP minter's
     * `amountInMinted`. Caller prerequisite: hold and approve the SP contract at least
     * `principalPortion + interestPortion` uAsset (both legs share that allowance); shortfall
     * reverts atomically with the dependency's error. Direct SY output enforces `minTokenOut`
     * locally and never reads the exchange rate (the owner exit channel is oracle-independent);
     * other tokens go through `SY.redeem`.
     * @param positionId Identifier of the position to redeem from.
     * @param syRedeemed Amount of SY collateral to redeem.
     * @param receiver Address receiving the redemption proceeds.
     * @param tokenOut Token requested on redemption.
     * @param minTokenOut Minimum acceptable token output from redemption.
     * @return principalBurned Amount of uAsset burned from the caller (principal leg).
     * @return interestPaid Amount of uAsset transferred to the treasury (interest leg).
     * @return amountTokenOut Amount of output token delivered to the receiver.
     */
    function redeem(uint256 positionId, uint256 syRedeemed, address receiver, address tokenOut, uint256 minTokenOut)
        external
        returns (uint256 principalBurned, uint256 interestPaid, uint256 amountTokenOut);

    // --------------------------------------------------------------------------
    // Owner-governed parameter setters
    // --------------------------------------------------------------------------

    /**
     * @notice Adjusts the per-second duty (segmented effect).
     * @dev Rejects sub-RAY values, zero included (`ZeroInput` — the cumulative rate must never
     *      move backwards; RAY itself is the zero-fee sentinel and a legal rate) and values above
     *      the duty cap (`DutyCap`). Settles the cumulative rate to the current timestamp under the
     *      old duty before storing the new one, so seconds before the change accrue at the old duty
     *      and seconds after at the new duty; positions need no migration.
     * @param newDuty New duty, RAY per-second point value.
     */
    function setDuty(uint256 newDuty) external;

    /**
     * @notice Updates the genesis launcher target of `stakeForGenesis`.
     * @dev Owner-only; accepts any address including zero — zero is the deployment default and
     * doubles as the kill switch that disables the `stakeForGenesis` entrypoint
     * (`GenesisLauncherNotSet`). No code-size validation is performed at configuration time
     * (dependency level mirrors `setProtocolTreasury`); runtime safety comes from the
     * strict full-consumption post-condition inside `stakeForGenesis`.
     * Operational invariant: `genesisLauncher` must equal `OutrunRouter.memeverseLauncher()` for the two genesis gates
     * to target one launcher; a single-side rotation makes router path-B entries and previews revert fail-closed
     * (`GenesisLauncherMismatch`), while the residual silent surface is router path-A (router launcher) versus direct-SP (SP launcher) targeting different launchers. Rotation must be atomic — update this value and
     * `router.memeverseLauncher` in the same governance transaction and verify
     * `genesisLauncher() == router.memeverseLauncher()` before opening new genesis.
     * @param genesisLauncher_ New launcher address (zero disables the entrypoint).
     */
    function setGenesisLauncher(address genesisLauncher_) external;

    /**
     * @notice Updates the minimum SY stake required for opening a position.
     * @param minStake_ New minimum stake amount; must be > 0.
     */
    function setMinStake(uint256 minStake_) external;

    /**
     * @notice Updates the treasury receiving interest payments.
     * @param protocolTreasury_ Address of the new protocol treasury; must be non-zero.
     */
    function setProtocolTreasury(address protocolTreasury_) external;

    // --------------------------------------------------------------------------
    // Views: tokens, parameters, and interest state
    // --------------------------------------------------------------------------

    /**
     * @notice Returns the SY token handled by the staking manager.
     * @dev Router flows treat this as the canonical SY for this manager and do not accept a
     * separate SY address.
     * @return Address of the standardized yield token.
     */
    // `SY` is part of the external protocol ABI; changing it would change the function selector.
    // solhint-disable-next-line naming-convention
    function SY() external view returns (address);

    /**
     * @notice Returns the universal asset minted against stakes.
     * @dev The stake manager is the uAsset minter; mint cap and repay accounting remain
     * minter-scoped in uAsset.
     * @return Address of the uAsset contract.
     */
    function uAsset() external view returns (address);

    /**
     * @notice Returns the minimum SY amount required per stake operation.
     * @return Minimum stake amount in SY.
     */
    function minStake() external view returns (uint256);

    /**
     * @notice Returns the treasury address that receives interest payments.
     * @dev Sole destination of the redeem interest leg.
     * @return Protocol treasury address.
     */
    function protocolTreasury() external view returns (address);

    /**
     * @notice Returns the per-second duty in RAY (1e27 = zero-fee sentinel, the v1 default).
     * @return Duty, RAY per-second point value.
     */
    function duty() external view returns (uint256);

    /**
     * @notice Returns the genesis launcher target of `stakeForGenesis`.
     * @dev Zero means the entrypoint is disabled (deployment default; the owner resets it to
     * zero to disable the gate).
     * @return Genesis launcher address, or zero when disabled.
     */
    function genesisLauncher() external view returns (address);

    /**
     * @notice Returns the settled cumulative rate (stored value, not extrapolated).
     * @return Rate, RAY cumulative value.
     */
    function rate() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the last rate settlement.
     * @return Last settled timestamp.
     */
    function rateLastSettledAt() external view returns (uint256);

    /**
     * @notice Returns the cumulative rate extrapolated to the current timestamp without writing state.
     * @dev Same closed-form compounding as the settlement touchpoints
     *      (`rmul(rpow(duty, block.timestamp - rateLastSettledAt), rate)`), so same-second
     *      preview and execution agree. At the zero-fee duty (1e27) this equals the stored rate.
     * @return Extrapolated cumulative rate.
     */
    function currentRate() external view returns (uint256);

    /**
     * @notice Returns the stored data for a staking position.
     * @dev A zero owner identifies a missing/deleted position in the current implementation.
     * @param positionId Identifier of the position to inspect.
     * @return owner Owner of the position.
     * @return syStaked SY collateral currently staked in the position.
     * @return principalDebt Minted principal debt in uAsset units.
     * @return accruedInterest Settled unpaid interest in uAsset units.
     * @return lastRate Rate snapshot at the position's last settlement.
     */
    function positions(uint256 positionId)
        external
        view
        returns (address owner, uint256 syStaked, uint256 principalDebt, uint256 accruedInterest, uint256 lastRate);

    /**
     * @notice Returns the position's unsettled interest extrapolated to the current timestamp.
     * @dev Read-only extrapolation (`principalDebt * (currentRate - lastRate) / 1e27`, single
     *      floor); never writes state. Zero for a missing id. Zero whenever
     *      `currentRate == lastRate`. Identically zero while duty has never exceeded 1e27;
     *      after `setDuty(1e27)` no new interest accrues while duty stays at 1e27, but pending
     *      accrued under a higher duty stays frozen until the position's next redeem settles it.
     * @param positionId Identifier of the position to inspect.
     * @return Unsettled interest in uAsset units.
     */
    function pendingInterest(uint256 positionId) external view returns (uint256);

    /**
     * @notice Returns the position's total debt: principal + settled interest + pending interest.
     * @param positionId Identifier of the position to inspect.
     * @return Total debt in uAsset units, extrapolated to the current timestamp.
     */
    function positionDebt(uint256 positionId) external view returns (uint256);

    // --------------------------------------------------------------------------
    // Preview family (quote-only, mirrors executor failure surfaces)
    // --------------------------------------------------------------------------

    /**
     * @notice Previews how much uAsset a genesis open would mint.
     * @dev Quote-only: reads the exchange rate, applies the same two-stage floor conversion as
     * `stakeForGenesis` (value parity, no scaling segment), and checks `minStake`; it does not
     * reserve mint cap, transfer SY, or create a position. Intentionally diverges from the
     * executor on dust: `previewStake` returns 0 where floor conversion zeroes the output, while
     * `stakeForGenesis` reverts `DustRoundedToZero` for the same input — callers must not treat a
     * 0 return as stakeable. Reverts `ZeroInput` when `amountInSY == 0`, `MinStakeInsufficient`
     * when `amountInSY < minStake()`, and `ZeroExchangeRate` when the rate reads zero. The
     * genesis executor guards (`minUAssetMinted`, uint128 bound, launcher gate, consumption
     * assertion) are not visible here.
     * @param amountInSY Amount of SY to stake.
     * @return UAssetMintable Quoted uAsset amount that would be minted; 0 when floor conversion
     * zeroes it. Named distinctly from the executor's `mintedUAsset` return to keep quote and
     * actual-minted separate at call sites.
     */
    function previewStake(uint256 amountInSY) external view returns (uint256 UAssetMintable);

    /**
     * @notice Previews a position redemption's two repayment legs and token output.
     * @dev Quote-only, mirrors `redeem`'s amount/existence checks and rounding: full redeem
     * returns the exact remaining debt legs; partial redeem ceils both legs pro-rata and rejects
     * any partial that would consume all remaining principal (`PartialRedeemMustLeaveDebt`).
     * Interest is extrapolated to the current timestamp without writing state. Direct-SY output never
     * reads the exchange rate (the owner exit channel is oracle-independent). Reverts
     * `PositionAccessDenied` when the position is missing, `ZeroInput` when `syRedeemed == 0`,
     * `ExceedsPositionBalance` when `syRedeemed > position.syStaked`.
     * @param positionId Identifier of the position being redeemed.
     * @param syRedeemed Amount of SY collateral to redeem.
     * @param tokenOut Token requested on redemption (SY itself or another token via SY.redeem).
     * @return principalPortion Principal leg that would be burned.
     * @return interestPortion Interest leg that would be transferred to the treasury.
     * @return amountTokenOut Token output expected by the receiver.
     */
    function previewRedeem(uint256 positionId, uint256 syRedeemed, address tokenOut)
        external
        view
        returns (uint256 principalPortion, uint256 interestPortion, uint256 amountTokenOut);

    // --------------------------------------------------------------------------
    // Events
    // --------------------------------------------------------------------------

    /**
     * @notice Emitted when a new position is created by `stakeForGenesis`, immediately followed by
     * `StakeForGenesis` (the two events corroborate each other).
     * @param positionId Identifier of the newly created position.
     * @param owner Owner of the created position (may differ from the funder).
     * @param amountInSY Amount of SY staked.
     * @param mintedUAsset Amount of uAsset minted at value parity, in uAsset decimals — the
     * position's initial `principalDebt`.
     */
    event Stake(uint256 indexed positionId, address indexed owner, uint256 amountInSY, uint256 mintedUAsset);

    /**
     * @notice Emitted after the genesis launcher consumed the minted uAsset in full and the
     * post-condition passed; always follows the same position's `Stake` event.
     * @param positionId Identifier of the newly created genesis position.
     * @param positionOwner Owner of the position and the user credited by the launcher.
     * @param verseId Opaque launcher-assigned identifier forwarded unchanged.
     * @param mintedUAsset Amount of uAsset minted and consumed by the launcher (= the position's
     * initial `principalDebt`).
     */
    event StakeForGenesis(
        uint256 indexed positionId, address indexed positionOwner, uint256 verseId, uint256 mintedUAsset
    );

    /**
     * @notice Emitted after a redeem completes its position update, two-leg repayment, and output.
     * @param positionId Identifier of the redeemed position.
     * @param owner Position owner who passed the owner guard (`msg.sender`).
     * @param syRedeemed SY collateral redeemed.
     * @param principalBurned uAsset burned by the principal leg.
     * @param interestPaid uAsset transferred to the treasury by the interest leg.
     * @param receiver Recipient of the redemption proceeds.
     * @param tokenOut Token delivered on redemption.
     * @param amountTokenOut Amount of `tokenOut` delivered.
     */
    event Redeem(
        uint256 indexed positionId,
        address indexed owner,
        uint256 syRedeemed,
        uint256 principalBurned,
        uint256 interestPaid,
        address indexed receiver,
        address tokenOut,
        uint256 amountTokenOut
    );

    /**
     * @notice Emitted when the duty is adjusted; the old duty's segmented settlement has
     * already run when this is emitted.
     */
    event SetDuty(uint256 oldDuty, uint256 newDuty);

    /**
     * @notice Emitted when the genesis launcher target changes; the zero address is a legal
     * value that disables the `stakeForGenesis` entrypoint.
     */
    event SetGenesisLauncher(address indexed oldLauncher, address indexed newLauncher);

    /// @notice Emitted when the minimum stake is updated; the prior value follows from the
    /// previous event.
    event SetMinStake(uint256 minStake);

    /// @notice Emitted when the interest-leg treasury destination is updated.
    event SetProtocolTreasury(address indexed protocolTreasury);
}
