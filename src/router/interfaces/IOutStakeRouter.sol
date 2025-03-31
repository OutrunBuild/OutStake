// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IOutStakeRouter {
    struct TokenInput {
        address tokenIn;
        uint256 amount;
        uint256 minTokenOut;
    }

    struct StakeParam {
        uint256 lockupDays;
        uint256 minPTGenerated;
        address PTRecipient;
        address YTRecipient;
        address PYTRecipient;
        address positionOwner;
        bool outputUPT;
    }

    struct RedeemParam {
        uint256 positionId; 
        uint256 positionShare;
        uint256 minRedeemedSyAmount;
    }

    /** MINT/REDEEM SY **/
    function mintSYFromToken(
        address SY,
        address tokenIn,
        address receiver,
        uint256 amountInput,
        uint256 minSyOut,
        bool doPull
    ) external payable returns (uint256 amountInSYOut);

    function redeemSyToToken(
        address SY,
        address receiver,
        address tokenOut,
        uint256 amountInSY,
        uint256 minTokenOut,
        bool doPull
    ) external returns (uint256 amountInTokenOut);


    /** MINT PT(UPT), YT, POT Tokens **/
    function mintPYFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) external payable returns (uint256 PTGenerated, uint256 YTGenerated);

    function mintPYFromSY(
        address SY,
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) external returns (uint256 PTGenerated, uint256 YTGenerated);

    error InsufficientPTGenerated(uint256 PTGenerated, uint256 minPTGenerated);
}
