// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IPositionRewardManager {
    function positionReward(address token, uint256 positionId) external view returns (uint128 index, uint128 accrued, bool finalCollected);

    function redeemWrapStakeRewards() external;

    function batchRedeemReward(uint256[] calldata positionIds) external;

    event RedeemRewards(
        uint256 indexed positionId, 
        address indexed initOwner, 
        uint256[] amountRewardsOut
    );

    event ProtocolRewardRevenue(address indexed rewardToken, uint256 amount);
}
