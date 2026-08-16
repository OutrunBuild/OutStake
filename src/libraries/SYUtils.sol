// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title SY (Standardized Yield) conversion helpers
/// @notice Conversion helpers between SY (Standardized Yield) shares and canonical asset amounts: canonical asset
///      is the SY's underlying asset in assetInfo().assetDecimals, uAsset is the borrowed debt token in
///      uAsset.decimals(). All conversions use the exchange rate scaled by 1e18 (ONE). Rounding direction is
///      chosen by the caller: round down when over-counting would over-mint or over-release value, and round up
///      when enough value must remain to cover debt or required backing.
library SYUtils {
    // Exchange rates are always scaled by 1e18 for precision, matching DeFi convention.
    uint256 internal constant ONE = 1e18;

    /// @notice Converts SY amount to canonical asset amount, rounded down.
    /// @param exchangeRate Canonical asset per SY, scaled by 1e18.
    /// @param syAmount Amount of SY to convert.
    /// @return The equivalent asset amount, rounded down.
    /// @dev exchangeRate is canonical asset per SY scaled by 1e18. This helper does not rescale into uAsset
    /// decimals.
    function syToAsset(uint256 exchangeRate, uint256 syAmount) internal pure returns (uint256) {
        return (syAmount * exchangeRate) / ONE;
    }

    /// @notice Converts SY amount to canonical asset amount, rounded up.
    /// @param exchangeRate Canonical asset per SY, scaled by 1e18.
    /// @param syAmount Amount of SY to convert.
    /// @return The equivalent asset amount, rounded up.
    /// @dev exchangeRate is canonical asset per SY scaled by 1e18. This helper does not rescale into uAsset
    /// decimals.
    // Rounds up — use when an asset value must be counted without leaving fractional dust behind.
    // The ceil term (+ ONE - 1) moves the checked-add overflow threshold to syAmount * exchangeRate >
    // type(uint256).max - ONE,
    // slightly narrower than the floor variant's 2^256 - 1. Real supplies and rates stay far below it.
    function syToAssetUp(uint256 exchangeRate, uint256 syAmount) internal pure returns (uint256) {
        return (syAmount * exchangeRate + ONE - 1) / ONE;
    }

    /// @notice Converts canonical asset amount to SY amount, rounded down.
    /// @param exchangeRate Canonical asset per SY, scaled by 1e18.
    /// @param assetAmount Amount of asset to convert.
    /// @return The equivalent SY amount, rounded down.
    /// @dev exchangeRate is canonical asset per SY scaled by 1e18. This helper does not rescale from uAsset
    /// decimals.
    // Rounds down — use when releasing or crediting too much SY would be unsafe.
    function assetToSy(uint256 exchangeRate, uint256 assetAmount) internal pure returns (uint256) {
        return (assetAmount * ONE) / exchangeRate;
    }

    /// @notice Converts canonical asset amount to SY amount, rounded up.
    /// @param exchangeRate Canonical asset per SY, scaled by 1e18.
    /// @param assetAmount Amount of asset to convert.
    /// @return The equivalent SY amount, rounded up.
    /// @dev exchangeRate is canonical asset per SY scaled by 1e18. This helper does not rescale from uAsset
    /// decimals.
    // Rounds up — use when enough SY must remain to cover an asset-denominated debt.
    // The ceil term (+ exchangeRate - 1) moves the checked-add overflow threshold to assetAmount * ONE >
    // type(uint256).max - exchangeRate,
    // slightly narrower than the floor variant's 2^256 - 1. Real debt and rates stay far below it.
    function assetToSyUp(uint256 exchangeRate, uint256 assetAmount) internal pure returns (uint256) {
        return (assetAmount * ONE + exchangeRate - 1) / exchangeRate;
    }
}
