// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.35;

/// @title L2 Oracle-Backed SY Deployment Validation
/// @notice Deployment-time guard for L2 oracle-backed SY family.
/// L1 underlying asset lives on Ethereum mainnet and is not deployed on L2, so the
/// chain cannot verify `underlyingAssetOnEthDecimals` on-chain. A mis-configured
/// decimals (e.g. stETH 18 filled as 6) silently distorts
/// `OutrunStakingPositionUpgradeable::_scaleCanonicalAssetToUAsset` by 1e12.
/// This library hard-codes expected decimals for known asset families and applies
/// a generic range check for unknown assets. Call it from deployment scripts
/// before invoking `__L2OracleBackedSY_init`.
/// @dev This is a script-side helper, not an on-chain guard. The contracts
/// themselves still accept any uint8 for maximum flexibility; the fail-fast
/// happens in the broadcast script.
library L2AssetValidation {
    /// @notice Known L1 stETH address on Ethereum mainnet.
    address internal constant L1_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    error L2InvalidDecimalsZero();
    error L2InvalidDecimalsOutOfRange(uint8 decimals);
    error L2InvalidDecimalsForKnownAsset(address asset, uint8 expected, uint8 actual);
    error L2ZeroAddress();

    /// @notice Validates L2 oracle-backed SY initialization params.
    /// @dev Reverts if decimals is zero, exceeds 18, or mismatches a known asset family.
    /// @param underlyingAssetOnEthAddr_ L1 underlying asset address (e.g. stETH on mainnet).
    /// @param underlyingAssetOnEthDecimals_ Decimals claimed for that L1 asset.
    /// @param exchangeRateOracle_ Oracle that reports canonical-asset-per-SY rate.
    function validateL2OracleBackedParams(
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_,
        address exchangeRateOracle_
    ) internal pure {
        if (underlyingAssetOnEthAddr_ == address(0) || exchangeRateOracle_ == address(0)) revert L2ZeroAddress();
        if (underlyingAssetOnEthDecimals_ == 0) revert L2InvalidDecimalsZero();
        // Generic upper bound: no known L1 canonical asset exceeds 18. Higher values
        // are almost certainly a typo and would under-scale uAsset debt.
        if (underlyingAssetOnEthDecimals_ > 18) revert L2InvalidDecimalsOutOfRange(underlyingAssetOnEthDecimals_);
        // Known-asset hard-coded expectations. Add more families here as L2 adapters expand.
        if (underlyingAssetOnEthAddr_ == L1_STETH && underlyingAssetOnEthDecimals_ != 18) {
            revert L2InvalidDecimalsForKnownAsset(underlyingAssetOnEthAddr_, 18, underlyingAssetOnEthDecimals_);
        }
        // Future known assets (example pattern, keep commented until wired):
        // if (underlyingAssetOnEthAddr_ == L1_USDe && underlyingAssetOnEthDecimals_ != 18) revert ...;
        // Unknown assets fall through with only the generic 1..18 range check above;
        // they must be manually verified against L1 Etherscan / official docs and recorded
        // in docs/deployment.md L2 checklist before broadcast.
    }

    /// @notice Validates wrappable L2 wstETH params (no oracle, stETH is rate source).
    function validateL2WrappableParams(
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_,
        address stETH_
    ) internal pure {
        if (underlyingAssetOnEthAddr_ == address(0) || stETH_ == address(0)) {
            revert L2ZeroAddress();
        }
        if (underlyingAssetOnEthDecimals_ == 0) revert L2InvalidDecimalsZero();
        if (underlyingAssetOnEthDecimals_ > 18) revert L2InvalidDecimalsOutOfRange(underlyingAssetOnEthDecimals_);
        if (underlyingAssetOnEthAddr_ == L1_STETH && underlyingAssetOnEthDecimals_ != 18) {
            revert L2InvalidDecimalsForKnownAsset(underlyingAssetOnEthAddr_, 18, underlyingAssetOnEthDecimals_);
        }
    }
}
