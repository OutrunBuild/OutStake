// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

// OutrunTODO Delete the Ownable when the mainnet goes live
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IOutrunRouter } from "./interfaces/IOutrunRouter.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IYieldToken } from "../core/YieldContracts/interfaces/IYieldToken.sol";
import { IStandardizedYield } from "../core/StandardizedYield/IStandardizedYield.sol";
import { TokenHelper, IERC20, IOutrunERC6909 } from "../core/libraries/TokenHelper.sol";
import { IOutrunStakeManager } from "../core/Position/interfaces/IOutrunStakeManager.sol";

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

    /** Preview mint SP, UPT, YT **/
    /**
     * @dev Preview mint yield tokens(SP, UPT, YT) from yield-Bearing token
     */
    function previewMintYieldTokensFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) external view override returns (uint256 SPMintable, uint256 YTMintable, uint256 UPTMintable) {
        uint256 amountInSY = IStandardizedYield(SY).previewDeposit(tokenIn, tokenAmount);

        (SPMintable, YTMintable, UPTMintable) = IOutrunStakeManager(SP).previewStake(
            amountInSY, 
            stakeParam.lockupDays,
            stakeParam.isSPSeparated
        );
    }

    /**
     * @dev Preview mint yield tokens(SP, UPT, YT) from SY
     */
    function previewMintYieldTokensFromSY(
        address SP,
        uint256 amountInSY,
        StakeParam calldata stakeParam
    ) external view override returns (uint256 SPMintable, uint256 YTMintable, uint256 UPTMintable) {
        (SPMintable, YTMintable, UPTMintable) = IOutrunStakeManager(SP).previewStake(
            amountInSY, 
            stakeParam.lockupDays,
            stakeParam.isSPSeparated
        );
    }

    /** MINT SP, UPT, YT **/
    /**
     * @dev Mint yield tokens(SP, UPT, YT) from yield-Bearing token
     */
    function mintYieldTokensFromToken(
        address SY,
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        StakeParam calldata stakeParam
    ) public payable override returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted, uint256 UPTMinted) {
        uint128 amountInSY = uint128(_mintSY(SY, tokenIn, address(this), tokenAmount, 0, true));

        _safeApproveInf(SY, SP);
        (positionId, SPMinted, YTMinted, UPTMinted) = _mintYieldTokensFromSY(
            SP,
            amountInSY, 
            stakeParam
        );
    }

    /**
     * @dev Mint yield tokens(SP, UPT, YT) by staking SY
     */
    function mintYieldTokensFromSY(
        address SY,
        address SP,
        uint128 amountInSY,
        StakeParam calldata stakeParam
    ) public override returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted, uint256 UPTMinted) {
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);

        _safeApproveInf(SY, SP);
        (positionId, SPMinted, YTMinted, UPTMinted) = _mintYieldTokensFromSY(
            SP,
            amountInSY, 
            stakeParam
        );
    }

    function _mintYieldTokensFromSY(
        address SP,
        uint128 amountInSY,
        StakeParam calldata stakeParam
    ) internal returns (uint256 positionId, uint256 SPMinted, uint256 YTMinted, uint256 UPTMinted) {
        (positionId, SPMinted, YTMinted) = IOutrunStakeManager(SP).stake(
            amountInSY, 
            stakeParam.lockupDays,
            address(this), 
            stakeParam.initOwner
        );

        uint256 minSPMinted = stakeParam.minSPMinted;
        require(SPMinted >= minSPMinted, InsufficientSPMinted(SPMinted, minSPMinted));

        if(stakeParam.isSPSeparated) {
            UPTMinted = IOutrunStakeManager(SP).separateUPT(positionId, uint128(SPMinted), stakeParam.initOwner, stakeParam.initOwner);
        } else {
            IOutrunERC6909(SP).transfer(stakeParam.initOwner, positionId, SPMinted);
        }
    }

    /** Redeem YT value **/
    function redeemValueFromYT(
        address SY,
        address YT,
        address tokenOut,
        uint256 YTAmount
    ) external override returns (uint256 amountYieldsOut) {
        amountYieldsOut = _redeemSy(SY, msg.sender, tokenOut, IYieldToken(YT).withdrawYields(YTAmount), 0, true);
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
        require(
            stakeParam.isSPSeparated && 
            stakeParam.initOwner == msg.sender && 
            stakeParam.lockupDays == 0,
            InvalidParam()
        );

        (, , , uint256 amountInUPT) = mintYieldTokensFromToken(SY, SP, tokenIn, tokenAmount, stakeParam);
        _safeApproveInf(UPT, memeverseLauncher);
        IMemeverseLauncher(memeverseLauncher).genesis(verseId, amountInUPT, genesisUser);
    }

    function genesisBySY(
        address SY,
        address SP,
        address UPT,
        uint128 amountInSY,
        uint256 verseId,
        address genesisUser,
        StakeParam calldata stakeParam
    ) external {
        require(
            stakeParam.isSPSeparated && 
            stakeParam.initOwner == msg.sender && 
            stakeParam.lockupDays == 0,
            InvalidParam()
        );

        (, , , uint256 amountInUPT) = mintYieldTokensFromSY(SY, SP, amountInSY, stakeParam);
        _safeApproveInf(UPT, memeverseLauncher);
        IMemeverseLauncher(memeverseLauncher).genesis(verseId, amountInUPT, genesisUser);
    }

    // OutrunTODO Delete this function when the mainnet goes live
    function setMemeverseLauncher(address _memeverseLauncher) external override onlyOwner {
        memeverseLauncher = _memeverseLauncher;
    }
}
