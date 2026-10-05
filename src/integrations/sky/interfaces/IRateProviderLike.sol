// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

/// @title Sky Savings Rate (SSR) RateProvider (cross-chain mirror)
/// @notice SSR is Sky's per-block yield accrual rate for sUSDS; the rate provider mirrors
///      it on L2, so the reading is a yield-accrual rate, not a market price. Returns the
///      sUSDS/USDS conversion rate scaled by 1e27 (ray). Consumed by Base PSM3 and reused
///      as independent pricing source for L2 SY exchangeRate.
interface IRateProviderLike {
    function getConversionRate() external view returns (uint256);
}
