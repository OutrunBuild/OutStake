//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SYUtils } from "../libraries/SYUtils.sol";
import { IBurnable } from "../libraries/IBurnable.sol";
import { TokenHelper } from "../libraries/TokenHelper.sol";
import { OutrunERC6909 } from "../common/OutrunERC6909.sol";
import { ReentrancyGuard } from "../libraries/ReentrancyGuard.sol";
import { AutoIncrementId } from "../libraries/AutoIncrementId.sol";
import { IOutrunStakeManager } from "./interfaces/IOutrunStakeManager.sol";
import { IYieldToken } from "../YieldContracts/interfaces/IYieldToken.sol";
import { IYieldManager } from "../YieldContracts/interfaces/IYieldManager.sol";
import { IStandardizedYield } from "../StandardizedYield/IStandardizedYield.sol";
import { PositionRewardManager, Math } from "../RewardManager/PositionRewardManager.sol";
import { IPrincipalToken } from "../YieldContracts/interfaces/IPrincipalToken.sol";
import { IOutrunPointsYieldToken } from "../YieldContracts/interfaces/IOutrunPointsYieldToken.sol";
import { IUniversalPrincipalToken } from "../YieldContracts/interfaces/IUniversalPrincipalToken.sol";

/**
 * @title Outrun Staking Position
 */
