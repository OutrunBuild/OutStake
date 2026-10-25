// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {WadRayMath} from "./WadRayMath.sol";

/// @title Aave V3 share/asset conversion helpers
/// @notice Conversion helpers for Aave V3's ray-scaled (1e27) liquidity index. Aave tracks balances as "scaled
///      shares" and converts to actual asset amounts using the liquidity index. The index is always ray-scaled
///      (1e27 = WadRayMath.RAY).
/// @dev Pure conversion helpers (half-up/floor family) for the Aave ray (1e27) domain, consumed by both
///      preview and execution (deposit/redeem) paths of the Aave SY adapter.
library AaveAdapterLib {
    /// @notice Thrown when the Aave liquidity index is zero; a unified guard applied by all three conversion
    /// entry points in this library. Only the half-up path (`calcSharesFromAssetHalfUp`) provides a decoded
    /// selector for the otherwise empty `WadRayMath.rayDiv` revert, which intentionally mirrors Aave's
    /// gas-optimized `revert(0,0)`; the shares-to-asset down path would otherwise return a silent zero and
    /// the asset-to-shares down path would otherwise raise a division-by-zero Panic.
    error ZeroIndex();

    /// @notice Converts Aave shares to assets using a ray-scaled liquidity index, rounded down.
    /// @dev Fail closed on a zero index: a zero liquidity index means an uninitialized or broken
    ///      Aave reserve, so the named ZeroIndex revert replaces the silent zero the raw formula
    ///      would return.
    /// @param amountShares Amount of Aave shares to convert.
    /// @param index Ray-scaled (1e27) liquidity index.
    /// @return The equivalent asset amount, rounded down.
    function calcSharesToAssetDown(uint256 amountShares, uint256 index) internal pure returns (uint256) {
        if (index == 0) revert ZeroIndex();
        return (amountShares * index) / WadRayMath.RAY;
    }

    /// @notice Converts assets to Aave shares using a ray-scaled liquidity index, rounded down.
    /// @dev Conservative preview variant for the underlying→aToken path. Uses floor division
    ///      `(a*RAY)/b` (no half-up) so the view never over-quotes vs the half-up
    ///      `ScaledBalanceTokenBase._mintScaled` execution (`amount.rayDiv(index)`) and the
    ///      `scaledBalanceOf` delta. Max under-quote is 1 wei; over-quote is 0.
    ///      Fail closed on a zero index: a zero liquidity index means an uninitialized or broken
    ///      Aave reserve, so the named ZeroIndex revert replaces the division-by-zero Panic the
    ///      raw formula would raise.
    /// @param amountAssets Amount of assets to convert.
    /// @param index Ray-scaled (1e27) liquidity index.
    /// @return The equivalent share amount, rounded down.
    function calcSharesFromAssetDown(uint256 amountAssets, uint256 index) internal pure returns (uint256) {
        if (index == 0) revert ZeroIndex();
        return (amountAssets * WadRayMath.RAY) / index;
    }

    /// @notice Converts assets to Aave shares using a ray-scaled liquidity index, rounded half up.
    /// @param amountAssets Amount of assets to convert.
    /// @param index Ray-scaled (1e27) liquidity index.
    /// @return The equivalent share amount, rounded half up.
    // The name states the mode explicitly so callers do not mistake this for a true ceiling round.
    function calcSharesFromAssetHalfUp(uint256 amountAssets, uint256 index) internal pure returns (uint256) {
        if (index == 0) revert ZeroIndex();
        return WadRayMath.rayDiv(amountAssets, index);
    }
}
