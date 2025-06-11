// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";


import { IERC6909 } from "../core/common/IERC6909.sol";
import { IOutrunRouter } from "./interfaces/IOutrunRouter.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { TokenHelper, IERC20, IERC6909 } from "../core/libraries/TokenHelper.sol";
import { IStandardizedYield } from "../core/StandardizedYield/IStandardizedYield.sol";
import { IOutrunStakeManager } from "../core/Position/interfaces/IOutrunStakeManager.sol";
import { IUniversalPrincipalToken } from "../core/YieldContracts/interfaces/IUniversalPrincipalToken.sol";

contract OutrunRouter is IOutrunRouter, TokenHelper, Ownable {
    address public memeverseLauncher;

    constructor(address _owner, address _memeverseLauncher) Ownable(_owner) {
        memeverseLauncher = _memeverseLauncher;
    }

    /** MINT/REDEEM SY **/
    function mintSYFromToken(
        address SY,
        address tokenIn,
        address receiver,
        uint256 amountInput,
        uint256 minSyOut,
        bool doPull
    ) external payable returns (uint256 amountInSYOut) {
        amountInSYOut = _mintSY(SY, tokenIn, receiver, amountInput, minSyOut, doPull);
    }

    function redeemSyToToken(
        address SY,
        address receiver,
        address tokenOut,
        uint256 amountInSY,
        uint256 minTokenOut,
        bool doPull
    ) external returns (uint256 amountInTokenOut) {
        amountInTokenOut = _redeemSy(SY, receiver, tokenOut, amountInSY, minTokenOut, doPull);
    }

    function _mintSY(
        address SY,
        address tokenIn,
        address receiver,
        uint256 amountInput,
        uint256 minSyOut,
        bool doPull
    ) internal returns (uint256 amountInSYOut) {
        if(doPull) _transferIn(tokenIn, msg.sender, amountInput);

        uint256 amountInNative = tokenIn == NATIVE ? amountInput : 0;
        _safeApproveInf(tokenIn, SY);
        amountInSYOut = IStandardizedYield(SY).deposit{value: amountInNative}(
            receiver,
            tokenIn,
            amountInput,
            minSyOut
        );
    }

    function _redeemSy(
        address SY,
        address receiver,
        address tokenOut,
        uint256 amountInSY,
        uint256 minTokenOut,
        bool doPull
    ) internal returns (uint256 amountInRedeemed) {
        if(doPull) _transferFrom(IERC20(SY), msg.sender, SY, amountInSY);

        amountInRedeemed = IStandardizedYield(SY).redeem(receiver, amountInSY, tokenOut, minTokenOut, doPull);
    }

    /** MINT SP, (U)PT, YT, PYT **/
    /**
     * @dev Mint yield tokens(SP, (U)PT, YT, PYT) from yield-Bearing token
     */
    function mintYieldTokensFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) public payable override returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted) {
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, 0, true);

        _safeApproveInf(SY, SP);
        (positionId, SPMinted, YTMinted) = _mintYieldTokensFromSY(
            SP,
            amountInSY, 
            stakeParam
        );
    }

    /**
     * @dev Mint yield tokens(SP, (U)PT, YT, PYT) by staking SY
     */
    function mintYieldTokensFromSY(
        address SY,
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) public override returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted) {
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);

        _safeApproveInf(SY, SP);
        (positionId, SPMinted, YTMinted) = _mintYieldTokensFromSY(
            SP,
            amountInSY, 
            stakeParam
        );
    }

    function _mintYieldTokensFromSY(
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) internal returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted) {
        (positionId, SPMinted, YTMinted) = IOutrunStakeManager(SP).stake(
            amountInSY, 
            stakeParam.lockupDays,
            stakeParam.YTRecipient, 
            stakeParam.PYTRecipient,
            stakeParam.initOwner,
            stakeParam.isTypeUPT
        );

        uint256 minSPMinted = stakeParam.minSPMinted;
        require(SPMinted >= minSPMinted, InsufficientSPMinted(SPMinted, minSPMinted));

        IOutrunStakeManager(SP).separatePT(stakeParam.PTRecipient, positionId, SPMinted);
    }

    /** Redeem Principal **/
    /**
     * @dev Redeem principal from (U)PT
     * @notice If position.isTypeUPT == true, Must have approved SP contract to spend sender's PT.
               Must have approved this contract to spend sender's "2 × PTAmount" SP.
     */
    function redeemPrincipalFromPT(
        address SP, 
        address sender, 
        uint256 positionId, 
        uint256 PTAmount
    ) external override returns (uint256 redeemedSyAmount) {
        IOutrunStakeManager(SP).encapsulatePT(sender, positionId, PTAmount);
        
        redeemedSyAmount = _redeemPrincipalFromSP(SP, sender, positionId, PTAmount);
    }

    /**
     * @dev Redeem principal from SP
     * @notice Must have approved this contract to spend sender's "PTAmount" SP.
     */
    function redeemPrincipalFromSP(
        address SP, 
        address sender, 
        uint256 positionId, 
        uint256 PTAmount
    ) external override returns (uint256 redeemedSyAmount) {
        redeemedSyAmount = _redeemPrincipalFromSP(SP, sender, positionId, PTAmount);
    }

    function _redeemPrincipalFromSP(
        address SP, 
        address sender, 
        uint256 positionId, 
        uint256 PTAmount
    ) internal returns (uint256 redeemedSyAmount) {
        IERC6909(SP).transferFrom(sender, address(this), positionId, PTAmount);
        redeemedSyAmount = IOutrunStakeManager(SP).redeemPrincipal(msg.sender, positionId, PTAmount);
    }

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
    ) external payable {
        (, uint256 amountInUPT, ) = mintYieldTokensFromToken(SY, SP, tokenIn, tokenAmount, stakeParam);
        _safeApproveInf(UPT, memeverseLauncher);
        IMemeverseLauncher(memeverseLauncher).genesis(verseId, amountInUPT, genesisUser);

    }

    function genesisBySY(
        address SY,
        address SP,
        address UPT,
        uint256 amountInSY,
        uint256 verseId,
        address genesisUser,
        StakeParam calldata stakeParam
    ) external {
        (, uint256 amountInUPT,) = mintYieldTokensFromSY(SY, SP, amountInSY, stakeParam);
        _safeApproveInf(UPT, memeverseLauncher);
        IMemeverseLauncher(memeverseLauncher).genesis(verseId, amountInUPT, genesisUser);
    }

    function setMemeverseLauncher(address _memeverseLauncher) external override onlyOwner {
        memeverseLauncher = _memeverseLauncher;
    }
}
