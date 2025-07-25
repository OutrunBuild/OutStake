// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { IPSM3 } from "../../../../external/sky/IPSM3.sol";

contract OutrunL2StakedUsdsSY is SYBase {
    address public immutable USDC;
    address public immutable USDS;
    address public immutable PSM3;

    constructor(
        address _owner,
        address _USDC,
        address _USDS,
        address _sUSDS,
        address _PSM3
    ) SYBase("SY Sky sUSDS", "SY sUSDS", _sUSDS, _owner) {
        USDC = _USDC;
        USDS = _USDS;
        PSM3 = _PSM3;

        _safeApproveInf(_USDC, _PSM3);
        _safeApproveInf(_USDS, _PSM3);
        _safeApproveInf(_sUSDS, _PSM3);
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == yieldBearingToken) {
            amountSharesOut = amountDeposited;
        } else {
            amountSharesOut = IPSM3(PSM3).swapExactIn(tokenIn, yieldBearingToken, amountDeposited, 0, address(this), 0);
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        if (tokenOut == yieldBearingToken) {
            _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        } else {
            amountTokenOut = IPSM3(PSM3).swapExactIn(yieldBearingToken, tokenOut, amountSharesToRedeem, 0, receiver, 0);
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        return IPSM3(PSM3).previewSwapExactIn(yieldBearingToken, USDS, 1 ether);
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == yieldBearingToken) {
            amountSharesOut = amountTokenToDeposit;
        } else {
            amountSharesOut = IPSM3(PSM3).previewSwapExactIn(tokenIn, yieldBearingToken, amountTokenToDeposit);
        }
    }

    function _previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal view override returns (uint256 amountTokenOut) {
        if (tokenOut == yieldBearingToken) {
            amountTokenOut = amountSharesToRedeem;
        } else {
            amountTokenOut = IPSM3(PSM3).previewSwapExactIn(yieldBearingToken, tokenOut, amountSharesToRedeem);
        }
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(USDC, USDS, yieldBearingToken);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(USDC, USDS, yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == USDC || token == USDS || token == yieldBearingToken;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == USDC || token == USDS || token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, USDS, 18);
    }
}
