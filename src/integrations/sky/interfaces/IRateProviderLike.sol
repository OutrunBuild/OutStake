// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

/// @title Sky Rate Provider (SSR cross-chain mirror)
/// @notice Returns sUSDS/USDS conversion rate scaled by 1e27. Consumed by Base PSM3
///      and reused as independent pricing source for L2 SY exchangeRate.
interface IRateProviderLike {
    function getConversionRate() external view returns (uint256);
}
