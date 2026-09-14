// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun USR savings vault (suToken) interface
 * @notice ERC4626 savings vault over one family uAsset: depositors hold suToken shares whose
 *      per-share price index grows second by second (timestamp-anchored) at the owner-set family
 *      rate, paid exclusively out of the real uAsset balance held by the vault. This interface
 *      declares the initialization binding, the owner surface (interest budget injection and rate
 *      setting), the accrual state views, and the error/event set; the standard ERC4626/ERC20 entry
 *      points and events come from their own interfaces.
 */
interface IUSRVault {
    /**
     * @notice Emitted by {fund} after an interest budget amount of the uAsset is pulled in from the
     *      owner. `fund` mints no shares; the amount only backs future index growth.
     * @param amount uAsset amount injected into the vault.
     */
    event UsrFunded(uint256 amount);

    /**
     * @notice Emitted by {setUsrRate} after the family rate is updated.
     * @param oldRate Rate that applied to every second settled before this call.
     * @param newRate Rate applying from the current timestamp onward.
     */
    event UsrRateSet(uint256 oldRate, uint256 newRate);

    /**
     * @notice Emitted by {_settleIndex} only when a settlement actually moves the index.
     * @dev No emission when the projection equals the settled value: same-second calls (zero
     *      delta), zero supply, zero balance, zero rate, or the budget cap pinning the index.
     *      The settlement timestamp is not a parameter; readers use the event's block.timestamp
     *      or {lastSettledAt}.
     * @param oldIndex Settled index before this settlement.
     * @param newIndex Settled index after this settlement.
     */
    event AccrualIndexSettled(uint256 oldIndex, uint256 newIndex);

    /**
     * @notice Thrown by {initialize} when the asset is the zero address or the share name/symbol
     *      is empty; also thrown by {fund} for a zero amount.
     */
    error ZeroInput();

    /**
     * @notice Thrown by {setUsrRate} when the new rate exceeds the absolute ceiling 1e17
     *      (10% annualized in 18-dec point terms).
     */
    error UsrRateTooHigh();

    /**
     * @notice Thrown by {setUsrRate} when the nonzero new rate is below SECONDS_PER_YEAR
     *      (the per-second term `newRate / SECONDS_PER_YEAR` would floor to zero and accrue nothing).
     */
    error UsrRateBelowResolution();

    /**
     * @notice Thrown by {initialize} when the bound family uAsset does not use 18 decimals.
     * @dev Share/asset conversion math is hardcoded to 18 decimals (the 1e18 index domain
     *      assumes an 18-dec asset). A non-18-dec asset would silently mis-scale every
     *      conversion by 10**delta and brick the budget-cap accounting.
     */
    error UAssetDecimalsMismatch(uint8 expected, uint8 actual);

    /**
     * @notice Initializes the vault, binding the family uAsset, the suToken metadata, and the owner.
     * @dev All parameters are immutable-style: there is no setter for any of them after
     *      initialization. A zero `asset_` or an empty name/symbol reverts ZeroInput; a non-18-dec
     *      `asset_` reverts UAssetDecimalsMismatch; a zero
     *      `owner_` reverts with the Ownable zero-owner error. The accrual clock is
     *      `block.timestamp` scaled by the internal SECONDS_PER_YEAR constant, so no per-chain
     *      cadence parameter exists.
     * @param asset_ Family uAsset deposited into this vault (the ERC4626 asset).
     * @param name_ suToken name.
     * @param symbol_ suToken symbol.
     * @param owner_ Initial owner address.
     */
    function initialize(address asset_, string calldata name_, string calldata symbol_, address owner_) external;

    /**
     * @notice Owner-only interest budget injection: pulls `amount` of the uAsset from the owner into
     *      the vault. This is the only owner fund-moving entry and it is one-directional (in).
     * @dev Settlement runs before the pull, so pending seconds accrue first; the pulled amount
     *      mints no shares. Reverts ZeroInput for a zero amount.
     * @param amount uAsset amount to pull from the owner (requires the owner's prior approval).
     */
    function fund(uint256 amount) external;

    /**
     * @notice Sets the family annualized rate. Owner-only.
     * @dev Settlement runs before the write, so every unsettled second keeps the old rate — the
     *      new rate applies only from the current timestamp onward. Reverts UsrRateTooHigh above
     *      1e17 and UsrRateBelowResolution for a nonzero rate below SECONDS_PER_YEAR; zero
     *      disables accrual and any other value within the bounds is settable in one call.
     * @param newRate New annualized rate in 18-dec point terms.
     */
    function setUsrRate(uint256 newRate) external;

    /**
     * @notice Returns the family annualized rate in 18-dec point terms (zero = accrual off).
     * @return Rate currently applied to each settled second.
     */
    function usrRate() external view returns (uint256);

    /**
     * @notice Returns the settled per-share price index in 1e18 terms (1e18 = par).
     * @dev This is the settled accounting value; the preview/convert views extrapolate it to the
     *      current timestamp separately from this accessor.
     * @return Settled index.
     */
    function accrualIndex() external view returns (uint256);

    /**
     * @notice Returns the timestamp the index was last settled to.
     * @return Last settled timestamp.
     */
    function lastSettledAt() external view returns (uint256);
}
