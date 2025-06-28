//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title Outrun SY Stake Manager interface
 */
interface IOutrunStakeManager {
    struct Position {
        uint256 SYStaked;               // Amount of SY staked
        uint256 principalRedeemable;    // The principal value redeemable
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

    error UPTNotSupported();

    error PositionMatured();

    error PermissionDenied();

    error UPTCannotBeMinted();

    error InsufficientSPBalance();

    error LockTimeNotExpired(uint256 deadLine);

    error MinStakeInsufficient(uint256 minStake);

    error InsufficientSPMintable(uint256 SPMintable);

    error InsufficientPTMintable(uint256 PTMintable);

    error InvalidLockupDays(uint256 minLockupDays, uint256 maxLockupDays);


    function syTotalStaking() external view returns (uint256);

    function totalPrincipalValue() external view returns (uint256);

    function averageStakingDays() external view returns (uint256);

    function calcSPAmount(uint256 principalValue, uint256 amountInYT) external view returns (uint256 amount);

    function previewStake(
        uint256 amountInSY, 
        uint256 lockupDays,
        bool isTypeUPT
    ) external view returns (uint256 PTMintable, uint256 YTMintable);
    
    function previewRedeem(
        uint256 positionId, 
        uint256 SPAmount
    ) external view returns (uint256 redeemableSyAmount);

    function stake(
        uint256 amountInSY,
        uint256 lockupDays,
        address YTRecipient,
        address PYTRecipient,
        address initOwner,
        bool isTypeUPT
    ) external returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted);

    function separatePT(uint256 positionId, uint256 PTAmount, address SPRecipient, address PTRecipient) external;

    function encapsulatePT(address sender, uint256 positionId, uint256 PTAmount) external;

    function redeemPrincipal(address receiver, uint256 positionId, uint256 SPAmount) external returns (uint256 redeemedSyAmount);

    function transferYields(address receiver, uint256 syAmount) external;

    function setLockupDuration(uint128 minLockupDays, uint128 maxLockupDays) external;

    function setUPT(address UPT) external;


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

    event SeparatePT(uint256 indexed positionId, uint256 PTAmount, address indexed SPRecipient, address indexed PTRecipient);

    event EncapsulatePT(address indexed sender, uint256 indexed positionId, uint256 PTAmount);

    event MintSP(uint256 indexed positionId, uint256 positionShare);

    event RedeemPrincipal(
        uint256 indexed positionId, 
        address indexed account,
        uint256 redeemedSyAmount, 
        uint256 positionShare
    );

    event SetLockupDuration(uint128 minLockupDays, uint128 maxLockupDays);
}