contract OutrunStakingPosition is 
    IOutrunStakeManager, 
    PositionRewardManager, 
    AutoIncrementId, 
    OutrunERC6909, 
    TokenHelper, 
    ReentrancyGuard, 
    Pausable, 
    Ownable
{
    using Math for uint256;

    uint256 public constant DAY = 24 * 3600;
    address public immutable SY;
    address public immutable PT;
    address public immutable YT;
    address public immutable PYT;
    
    uint256 public minStake;
    uint256 public syTotalStaking;
    uint256 public totalPrincipalValue;
    LockupDuration public lockupDuration;

    address public UPT;
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
        address _YT,
        address _PYT,
        address _UPT
    ) OutrunERC6909(name_, symbol_, decimals_) Ownable(owner_) {
        SY = _SY;
        PT = _PT;
        YT = _YT;
        PYT = _PYT;
        UPT = _UPT;
        minStake = minStake_;
        revenuePool = revenuePool_;
        protocolFeeRate = protocolFeeRate_;
    }

    modifier onlyYT() {
        require(msg.sender == YT, PermissionDenied());
        _;
    }

    modifier accumulateYields() {
        IYieldManager(YT).accumulateYields();
        _;
    }
    
    /**
     * @dev The implied average number of days staked based on YT. It isn't the true average number of days staked for the position.
     */
    function averageStakingDays() external view override returns (uint256) {
        uint256 _syTotalStaking = syTotalStaking == 0 ? 1 : syTotalStaking;
        return IERC20(YT).totalSupply() / _syTotalStaking;
    }

    /**
     * @dev Calculate SP amount by YT amount and principal value, reasonable input needs to be provided during simulation calculations.
     */
    function calcSPAmount(uint256 principalValue, uint256 amountInYT) public view override returns (uint256 amount) {
        if (amountInYT == 0) {
            amount = principalValue;
        } else {
            uint256 newYTSupply = IERC20(YT).totalSupply() + amountInYT;
            uint256 yieldTokenValue = amountInYT * IYieldManager(YT).totalRedeemableYields() / newYTSupply;
            amount = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), (principalValue > yieldTokenValue ? principalValue - yieldTokenValue : 0));
        }
    }

    /**
     * @dev Preview PT mintable amount and YT mintable amount before stake
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     */
    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays,
        bool isTypeUPT
    ) external view override returns (uint256 PTMintable, uint256 YTMintable) {
        _stakeParamValidate(amountInSY, lockupDays);

        YTMintable = amountInSY * lockupDays;
        uint256 principalValue = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY);
        PTMintable = isTypeUPT ? calcSPAmount(principalValue, YTMintable) : principalValue;
    }

    /**
     * @dev Preview redeemable SY amount before redeem
     * @param positionId - Position Id
     * @param SPAmount - Amount of SPAmount
     */
    function previewRedeem(
        uint256 positionId, 
        uint256 SPAmount
    ) external view override returns (uint256 redeemableSyAmount) {
        Position memory position = positions[positionId];
        uint256 redeemedPrincipalValue = position.principalRedeemable * SPAmount / position.SPMinted;
        redeemableSyAmount = SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemedPrincipalValue);
    }

    /**
     * @dev Allows user to deposit SY, then mints PT, YT.
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     * @param YTRecipient - Receiver of YT
     * @param initOwner - Init owner of position
     * @param isTypeUPT - Is the PT type UPT?
     * @notice User must have approved this contract to spend SY
     */
    function stake(
        uint256 amountInSY,
        uint256 lockupDays,
        address YTRecipient,
        address PYTRecipient,
        address initOwner,
        bool isTypeUPT
    ) external override accumulateYields nonReentrant whenNotPaused returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted) {
        require(YTRecipient != address(0) && PYTRecipient != address(0) && initOwner != address(0), ZeroInput());
        if(isTypeUPT) require(IUniversalPrincipalToken(UPT).isAuthorized(address(this)), UPTNotSupported());

        _stakeParamValidate(amountInSY, lockupDays);
        _transferIn(SY, msg.sender, amountInSY);
        
        uint256 deadline;
        uint256 principalValue = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY);
        unchecked {
            syTotalStaking += amountInSY;
            totalPrincipalValue += principalValue;
            deadline = block.timestamp + lockupDays * DAY;
            YTMinted = amountInSY * lockupDays;
        }

        positionId = _nextId();
        SPMinted = isTypeUPT ? principalValue : calcSPAmount(principalValue, YTMinted);
        positions[positionId] = Position(amountInSY, principalValue, 0, SPMinted, deadline, initOwner, isTypeUPT);
        if (lockupDays != 0) IYieldToken(YT).mint(YTRecipient, YTMinted);
        // Positions of the UPT type will forgo Points yields.
        if(!isTypeUPT && lockupDays != 0) IOutrunPointsYieldToken(PYT).mint(PYTRecipient, positionId, SPMinted);
        _mint(msg.sender, positionId, SPMinted);

        _storeRewardIndexes(positionId);

        emit Stake(positionId, amountInSY, principalValue, SPMinted, YTMinted, deadline, initOwner, isTypeUPT);
    }

    /**
     * @dev Allow the separation of PT from SP
     * @param receiver - Receiver of nonTransferableSP and PT
     * @param positionId - Position Id
     * @param PTAmount - Amount of PT minted
     */
    function separatePT(address receiver, uint256 positionId, uint256 PTAmount) external override whenNotPaused {
        require(PTAmount != 0, ZeroInput());

        Position storage position = positions[positionId];
        uint256 PTMinted = position.PTMinted;
        uint256 SPMinted = position.SPMinted;
        uint256 PTMintable = SPMinted - PTMinted;

        require(block.timestamp < position.deadline, PositionMatured());
        require(PTAmount <= PTMintable, InsufficientPTMintable(PTMintable));
        require(balanceOf(msg.sender, positionId) >= PTAmount, InsufficientSPBalance());

        if (msg.sender != receiver) transfer(receiver, positionId, PTAmount);
        unchecked {
            position.PTMinted += PTAmount;
            nonTransferableBalanceOf[receiver][positionId] += PTAmount;
        }

        _mintPT(position.isTypeUPT, PTAmount, receiver);

        emit SeparatePT(receiver, positionId, PTAmount);
    }

    /**
     * @dev Allow PT to be encapsulated into transferable SP
     * @param sender - Sender of nonTransferableSP and PT
     * @param positionId - Position Id
     * @param PTAmount - Amount of PT burned
     * @notice MUST have approved this contract to spend PT.
               If sender != msg.sender, user MUST have approved msg.sender to spend SP.
     */
    function encapsulatePT(address sender, uint256 positionId, uint256 PTAmount) external override whenNotPaused {
        require(PTAmount != 0, ZeroInput());
        _spendAllowance(sender, positionId, PTAmount);

        Position storage position = positions[positionId];
        require(nonTransferableBalanceOf[sender][positionId] >= PTAmount, InsufficientSPBalance());

        unchecked {
            position.PTMinted -= PTAmount;
            nonTransferableBalanceOf[sender][positionId] -= PTAmount;
        }

        address input = position.isTypeUPT ? UPT : PT;
        IBurnable(input).burn(sender, PTAmount);  

        emit EncapsulatePT(sender, positionId, PTAmount);
    }

    /**
     * @dev Allows user to redeem principal by burning transferableSP.
     * @param receiver - Receiver of redeemed principal
     * @param positionId - Position Id
     * @param SPAmount - Amount of SP burned
     */
    function redeemPrincipal(address receiver, uint256 positionId, uint256 SPAmount) 
    external override accumulateYields nonReentrant whenNotPaused 
    returns (uint256 redeemedSyAmount) {
        require(SPAmount != 0, ZeroInput());
        Position storage position = positions[positionId];
        uint256 deadline = position.deadline;
        require(block.timestamp >= deadline, LockTimeNotExpired(deadline));
        require(balanceOf(msg.sender, positionId) >= SPAmount, InsufficientSPBalance());

        _burn(msg.sender, positionId, SPAmount);
        
        uint256 SYRedeemable = position.SYRedeemable;
        _redeemRewards(position.initOwner, positionId, SYRedeemable);
        uint256 SPMinted = position.SPMinted;
        uint256 principalRedeemable = position.principalRedeemable;
        uint256 redeemedPrincipalValue = principalRedeemable * SPAmount / SPMinted;
        redeemedSyAmount = SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemedPrincipalValue);
        
        unchecked {
            totalPrincipalValue -= redeemedPrincipalValue;
            position.SYRedeemable = SYRedeemable - redeemedSyAmount;
            position.SPMinted = SPMinted - SPAmount;
            position.principalRedeemable = principalRedeemable - redeemedPrincipalValue;
        }

        _transferSY(receiver, redeemedSyAmount);
        
        emit RedeemPrincipal(positionId, msg.sender, redeemedSyAmount, SPAmount);
    }

    /**
     * @dev Allows redemption of generated rewards after position unlocks
     * @param positionId - Position id
     */
    function redeemReward(uint256 positionId) external whenNotPaused override {
        Position storage position = positions[positionId];
        uint256 deadline = position.deadline;
        require(deadline <= block.timestamp, LockTimeNotExpired(deadline));

        _redeemRewards(position.initOwner, positionId, position.SYRedeemable);
    }

    /**
     * @dev Transfer yields when collecting protocol fees and withdrawing yields, only YT can call
     * @param receiver - Address of receiver
     * @param syAmount - Amount of protocol fee
     */
    function transferYields(address receiver, uint256 syAmount) external whenNotPaused override onlyYT {
        require(msg.sender == YT, PermissionDenied());
        _transferSY(receiver, syAmount);
    }
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
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

    function setUPT(address _UPT) external override onlyOwner {
        UPT = _UPT;
    }

    function _mintPT(bool isTypeUPT, uint256 amount, address receiver) internal {
        if (isTypeUPT) {
            IUniversalPrincipalToken(UPT).mint(receiver, amount);
        } else {
            IPrincipalToken(PT).mint(receiver, amount);
        }
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
        address initOwner,
        uint256 positionId, 
        uint256 SYRedeemable
    ) internal returns (uint256[] memory rewardsOut) {
        _updatePositionRewards(positionId, SYRedeemable);
        rewardsOut = _doTransferOutRewards(initOwner, positionId);
        if (rewardsOut.length != 0) emit RedeemRewards(positionId, initOwner, rewardsOut);
    }

    function _doTransferOutRewards(address receiver, uint256 positionId) internal override returns (uint256[] memory rewardAmounts) {
        bool redeemExternalThisRound;

        address[] memory tokens = getRewardTokens();
        rewardAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            PositionReward storage rewardOfPosition = positionReward[token][positionId];
            uint128 totalRewards = rewardOfPosition.accrued;

            if (totalRewards == 0) continue;

            if (!redeemExternalThisRound) {
                if (_selfBalance(token) < totalRewards) {
                    _redeemExternalReward();
                    redeemExternalThisRound = true;
                }
            }

            uint256 revenue;
            if (!rewardOfPosition.ownerCollected) {
                revenue = uint256(totalRewards).mulDown(protocolFeeRate);
                totalRewards -= revenue.Uint128();
                rewardAmounts[i] = totalRewards;
                positionReward[token][positionId].accrued = 0;

                _transferOut(token, receiver, totalRewards);
            } else {
                revenue = totalRewards;
            }

            _transferOut(token, revenuePool, revenue);

            emit ProtocolRewardRevenue(token, revenue);
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
