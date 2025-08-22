// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IStETH } from "../../../../external/lido/IStETH.sol";
import { IWstETH } from "../../../../external/lido/IWstETH.sol";
import { ArrayLib } from "../../../libraries/ArrayLib.sol";
import { SYBase, IERC20Metadata } from "../../SYBase.sol";

contract OutrunWstETHSY is SYBase {
    address public immutable STETH;

    constructor(
        address _owner,
        address _stETH,
        address _wstETH
    ) SYBase("SY Lido wstETH", "SY wstETH", _wstETH, _owner) {
        STETH = _stETH;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            uint256 stETHShareAmount = IStETH(STETH).submit{value: amountDeposited}();
            _safeApproveInf(STETH, yieldBearingToken);
            amountSharesOut = IWstETH(yieldBearingToken).wrap(IStETH(STETH).getPooledEthByShares(stETHShareAmount));
        } else if (tokenIn == STETH) {
            _safeApproveInf(STETH, yieldBearingToken);
            amountSharesOut = IWstETH(yieldBearingToken).wrap(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        if (tokenOut == STETH) {
            amountTokenOut = IWstETH(yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(STETH, receiver, amountTokenOut);
        } else {
            _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        return IWstETH(yieldBearingToken).stEthPerToken();
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE || tokenIn == STETH) {
            amountSharesOut = IStETH(STETH).getSharesByPooledEth(amountTokenToDeposit);
        } else {
            amountSharesOut = amountTokenToDeposit;
        }
    }

    function _previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal view override returns (uint256 amountTokenOut) {
        if (tokenOut == STETH) {
            amountTokenOut = IStETH(STETH).getPooledEthByShares(amountSharesToRedeem);
        } else {
            amountTokenOut = amountSharesToRedeem;
        }
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken, NATIVE, STETH);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken, STETH);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == NATIVE || token == STETH;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == STETH;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, STETH, IERC20Metadata(STETH).decimals());
    }
}
