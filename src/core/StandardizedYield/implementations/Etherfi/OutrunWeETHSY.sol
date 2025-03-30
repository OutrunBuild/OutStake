// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { IWeETH } from "../../../../external/etherfi/IWeETH.sol";
import { ILiquidityPool } from "../../../../external/etherfi/ILiquidityPool.sol";
import { IDepositAdapter } from "../../../../external/etherfi/IDepositAdapter.sol";

contract OutrunWeETHSY is SYBase {
    address public immutable EETH;
    address public immutable DEPOSIT_ADAPTER;
    address public immutable LIQUIDITY_POOL;

    constructor(
        address _owner,
        address _eETH,
        address _weETH,
        address _depositAdapter,
        address _liquidityPool
    ) SYBase("SY Etherfi weETH", "SY-weETH", _weETH, _owner) {
        EETH = _eETH;
        DEPOSIT_ADAPTER = _depositAdapter;
        LIQUIDITY_POOL = _liquidityPool;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            amountSharesOut = IDepositAdapter(DEPOSIT_ADAPTER).depositETHForWeETH{value: amountDeposited}(address(0));
        } else if (tokenIn == EETH) {
            amountSharesOut = IWeETH(yieldBearingToken).wrap(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        if (tokenOut == EETH) {
            amountTokenOut = IWeETH(yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(EETH, receiver, amountTokenOut);
        } else {
            amountTokenOut = amountSharesToRedeem;
            _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        return ILiquidityPool(LIQUIDITY_POOL).amountForShare(1 ether);
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            uint256 eETHAmount = ILiquidityPool(LIQUIDITY_POOL).amountForShare(ILiquidityPool(LIQUIDITY_POOL).sharesForAmount(amountTokenToDeposit));
            amountSharesOut = ILiquidityPool(LIQUIDITY_POOL).sharesForAmount(eETHAmount);
        } else if (tokenIn == EETH) {
            amountSharesOut = ILiquidityPool(LIQUIDITY_POOL).sharesForAmount(amountTokenToDeposit);
        } else {
            amountSharesOut = amountTokenToDeposit;
        }
    }

    function _previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal view override returns (uint256 amountTokenOut) {
        if (tokenOut == EETH) {
            amountTokenOut = ILiquidityPool(LIQUIDITY_POOL).amountForShare(amountSharesToRedeem);
        } else {
            amountTokenOut = amountSharesToRedeem;
        }
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken, NATIVE);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken, EETH);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == NATIVE;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == EETH;
    }

    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
