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
import { AutoIncrementId } from "../libraries/AutoIncrementId.sol";
import { IOutrunStakeManager } from "./interfaces/IOutrunStakeManager.sol";
import { IYieldToken } from "../YieldContracts/interfaces/IYieldToken.sol";
import { IStandardizedYield } from "../StandardizedYield/IStandardizedYield.sol";
import { PositionRewardManager } from "../RewardManager/PositionRewardManager.sol";
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
    Pausable, 
    Ownable
{
    uint256 public constant DAY = 24 * 3600;
    address public immutable SY;
    address public immutable YT;
    
    uint256 public minStake;
    uint256 public negativeYields;
    uint128 public syTotalStaking;
    uint128 public totalPrincipalValue;
    uint256 public syWrapStaking;
    LockupDuration public lockupDuration;

    uint256 public MTV;             // Mint-to-Value Ratio
    uint256 public mintFeeRate;
    uint256 public keeperFeeRate;
    uint256 public protocolFeeRate;

    address public UPT;
    address public revenuePool;

    mapping(address keeper => bool) public keepers;

    mapping(uint256 positionId => Position) public positions;

    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 minStake_,
        uint256 MTV_,
        uint256 mintFeeRate_,
        uint256 keeperFeeRate_,
        uint256 protocolFeeRate_,
        address revenuePool_,
        address _SY,
        address _YT,
        address _UPT
    ) OutrunERC6909(name_, symbol_, decimals_) Ownable(owner_) {
        SY = _SY;
        YT = _YT;
        UPT = _UPT;
        MTV = MTV_;
        minStake = minStake_;
        revenuePool = revenuePool_;
        mintFeeRate = mintFeeRate_;
        keeperFeeRate = keeperFeeRate_;
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
     * @dev The total actual principal value
     */
    function totalActualPrincipal() external view override returns (uint256) {
        return totalPrincipalValue - negativeYields;
    }

    /**
     * @dev Calculate UPT amount by YT amount and principal value, reasonable input needs to be provided during simulation calculations.
     */
    function calcUPTAmount(uint256 principalValue, uint256 amountInYT) public view override returns (uint256 calcAmount) {
        int256 totalRedeemableYields = IYieldToken(YT).totalRedeemableYields();
        require(totalRedeemableYields >= 0, NegativeYields());
        if (amountInYT == 0) return principalValue;
        
        uint256 newYTSupply = IERC20(YT).totalSupply() + amountInYT;
        uint256 yieldTokenValue = uint256(SYUtils.syToAsset(
            IStandardizedYield(SY).exchangeRate(), 
            Math.mulDiv(amountInYT, uint256(totalRedeemableYields), newYTSupply, Math.Rounding.Ceil)
        ));
        calcAmount = principalValue > yieldTokenValue ? principalValue - yieldTokenValue : 0;

        uint256 maxMintAmount = Math.mulDiv(principalValue, MTV, 1e18);
        if (calcAmount > maxMintAmount) calcAmount = maxMintAmount;
    }

    /**
     * @dev Preview the token mintable amount before stake
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     * @param isSPSeparated - Is SP separated?
     */
    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays,
        bool isSPSeparated
    ) external view override returns (uint256 SPMintable, uint256 YTMintable, uint256 UPTMintable) {
        _stakeParamValidate(amountInSY, lockupDays);

        YTMintable = amountInSY * lockupDays;
        SPMintable = SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY);
        if (isSPSeparated) UPTMintable = calcUPTAmount(SPMintable, YTMintable);
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
     * @dev Allows user to deposit SY, then mints UPT, YT.
     * @param amountInSY - Staked amount of SY
     * @param lockupDays - User can redeem after lockupDays
     * @param SPRecipient - Receiver of SP
     * @param initOwner - Init owner of position
     * @notice User must have approved this contract to spend SY
     */
    function stake(
        uint128 amountInSY,
        uint128 lockupDays,
        address SPRecipient,
        address initOwner
    ) external override accumulateYields nonReentrant whenNotPaused returns (
        uint256 positionId, 
        uint128 SPMinted, 
        uint128 YTMinted
    ) {
        require(initOwner != address(0), ZeroInput());

        _stakeParamValidate(amountInSY, lockupDays);
        _transferIn(SY, msg.sender, amountInSY);
        
        uint128 deadline;
        uint128 principalValue = uint128(SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY));
        unchecked {
            syTotalStaking += amountInSY;
            totalPrincipalValue += principalValue;
            deadline = uint128(block.timestamp + lockupDays * DAY);
            YTMinted = amountInSY * lockupDays;
        }

        positionId = _nextId();
        SPMinted = principalValue;
        positions[positionId] = Position(
            amountInSY, 
            deadline,
            0, 
            uint128(calcUPTAmount(principalValue, YTMinted)), 
            principalValue, 
            SPMinted, 
            initOwner
        );
        IYieldToken(YT).mint(initOwner, YTMinted);

        _mint(SPRecipient, positionId, SPMinted);

        _storeRewardIndexes(positionId);

        emit Stake(positionId, amountInSY, principalValue, SPMinted, YTMinted, deadline, initOwner);
    }

    /**
     * @dev Allows user to deposit SY and only mint UPT.
     * @param amountInSY - Staked amount of SY
     * @param UPTRecipient - Init owner of position
     * @notice User must have approved this contract to spend SY
     * @return amountInUPT - Amount of UPT minted
     * @return mintFee - Mint fee
     */
    function wrapStake(uint128 amountInSY, address UPTRecipient) 
    external override nonReentrant whenNotPaused returns (uint128 amountInUPT, uint256 mintFee) {
        require(UPTRecipient != address(0), ZeroInput());

        uint256 _syWrapStaking = syWrapStaking;
        _updateWrapStakeRewards(_syWrapStaking);

        _transferIn(SY, msg.sender, amountInSY);
        
        uint128 principalValue = uint128(SYUtils.syToAsset(IStandardizedYield(SY).exchangeRate(), amountInSY));
        unchecked {
            syTotalStaking += amountInSY;
            totalPrincipalValue += principalValue;
            syWrapStaking = _syWrapStaking + amountInSY;
        }

        amountInUPT = uint128(calcUPTAmount(principalValue, 0));
        require(IUniversalPrincipalToken(UPT).checkMintableAmount(address(this)) >= amountInUPT, UPTMintingCapReached());

        mintFee = Math.mulDiv(amountInUPT, mintFeeRate, 1e18);
        IUniversalPrincipalToken(UPT).mint(revenuePool, mintFee);
        IUniversalPrincipalToken(UPT).mint(UPTRecipient, amountInUPT - mintFee);

        emit WrapStake(amountInSY, amountInUPT, UPTRecipient);
    }

    /**
     * @dev Allow the separation of UPT from transferableSP
     * @param positionId - Position Id
     * @param SPAmount - Amount of transferableSP
     * @param SPRecipient - Receiver of nonTransferableSP
     * @param UPTRecipient - Receiver of UPT
     * @return amountInUPT - UPT separated Amount
     */
    function separateUPT(
        uint256 positionId, 
        uint256 SPAmount, 
        address SPRecipient, 
        address UPTRecipient
    ) external override nonReentrant whenNotPaused returns (uint128 amountInUPT, uint256 mintFee) {
        require(positionId != 0 && SPAmount != 0 && SPRecipient != address(0) && UPTRecipient != address(0), ZeroInput());
        require(balanceOf(msg.sender, positionId) >= SPAmount, InsufficientSPBalance());

        Position storage position = positions[positionId];
        require(block.timestamp < position.deadline, PositionMatured());

        if (SPRecipient != msg.sender) transfer(SPRecipient, positionId, SPAmount);

        amountInUPT = uint128(Math.mulDiv(position.UPTMintable, SPAmount, position.SPMinted));
        require(IUniversalPrincipalToken(UPT).checkMintableAmount(address(this)) >= amountInUPT, UPTMintingCapReached());

        unchecked {
            position.UPTMinted += amountInUPT;
            nonTransferableBalanceOf[SPRecipient][positionId] += SPAmount;
        }

        if (block.timestamp >= position.deadline) {
            mintFee = Math.mulDiv(amountInUPT, mintFeeRate, 1e18);
            IUniversalPrincipalToken(UPT).mint(revenuePool, mintFee);
            IUniversalPrincipalToken(UPT).mint(UPTRecipient, amountInUPT - mintFee);
        } else {
            IUniversalPrincipalToken(UPT).mint(UPTRecipient, amountInUPT);
        }
        
        emit SeparateUPT(positionId, SPAmount, amountInUPT, SPRecipient, UPTRecipient);
    }

    /**
     * @dev Allow UPT to be encapsulated into transferable SP
     * @param positionId - Position Id
     * @param SPAmount - Amount of nonTransferableSP
     */
    function encapsulateUPT(uint256 positionId, uint256 SPAmount) external override nonReentrant whenNotPaused returns (uint256 UPTBurned) {
        require(positionId != 0 && SPAmount != 0, ZeroInput());

        UPTBurned = _encapsulateUPT(positions[positionId], positionId, SPAmount);

        emit EncapsulateUPT(msg.sender, positionId, SPAmount, UPTBurned);
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
     * @dev Allows user to redeem principal by burning nonTransferableSP and UPT.
     * @param receiver - Receiver of redeemed principal
     * @param positionId - Position Id
     * @param SPBurned - Amount of SP burned
     */
    function redeemPrincipalFromNSPAndUPT(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external override accumulateYields nonReentrant whenNotPaused returns (uint256 UPTBurned, uint256 redeemedPrincipal) {
        require(receiver != address(0) && positionId != 0 && SPBurned != 0 , ZeroInput());

        Position storage position = positions[positionId];
        UPTBurned = _encapsulateUPT(position, positionId, SPBurned);
        redeemedPrincipal = _redeemPrincipalFromSP(receiver, position, positionId, SPBurned);
        
        emit RedeemPrincipalFromNSPAndUPT(positionId, msg.sender, SPBurned, UPTBurned, redeemedPrincipal);
    }

    /**
     * @dev After the expiration of any non-transferable SP, the keepers can redeem the principal on its behalf, 
            and the position holder will not incur any losses.
     * @param SPOwner - Owner of non-transferable SP
     * @param receiver - Receiver of redeemed principal
     * @param positionId - Position Id
     * @param SPBurned - Amount of SP burned
     */
    function keepRedeem(
        address SPOwner,
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external override accumulateYields nonReentrant whenNotPaused {
        require(keepers[msg.sender], PermissionDenied());
        require(receiver != address(0) && positionId != 0 && SPBurned != 0 , ZeroInput());

        Position storage position = positions[positionId];
        uint256 deadline = position.deadline;
        require(block.timestamp >= deadline, LockTimeNotExpired(deadline));

        /** EncapsulateUPT **/
        uint256 nonTransferableSPBalance = nonTransferableBalanceOf[SPOwner][positionId];
        require(nonTransferableSPBalance >= SPBurned, InsufficientSPBalance());

        uint256 UPTBurned = Math.mulDiv(position.UPTMintable, SPBurned, position.SPMinted, Math.Rounding.Ceil);
        IBurnable(UPT).burn(msg.sender, UPTBurned);  

        unchecked {
            position.UPTMinted -= uint128(UPTBurned);
            nonTransferableBalanceOf[SPOwner][positionId] = nonTransferableSPBalance - SPBurned;
        }

        /** Redeem Principal **/
        uint256 SYStaked = position.SYStaked;
        _redeemRewards(position.initOwner, positionId, SYStaked);

        _burn(SPOwner, positionId, SPBurned);

        uint128 _totalPrincipalValue = totalPrincipalValue;
        uint128 redeemablePrincipalValue = _calcRedeemablePrincipalValue(
            negativeYields, 
            _totalPrincipalValue, 
            position.initPrincipal, 
            SPBurned, 
            position.SPMinted
        );

        uint256 exchangeRate = IStandardizedYield(SY).exchangeRate();
        uint256 redeemedPrincipal = SYUtils.assetToSy(exchangeRate, redeemablePrincipalValue);
        
        unchecked {
            totalPrincipalValue -= redeemablePrincipalValue;
            position.SYStaked = uint128(SYStaked - redeemedPrincipal);
        }

        uint256 keeperPrincipal = SYUtils.assetToSy(exchangeRate, UPTBurned);
        uint256 keeperFee = Math.mulDiv(keeperPrincipal, keeperFeeRate, 1e18);
        _transferSY(revenuePool, keeperFee);
        _transferSY(receiver, keeperPrincipal - keeperFee);
        if(redeemedPrincipal > keeperPrincipal) _transferSY(SPOwner, redeemedPrincipal - keeperPrincipal);
        
        emit KeepRedeem(positionId, SPOwner, SPBurned, redeemedPrincipal, keeperPrincipal, keeperFee);
    }

    /**
     * @dev The Keeper can burn UPT to redeem SY deposited through WrapStake at a 1:1 underlying asset price.
     * @param receiver - Receiver of SY
     * @param amountInUPT - Amount of UPT burned
     */
    function keepWrapRedeem(
        address receiver,
        uint128 amountInUPT
    ) external override accumulateYields nonReentrant whenNotPaused {
        require(keepers[msg.sender], PermissionDenied());
        require(receiver != address(0) && amountInUPT != 0 , ZeroInput());

        _redeemWrapStakeRewards();

        IBurnable(UPT).burn(msg.sender, amountInUPT);

        uint256 _negativeYields = negativeYields;
        uint128 _totalPrincipalValue = totalPrincipalValue;
        uint128 redeemablePrincipalValue = _negativeYields > 0
            ? uint128(Math.mulDiv(amountInUPT, _totalPrincipalValue - _negativeYields, _totalPrincipalValue))
            : amountInUPT;
        uint128 amountInSY = uint128(SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemablePrincipalValue));
        
        unchecked {
            syTotalStaking -= amountInSY;
            totalPrincipalValue = _totalPrincipalValue - redeemablePrincipalValue;
            syWrapStaking -= amountInSY;
        }

        uint256 keeperFee = Math.mulDiv(amountInSY, keeperFeeRate, 1e18);
        _transferSY(revenuePool, keeperFee);
        _transferSY(receiver, amountInSY - keeperFee);
        
        emit KeepWrapRedeem(receiver, amountInUPT, amountInSY, keeperFee);
    }

    /**
     * @dev Allow batch redemption of accumulated rewards
     * @param positionIds - Array of Position id
     */
    function batchRedeemReward(uint256[] calldata positionIds) external whenNotPaused override {
        (address[] memory tokens, uint256[] memory indexes) = _updateRewardIndex();

        uint256 positionId;
        uint256 SYStaked;
        address initOwner;
        Position storage position;
        for (uint256 i = 0; i < positionIds.length; i++) {
            positionId = positionIds[i];
            position = positions[positionId];
            SYStaked = position.SYStaked;
            initOwner = position.initOwner;

            _updatePositionRewards(positionId, SYStaked, tokens, indexes);
            uint256[] memory rewardsOut = _doTransferOutRewards(initOwner, positionId);
            if (rewardsOut.length != 0) emit RedeemRewards(positionId, initOwner, rewardsOut);
        }
    }

    /**
     * @dev Redeem the rewards generated by SY staked through WrapStake
     */
    function redeemWrapStakeRewards() external whenNotPaused override {
        _redeemWrapStakeRewards();
    }
    
    /**
     * @dev Transfer yields when collecting protocol fees and withdrawing yields, only YT can call
     * @param receiver - Address of receiver
     * @param syAmount - Amount of protocol fee
     */
    function transferYields(address receiver, uint256 syAmount) external whenNotPaused override onlyYT {
        _transferSY(receiver, syAmount);
    }

    /**
     * @dev Update the negative yields, only when the total yields is negative (triggered only in extreme cases)
     * @param _negativeYields - negativeYields
     */
    function updateNegativeYields(uint256 _negativeYields) external whenNotPaused override onlyYT {
        negativeYields = _negativeYields;

        emit UpdateNegativeYields(_negativeYields);
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

    function addKeeper(address _keeper) external override onlyOwner {
        require(_keeper != address(0), ZeroInput());
        keepers[_keeper] = true;

        emit AddKeeper(_keeper);
    }

    function removeKeeper(address _keeper) external override onlyOwner {
        require(_keeper != address(0), ZeroInput());
        keepers[_keeper] = false;

        emit RemoveKeeper(_keeper);
    }

    function setMTV(uint256 _MTV) external override onlyOwner {
        require(_MTV <= 1e18, RateOverflow());
        MTV = _MTV;

        emit SetMTV(_MTV);
    }

    function setMintFeeRate(uint256 _mintFeeRate) external override onlyOwner {
        require(_mintFeeRate <= 1e18, RateOverflow());
        mintFeeRate = _mintFeeRate;

        emit SetMintFeeRate(_mintFeeRate);
    }

    function setKeeperFeeRate(uint256 _keeperFeeRate) external override onlyOwner {
        require(_keeperFeeRate <= 1e18, RateOverflow());
        keeperFeeRate = _keeperFeeRate;

        emit SetKeeperFeeRate(_keeperFeeRate);
    }

    function setProtocolFeeRate(uint256 _protocolFeeRate) external override onlyOwner {
        require(_protocolFeeRate <= 1e18, RateOverflow());
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

    function _encapsulateUPT(
        Position storage position, 
        uint256 positionId, 
        uint256 SPAmount
    ) internal returns (uint256 UPTBurned) {
        uint256 nonTransferableSPBalance = nonTransferableBalanceOf[msg.sender][positionId];
        require(nonTransferableSPBalance >= SPAmount, InsufficientSPBalance());

        UPTBurned = Math.mulDiv(position.UPTMintable, SPAmount, position.SPMinted, Math.Rounding.Ceil);
        IBurnable(UPT).burn(msg.sender, UPTBurned);  

        unchecked {
            position.UPTMinted -= uint128(UPTBurned);
            nonTransferableBalanceOf[msg.sender][positionId] = nonTransferableSPBalance - SPAmount;
        }
    }

    function _redeemPrincipalFromSP(
        address receiver, 
        Position storage position, 
        uint256 positionId, 
        uint256 SPBurned
    ) internal returns (uint128 redeemedPrincipal) {
        uint256 deadline = position.deadline;
        require(block.timestamp >= deadline, LockTimeNotExpired(deadline));

        uint128 SYStaked = position.SYStaked;
        _redeemRewards(position.initOwner, positionId, SYStaked);

        _burn(msg.sender, positionId, SPBurned);

        uint128 _totalPrincipalValue = totalPrincipalValue;
        uint128 redeemablePrincipalValue = _calcRedeemablePrincipalValue(
            negativeYields, 
            _totalPrincipalValue, 
            position.initPrincipal, 
            SPBurned, 
            position.SPMinted
        );
        redeemedPrincipal = uint128(SYUtils.assetToSy(IStandardizedYield(SY).exchangeRate(), redeemablePrincipalValue));
        
        unchecked {
            totalPrincipalValue = _totalPrincipalValue - redeemablePrincipalValue;
            position.SYStaked = SYStaked - redeemedPrincipal;
        }

        _transferSY(receiver, redeemedPrincipal);
    }

    function _calcRedeemablePrincipalValue(
        uint256 _negativeYields,
        uint128 _totalPrincipalValue,
        uint128 _initPositionPrincipal, 
        uint256 _SPBurned, 
        uint256 _SPMinted
    ) internal pure returns (uint128 redeemablePrincipalValue) {
        uint128 actualPositionPrincipal = _negativeYields > 0
            ? uint128(Math.mulDiv(_initPositionPrincipal, _totalPrincipalValue - _negativeYields, _totalPrincipalValue))
            : _initPositionPrincipal;
        redeemablePrincipalValue = uint128(Math.mulDiv(actualPositionPrincipal, _SPBurned, _SPMinted));
    }

    function _transferSY(address receiver, uint256 syAmount) internal {
        unchecked {
            syTotalStaking -= uint128(syAmount);
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
        uint256 len = tokens.length;
        if (len == 0) return;

        for (uint256 i = 0; i < len;) {
            positionReward[tokens[i]][positionId] = PositionReward(uint128(indexes[i]), 0, false);
            unchecked { i++; }
        }
    }

    function _redeemRewards(
        address initOwner,
        uint256 positionId, 
        uint256 SYStaked
    ) internal returns (uint256[] memory rewardsOut) {
        (address[] memory tokens, uint256[] memory indexes) = _updateRewardIndex();
        _updatePositionRewards(positionId, SYStaked, tokens, indexes);
        rewardsOut = _doTransferOutRewards(initOwner, positionId);
        if (rewardsOut.length != 0) emit RedeemRewards(positionId, initOwner, rewardsOut);
    }

    function _redeemWrapStakeRewards() internal returns (uint256[] memory rewardsOut) {
        _updateWrapStakeRewards(syWrapStaking);

        bool redeemExternalThisRound;
        address[] memory tokens = getRewardTokens();
        uint256 len = tokens.length;
        rewardsOut = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            uint128 totalRewards = wrapStakeRewardAccrued[token];

            if (totalRewards == 0) {
                unchecked { i++; }
                continue;
            }

            if (!redeemExternalThisRound) {
                if (_selfBalance(token) < totalRewards) {
                    _redeemExternalReward();
                    redeemExternalThisRound = true;
                }
            }

            wrapStakeRewardAccrued[token] = 0;
            rewardsOut[i] = totalRewards;
            _transferOut(token, revenuePool, totalRewards);

            emit ProtocolRewardRevenue(token, totalRewards);

            unchecked { i++; }
        }
    }

    function _doTransferOutRewards(address receiver, uint256 positionId) internal override returns (uint256[] memory rewardAmounts) {
        bool redeemExternalThisRound;

        address[] memory tokens = getRewardTokens();
        uint256 len = tokens.length;
        rewardAmounts = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            PositionReward storage rewardOfPosition = positionReward[token][positionId];
            uint128 totalRewards = rewardOfPosition.accrued;

            if (totalRewards == 0) {
                unchecked { i++; }
                continue;
            }

            if (!redeemExternalThisRound) {
                if (_selfBalance(token) < totalRewards) {
                    _redeemExternalReward();
                    redeemExternalThisRound = true;
                }
            }

            positionReward[token][positionId].accrued = 0;

            uint256 revenue;
            if (!rewardOfPosition.finalCollected) {
                revenue = Math.mulDiv(uint256(totalRewards), protocolFeeRate, 1e18);
                totalRewards -= uint128(revenue);
                rewardAmounts[i] = totalRewards;
                if (block.timestamp >= positions[positionId].deadline) rewardOfPosition.finalCollected = true;

                _transferOut(token, receiver, totalRewards);
            } else {
                revenue = totalRewards;
            }

            _transferOut(token, revenuePool, revenue);

            emit ProtocolRewardRevenue(token, revenue);

            unchecked { i++; }
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
