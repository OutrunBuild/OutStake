// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { SYBase, ArrayLib } from "../../SYBase.sol";
import { IWETH } from "../../../../external/IWETH.sol";
import { SYUtils } from "../../../libraries/SYUtils.sol";
import { IERC20Rebasing } from "../../../../external/blast/IERC20Rebasing.sol";
import { BlastGovernorable } from "../../../../external/blast/BlastGovernorable.sol";

contract OutrunBlastETHSY is SYBase, BlastGovernorable {
    address public immutable WETH;

    uint256 public totalAssets;

    constructor(
        address _WETH,
        address _owner,
        address _blastGovernor
    ) SYBase("SY Blast ETH", "SY-BETH", _WETH, _owner) BlastGovernorable(_blastGovernor) {
        WETH = _WETH;
    }

    function _deposit(
        address tokenIn,
        uint256 amountDeposited
    ) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) IWETH(WETH).deposit{value: amountDeposited}();
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
        uint256 claimableYields = IERC20Rebasing(WETH).getClaimableAmount(address(this));
        uint256 _totalAssets = totalAssets;
        if (claimableYields > 0) {
            IERC20Rebasing(WETH).claim(address(this), claimableYields);
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
        
        if (tokenOut == NATIVE) IWETH(WETH).withdraw(amountTokenOut);
        _transferOut(tokenOut, receiver, amountTokenOut);
    }

    function exchangeRate() public view override returns (uint256 res) {
        uint256 _totalAssets = totalAssets + IERC20Rebasing(WETH).getClaimableAmount(address(this));
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
        return ArrayLib.create(WETH, NATIVE);
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(WETH, NATIVE);
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == WETH || token == NATIVE;
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == WETH || token == NATIVE;
    }

    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
