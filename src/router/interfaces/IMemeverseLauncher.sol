// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title MemeverseLauncher interface
 * @notice External launcher surface consumed by the genesis flows of OutrunRouter and the staking position.
 */
interface IMemeverseLauncher {
    /**
     * @notice Launches a launcher-defined verse genesis flow using newly minted uAsset.
     * @dev The caller mints uAsset and approves this launcher the exact minted amount in the same
     * transaction, then invokes this function. Two callers share the surface under the same strict
     * contract: OutrunRouter's PSM gate (face-value reserve swap, no position) and the staking
     * position's `stakeForGenesis` entry (an open-term value-parity position for `user`, no lockup).
     * Each caller asserts after the call that the launcher consumed the approval in full (its uAsset
     * balance back to the pre-mint baseline and the allowance zero), reverting the whole transaction
     * otherwise. The launcher assigns and interprets `verseId`; any validity rules are launcher-side.
     * Callers treat it as opaque and forward it unchanged. This interface records only the local call
     * boundary, not launcher-side accounting rules.
     * @param verseId Opaque launcher-assigned identifier for the target verse; the caller does not validate it.
     * @param amountInUAsset Amount of uAsset committed to genesis.
     * @param user User credited for the genesis action.
     */
    function genesis(uint256 verseId, uint128 amountInUAsset, address user) external;
}
