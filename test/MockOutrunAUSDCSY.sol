// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMockAUSDC } from "./MockAUSDC.sol";
import { SYBase, ArrayLib } from "../src/core/StandardizedYield/SYBase.sol";

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockOutrunAUSDCSY is SYBase {
    address public immutable MOCK_USDC;

    constructor(
        address _owner,
        address _mockUSDC,
        address _aUSDC
    ) SYBase("SY Aave aUSDC", "SY aUSDC", _aUSDC, _owner) {
        MOCK_USDC = _mockUSDC;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == MOCK_USDC) {
            _safeApproveInf(MOCK_USDC, yieldBearingToken);
            amountSharesOut = IMockAUSDC(yieldBearingToken).wrap(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        if (tokenOut == MOCK_USDC) {
            amountTokenOut = IMockAUSDC(yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(MOCK_USDC, receiver, amountTokenOut);
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
        return ArrayLib.create(MOCK_USDC, yieldBearingToken);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(MOCK_USDC, yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == MOCK_USDC || token == yieldBearingToken;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == MOCK_USDC || token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, MOCK_USDC, 18);
    }
}
