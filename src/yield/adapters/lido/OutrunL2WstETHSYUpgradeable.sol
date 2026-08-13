// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// L2 wstETH SY adapter. On L2, wstETH balance doesn't accrue staking rewards
// (rewards accrue on Ethereum mainnet). The exchange rate comes from an oracle
// that tracks what wstETH is worth on L1. Deposit/redeem are 1:1 with wstETH
// since wrapping happens at the L2 bridge level. Shared oracle-backed behavior
// lives in OutrunL2OracleBackedSYUpgradeable.
// Production Lido L2 wstETH/stETH rate adapters should use maxStaleness = 2 days
// and enable the L2 sequencer uptime feed with a post-recovery grace period.
// Evidence: Lido cross-chain token guide says stETH rate data should not be
// outdated by more than 2 days.
// https://docs.lido.fi/token-guides/cross-chain-tokens-guide/

import {OutrunL2OracleBackedSYUpgradeable} from "../../OutrunL2OracleBackedSYUpgradeable.sol";

contract OutrunL2WstETHSYUpgradeable is OutrunL2OracleBackedSYUpgradeable {
    /// @notice Initializes the L2 wstETH SY adapter with the fixed Lido name and symbol.
    /// @param owner_ Address that will be granted the owner role.
    /// @param wstETH_ The wstETH token on L2 (IS the SY — no wrapping needed).
    /// @param exchangeRateOracle_ Oracle that reports the canonical-asset-per-SY exchange rate.
    /// @param underlyingAssetOnEthAddr_ Address of the underlying asset (stETH) on Ethereum mainnet.
    /// @param underlyingAssetOnEthDecimals_ Decimals of the underlying asset on Ethereum mainnet.
    // solhint-disable-next-line gas-small-strings
    function initialize(
        address owner_,
        address wstETH_,
        address exchangeRateOracle_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) external initializer {
        __L2OracleBackedSY_init(
            "SY Lido wstETH",
            "SY wstETH",
            owner_,
            wstETH_,
            exchangeRateOracle_,
            underlyingAssetOnEthAddr_,
            underlyingAssetOnEthDecimals_
        );
    }
}
