// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IPositionRewardManager {
    function positionReward(address token, uint256 positionId) external view returns (uint128 index, uint128 accrued, bool ownerCollected);

    function redeemReward(uint256 positionId) external;

    event RedeemRewards(
        uint256 indexed positionId, 
        address indexed initOwner, 
        uint256[] amountRewardsOut
    );

    event ProtocolRewardRevenue(address indexed rewardToken, uint256 amount);
}
