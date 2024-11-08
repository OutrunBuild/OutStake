//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { SYUtils } from "../libraries/SYUtils.sol";
import { TokenHelper } from "../libraries/TokenHelper.sol";
import { OutrunERC1155 } from "../common/OutrunERC1155.sol";
import { AutoIncrementId } from "../common/AutoIncrementId.sol";
import { IOutrunStakeManager } from "./interfaces/IOutrunStakeManager.sol";
import { PositionRewardManager, Math } from "../RewardManager/PositionRewardManager.sol";
import { IStandardizedYield } from "../StandardizedYield/IStandardizedYield.sol";
import { IYieldToken } from "../YieldContracts/interfaces/IYieldToken.sol";
import { IYieldManager } from "../YieldContracts/interfaces/IYieldManager.sol";
import { IPrincipalToken } from "../YieldContracts/interfaces/IPrincipalToken.sol";

/**
 * @title Outrun Position Option Token
 */
contract OutrunPositionOptionToken is 
    IOutrunStakeManager, 
    PositionRewardManager, 
    AutoIncrementId, 
    OutrunERC1155, 
    TokenHelper, 
    ReentrancyGuard, 
    Ownable
{
    using Math for uint256;

    uint256 public constant DAY = 24 * 3600;
    address public immutable SY;
    address public immutable PT;
    address public immutable YT;

    uint256 public minStake;
    uint256 public syTotalStaking;
    uint256 public totalPrincipalValue;
    LockupDuration public lockupDuration;

    address public revenuePool;
    uint256 public protocolFeeRate;

    mapping(uint256 positionId => Position) public positions;

    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 minStake_,
        uint256 protocolFeeRate_,
        address revenuePool_,
        address _SY,
        address _PT,
        address _YT
    ) OutrunERC1155(name_, symbol_, decimals_) Ownable(owner_) {
        SY = _SY;
        PT = _PT;
        YT = _YT;
        minStake = minStake_;
        revenuePool = revenuePool_;
        protocolFeeRate = protocolFeeRate_;
    }

    modifier onlyYT() {
        require(msg.sender == YT, PermissionDenied());
        _;
    }

    /**
     * @dev The average number of days staked based on YT. It isn't the true average number of days staked for the position.
     */
    function impliedStakingDays() external view override returns (uint256) {
        return IERC20(YT).totalSupply() / syTotalStaking;
    }

    /**
     * @dev Calculate PT amount by YT amount and principal value, reasonable input needs to be provided during simulation calculations.
     */
    function calcPTAmount(uint256 principalValue, uint256 amountInYT) public view override returns (uint256 amount) {
        uint256 newYTSupply = IERC20(YT).totalSupply() + amountInYT;
        uint256 yieldTokenValue = amountInYT * IYieldManager(YT).totalRedeemableYields() / newYTSupply;
        amount = principalValue > yieldTokenValue ? principalValue - yieldTokenValue : 0;
    }

    /**
     * @dev Preview PT generateable amount and YT generateable amount before stake
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     */
    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays
    ) external view override returns (uint256 PTGenerateable, uint256 YTGenerateable) {
        _stakeParamValidate(amountInSY, lockupDays);

        uint256 principalValue = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY);
        PTGenerateable = principalValue * lockupDays;
        YTGenerateable = calcPTAmount(principalValue, YTGenerateable);
    }

    /**
     * @dev Preview redeemable SY amount before redeem
     * @param positionId - Position Id
     * @param positionShare - Share of the position
     */
    function previewRedeem(
        uint256 positionId, 
        uint256 positionShare
    ) external view override returns (uint256 redeemableSyAmount) {
        Position memory position = positions[positionId];
        uint256 redeemedPrincipalValue = position.principalRedeemable * positionShare / position.PTRedeemable;
        redeemableSyAmount = SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemedPrincipalValue);
    }

    /**
     * @dev Allows user to deposit SY, then mints PT, YT and POT for the user.
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     * @param PTRecipient - Receiver of PT
     * @param YTRecipient - Receiver of YT
     * @param positionOwner - Owner of position
     * @notice User must have approved this contract to spend SY
     */
    function stake(
        uint256 amountInSY,
        uint256 lockupDays,
        address PTRecipient, 
        address YTRecipient,
        address positionOwner
    ) external override nonReentrant returns (uint256 PTGenerated, uint256 YTGenerated) {
        _stakeParamValidate(amountInSY, lockupDays);
        _transferIn(SY, msg.sender, amountInSY);
        
        uint256 deadline;
        uint256 principalValue = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY);
        unchecked {
            syTotalStaking += amountInSY;
            totalPrincipalValue += principalValue;
            deadline = block.timestamp + lockupDays * DAY;
            YTGenerated = principalValue * lockupDays;
        }

        uint256 positionId = _nextId();
        PTGenerated = calcPTAmount(principalValue, YTGenerated);
        positions[positionId] = Position(amountInSY, principalValue, PTGenerated, deadline);
        IYieldToken(YT).mint(YTRecipient, YTGenerated);
        IPrincipalToken(PT).mint(PTRecipient, PTGenerated);
        _mint(positionOwner, positionId, PTGenerated, "");  // mint POT

        _storeRewardIndexes(positionId);

        emit Stake(positionId, amountInSY, principalValue, PTGenerated, YTGenerated, deadline);
    }

    /**
     * @dev Allows user to unstake SY by burnning PT and POT.
     * @param positionId - Position Id
     * @param positionShare - Share of the position
     */
    function redeem(
        uint256 positionId, 
        uint256 positionShare
    ) external override nonReentrant returns (uint256 redeemedSyAmount) {
        Position storage position = positions[positionId];
        uint256 deadline = position.deadline;
        require(deadline <= block.timestamp, LockTimeNotExpired(deadline));

        address msgSender = msg.sender;
        burn(msgSender, positionId, positionShare);
        
        uint256 PTRedeemable = position.PTRedeemable;
        uint256 principalRedeemable = position.principalRedeemable;

        IPrincipalToken(PT).burn(msgSender, positionShare);
        _redeemRewards(positionId, positionShare, position.SYRedeemable, PTRedeemable);

        uint256 redeemedPrincipalValue = principalRedeemable * positionShare / PTRedeemable;
        redeemedSyAmount = SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemedPrincipalValue);
        
        unchecked {
            totalPrincipalValue -= redeemedPrincipalValue;
            position.SYRedeemable -= redeemedSyAmount;
            position.PTRedeemable -= positionShare;
            position.principalRedeemable -= redeemedPrincipalValue;
        }

        _transferSY(msgSender, redeemedSyAmount);
        
        emit Redeem(positionId, msgSender, redeemedSyAmount, positionShare);
    }

    /**
     * @dev Transfer yields when collecting protocol fees and withdrawing yields, only YT can call
     * @param receiver - Address of receiver
     * @param syAmount - Amount of protocol fee
     */
    function transferYields(address receiver, uint256 syAmount) external override onlyYT {
        require(msg.sender == YT, PermissionDenied());
        _transferSY(receiver, syAmount);
    }

    /**
     * @param _minLockupDays - Min lockup days
     * @param _maxLockupDays - Max lockup days
     */
    function setLockupDuration(uint128 _minLockupDays, uint128 _maxLockupDays) external override onlyOwner {
        require(
            _minLockupDays != 0 && 
            _maxLockupDays != 0 && 
            _minLockupDays < _maxLockupDays, 
            ErrorInput()
        );

        lockupDuration.minLockupDays = _minLockupDays;
        lockupDuration.maxLockupDays = _maxLockupDays;

        emit SetLockupDuration(_minLockupDays, _maxLockupDays);
    }

    function _transferSY(address receiver, uint256 syAmount) internal {
        unchecked {
            syTotalStaking -= syAmount;
        }

        _transferOut(SY, receiver, syAmount);
    }

    function _stakeParamValidate(uint256 amountInSY, uint256 lockupDays) internal view {
        require(amountInSY >= minStake, MinStakeInsufficient(minStake));
        uint256 _minLockupDays = lockupDuration.minLockupDays;
        uint256 _maxLockupDays = lockupDuration.maxLockupDays;
        require(
            lockupDays >= _minLockupDays && lockupDays <= _maxLockupDays, 
            InvalidLockupDays(_minLockupDays, _maxLockupDays)
        );
    }

    /*///////////////////////////////////////////////////////////////
                               REWARDS-RELATED
    //////////////////////////////////////////////////////////////*/

    function getRewardTokens() public view returns (address[] memory) {
        return IStandardizedYield(SY).getRewardTokens();
    }

    function _storeRewardIndexes(uint256 positionId) internal {
        (address[] memory tokens, uint256[] memory indexes) = _updateRewardIndex();
        if (tokens.length == 0) return;

        for (uint256 i = 0; i < tokens.length; ++i) {
            positionReward[tokens[i]][positionId] = PositionReward(indexes[i].Uint128(), 0, false);
        }
    }

    function _redeemRewards(
        uint256 positionId, 
        uint256 positionShare, 
        uint256 SYRedeemable, 
        uint256 PTRedeemable
    ) internal returns (uint256[] memory rewardsOut) {
        _updatePositionRewards(positionId, SYRedeemable);
        
        address msgSender = msg.sender;
        rewardsOut = _doTransferOutRewards(msgSender, positionId, positionShare, PTRedeemable);

        if (rewardsOut.length != 0) emit RedeemRewards(positionId, msgSender, rewardsOut, positionShare);
    }

    function _doTransferOutRewards(
        address receiver, 
        uint256 positionId, 
        uint256 positionShare, 
        uint256 PTRedeemable
    ) internal override returns (uint256[] memory rewardAmounts) {
        bool redeemExternalThisRound;

        address[] memory tokens = getRewardTokens();
        rewardAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            PositionReward storage rewardOfPosition = positionReward[tokens[i]][positionId];
            uint128 totalRewards = rewardOfPosition.accrued;
            uint256 shareRewards = totalRewards * positionShare / PTRedeemable;
            rewardAmounts[i] = shareRewards;
            positionReward[tokens[i]][positionId].accrued = (totalRewards - shareRewards).Uint128();

            if (!redeemExternalThisRound) {
                if (_selfBalance(tokens[i]) < totalRewards) {
                    _redeemExternalReward();
                    redeemExternalThisRound = true;
                }
            }

            // The protocol fee will only be charged once during the lock-up period, and no fee will be charged for rewards after the lock-up expire time.
            if (!rewardOfPosition.feesCollected) {
                uint256 feeAmount = uint256(totalRewards).mulDown(protocolFeeRate);
                _transferOut(tokens[i], revenuePool, feeAmount);
                rewardAmounts[i] -= shareRewards.mulDown(protocolFeeRate);

                emit CollectRewardFee(tokens[i], feeAmount);
            }
            
            _transferOut(tokens[i], receiver, rewardAmounts[i]);
        }
    }

    /**
     * @notice updates and returns the reward indexes
     */
    function rewardIndexesCurrent() external override returns (uint256[] memory) {
        return IStandardizedYield(SY).rewardIndexesCurrent();
    }

    function _updateRewardIndex() internal override returns (address[] memory tokens, uint256[] memory indexes) {
        tokens = getRewardTokens();
        indexes = IStandardizedYield(SY).rewardIndexesCurrent();
    }

    function _redeemExternalReward() internal virtual override {
        IStandardizedYield(SY).claimRewards(address(this));
    }
}
