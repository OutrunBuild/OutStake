// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { ISlisBNBProvider } from "../../../../external/lista/ISlisBNBProvider.sol";
import { IListaBNBStakeManager } from "../../../../external/lista/IListaBNBStakeManager.sol";

contract OutrunSlisBNBSY is SYBase {
    IListaBNBStakeManager public immutable listaBNBStakeManager;
    ISlisBNBProvider public immutable slisBNBProvider;
    address public delegateTo;

    event UpdateDelegateTo(address oldDelegateTo, address newDelegateTo);

    constructor(
        address _owner,
        address _slisBNB,
        address _delegateTo,
        IListaBNBStakeManager _stakeManager,
        ISlisBNBProvider _slisBNBProvider
    ) SYBase("SY Lista slisBNB", "SY-slisBNB", _slisBNB, _owner) {
        delegateTo = _delegateTo;
        listaBNBStakeManager = _stakeManager;
        slisBNBProvider = _slisBNBProvider;
    }

    function updateDelegateTo(address _delegateTo) external onlyOwner {
        uint256 _totalSupply = totalSupply();
        slisBNBProvider.release(address(this), _totalSupply);
        slisBNBProvider.provide(_totalSupply, _delegateTo);

        address oldDelegateTo = delegateTo;
        delegateTo = _delegateTo;

        emit UpdateDelegateTo(oldDelegateTo, _delegateTo);
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            listaBNBStakeManager.deposit{value: amountDeposited}();
            amountSharesOut = listaBNBStakeManager.convertBnbToSnBnb(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }

        slisBNBProvider.provide(amountSharesOut, delegateTo);
    }

    function _redeem(
        address receiver,
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256) {
        slisBNBProvider.release(receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function exchangeRate() public view override returns (uint256 res) {
        return listaBNBStakeManager.convertSnBnbToBnb(1 ether);
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            amountSharesOut = listaBNBStakeManager.convertBnbToSnBnb(amountTokenToDeposit);
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
        return ArrayLib.create(yieldBearingToken, NATIVE);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken || token == NATIVE;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken;
    }

    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
