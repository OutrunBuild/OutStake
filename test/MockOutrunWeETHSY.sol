// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMockWeETH } from "./MockWeETH.sol";
import { SYBase, ArrayLib } from "../src/core/StandardizedYield/SYBase.sol";

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockOutrunWeETHSY is SYBase {
    address public immutable MOCK_ETH;

    constructor(
        address _owner,
        address _mockETH,
        address _weETH
    ) SYBase("SY Etherfi weETH", "SY-weETH", _weETH, _owner) {
        MOCK_ETH = _mockETH;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == MOCK_ETH) {
            _safeApproveInf(MOCK_ETH, yieldBearingToken);
            amountSharesOut = IMockWeETH(yieldBearingToken).wrap(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        if (tokenOut == MOCK_ETH) {
            amountTokenOut = IMockWeETH(yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(MOCK_ETH, receiver, amountTokenOut);
        } else {
            amountTokenOut = amountSharesToRedeem;
            _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
        }
    }

    function exchangeRate() public pure override returns (uint256 res) {
        return 1e18;
    }

    function _previewDeposit(
        address /*tokenIn*/,
        uint256 amountTokenToDeposit
    ) internal pure override returns (uint256 amountSharesOut) {
        amountSharesOut = amountTokenToDeposit;
    }

    function _previewRedeem(
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal pure override returns (uint256 amountTokenOut) {
        amountTokenOut = amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(MOCK_ETH, yieldBearingToken);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(MOCK_ETH, yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == MOCK_ETH || token == yieldBearingToken;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == MOCK_ETH || token == yieldBearingToken;
    }

    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
