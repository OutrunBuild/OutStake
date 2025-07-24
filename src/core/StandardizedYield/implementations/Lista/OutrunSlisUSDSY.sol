// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { ISlisUSD } from "../../../../external/lista/ISlisUSD.sol";

contract OutrunSlisUSDSY is SYBase {
    address public immutable LISUSD;

    constructor(
        address _owner,
        address _lisUSD,
        address _slisUSD
    ) SYBase("SY Lista slisUSD", "SY slisUSD", _slisUSD, _owner) {
        LISUSD = _lisUSD;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == LISUSD) {
            ISlisUSD(yieldBearingToken).deposit(amountDeposited);
            amountSharesOut = ISlisUSD(yieldBearingToken).convertToShares(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256) {
        _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function exchangeRate() public view override returns (uint256 res) {
        return ISlisUSD(yieldBearingToken).convertToAssets(1 ether);
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == LISUSD) {
            amountSharesOut = ISlisUSD(yieldBearingToken).convertToShares(amountTokenToDeposit);
        } else {
            amountSharesOut = amountTokenToDeposit;
        }
    }

    function _previewRedeem(
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal pure override returns (uint256 /*amountTokenOut*/) {
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken, LISUSD);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == LISUSD;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, LISUSD, 18);
    }
}
