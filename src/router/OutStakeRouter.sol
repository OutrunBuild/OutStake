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

    /** MINT PT(UPT), YT, PYT **/
    /**
     * @dev Mint PT(UPT), YT, PYT from yield-Bearing token
     * @notice When minting UPT is not required, mintUPTParam can be empty
     */
    function mintPYFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) external payable returns (uint256 PTGenerated, uint256 YTGenerated) {
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, 0, true);

        _safeApproveInf(SY, SP);
        (PTGenerated, YTGenerated) = _mintPYFromSY(
            SP,
            amountInSY, 
            stakeParam
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
        StakeParam calldata stakeParam
    ) external returns (uint256 PTGenerated, uint256 YTGenerated) {
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);

        _safeApproveInf(SY, SP);
        (PTGenerated, YTGenerated) = _mintPYFromSY(
            SP,
            amountInSY, 
            stakeParam
        );
    }

    function _mintPYFromSY(
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) internal returns (uint256 PTGenerated, uint256 YTGenerated) {
        (PTGenerated, YTGenerated) = IOutrunStakeManager(SP).stake(
            amountInSY, 
            stakeParam.lockupDays,
            stakeParam.PTRecipient,
            stakeParam.YTRecipient, 
            stakeParam.PYTRecipient,
            stakeParam.positionOwner,
            stakeParam.outputUPT
        );

        uint256 minPTGenerated = stakeParam.minPTGenerated;
        require(PTGenerated >= minPTGenerated, InsufficientPTGenerated(PTGenerated, minPTGenerated));
    }
}
