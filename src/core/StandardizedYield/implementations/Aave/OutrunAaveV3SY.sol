// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { SYUtils } from "../../../libraries/SYUtils.sol";
import { IAToken } from "../../../../external/aave/IAToken.sol";
import { SYBase, ArrayLib, IERC20Metadata } from "../../SYBase.sol";
import { IAaveV3Pool } from "../../../../external/aave/IAaveV3Pool.sol";
import { AaveAdapterLib } from "../../../../external/aave/libraries/AaveAdapterLib.sol";

contract OutrunAaveV3SY is SYBase {
    address public immutable underlying;
    address public immutable aavePool;

    constructor(
        string memory _name,
        string memory _symbol,
        address _aToken,
        address _aavePool,
        address _owner
    ) SYBase(_name, _symbol, _aToken, _owner) {
        underlying = IAToken(_aToken).UNDERLYING_ASSET_ADDRESS();
        aavePool = _aavePool;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == underlying) {
            _safeApproveInf(underlying, aavePool);
            IAaveV3Pool(aavePool).supply(underlying, amountDeposited, address(this), 0);
        }
        amountSharesOut = AaveAdapterLib.calcSharesFromAssetUp(amountDeposited, _getNormalizedIncome());
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        amountTokenOut = AaveAdapterLib.calcSharesToAssetDown(amountSharesToRedeem, _getNormalizedIncome());
        if (tokenOut == underlying) {
            IAaveV3Pool(aavePool).withdraw(underlying, amountTokenOut, receiver);
        } else {
            _transferOut(yieldBearingToken, receiver, amountTokenOut);
        }
    }

    function exchangeRate() public view virtual override returns (uint256) {
        return _getNormalizedIncome() / 1e9;
    }

    function _previewDeposit(
        address /*tokenIn*/,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        amountSharesOut = AaveAdapterLib.calcSharesFromAssetUp(amountTokenToDeposit, _getNormalizedIncome());
    }

    function _previewRedeem(
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal view override returns (uint256 amountTokenOut) {
        amountTokenOut = SYUtils.syToAsset(exchangeRate(), amountSharesToRedeem);
        AaveAdapterLib.calcSharesToAssetDown(amountSharesToRedeem, _getNormalizedIncome());
    }

    function _getNormalizedIncome() internal view returns (uint256) {
        return IAaveV3Pool(aavePool).getReserveNormalizedIncome(underlying);
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(underlying, yieldBearingToken);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(underlying, yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == underlying || token == yieldBearingToken;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == underlying || token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, underlying, IERC20Metadata(underlying).decimals());
    }
}
