//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SYUtils } from "../libraries/SYUtils.sol";
import { IBurnable } from "../libraries/IBurnable.sol";
import { TokenHelper } from "../libraries/TokenHelper.sol";
import { OutrunERC6909 } from "../common/OutrunERC6909.sol";
import { ReentrancyGuard } from "../libraries/ReentrancyGuard.sol";
import { AutoIncrementId } from "../libraries/AutoIncrementId.sol";
import { IOutrunStakeManager } from "./interfaces/IOutrunStakeManager.sol";
import { IYieldToken } from "../YieldContracts/interfaces/IYieldToken.sol";
import { IStandardizedYield } from "../StandardizedYield/IStandardizedYield.sol";
import { IPrincipalToken } from "../YieldContracts/interfaces/IPrincipalToken.sol";
import { PositionRewardManager } from "../RewardManager/PositionRewardManager.sol";
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
    address public liquidator;
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
        address liquidator_,
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
        liquidator = liquidator_;
        protocolFeeRate = protocolFeeRate_;
    }

    modifier onlyYT() {
        require(msg.sender == YT, PermissionDenied());
        _;
    }

    modifier accumulateYields() {
        IYieldToken(YT).accumulateYields();
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
     * @dev Calculate PT amount by YT amount and principal value, reasonable input needs to be provided during simulation calculations.
     */
    function calcPTAmount(uint256 principalValue, uint256 amountInYT, bool isTypeUPT) public view override returns (uint256 amount) {
        if (amountInYT == 0 || !isTypeUPT) {
            amount = principalValue;
        } else {
            uint256 newYTSupply = IERC20(YT).totalSupply() + amountInYT;
            uint256 yieldTokenValue = SYUtils.syToAsset(
                IStandardizedYield(SY).exchangeRate(), 
                Math.mulDiv(amountInYT, IYieldToken(YT).totalRedeemableYields(), newYTSupply, Math.Rounding.Ceil)
            );
            amount = principalValue > yieldTokenValue ? principalValue - yieldTokenValue : 0;
        }
    }

    /**
     * @dev Preview the token mintable amount before stake
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     * @param isTypeUPT - Is the PT type UPT?
     * @param isSPSeparated - Is SP separated?
     */
    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays,
        bool isTypeUPT,
        bool isSPSeparated
    ) external view override returns (uint256 SPMintable, uint256 YTMintable, uint256 PTMintable, uint256 PYTMintable) {
        _stakeParamValidate(amountInSY, lockupDays);

        YTMintable = amountInSY * lockupDays;
        SPMintable = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY);
        if (isSPSeparated) PTMintable = calcPTAmount(SPMintable, YTMintable, isTypeUPT);
        if(!isTypeUPT && lockupDays != 0) PYTMintable = amountInSY;
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
        uint256 redeemedPrincipalValue = Math.mulDiv(position.initPrincipal, SPAmount, position.SPMinted);
        redeemableSyAmount = SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemedPrincipalValue);
    }

    /**
     * @dev Allows user to deposit SY, then mints PT, YT.
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     * @param SPRecipient - Receiver of SP
     * @param initOwner - Init owner of position
     * @param isTypeUPT - Is the PT type UPT?
     * @notice User must have approved this contract to spend SY
     */
    function stake(
        uint256 amountInSY,
        uint256 lockupDays,
        address SPRecipient,
        address initOwner,
        bool isTypeUPT
    ) external override accumulateYields nonReentrant whenNotPaused returns (
        uint256 positionId, 
        uint256 SPMinted, 
        uint256 YTMinted, 
        uint256 PYTMintable
    ) {
        require(initOwner != address(0), ZeroInput());
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
        SPMinted = principalValue;
        uint256 PTMintable = calcPTAmount(principalValue, YTMinted, isTypeUPT);
        positions[positionId] = Position(amountInSY, principalValue, PTMintable, 0, SPMinted, deadline, initOwner, isTypeUPT);
        if (lockupDays != 0) IYieldToken(YT).mint(initOwner, YTMinted, !isTypeUPT);
        // Positions of the UPT type will forgo Points yields.
        if(!isTypeUPT && lockupDays != 0) {
            IOutrunPointsYieldToken(PYT).mint(initOwner, positionId, amountInSY);
            PYTMintable = amountInSY;
        }

        _mint(SPRecipient, positionId, SPMinted);

        _storeRewardIndexes(positionId);

        emit Stake(positionId, amountInSY, principalValue, SPMinted, YTMinted, deadline, initOwner, isTypeUPT);
    }

    /**
     * @dev Allow the separation of PT from transferableSP
     * @param positionId - Position Id
     * @param SPAmount - Amount of transferableSP
     * @param SPRecipient - Receiver of nonTransferableSP
     * @param PTRecipient - Receiver of PT
     * @return PTAmount - PT separated Amount
     */
    function separatePT(
        uint256 positionId, 
        uint256 SPAmount, 
        address SPRecipient, 
        address PTRecipient
    ) external override whenNotPaused returns (uint256 PTAmount) {
        require(positionId != 0 && SPAmount != 0 && SPRecipient != address(0) && PTRecipient != address(0), ZeroInput());
        require(balanceOf(msg.sender, positionId) >= SPAmount, InsufficientSPBalance());

        Position storage position = positions[positionId];
        require(block.timestamp < position.deadline, PositionMatured());

        if (SPRecipient != msg.sender) transfer(SPRecipient, positionId, SPAmount);

        uint256 PTMintable = position.PTMintable;
        PTAmount = position.isTypeUPT ? Math.mulDiv(PTMintable, SPAmount, position.SPMinted) : SPAmount;

        unchecked {
            position.PTMinted += PTAmount;
            nonTransferableBalanceOf[SPRecipient][positionId] += SPAmount;
        }

        _mintPT(position.isTypeUPT, PTAmount, PTRecipient);

        emit SeparatePT(positionId, SPAmount, PTAmount, SPRecipient, PTRecipient);
    }

    /**
     * @dev Allow PT to be encapsulated into transferable SP
     * @param positionId - Position Id
     * @param SPAmount - Amount of nonTransferableSP
     */
    function encapsulatePT(uint256 positionId, uint256 SPAmount) external override whenNotPaused returns (uint256 PTBurned) {
        require(positionId != 0 && SPAmount != 0, ZeroInput());

        PTBurned = _encapsulatePT(positions[positionId], positionId, SPAmount);

        emit EncapsulatePT(msg.sender, positionId, SPAmount, PTBurned);
    }

    /**
     * @dev Allows user to redeem principal by burning transferableSP.
     * @param receiver - Receiver of redeemed principal
     * @param positionId - Position Id
     * @param SPBurned - Amount of SP burned
     */
    function redeemPrincipalFromSP(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external override accumulateYields nonReentrant whenNotPaused returns (uint256 redeemedPrincipal) {
        require(receiver != address(0) && positionId != 0 && SPBurned != 0 , ZeroInput());

        redeemedPrincipal = _redeemPrincipalFromSP(receiver, positions[positionId], positionId, SPBurned);

        emit RedeemPrincipalFromSP(positionId, msg.sender, redeemedPrincipal, SPBurned);
    }

    /**
     * @dev Allows user to redeem principal by burning nonTransferableSP and PT.
     * @param receiver - Receiver of redeemed principal
     * @param positionId - Position Id
     * @param SPBurned - Amount of SP burned
     */
    function redeemPrincipalFromNSPAndPT(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external override accumulateYields nonReentrant whenNotPaused returns (uint256 PTBurned, uint256 redeemedPrincipal) {
        require(receiver != address(0) && positionId != 0 && SPBurned != 0 , ZeroInput());

        Position storage position = positions[positionId];
        PTBurned = _encapsulatePT(position, positionId, SPBurned);
        redeemedPrincipal = _redeemPrincipalFromSP(receiver, position, positionId, SPBurned);
        
        emit RedeemPrincipalFromNSPAndPT(positionId, msg.sender, SPBurned, PTBurned, redeemedPrincipal);
    }

    /**
     * @dev After the expiration of any non-transferable SP, the liquidator can redeem the principal on its behalf, 
            and the position holder will not incur any losses.
     * @param SPOwner - Owner of non-transferable SP
     * @param receiver - Receiver of redeemed principal
     * @param positionId - Position Id
     * @param SPBurned - Amount of SP burned
     */
    function redeemLiquidate(
        address SPOwner,
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external override accumulateYields nonReentrant whenNotPaused {
        require(msg.sender == liquidator, PermissionDenied());
        require(receiver != address(0) && positionId != 0 && SPBurned != 0 , ZeroInput());

        Position storage position = positions[positionId];
        require(position.isTypeUPT, NotUPTPosition());
        uint256 deadline = position.deadline;
        require(block.timestamp >= deadline, LockTimeNotExpired(deadline));

        /** EncapsulatePT **/
        uint256 nonTransferableSPBalance = nonTransferableBalanceOf[SPOwner][positionId];
        require(nonTransferableSPBalance >= SPBurned, InsufficientSPBalance());

        uint256 PTBurned = Math.mulDiv(position.PTMintable, SPBurned, position.SPMinted, Math.Rounding.Ceil);
        IBurnable(UPT).burn(msg.sender, PTBurned);  

        unchecked {
            position.PTMinted -= PTBurned;
            nonTransferableBalanceOf[SPOwner][positionId] = nonTransferableSPBalance - SPBurned;
        }

        /** Redeem Principal **/
        uint256 SYStaked = position.SYStaked;
        _redeemRewards(position.initOwner, positionId, SYStaked);

        _burn(SPOwner, positionId, SPBurned);

        uint256 redeemedPrincipalValue = Math.mulDiv(position.initPrincipal, SPBurned, position.SPMinted);
        uint256 exchangeRate = IStandardizedYield(SY).exchangeRate();
        uint256 redeemedPrincipal = SYUtils.assetToSy(exchangeRate, redeemedPrincipalValue);
        
        unchecked {
            totalPrincipalValue -= redeemedPrincipalValue;
            position.SYStaked = SYStaked - redeemedPrincipal;
        }

        uint256 liquidatorPrincipal = SYUtils.assetToSy(exchangeRate, PTBurned);
        _transferSY(receiver, liquidatorPrincipal);
        if(redeemedPrincipal > liquidatorPrincipal) _transferSY(SPOwner, redeemedPrincipal - liquidatorPrincipal);
        
        emit RedeemLiquidate(positionId, SPOwner, SPBurned, redeemedPrincipal, liquidatorPrincipal);
    }

    /**
     * @dev Allows redemption of generated rewards after position unlocks
     * @param positionId - Position id
     */
    function redeemReward(uint256 positionId) external whenNotPaused override {
        Position storage position = positions[positionId];
        uint256 deadline = position.deadline;
        require(deadline <= block.timestamp, LockTimeNotExpired(deadline));

        _redeemRewards(position.initOwner, positionId, position.SYStaked);
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
        require(_maxLockupDays != 0 && _minLockupDays < _maxLockupDays, ErrorInput());

        lockupDuration.minLockupDays = _minLockupDays;
        lockupDuration.maxLockupDays = _maxLockupDays;

        emit SetLockupDuration(_minLockupDays, _maxLockupDays);
    }

    function setMinStake(uint256 _minStake) external override onlyOwner {
        minStake = _minStake;

        emit SetMinStake(_minStake);
    }

    function setUPT(address _UPT) external override onlyOwner {
        require(_UPT != address(0), ZeroInput());
        UPT = _UPT;

        emit SetUPT(_UPT);
    }

    function setRevenuePool(address _revenuePool) external override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());
        revenuePool = _revenuePool;

        emit SetRevenuePool(_revenuePool);
    }

    function setLiquidator(address _liquidator) external override onlyOwner {
        require(_liquidator != address(0), ZeroInput());
        liquidator = _liquidator;

        emit SetLiquidator(_liquidator);
    }

    function setProtocolFeeRate(uint256 _protocolFeeRate) external override onlyOwner {
        require(_protocolFeeRate <= 1e18, FeeRateOverflow());
        protocolFeeRate = _protocolFeeRate;

        emit SetProtocolFeeRate(_protocolFeeRate);
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

    function _mintPT(bool isTypeUPT, uint256 amount, address receiver) internal {
        if (isTypeUPT) {
            IUniversalPrincipalToken(UPT).mint(receiver, amount);
        } else {
            IPrincipalToken(PT).mint(receiver, amount);
        }
    }

    function _encapsulatePT(
        Position storage position, 
        uint256 positionId, 
        uint256 SPAmount
    ) internal returns (uint256 PTBurned) {
        uint256 nonTransferableSPBalance = nonTransferableBalanceOf[msg.sender][positionId];
        require(nonTransferableSPBalance >= SPAmount, InsufficientSPBalance());

        PTBurned = position.isTypeUPT ? Math.mulDiv(position.PTMintable, SPAmount, position.SPMinted, Math.Rounding.Ceil) : SPAmount;
        IBurnable(position.isTypeUPT ? UPT : PT).burn(msg.sender, PTBurned);  

        unchecked {
            position.PTMinted -= PTBurned;
            nonTransferableBalanceOf[msg.sender][positionId] = nonTransferableSPBalance - SPAmount;
        }
    }

    function _redeemPrincipalFromSP(
        address receiver, 
        Position storage position, 
        uint256 positionId, 
        uint256 SPBurned
    ) internal returns (uint256 redeemedPrincipal) {
        uint256 deadline = position.deadline;
        require(block.timestamp >= deadline, LockTimeNotExpired(deadline));

        uint256 SYStaked = position.SYStaked;
        _redeemRewards(position.initOwner, positionId, SYStaked);

        _burn(msg.sender, positionId, SPBurned);

        uint256 redeemedPrincipalValue = Math.mulDiv(position.initPrincipal, SPBurned, position.SPMinted);
        redeemedPrincipal = SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemedPrincipalValue);
        
        unchecked {
            totalPrincipalValue -= redeemedPrincipalValue;
            position.SYStaked = SYStaked - redeemedPrincipal;
        }

        _transferSY(receiver, redeemedPrincipal);
    }

    function _transferSY(address receiver, uint256 syAmount) internal {
        unchecked {
            syTotalStaking -= syAmount;
        }

        _transferOut(SY, receiver, syAmount);
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
            positionReward[tokens[i]][positionId] = PositionReward(uint128(indexes[i]), 0, false);
        }
    }

    function _redeemRewards(
        address initOwner,
        uint256 positionId, 
        uint256 SYStaked
    ) internal returns (uint256[] memory rewardsOut) {
        _updatePositionRewards(positionId, SYStaked);
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
                revenue = Math.mulDiv(uint256(totalRewards), protocolFeeRate, 1e18);
                totalRewards -= uint128(revenue);
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
