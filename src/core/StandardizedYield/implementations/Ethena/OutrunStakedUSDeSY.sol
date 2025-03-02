// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { SYBase, ArrayLib } from "../../SYBase.sol";

contract OutrunStakedUSDeSY is SYBase {
    address public immutable USDE;

    constructor(
        address _owner,
        address _USDe,
        address _sUSDe
    ) SYBase("SY Ethena sUSDe", "SY-sUSDe", _sUSDe, _owner) {
        USDE = _USDe;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == USDE) {
            amountSharesOut = IERC4626(yieldBearingToken).deposit(amountDeposited, address(this));
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
        return IERC4626(yieldBearingToken).convertToAssets(1 ether);
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == USDE) {
            amountSharesOut = IERC4626(yieldBearingToken).previewDeposit(amountTokenToDeposit);
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
        return ArrayLib.create(yieldBearingToken, USDE);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == USDE;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, USDE, 18);
    }
}
