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
    /// @notice Thrown when the Aave liquidity index is zero; provides a decoded selector for the otherwise
    /// empty `WadRayMath.rayDiv` revert, which intentionally mirrors Aave's gas-optimized `revert(0,0)`.
    error ZeroIndex();

    /// @notice Converts Aave shares to assets using a ray-scaled liquidity index, rounded down.
    /// @param amountShares Amount of Aave shares to convert.
    /// @param index Ray-scaled (1e27) liquidity index.
    /// @return The equivalent asset amount, rounded down.
    function calcSharesToAssetDown(uint256 amountShares, uint256 index) internal pure returns (uint256) {
        return (amountShares * index) / WadRayMath.RAY;
    }

    /// @notice Converts assets to Aave shares using a ray-scaled liquidity index, rounded down.
    /// @dev Conservative preview variant for the underlying→aToken path. Uses floor division
    ///      `(a*RAY)/b` (no half-up) so the view never over-quotes vs the half-up
    ///      `ScaledBalanceTokenBase._mintScaled` execution (`amount.rayDiv(index)`) and the
    ///      `scaledBalanceOf` delta. Max under-quote is 1 wei; over-quote is 0.
    /// @param amountAssets Amount of assets to convert.
    /// @param index Ray-scaled (1e27) liquidity index.
    /// @return The equivalent share amount, rounded down.
    function calcSharesFromAssetDown(uint256 amountAssets, uint256 index) internal pure returns (uint256) {
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
