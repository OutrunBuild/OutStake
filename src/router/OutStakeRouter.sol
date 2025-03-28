// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IOutStakeRouter } from "./interfaces/IOutStakeRouter.sol";
import { TokenHelper, IERC20, IERC6909 } from "../core/libraries/TokenHelper.sol";
import { IStandardizedYield } from "../core/StandardizedYield/IStandardizedYield.sol";
import { IOutrunStakeManager } from "../core/Position/interfaces/IOutrunStakeManager.sol";
import { IUniversalPrincipalToken } from "../core/YieldContracts/interfaces/IUniversalPrincipalToken.sol";

contract OutStakeRouter is IOutStakeRouter, TokenHelper {
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

    /** MINT PT(UPT), YT **/
    /**
     * @dev Mint PT(UPT), YT from yield-Bearing token
     * @notice When minting UPT is not required, mintUPTParam can be empty
     */
    function mintPYFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam,
        MintUPTParam calldata mintUPTParam
    ) external payable returns (uint256 PTGenerated, uint256 YTGenerated) {
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, 0, true);

        _safeApproveInf(SY, SP);
        (PTGenerated, YTGenerated) = _mintPYFromSY(
            SP,
            amountInSY, 
            stakeParam,
            mintUPTParam
        );
    }

    /**
     * @dev Mint PT(UPT), YT by staking SY
     * @notice When minting UPT is not required, mintUPTParam can be empty
     */
    function mintPYFromSY(
        address SY,
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam,
        MintUPTParam calldata mintUPTParam
    ) external returns (uint256 PTGenerated, uint256 YTGenerated) {
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);

        _safeApproveInf(SY, SP);
        (PTGenerated, YTGenerated) = _mintPYFromSY(
            SP,
            amountInSY, 
            stakeParam,
            mintUPTParam
        );
    }

    function _mintPYFromSY(
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam,
        MintUPTParam calldata mintUPTParam
    ) internal returns (uint256 PTGenerated, uint256 YTGenerated) {
        address UPT = mintUPTParam.UPT;

        (PTGenerated, YTGenerated) = IOutrunStakeManager(SP).stake(
            amountInSY, 
            stakeParam.lockupDays,
            UPT == address(0) ? stakeParam.PTRecipient : address(this),
            stakeParam.YTRecipient, 
            stakeParam.positionOwner
        );

        if (UPT != address(0)) IUniversalPrincipalToken(UPT).mintUPTFromPT(mintUPTParam.PT, msg.sender, PTGenerated);

        uint256 minPTGenerated = stakeParam.minPTGenerated;
        require(PTGenerated >= minPTGenerated, InsufficientPTGenerated(PTGenerated, minPTGenerated));
    }

    /** REDEEM From PT, SP **/
    /**
     * @dev Redeem SY by burning PT, SP
     * @notice When redeeming from UPT is not required, UPT can be address(0)
     */
    function redeemPSPToSy(
        address SY,
        address PT,
        address UPT,
        address SP,
        address receiver,
        RedeemParam calldata redeemParam,
        bool useSP
    ) external returns (uint256 redeemedSyAmount) {
        redeemedSyAmount = _redeemPSPToSy(PT, UPT, SP, redeemParam, useSP);

        uint256 minRedeemedSyAmount = redeemParam.minRedeemedSyAmount;
        require(redeemedSyAmount >= minRedeemedSyAmount, InsufficientSYRedeemed(redeemedSyAmount, minRedeemedSyAmount));
        
        _transferOut(SY, receiver, redeemedSyAmount);
    }

    /**
     * @dev Redeem native yield token(tokenOut) by burning PT, SP
     * @notice When redeeming from UPT is not required, UPT can be address(0)
     */
    function redeemPSPToToken(
        address SY,
        address PT,
        address UPT,
        address SP,
        address tokenOut,
        address receiver,
        RedeemParam calldata redeemParam,
        bool useSP
    ) external returns (uint256 redeemedSyAmount) {
        redeemedSyAmount = _redeemPSPToSy(PT, UPT, SP, redeemParam, useSP);

        uint256 minRedeemedSyAmount = redeemParam.minRedeemedSyAmount;
        require(redeemedSyAmount >= minRedeemedSyAmount, InsufficientSYRedeemed(redeemedSyAmount, minRedeemedSyAmount));
        
        _redeemSy(SY, receiver, tokenOut, redeemedSyAmount, 0, false);
    }

    function _redeemPSPToSy(
        address PT,
        address UPT,
        address SP,
        RedeemParam calldata redeemParam,
        bool useSP
    ) internal returns (uint256 redeemedSyAmount) {
        uint256 share = redeemParam.positionShare;
        uint256 positionId = redeemParam.positionId;

        if (useSP) {
            _transferFrom(IERC6909(SP), msg.sender, address(this), positionId, share);
        } else {
            if (UPT != address(0)) {
                _transferFrom(IERC20(UPT), msg.sender, address(this), share);
                IUniversalPrincipalToken(UPT).redeemPTFromUPT(PT, address(this), share);
            } else {
                _transferFrom(IERC20(PT), msg.sender, address(this), share);
            }
        }

        redeemedSyAmount = IOutrunStakeManager(SP).redeem(redeemParam.positionId, share, useSP);
    }
}
