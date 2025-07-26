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

    function _realTimeYieldInfo() internal view returns (uint256 realTimeYield, int256 increasedYield) {
        IOutrunStakeManager syStakeManager = IOutrunStakeManager(SP);
        uint256 exchangeRate = IStandardizedYield(SY).exchangeRate();
        uint256 totalCurrentAssetValue = SYUtils.syToAsset(exchangeRate, syStakeManager.syTotalStaking());
        uint256 totalPrincipalValue = syStakeManager.totalPrincipalValue();

        if (totalCurrentAssetValue > totalPrincipalValue) {
            uint256 yieldInAsset = totalCurrentAssetValue - totalPrincipalValue;
            // Real-time withdrawable yields
            realTimeYield = SYUtils.assetToSy(exchangeRate, yieldInAsset);
            increasedYield = int256(realTimeYield) - int256(yieldBalance);
        }
    }

    /**
     * @dev Total redeemable yields
     */
    function totalRedeemableYields() public view override returns (uint256) {
        (uint256 realTimeYield, int256 increasedYield) = _realTimeYieldInfo();
        if (increasedYield > 0) {
            unchecked {
                uint256 protocolFee = uint256(increasedYield).mulDown(protocolFeeRate);
                realTimeYield -= protocolFee;
            }
        }
        return realTimeYield;
    }

    /**
     * @dev Accumulate yields
     */
    function accumulateYields() public override returns (uint256 realTimeYield, int256 increasedYield) {
        (realTimeYield, increasedYield) = _realTimeYieldInfo();
        
        uint256 protocolFee;
        if (increasedYield > 0) {
            unchecked {
                protocolFee = uint256(increasedYield).mulDown(protocolFeeRate);
                realTimeYield -= protocolFee;
            }
            IOutrunStakeManager(SP).transferYields(revenuePool, protocolFee);
        }
        
        yieldBalance = realTimeYield;

        emit AccumulateYields(realTimeYield, increasedYield, protocolFee);
    }
}
