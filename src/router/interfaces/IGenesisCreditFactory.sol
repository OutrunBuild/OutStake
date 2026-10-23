// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title GenesisCreditFactory interface (minimal, router-local)
/// @notice Credit-token resolution consumed by the router's credit-funded leveraged genesis leg.
interface IGenesisCreditFactory {
    /// @notice Returns the deterministic GenesisCredit address for a family uAsset; address(0) when
    ///      none is deployed.
    function creditOf(address uAsset) external view returns (address credit);
}
