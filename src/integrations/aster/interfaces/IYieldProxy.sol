//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Aster yield proxy interface (BSC)
 * @notice Aster's yield routing contract that fronts the Lista stake manager and queues async mint activities;
 *      OutrunAsBNBSY reads the stake manager from it during setup and checks `activitiesOnGoing` to classify a
 *      zero-mint deposit as queued.
 */
interface IYieldProxy {
    /**
     * @notice Returns the Lista stake manager wired to the yield proxy.
     * @dev OutrunAsBNBSY reads this during setup and then consumes the stake manager's conversion quote methods.
     * @return The stake manager address.
     */
    function stakeManager() external view returns (address);

    /**
     * @notice Returns whether the yield proxy is processing queued activities.
     * @dev OutrunAsBNBSY checks this after a zero mint result to classify the local deposit as queued.
     * @return Whether async activities are still in progress.
     */
    function activitiesOnGoing() external view returns (bool);
}
