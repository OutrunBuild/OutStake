// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GenesisGateLib
/// @notice Single source for the genesis physical-gate post-condition.
/// @dev The newly-minted uAsset (value-parity mint (SP) or face-value mint (PSM)) can only reach its consumer atomically
/// (the launcher on genesis paths, the POLend market on the POLend path).
/// Baseline is the caller's uAsset balance before the mint (pre-existing dust
/// is outside the assertion domain). After the consumer takes the minted amount
/// (e.g. via `IMemeverseLauncher.genesis`) the caller asserts balance == baseline
/// and allowance == 0, else reverts.
/// In-window inflows other than the mint (e.g. a consumer transfer-back)
/// can only credit the caller, so `balanceAfter - baseline` cannot underflow
/// when the check fails (balanceAfter >= baseline invariant).
library GenesisGateLib {
    /// @dev Reverts when the consumer did not take the minted uAsset in full:
    /// balance did not return to the pre-mint baseline or allowance not zero.
    error GenesisUAssetNotConsumed(uint256 residualBalance, uint256 residualAllowance);
    /// @dev Reverts when a mint exceeds the launcher's uint128 amount domain.
    /// Mirrors the `InvalidParam()` errors of the stake-manager and router interfaces by
    /// signature, so the revert data is byte-identical (an error selector depends only on
    /// name and parameter types, not on where the error is declared).
    error InvalidParam();

    /// @notice Asserts the consumer fully consumed the minted uAsset.
    /// @param uAsset Universal asset that was minted and approved.
    /// @param consumer Address that should have consumed the approval via transferFrom.
    /// @param baseline Pre-mint snapshot of this contract's uAsset balance.
    function assertFullConsumption(address uAsset, address consumer, uint256 baseline) internal view {
        uint256 balanceAfter = IERC20(uAsset).balanceOf(address(this));
        uint256 residualAllowance = IERC20(uAsset).allowance(address(this), consumer);
        // balanceAfter >= baseline always holds: the mint is the only guaranteed inflow,
        // total outflows are bounded by the exact allowance, and any other in-window
        // movement can only credit this contract.
        if (balanceAfter != baseline || residualAllowance != 0) {
            revert GenesisUAssetNotConsumed(balanceAfter - baseline, residualAllowance);
        }
    }

    /// @notice Rejects a minted amount the launcher cannot accept.
    /// @param mintedUAsset uAsset minted for this genesis flow.
    /// @dev Single source for the launcher uint128-domain bound shared by both genesis gates
    /// (the staking position and the router tail). Must run before any allowance is granted.
    function requireLauncherAmount(uint256 mintedUAsset) internal pure {
        if (mintedUAsset > type(uint128).max) revert InvalidParam();
    }
}
