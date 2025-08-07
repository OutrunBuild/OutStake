// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunMath } from "../libraries/OutrunMath.sol";
import { SYUtils } from "../libraries/SYUtils.sol";
import { OutrunYieldToken, IOutrunStakeManager } from "./OutrunYieldToken.sol";
import { IStandardizedYield } from "../StandardizedYield/IStandardizedYield.sol";

/**
 * With YT yielding more SYs overtime, which is allowed to be redeemed by users, the yields distribution
 * should be based on the amount of SYs that their YT currently represent
 */
contract OutrunERC4626YieldToken is OutrunYieldToken {
    using OutrunMath for uint256;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner_,
        address revenuePool_,
        uint256 protocolFeeRate_
    ) OutrunYieldToken(name_, symbol_, decimals_, revenuePool_, protocolFeeRate_) Ownable(owner_) {}

    function _realTimeYieldInfo() internal view returns (int256 realTimeYield, int256 increasedYield) {
        IOutrunStakeManager syStakeManager = IOutrunStakeManager(SP);
        uint256 exchangeRate = IStandardizedYield(SY).exchangeRate();
        int256 totalCurrentAssetValue = int256(SYUtils.syToAsset(exchangeRate, syStakeManager.syTotalStaking()));
        int256 totalPrincipalValue = int256(syStakeManager.totalPrincipalValue());

        int256 yieldInAsset = totalCurrentAssetValue - totalPrincipalValue;
        bool isPositive = yieldInAsset > 0;
        uint256 realTimeYieldAbs = SYUtils.assetToSy(exchangeRate, uint256(isPositive ? yieldInAsset : -yieldInAsset));
        realTimeYield = isPositive ? int256(realTimeYieldAbs) : -int256(realTimeYieldAbs);
        increasedYield = realTimeYield - yieldBalance;
    }

    /**
     * @dev Total redeemable yields
     * @return realTimeYield - The real-time accumulated yield
     */
    function totalRedeemableYields() public view override returns (int256) {
        (int256 realTimeYield, int256 increasedYield) = _realTimeYieldInfo();
        if (increasedYield > 0) {
            unchecked {
                int256 protocolFee = int256(uint256(increasedYield).mulDown(protocolFeeRate));
                realTimeYield -= protocolFee;
            }
        }
        return realTimeYield;
    }

    /**
     * @dev Accumulate yields
     * @return realTimeYield - The real-time accumulated yield
     * @return increasedYield - The increased yield
     */
    function accumulateYields() public override returns (int256 realTimeYield, int256 increasedYield) {
        (realTimeYield, increasedYield) = _realTimeYieldInfo();
        
        uint256 protocolFee;
        if (increasedYield > 0) {
            unchecked {
                protocolFee = uint256(increasedYield).mulDown(protocolFeeRate);
                realTimeYield -= int256(protocolFee);
            }
            IOutrunStakeManager(SP).transferYields(revenuePool, protocolFee);
        }
        
        if (realTimeYield < 0 && realTimeYield != yieldBalance) {
            IOutrunStakeManager(SP).updateNegativeYields(uint256(-realTimeYield));
        } else if (yieldBalance < 0 && realTimeYield >= 0) {
            IOutrunStakeManager(SP).updateNegativeYields(0);
        }

        yieldBalance = realTimeYield;

        emit AccumulateYields(realTimeYield, increasedYield, protocolFee);
    }
}
