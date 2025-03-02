// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IRewardManager {
    function userReward(address token, address user) external view returns (uint128 index, uint128 accrued);

    event RedeemRewards(
        uint256 indexed positionId, 
        address indexed msgSender, 
        uint256[] amountRewardsOut, 
        uint256 positionShare
    );

    event CollectRewardFee(address indexed rewardToken, uint256 amountRewardFee);
}
