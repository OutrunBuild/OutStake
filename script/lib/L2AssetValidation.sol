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
interface IAdapterView {
    function oracle() external view returns (address);
    function maxStaleness() external view returns (uint256);
    function sequencerUptimeFeed() external view returns (address);
    function sequencerGracePeriod() external view returns (uint256);
}

library L2AssetValidation {
    /// @notice Known L1 stETH address on Ethereum mainnet.
    address internal constant L1_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice Expected maxStaleness for Lido wstETH L2 adapters (2 days per Lido guide).
    /// @dev Lido cross-chain token guide: stETH rate data should not be outdated by more than 2 days.
    /// https://docs.lido.fi/token-guides/cross-chain-tokens-guide/
    uint256 internal constant EXPECTED_WSTETH_MAX_STALENESS = 2 days;

    /// @notice Generic bounds for unknown L2 oracle adapters (1 hour .. 7 days).
    uint256 internal constant MIN_GENERIC_MAX_STALENESS = 1 hours;
    uint256 internal constant MAX_GENERIC_MAX_STALENESS = 7 days;

    /// @notice Grace period bounds for L2 sequencer uptime feed (30 min .. 1 day).
    uint256 internal constant MIN_GRACE_PERIOD = 30 minutes;
    uint256 internal constant MAX_GRACE_PERIOD = 1 days;

    error L2InvalidDecimalsZero();
    error L2InvalidDecimalsOutOfRange(uint8 decimals);
    error L2InvalidDecimalsForKnownAsset(address asset, uint8 expected, uint8 actual);
    error L2ZeroAddress();
    error L2InvalidOracleAdapterNotAdapter(address oracle);
    error L2InvalidOracleAdapterMaxStaleness(address oracle, uint256 expected, uint256 actual);
    error L2InvalidOracleAdapterSequencerZero(address oracle);
    error L2InvalidOracleAdapterGracePeriod(address oracle, uint256 gracePeriod);

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

    /// @notice Validates L2 oracle adapter configuration (G-1 hardening).
    /// @dev Reverts if adapter is not an OutrunExchangeOracleAdapter, or if maxStaleness / sequencer
    ///      does not match the deployment checklist. For L1_STETH, enforces exactly 2 days and
    ///      non-zero sequencer with grace period in [30 min, 1 day]. For unknown assets, enforces
    ///      generic range 1 hour .. 7 days and same sequencer bounds. Call from YieldDeployScript
    ///      after decimals validation and before proxy deployment.
    /// @param exchangeRateOracle_ Adapter address that will be stored in SY.
    /// @param underlyingAssetOnEthAddr_ L1 underlying asset address to select strict vs generic bounds.
    function validateL2OracleAdapter(address exchangeRateOracle_, address underlyingAssetOnEthAddr_) internal view {
        if (exchangeRateOracle_ == address(0)) revert L2ZeroAddress();
        // Fail fast if target is not an OutrunExchangeOracleAdapter (missing view selectors).
        uint256 maxStaleness_;
        address sequencer_;
        uint256 gracePeriod_;
        try IAdapterView(exchangeRateOracle_).maxStaleness() returns (uint256 v) {
            maxStaleness_ = v;
        } catch {
            revert L2InvalidOracleAdapterNotAdapter(exchangeRateOracle_);
        }
        try IAdapterView(exchangeRateOracle_).sequencerUptimeFeed() returns (address v) {
            sequencer_ = v;
        } catch {
            revert L2InvalidOracleAdapterNotAdapter(exchangeRateOracle_);
        }
        try IAdapterView(exchangeRateOracle_).sequencerGracePeriod() returns (uint256 v) {
            gracePeriod_ = v;
        } catch {
            revert L2InvalidOracleAdapterNotAdapter(exchangeRateOracle_);
        }

        if (underlyingAssetOnEthAddr_ == L1_STETH) {
            if (maxStaleness_ != EXPECTED_WSTETH_MAX_STALENESS) {
                revert L2InvalidOracleAdapterMaxStaleness(
                    exchangeRateOracle_, EXPECTED_WSTETH_MAX_STALENESS, maxStaleness_
                );
            }
        } else {
            if (maxStaleness_ < MIN_GENERIC_MAX_STALENESS || maxStaleness_ > MAX_GENERIC_MAX_STALENESS) {
                revert L2InvalidOracleAdapterMaxStaleness(exchangeRateOracle_, 0, maxStaleness_);
            }
        }
        if (sequencer_ == address(0)) revert L2InvalidOracleAdapterSequencerZero(exchangeRateOracle_);
        if (gracePeriod_ < MIN_GRACE_PERIOD || gracePeriod_ > MAX_GRACE_PERIOD) {
            revert L2InvalidOracleAdapterGracePeriod(exchangeRateOracle_, gracePeriod_);
        }
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
