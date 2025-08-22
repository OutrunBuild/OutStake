// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMockSUSDS } from "./MockSUSDS.sol";
import { ArrayLib } from "../src/core/libraries/ArrayLib.sol";
import { SYBase } from "../src/core/StandardizedYield/SYBase.sol";
import { IExchangeRateOracle } from "../src/oracles/interfaces/IExchangeRateOracle.sol";

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockOutrunSUSDSSY is SYBase {
    address public immutable MOCK_USDC;
    address public ORACLE;

    constructor(
        address _owner,
        address _mockUSDC,
        address _sUSDS,
        address _oracle
    ) SYBase("SY Sky sUSDS", "SY sUSDS", _sUSDS, _owner) {
        MOCK_USDC = _mockUSDC;
        ORACLE = _oracle;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == MOCK_USDC) {
            _safeApproveInf(MOCK_USDC, yieldBearingToken);
            amountSharesOut = IMockSUSDS(yieldBearingToken).wrap(amountDeposited);
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
            amountTokenOut = IMockSUSDS(yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(MOCK_USDC, receiver, amountTokenOut);
        } else {
            amountTokenOut = amountSharesToRedeem;
            _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        return IExchangeRateOracle(ORACLE).getExchangeRate();
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
