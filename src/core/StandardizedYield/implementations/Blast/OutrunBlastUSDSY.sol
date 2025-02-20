// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { SYUtils } from "../../../libraries/SYUtils.sol";
import { IERC20Rebasing } from "../../../../external/blast/IERC20Rebasing.sol";
import { BlastGovernorable } from "../../../../external/blast/BlastGovernorable.sol";

contract OutrunBlastUSDSY is SYBase, BlastGovernorable {
    address public immutable USDB;

    uint256 public totalAssets;

    constructor(
        address _USDB,
        address _owner,
        address _blastGovernor
    ) SYBase("SY Blast USD", "SY-USDB", _USDB, _owner) BlastGovernorable(_blastGovernor) {
        USDB = _USDB;
    }

    function _deposit(
        address /*tokenIn*/,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        amountSharesOut = SYUtils.assetToSy(exchangeRate(), amountDeposited);
        unchecked {
            totalAssets += amountDeposited;
        }
    }

    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal override returns (uint256 amountTokenOut) {
        uint256 claimableYields = IERC20Rebasing(USDB).getClaimableAmount(address(this));
        uint256 _totalAssets = totalAssets;
        if (claimableYields > 0) {
            IERC20Rebasing(USDB).claim(address(this), claimableYields);
            unchecked {
                _totalAssets += claimableYields;
            }
        }

        _totalAssets = _totalAssets == 0 ? 1 : _totalAssets;
        uint256 totalShares = totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares; 

        unchecked {
            amountTokenOut = amountSharesToRedeem * totalAssets / totalShares;
            totalAssets = _totalAssets - amountTokenOut;
        }
        
        _transferOut(tokenOut, receiver, amountTokenOut);
    }

    function exchangeRate() public view override returns (uint256 res) {
        uint256 _totalAssets = totalAssets + IERC20Rebasing(USDB).getClaimableAmount(address(this));
        _totalAssets = _totalAssets == 0 ? 1 : _totalAssets; 

        uint256 totalShares = totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;
 
        res = (1e18 * _totalAssets) / totalShares;
    }

    function _previewDeposit(
        address /*tokenIn*/,
        uint256 amountTokenToDeposit
    ) internal view override returns (uint256 amountSharesOut) {
        amountSharesOut = SYUtils.assetToSy(exchangeRate(), amountTokenToDeposit);
    }

    function _previewRedeem(
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal view override returns (uint256 amountTokenOut) {
        amountTokenOut = SYUtils.syToAsset(exchangeRate(), amountSharesToRedeem);
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(USDB);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(USDB);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == USDB;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == USDB;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, USDB, 18);
    }
}
