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
        bool finalCollected;
    }

    // [token] => (index)
    mapping(address => uint128) public wrapStakeRewardIndex;

    // [token] => (accrued)
    mapping(address => uint128) public wrapStakeRewardAccrued;

    // [token] => [positionId] => (index, accrued, finalCollected)
    mapping(address => mapping(uint256 => PositionReward)) public positionReward;

    function _updateWrapStakeRewards(uint256 rewardShares) internal virtual {
        (address[] memory tokens, uint256[] memory indexes) = _updateRewardIndex();
        uint256 len = tokens.length;
        if (len == 0) return;

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            uint256 index = indexes[i];
            unchecked { i++; }

            uint128 _wrapStakeRewardIndex = wrapStakeRewardIndex[token];
            uint128 _wrapStakeRewardAccrued = wrapStakeRewardAccrued[token];

            if (_wrapStakeRewardIndex == 0) {
                wrapStakeRewardIndex[token] = INITIAL_REWARD_INDEX.Uint128();
            }

            if (_wrapStakeRewardIndex == index) continue;

            uint256 deltaIndex = index - _wrapStakeRewardIndex;
            if (deltaIndex > 0) {
                uint256 rewardAccrued = _wrapStakeRewardAccrued + rewardShares.mulDown(deltaIndex);
                wrapStakeRewardIndex[token] = index.Uint128();
                wrapStakeRewardAccrued[token] = rewardAccrued.Uint128();
            }
        }
    }

    function _updatePositionRewards(
        uint256 positionId,
        uint256 rewardShares,
        address[] memory tokens,
        uint256[] memory indexes
    ) internal virtual {
        uint256 len = tokens.length;
        if (len == 0) return;

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            uint256 index = indexes[i];
            unchecked { i++; }
            PositionReward storage rewardOfPosition = positionReward[token][positionId];
            uint256 positionIndex = rewardOfPosition.index;

            if (positionIndex == 0) {
                positionIndex = INITIAL_REWARD_INDEX.Uint128();
            }

            if (positionIndex == index) continue;

            uint256 deltaIndex = index - positionIndex;
            if (deltaIndex > 0 ) {
                uint256 rewardAccrued = rewardOfPosition.accrued + rewardShares.mulDown(deltaIndex);
                rewardOfPosition.index = index.Uint128();
                rewardOfPosition.accrued = rewardAccrued.Uint128();
            }
        }
    }

    function rewardIndexesCurrent() external virtual returns (uint256[] memory);

    function redeemWrapStakeRewards() external virtual;

    function batchRedeemReward(uint256[] calldata positionIds) external virtual;

    function _updateRewardIndex() internal virtual returns (address[] memory tokens, uint256[] memory indexes);

    function _redeemExternalReward() internal virtual;

    function _doTransferOutRewards(
        address receiver, 
        uint256 positionId
    ) internal virtual returns (uint256[] memory rewardAmounts);
}
