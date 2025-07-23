// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IOutrunRouter {
    struct TokenInput {
        address tokenIn;
        uint256 amount;
        uint256 minTokenOut;
    }

    struct StakeParam {
        uint256 lockupDays;
        uint256 minSPMinted;
        address initOwner;
        bool isSPSeparated;
        bool isTypeUPT;
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


    /** Mint yield tokens(SP, (U)PT, YT, PYT) **/
    function mintYieldTokensFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) external payable returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted);

    function mintYieldTokensFromSY(
        address SY,
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) external returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted);

    /** Memeverse Genesis **/
    function genesisByToken(
        address SY,
        address SP,
        address UPT,
        address tokenIn,
        uint256 tokenAmount,
        uint256 verseId,
        address genesisUser,
        StakeParam calldata stakeParam
    ) external payable;

    function genesisBySY(
        address SY,
        address SP,
        address UPT,
        uint256 amountInSY,
        uint256 verseId,
        address genesisUser,
        StakeParam calldata stakeParam
    ) external;

    function setMemeverseLauncher(address memeverseLauncher) external;

    error InsufficientSPMinted(uint256 SPMinted, uint256 minMinted);
}
