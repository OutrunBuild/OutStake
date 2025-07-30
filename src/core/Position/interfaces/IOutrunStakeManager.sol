//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title Outrun SY Stake Manager interface
 */
interface IOutrunStakeManager {
    struct Position {
        uint256 SYStaked;               // Amount of SY staked
        uint256 initPrincipal;          // The initial principal value
        uint256 PTMintable;             // Amount of PT mintable
        uint256 PTMinted;               // Amount of PT minted
        uint256 SPMinted;               // Amount of SP minted
        uint256 deadline;               // Position unlock time
        address initOwner;              // Address of init staker(For redeem reward)
        bool isTypeUPT;                 // Is the PT type UPT?
    }

    struct LockupDuration {
        uint128 minLockupDays;      // Position min lockup days
        uint128 maxLockupDays;      // Position max lockup days
    }

    error ZeroInput();

    error ErrorInput();

    error NotUPTPosition();

    error FeeRateOverflow();

    error UPTNotSupported();

    error PositionMatured();

    error PermissionDenied();

    error InsufficientSPBalance();

    error LockTimeNotExpired(uint256 deadLine);

    error MinStakeInsufficient(uint256 minStake);

    error InvalidLockupDays(uint256 minLockupDays, uint256 maxLockupDays);


    function syTotalStaking() external view returns (uint256);

    function totalPrincipalValue() external view returns (uint256);

    function averageStakingDays() external view returns (uint256);

    function calcPTAmount(uint256 principalValue, uint256 amountInYT, bool isTypeUPT) external view returns (uint256 amount);

    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays,
        bool isTypeUPT,
        bool isSPSeparated
    ) external view returns (uint256 SPMintable, uint256 YTMintable, uint256 PTMintable, uint256 PYTMintable);
    
    function previewRedeem(
        uint256 positionId, 
        uint256 SPAmount
    ) external view returns (uint256 redeemableSyAmount);

    function stake(
        uint256 amountInSY,
        uint256 lockupDays,
        address SPRecipient,
        address initOwner,
        bool isTypeUPT
    ) external returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted, uint256 PYTMintable);

    function separatePT(
        uint256 positionId, 
        uint256 SPAmount, 
        address SPRecipient, 
        address PTRecipient
    ) external returns (uint256 PTAmount);

    function encapsulatePT(uint256 positionId, uint256 SPAmount) external returns (uint256 PTBurned);

    function redeemPrincipalFromSP(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external returns (uint256 redeemedPrincipal);

    function redeemPrincipalFromNSPAndPT(
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external returns (uint256 PTBurned, uint256 redeemedPrincipal);

    function redeemLiquidate(
        address SPOwner,
        address receiver, 
        uint256 positionId, 
        uint256 SPBurned
    ) external;

    function transferYields(address receiver, uint256 syAmount) external;

    function setLockupDuration(uint128 minLockupDays, uint128 maxLockupDays) external;

    function setMinStake(uint256 minStake) external;

    function setUPT(address UPT) external;

    function setRevenuePool(address revenuePool) external;

    function setLiquidator(address liquidator) external;

    function setProtocolFeeRate(uint256 protocolFeeRate) external;


    event Stake(
        uint256 indexed positionId,
        uint256 amountInSY,
        uint256 principalValue,
        uint256 SPMinted,
        uint256 YTMinted,
        uint256 deadline,
        address indexed initOwner,
        bool indexed isTypeUPT
    );

    event SeparatePT(
        uint256 indexed positionId, 
        uint256 transferableSPAmount,
        uint256 PTAmount,
        address indexed SPRecipient, 
        address indexed PTRecipient
    );

    event EncapsulatePT(
        address indexed sender, 
        uint256 indexed positionId, 
        uint256 nonTransferableSPAmount,
        uint256 PTBurned
    );

    event RedeemPrincipalFromSP(
        uint256 indexed positionId, 
        address indexed account,
        uint256 redeemedPrincipal, 
        uint256 SPBurned
    );

    event RedeemPrincipalFromNSPAndPT(
        uint256 indexed positionId, 
        address indexed account, 
        uint256 SPBurned, 
        uint256 PTBurned, 
        uint256 redeemedPrincipal
    );

    event RedeemLiquidate(
        uint256 indexed positionId, 
        address indexed SPOwner, 
        uint256 SPBurned, 
        uint256 redeemedPrincipal, 
        uint256 liquidatorPrincipal
    );

    event SetLockupDuration(uint128 minLockupDays, uint128 maxLockupDays);

    event SetMinStake(uint256 minStake);

    event SetUPT(address UPT);

    event SetRevenuePool(address revenuePool);

    event SetLiquidator(address liquidator);

    event SetProtocolFeeRate(uint256 protocolFeeRate);
}