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
        address stakeManager;
    }
    OutrunSlisBNBSYStorage private outrunSlisBNBSYStorage;

    error InvalidStakeManager();
    error StakeManagerDepositZero();

    // Validates that 1 slisBNB >= 1 BNB (i.e., the exchange rate is at least parity — equality passes).
    // Staking yield is expected to keep slisBNB worth more than BNB; only a below-parity rate reverts.
    /// @notice Initializes the SY adapter for Lista slisBNB.
    /// @param owner_ The contract owner address.
    /// @param slisBNB_ Address of the slisBNB yield-bearing token.
    /// @param stakeManager_ Address of the Lista StakeManager contract.
    /// @dev Reverts with SYZeroAddress if slisBNB_ or stakeManager_ is the zero address, or with
    ///      InvalidStakeManager if 1 slisBNB is worth less than 1 BNB (below-parity rate).
    function initialize(address owner_, address slisBNB_, address stakeManager_) external initializer {
        if (slisBNB_ == address(0) || stakeManager_ == address(0)) revert SYZeroAddress();
        if (IListaStakeManager(stakeManager_).convertSnBnbToBnb(1 ether) < 1 ether) revert InvalidStakeManager();
        __SYBase_init("SY Lista slisBNB", "SY slisBNB", slisBNB_, owner_);
        outrunSlisBNBSYStorage.stakeManager = stakeManager_;
    }

    /// @notice Returns the Lista StakeManager contract address.
    /// @return The StakeManager address.
    function stakeManager() public view returns (address) {
        return outrunSlisBNBSYStorage.stakeManager;
    }

    // Deposit BNB into Lista StakeManager and measure received slisBNB by balance difference.
    // Using balance diff rather than return value because the StakeManager's deposit() doesn't return the amount.
    // slither-disable-next-line reentrancy-eth,reentrancy-balance
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            address _yieldBearingToken = yieldBearingToken();
            uint256 beforeBalance = _selfBalance(_yieldBearingToken);
            IListaStakeManager(stakeManager()).deposit{value: amountDeposited}();
            uint256 afterBalance = _selfBalance(_yieldBearingToken);
            amountSharesOut = afterBalance - beforeBalance;
            // Zero-received guard on our own balance diff around one external call: the equality flags the
            // degenerate no-mint outcome, not an attacker-forced state decision.
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
    /// @notice Returns the current exchange rate: BNB per 1 slisBNB, scaled by 1e18.
    /// @return res StakeManager.convertSnBnbToBnb(1 ether), which grows as Lista staking yield accrues.
    function exchangeRate() public view override returns (uint256 res) {
        return IListaStakeManager(stakeManager()).convertSnBnbToBnb(1 ether);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // Native BNB preview uses Lista's conversion quote; existing slisBNB deposits are 1:1.
        if (tokenIn == NATIVE) return IListaStakeManager(stakeManager()).convertBnbToSnBnb(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    /// @notice Returns all tokens accepted for deposit: native BNB and slisBNB.
    /// @return res Array of accepted deposit token addresses.
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(NATIVE, yieldBearingToken());
    }

    /// @notice Returns all tokens accepted for redemption: slisBNB only.
    /// @return res Array of accepted redemption token addresses.
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @notice Checks whether the token is accepted for deposit (native BNB or slisBNB).
    /// @param token The token address to check.
    /// @return True if the token is a valid deposit token.
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == NATIVE || token == yieldBearingToken();
    }

    /// @notice Checks whether the token is accepted for redemption (slisBNB only).
    /// @param token The token address to check.
    /// @return True if the token is a valid redemption token.
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
