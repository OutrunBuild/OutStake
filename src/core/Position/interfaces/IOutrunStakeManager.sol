//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title Outrun SY Stake Manager interface
 */
interface IOutrunStakeManager {
    struct Position {
        uint128 SYStaked;               // Amount of SY staked
        uint128 deadline;               // Position unlock time
        uint128 UPTMinted;               // Amount of UPT minted
        uint128 UPTMintable;             // Amount of UPT mintable
        uint128 initPrincipal;          // Initial principal value, non-redeemable actual principal
        uint128 SPMinted;               // Amount of SP minted
        address initOwner;              // Address of init staker(For redeem reward)
    }

    struct LockupDuration {
        uint128 minLockupDays;      // Position min lockup days
        uint128 maxLockupDays;      // Position max lockup days
    }

    error ZeroInput();

    error ErrorInput();

    error RateOverflow();

    error NegativeYields();

    error UPTNotSupported();

    error PositionMatured();

    error PermissionDenied();

    error InsufficientSPBalance();

    error LockTimeNotExpired(uint256 deadLine);

    error MinStakeInsufficient(uint256 minStake);

    error InvalidLockupDays(uint256 minLockupDays, uint256 maxLockupDays);


    function syTotalStaking() external view returns (uint128);

    function totalPrincipalValue() external view returns (uint128);

    function totalActualPrincipal() external view returns (uint256);

    function averageStakingDays() external view returns (uint256);

    function calcUPTAmount(uint256 principalValue, uint256 amountInYT) external view returns (uint256 calcAmount);

    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays,
        bool isSPSeparated
    ) external view returns (uint256 SPMintable, uint256 YTMintable, uint256 UPTMintable);
    
    function previewRedeem(
        uint256 positionId, 
        uint256 SPAmount
    ) external view returns (uint256 redeemableSyAmount);

    function stake(
        uint128 amountInSY,
        uint128 lockupDays,
        address SPRecipient,
        address initOwner
    ) external returns (uint256 positionId, uint128 SPMinted, uint128 YTMinted);

    function separateUPT(
        uint256 positionId, 
        uint256 SPAmount, 
        address SPRecipient, 
        address UPTRecipient
    ) external returns (uint128 UPTAmount, uint256 mintFee);

    function encapsulateUPT(uint256 positionId, uint256 SPAmount) external returns (uint256 UPTBurned);

    function redeemPrincipalFromSP(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external returns (uint256 redeemedPrincipal);

    function redeemPrincipalFromNSPAndUPT(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external returns (uint256 UPTBurned, uint256 redeemedPrincipal);

    function redeemLiquidate(
        address SPOwner,
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external;

    function transferYields(address receiver, uint256 syAmount) external;

    function updateNegativeYields(uint256 negativeYields) external;

    function setLockupDuration(uint128 minLockupDays, uint128 maxLockupDays) external;

    function setMinStake(uint256 minStake) external;

    function setUPT(address UPT) external;

    function setRevenuePool(address revenuePool) external;

    function setLiquidator(address liquidator) external;

    function setMTV(uint96 MTV) external;

    function setProtocolFeeRate(uint96 protocolFeeRate) external;


    event Stake(
        uint256 indexed positionId,
        uint256 amountInSY,
        uint256 principalValue,
        uint256 SPMinted,
        uint256 YTMinted,
        uint256 deadline,
        address indexed initOwner
    );

    event SeparateUPT(
        uint256 indexed positionId, 
        uint256 transferableSPAmount,
        uint256 UPTAmount,
        address indexed SPRecipient, 
        address indexed UPTRecipient
    );

    event EncapsulateUPT(
        address indexed sender, 
        uint256 indexed positionId, 
        uint256 nonTransferableSPAmount,
        uint256 UPTBurned
    );

    event RedeemPrincipalFromSP(
        uint256 indexed positionId, 
        address indexed account,
        uint256 redeemedPrincipal, 
        uint256 SPBurned
    );

    event RedeemPrincipalFromNSPAndUPT(
        uint256 indexed positionId, 
        address indexed account, 
        uint256 SPBurned, 
        uint256 UPTBurned, 
        uint256 redeemedPrincipal
    );

    event RedeemLiquidate(
        uint256 indexed positionId, 
        address indexed SPOwner, 
        uint256 SPBurned, 
        uint256 redeemedPrincipal, 
        uint256 liquidatorPrincipal
    );

    event UpdateNegativeYields(uint256 negativeYields);

    event SetLockupDuration(uint128 minLockupDays, uint128 maxLockupDays);

    event SetMinStake(uint256 minStake);

    event SetUPT(address UPT);

    event SetRevenuePool(address revenuePool);

    event SetLiquidator(address liquidator);

    event SetMTV(uint96 MTV);

    event SetProtocolFeeRate(uint96 protocolFeeRate);
}