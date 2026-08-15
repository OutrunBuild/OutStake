// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IListaStakeManager} from "../../../integrations/lista/interfaces/IListaStakeManager.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";

/// @title Outrun Lista slisBNB SY adapter
/// @notice SY adapter for Lista slisBNB (BSC). The yield-bearing token is slisBNB. Deposit path: native BNB →
///      deposit into Lista StakeManager to receive slisBNB. Exchange rate from StakeManager.convertSnBnbToBnb.
contract OutrunSlisBNBSYUpgradeable layout at erc7201("outrun.storage.OutrunSlisBNBSY") is SYBaseUpgradeable {
    struct OutrunSlisBNBSYStorage {
        address STAKE_MANAGER;
    }
    OutrunSlisBNBSYStorage private outrunSlisBNBSYStorage;

    error InvalidStakeManager();
    error StakeManagerDepositZero();

    // Validates that 1 slisBNB > 1 BNB (i.e., the exchange rate is above parity —
    // slisBNB should always be worth more than BNB due to staking yield).
    function initialize(address owner_, address slisBNB_, address stakeManager_) external initializer {
        if (slisBNB_ == address(0) || stakeManager_ == address(0)) revert SYZeroAddress();
        if (IListaStakeManager(stakeManager_).convertSnBnbToBnb(1 ether) < 1 ether) revert InvalidStakeManager();
        __SYBase_init("SY Lista slisBNB", "SY slisBNB", slisBNB_, owner_);
        outrunSlisBNBSYStorage.STAKE_MANAGER = stakeManager_;
    }

    function STAKE_MANAGER() public view returns (address) {
        return outrunSlisBNBSYStorage.STAKE_MANAGER;
    }

    // Deposit BNB into Lista StakeManager and measure received slisBNB by balance difference.
    // Using balance diff rather than return value because the StakeManager's deposit() doesn't return the amount.
    // slither-disable-next-line reentrancy-eth,reentrancy-balance
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            address _yieldBearingToken = yieldBearingToken();
            uint256 beforeBalance = _selfBalance(_yieldBearingToken);
            IListaStakeManager(STAKE_MANAGER()).deposit{value: amountDeposited}();
            uint256 afterBalance = _selfBalance(_yieldBearingToken);
            amountSharesOut = afterBalance - beforeBalance;
            // slither-disable-next-line incorrect-equality
            if (amountSharesOut == 0) revert StakeManagerDepositZero();
            return amountSharesOut;
        }
        return amountDeposited;
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        // This adapter only redeems to slisBNB itself; unstaking back to BNB is handled outside this SY.
        amountTokenOut = amountSharesToRedeem;
        _transferOut(tokenOut, receiver, amountTokenOut);
    }

    // convertSnBnbToBnb(1 ether) returns how much BNB 1 slisBNB is worth, scaled by 1e18.
    function exchangeRate() public view override returns (uint256 res) {
        return IListaStakeManager(STAKE_MANAGER()).convertSnBnbToBnb(1 ether);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // Native BNB preview uses Lista's conversion quote; existing slisBNB deposits are 1:1.
        if (tokenIn == NATIVE) return IListaStakeManager(STAKE_MANAGER()).convertBnbToSnBnb(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(NATIVE, yieldBearingToken());
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == NATIVE || token == yieldBearingToken();
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @notice Returns asset metadata: canonical asset is native BNB (NATIVE = address(0) sentinel).
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress NATIVE sentinel (address(0)) — canonical asset is native BNB
    /// @return assetDecimals always 18
    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
