// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title SY (Standardized Yield) conversion helpers
/// @notice Conversion helpers from SY (Standardized Yield) shares to canonical asset amounts: canonical asset is
///      the SY's underlying asset in assetInfo().assetDecimals, uAsset is the borrowed debt token in
///      uAsset.decimals(). All conversions use the exchange rate scaled by 1e18 (ONE) and round down — the
///      conservative direction whenever releasing or crediting too much value would be unsafe; this library
///      deliberately provides no round-up variant.
library SYUtils {
    // Exchange rates are always scaled by 1e18 for precision, matching DeFi convention.
    // Wad-only domain (1e18): Position, oracle adapter, and SY exchangeRate use this scale exclusively;
    // never substitute WadRayMath.RAY (1e27) — ray is exclusive to AaveAdapterLib index conversions.
    uint256 internal constant ONE = 1e18;

    /// @notice Converts SY amount to canonical asset amount, rounded down.
    /// @param exchangeRate Canonical asset per SY, scaled by 1e18.
    /// @param syAmount Amount of SY to convert.
    /// @return The equivalent asset amount, rounded down.
    /// @dev This helper does not rescale into uAsset decimals. Rounds down — use when releasing
    ///      or crediting too much value would be unsafe (the position mints at value parity off
    ///      this direction only).
    function syToAsset(uint256 exchangeRate, uint256 syAmount) internal pure returns (uint256) {
        return (syAmount * exchangeRate) / ONE;
    }
}
