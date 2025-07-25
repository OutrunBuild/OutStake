// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { IWstETH } from "../../../../external/lido/IWstETH.sol";
import { IL2StETH } from "../../../../external/lido/IL2StETH.sol";
import { AggregatorInterface } from "../../../../oracles/interfaces/AggregatorInterface.sol";

contract OutrunL2WrappableWstETHSY is SYBase {
    address public immutable STETH;
    AggregatorInterface public immutable TOKEN_RATE_ORACLE;
    address internal immutable underlyingAssetOnEthAddr;
    uint8 internal immutable underlyingAssetOnEthDecimals;
    
    constructor(
        address _owner,
        address _stETH,
        address _wstETH,
        address _tokenRateOracle,
        address _underlyingAssetOnEthAddr,
        uint8 _underlyingAssetOnEthDecimals
    ) SYBase("SY Lido wstETH", "SY wstETH", _wstETH, _owner) {
        STETH = _stETH;
        TOKEN_RATE_ORACLE = AggregatorInterface(_tokenRateOracle);
        underlyingAssetOnEthAddr = _underlyingAssetOnEthAddr;
        underlyingAssetOnEthDecimals = _underlyingAssetOnEthDecimals;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == STETH) {
            amountSharesOut = IL2StETH(STETH).unwrap(amountDeposited);
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        if (tokenOut == STETH) {
            _safeApproveInf(yieldBearingToken, STETH);
            amountTokenOut = IL2StETH(STETH).wrap(amountSharesToRedeem);
        } else {
            _transferOut(yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        return uint256(TOKEN_RATE_ORACLE.latestAnswer());
    }

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        if (tokenIn == STETH) {
            amountSharesOut = IL2StETH(STETH).getSharesByTokens(amountTokenToDeposit);
        } else {
            amountSharesOut = amountTokenToDeposit;
        }
    }

    function _previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal view override returns (uint256 amountTokenOut) {
        if (tokenOut == STETH) {
            amountTokenOut = IL2StETH(STETH).getTokensByShares(amountSharesToRedeem);
        } else {
            amountTokenOut = amountSharesToRedeem;
        }
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(STETH, yieldBearingToken);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(STETH, yieldBearingToken);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == STETH || token == yieldBearingToken;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == STETH || token == yieldBearingToken;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, underlyingAssetOnEthAddr, underlyingAssetOnEthDecimals);
    }
}
