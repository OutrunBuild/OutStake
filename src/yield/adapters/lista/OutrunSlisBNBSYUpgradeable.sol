// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IListaStakeManager} from "../../../integrations/lista/interfaces/IListaStakeManager.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {IStandardizedYield} from "../../interfaces/IStandardizedYield.sol";

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
            // Recipient is the initializer-validated Lista StakeManager, not a user-supplied address.
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

    /// @notice Returns the current exchange rate: BNB per 1 slisBNB, scaled by 1e18.
    /// @return res StakeManager.convertSnBnbToBnb(1 ether), which grows as Lista staking yield accrues.
    function exchangeRate() public view override returns (uint256 res) {
        return IListaStakeManager(stakeManager()).convertSnBnbToBnb(1 ether);
    }

    /// @notice Preview slisBNB shares for a deposit (quote-only, not reserved).
    /// @dev Native BNB path returns `IListaStakeManager.convertBnbToSnBnb(amountTokenToDeposit)` which is
    ///      `floor(amount * totalShares / totalPooledBnb)` at `P_old`. Execution mints `floor(...)` at `P_new`
    ///      via `deposit{value:amount}` balance-diff; same Floor family but different snapshot, so
    ///      `preview` may overquote `execution` by ≤1 wei when `amount*totalShares mod totalPooled` straddles
    ///      the remainder (BSC 98_653_065 fork single point `preview==execution` does not guarantee).
    ///      `ListaStakeManager.sol:195,890` has no deposit fee — `synFee` is charged only on `compoundRewards`
    ///      profit. Inter-block `totalPooledBnb` growth can make next-block execution < prior preview
    ///      (quote-only cost per EIP-4626).
    ///      Same 50 bps conservative-headroom rationale as OutrunAsBNBSYUpgradeable._previewDeposit.
    ///      The fixed `-1 wei` trick is intentionally not used: it neither covers inter-block drift
    ///      nor satisfies EIP-4626 `preview <= execution` as-close-as-possible — bps does.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        if (tokenIn == NATIVE) {
            uint256 raw = IListaStakeManager(stakeManager()).convertBnbToSnBnb(amountTokenToDeposit);
            if (raw != 0) raw = raw * 9950 / 10000;
            return raw;
        }
        return amountTokenToDeposit;
    }

    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    /// @inheritdoc IStandardizedYield
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(NATIVE, yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == NATIVE || token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
