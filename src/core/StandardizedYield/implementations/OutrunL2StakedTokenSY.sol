// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { SYBase, ArrayLib } from "../SYBase.sol";
import { IExchangeRateOracle } from "../../../oracles/interfaces/IExchangeRateOracle.sol";

contract OutrunL2StakedTokenSY is SYBase {
    address public exchangeRateOracle;
    address internal immutable underlyingAssetOnEthAddr;
    uint8 internal immutable underlyingAssetOnEthDecimals;

    constructor(
        string memory _name,
        string memory _symbol,
        address _owner,
        address _token,
        address _exchangeRateOracle,
        address _underlyingAssetOnEthAddr,
        uint8 _underlyingAssetOnEthDecimals
    ) SYBase(_name, _symbol, _token, _owner) {
        exchangeRateOracle = _exchangeRateOracle;
        underlyingAssetOnEthAddr = _underlyingAssetOnEthAddr;
        underlyingAssetOnEthDecimals = _underlyingAssetOnEthDecimals;
    }

    function setExchangeRateOracle(address newOracle) external onlyOwner {
        exchangeRateOracle = newOracle;
    }

    function _deposit(
        address /*tokenIn*/,
        uint256 amountDeposited
    ) internal pure override returns (uint256 /*amountSharesOut*/) {
        return amountDeposited;
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 /*amountTokenOut*/) {
        _transferOut(tokenOut, receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function exchangeRate() public view override returns (uint256) {
        return IExchangeRateOracle(exchangeRateOracle).getExchangeRate();
    }

    function _previewDeposit(
        address /*tokenIn*/,
        uint256 amountTokenToDeposit
    ) internal pure override returns (uint256 /*amountSharesOut*/) {
        return amountTokenToDeposit;
    }

    function _previewRedeem(
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal pure override returns (uint256 /*amountTokenOut*/) {
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, underlyingAssetOnEthAddr, underlyingAssetOnEthDecimals);
    }
}