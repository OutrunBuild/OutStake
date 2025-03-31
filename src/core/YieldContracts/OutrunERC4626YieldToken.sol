// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Math } from "../libraries/Math.sol";
import { SYUtils } from "../libraries/SYUtils.sol";
import { OutrunYieldToken } from "./OutrunYieldToken.sol";
import { IYieldManager } from "./interfaces/IYieldManager.sol";
import { ReentrancyGuard } from "../libraries/ReentrancyGuard.sol";
import { IStandardizedYield } from "../StandardizedYield/IStandardizedYield.sol";
import { IOutrunStakeManager } from "../Position/interfaces/IOutrunStakeManager.sol";

/**
 * With YT yielding more SYs overtime, which is allowed to be redeemed by users, the yields distribution
 * should be based on the amount of SYs that their YT currently represent
 */
contract OutrunERC4626YieldToken is IYieldManager, OutrunYieldToken, ReentrancyGuard {
    using Math for uint256;

    address public revenuePool;
    uint256 public protocolFeeRate;
    uint256 public yieldBalance;        // Withdrawable yields balance
    uint256 public withdrawedYields;    // Cumulatively withdrawn yields
    RecentAccumulatedInfo[2] public recentTwoAccumulatedInfos;   // Recent accumulated yields information.

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner_,
        address revenuePool_,
        uint256 protocolFeeRate_
    ) OutrunYieldToken(name_, symbol_, decimals_) Ownable(owner_) {
        revenuePool = revenuePool_;
        protocolFeeRate = protocolFeeRate_;

        uint64 currentTime = uint64(block.timestamp);
        recentTwoAccumulatedInfos[0].latestAccumulateTime = currentTime;
        recentTwoAccumulatedInfos[1].latestAccumulateTime = currentTime;
    }

    function _realTimeYieldInfo() internal view returns (uint256 realTimeYield, uint256 increasedYield) {
        IOutrunStakeManager syStakeManager = IOutrunStakeManager(SP);
        uint256 exchangeRate = IStandardizedYield(SY).exchangeRate();
        uint256 totalCurrentAssetValue = SYUtils.syToAsset(exchangeRate, syStakeManager.syTotalStaking());
        uint256 totalPrincipalValue = syStakeManager.totalPrincipalValue();

        if (totalCurrentAssetValue > totalPrincipalValue) {
            uint256 yieldInAsset = totalCurrentAssetValue - totalPrincipalValue;
            // Real-time withdrawable yields
            realTimeYield = SYUtils.assetToSy(exchangeRate, yieldInAsset);
            if (realTimeYield > yieldBalance) {
                increasedYield = realTimeYield - yieldBalance;
            }
        }
    }

    /**
     * @dev Total redeemable yields
     */
    function totalRedeemableYields() public view override returns (uint256) {
        (uint256 realTimeYield, uint256 increasedYield) = _realTimeYieldInfo();
        if (increasedYield > 0) {
            unchecked {
                uint256 protocolFee = increasedYield.mulDown(protocolFeeRate);
                realTimeYield -= protocolFee;
            }
        }
        return realTimeYield;
    }

    /**
     * @dev Total historical accumulated yields
     */
    function totalAccumulatedYields() external view override returns (uint256) {
        (uint256 realTimeYield, uint256 increasedYield) = _realTimeYieldInfo();
        if (increasedYield > 0) {
            unchecked {
                uint256 protocolFee = increasedYield.mulDown(protocolFeeRate);
                realTimeYield -= protocolFee;
            }
        }

        return realTimeYield + withdrawedYields;
    }

    /**
     * @dev Preview available yields
     * @param amountInBurnedYT - The amount of burned YT
     */
    function previewWithdrawYields(uint256 amountInBurnedYT) public view override returns (uint256 amountYieldsOut) {
        uint256 _totalSupply = totalSupply();
        require(amountInBurnedYT <= _totalSupply && _totalSupply > 0, InvalidInput());
        amountYieldsOut = amountInBurnedYT * totalRedeemableYields() / _totalSupply;
    }
    /**
     * @dev Accumulate yields
     */
    function accumulateYields() public override returns (uint256 increasedYield) {
        uint256 realTimeYield;
        (realTimeYield, increasedYield) = _realTimeYieldInfo();
        if (increasedYield > 0) {
            uint256 protocolFee;
            unchecked {
                protocolFee = increasedYield.mulDown(protocolFeeRate);
                realTimeYield -= protocolFee;
            }
            yieldBalance = realTimeYield;

            RecentAccumulatedInfo storage index0 = recentTwoAccumulatedInfos[0];
            RecentAccumulatedInfo storage index1 = recentTwoAccumulatedInfos[1];
            uint256 time0 = index0.latestAccumulateTime;
            uint256 time1 = index1.latestAccumulateTime;
            if (block.timestamp > time0 + 24 * 3600 && block.timestamp > time1 + 24 * 3600) {
                uint64 currentTime = uint64(block.timestamp);
                uint192 totalAccumulated = uint192(realTimeYield + withdrawedYields);
                if (time0 < time1) {
                    index0.latestAccumulateTime = currentTime;
                    index0.accumulatedYields = totalAccumulated;
                } else {
                    index1.latestAccumulateTime = currentTime;
                    index1.accumulatedYields = totalAccumulated;
                }
            }

            IOutrunStakeManager(SP).transferYields(revenuePool, protocolFee);

            emit AccumulateYields(increasedYield, protocolFee);
        }
    }

    /**
     * @dev Burn YT to withdraw yields
     * @param amountInBurnedYT - The amount of burned YT
     */
    function withdrawYields(uint256 amountInBurnedYT) external override nonReentrant whenNotPaused returns (uint256 amountYieldsOut) {
        require(amountInBurnedYT != 0, ZeroInput());
        uint256 _totalSupply = totalSupply();
        require(amountInBurnedYT <= _totalSupply && _totalSupply > 0, InvalidInput());
        accumulateYields();

        unchecked {
            amountYieldsOut = yieldBalance * amountInBurnedYT / _totalSupply;
            yieldBalance -= amountYieldsOut;
            withdrawedYields += amountYieldsOut;
        }

        address msgSender = msg.sender;
        _burn(msgSender, amountInBurnedYT);
        IOutrunStakeManager(SP).transferYields(msgSender, amountYieldsOut);

        emit WithdrawYields(msgSender, amountYieldsOut);
    }

    /**
     * @param _revenuePool - Address of revenue pool
     */
    function setRevenuePool(address _revenuePool) public override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());

        revenuePool = _revenuePool;
        emit SetRevenuePool(_revenuePool);
    }

    /**
     * @param _protocolFeeRate - Protocol fee rate
     */
    function setProtocolFeeRate(uint256 _protocolFeeRate) public override onlyOwner {
        require(_protocolFeeRate <= 1e18, FeeRateOverflow());

        protocolFeeRate = _protocolFeeRate;
        emit SetProtocolFeeRate(_protocolFeeRate);
    }
}
