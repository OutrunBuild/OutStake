// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunMath } from "../libraries/OutrunMath.sol";
import { IPositionRewardManager } from "./interfaces/IPositionRewardManager.sol";

/**
 * @notice PositionRewardManager must not have duplicated rewardTokens
 */
abstract contract PositionRewardManager is IPositionRewardManager {
    using OutrunMath for uint256;

    uint256 internal constant INITIAL_REWARD_INDEX = 1;

    struct PositionReward {
        uint128 index;
        uint128 accrued;
        bool ownerCollected;
    }

    // [token] => [positionId] => (index,accrued,ownerCollected)
    mapping(address => mapping(uint256 => PositionReward)) public positionReward;

    function _updatePositionRewards(uint256 positionId, uint256 rewardShares) internal virtual {
        (address[] memory tokens, uint256[] memory indexes) = _updateRewardIndex();
        if (tokens.length == 0) return;

        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 index = indexes[i];
            PositionReward storage rewardOfPosition = positionReward[token][positionId];
            uint256 positionIndex = rewardOfPosition.index;

            if (positionIndex == 0) {
                positionIndex = INITIAL_REWARD_INDEX.Uint128();
            }

            if (positionIndex == index) continue;

            uint256 deltaIndex = index - positionIndex;
            uint256 rewardDelta = rewardShares.mulDown(deltaIndex);
            uint256 rewardAccrued = rewardOfPosition.accrued + rewardDelta;

            rewardOfPosition.index = index.Uint128();
            rewardOfPosition.accrued = rewardAccrued.Uint128();
        }
    }

    function rewardIndexesCurrent() external virtual returns (uint256[] memory);

    function redeemReward(uint256 positionId) external virtual;

    function _updateRewardIndex() internal virtual returns (address[] memory tokens, uint256[] memory indexes);

    function _redeemExternalReward() internal virtual;

    function _doTransferOutRewards(
        address receiver, 
        uint256 positionId
    ) internal virtual returns (uint256[] memory rewardAmounts);
}
