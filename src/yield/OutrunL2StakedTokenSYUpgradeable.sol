// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.35;

import {OutrunL2OracleBackedSYUpgradeable} from "./OutrunL2OracleBackedSYUpgradeable.sol";

/// @title Outrun L2 staked token SY adapter
/// @notice L2 SY adapter where the yield-bearing token itself is the SY. Deposit and redeem are 1:1 with the
///      underlying token. The exchange rate comes from a configured oracle (since the staking yield accrues on
///      L1/Ethereum mainnet and the L2 token balance doesn't reflect it). Shared oracle-backed behavior lives in
///      OutrunL2OracleBackedSYUpgradeable.
// solhint-disable-next-line gas-small-strings
contract OutrunL2StakedTokenSYUpgradeable is OutrunL2OracleBackedSYUpgradeable {
    /// @notice Initializes the L2 staked token SY adapter.
    /// @param name_ Token name for the ERC20 representation.
    /// @param symbol_ Token symbol for the ERC20 representation.
    /// @param owner_ Address that will be granted the owner role.
    /// @param token_ The yield-bearing token on L2 (IS the SY — no wrapping needed).
    /// @param exchangeRateOracle_ Oracle that reports the canonical-asset-per-SY exchange rate.
    /// @param underlyingAssetOnEthAddr_ Address of the underlying asset on Ethereum mainnet.
    /// @param underlyingAssetOnEthDecimals_ Decimals of the underlying asset on Ethereum mainnet.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address owner_,
        address token_,
        address exchangeRateOracle_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) external initializer {
        __L2OracleBackedSY_init(
            name_,
            symbol_,
            owner_,
            token_,
            exchangeRateOracle_,
            underlyingAssetOnEthAddr_,
            underlyingAssetOnEthDecimals_
        );
    }
}
