// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { IMETHStaking } from "../../../../external/mantle/IMETHStaking.sol";
import { ICmETHTeller, ERC20 } from "../../../../external/mantle/ICmETHTeller.sol";

contract OutrunMethSY is SYBase {
    address public immutable METH;
    address public immutable VAULT;

    constructor(
        address _owner,
        address _mETH,
        address _cmETH,
        address _vault
    ) SYBase("SY Mantle cmETH", "SY cmETH", _cmETH, _owner) {
        METH = _mETH;
        VAULT = _vault;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            amountSharesOut = ICmETHTeller(yieldBearingToken).deposit{value: amountDeposited}(ERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), amountDeposited, 0);
        } else if (tokenIn == METH) {
            _safeApproveInf(METH, VAULT);
            amountSharesOut = ICmETHTeller(yieldBearingToken).deposit(ERC20(METH), amountDeposited, 0);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 /*amountTokenOut*/) {
        _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function exchangeRate() public view override returns (uint256 res) {
        return IMETHStaking(METH).mETHToETH(1 ether);
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            amountSharesOut = IMETHStaking(METH).ethToMETH(amountTokenToDeposit);
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
        return ArrayLib.create(yieldBearingToken, NATIVE, METH);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == NATIVE || token == METH;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken;
    }

    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
