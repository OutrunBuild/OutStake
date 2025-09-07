// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IOutrunRouter {
    struct TokenInput {
        address tokenIn;
        uint256 amount;
        uint256 minTokenOut;
    }

    struct StakeParam {
        uint128 lockupDays;
        uint128 minSPMinted;
        address initOwner;
        bool isSPSeparated;
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

    function previewMintYieldTokensFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) external view returns (uint256 SPMintable, uint256 YTMintable, uint256 PTMintable);

    function previewMintYieldTokensFromSY(
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) external view returns (uint256 SPMintable, uint256 YTMintable, uint256 PTMintable);

    function previewWrapStakeFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount
    ) external view returns (uint256 UPTMintable);

    /** Mint yield tokens(SP, UPT, YT) **/
    function mintYieldTokensFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) external payable returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted, uint256 PTMinted);

    function mintYieldTokensFromSY(
        address SY,
        address SP,
        uint128 amountInSY,
        StakeParam calldata stakeParam
    ) external returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted, uint256 UPTMinted);

    function wrapStakeFromToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        address UPTRecipient
    ) external payable returns (uint128 UPTMinted, uint256 mintFee);

    /** Memeverse Genesis **/
    function genesisByToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 verseId,
        address genesisUser
    ) external payable;

    function genesisBySY(
        address SP,
        uint128 amountInSY,
        uint256 verseId,
        address genesisUser
    ) external;

    function setMemeverseLauncher(address memeverseLauncher) external;

    error InvalidParam();

    error InsufficientSPMinted(uint256 SPMinted, uint256 minMinted);
}
