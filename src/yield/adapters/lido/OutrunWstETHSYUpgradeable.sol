// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStETH} from "../../../integrations/lido/interfaces/IStETH.sol";
import {IWstETH} from "../../../integrations/lido/interfaces/IWstETH.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {IStandardizedYield} from "../../interfaces/IStandardizedYield.sol";

/// @title Outrun Lido wstETH SY adapter
/// @notice SY adapter for Lido wstETH on Ethereum mainnet. The yield-bearing token is wstETH (wrapped stETH).
///      Deposit paths:
///      (a) native ETH → stETH via Lido submit → wrap to wstETH,
///      (b) existing stETH → wrap to wstETH,
///      (c) existing wstETH directly.
///      Exchange rate from wstETH.stEthPerToken().
contract OutrunWstETHSYUpgradeable layout at erc7201("outrun.storage.OutrunWstETHSY") is SYBaseUpgradeable {
    struct OutrunWstETHSYStorage {
        address stETH;
    }
    OutrunWstETHSYStorage private outrunWstETHSYStorage;

    error WstETHStakeFailed();

    /// @notice Initializes the SY adapter for Lido wstETH.
    /// @param owner_ The contract owner address.
    /// @param stETH_ Address of the Lido stETH token.
    /// @param wstETH_ Address of the wstETH yield-bearing token.
    /// @dev Reverts with SYZeroAddress if stETH_ or wstETH_ is the zero address.
    function initialize(address owner_, address stETH_, address wstETH_) external initializer {
        if (stETH_ == address(0) || wstETH_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Lido wstETH", "SY wstETH", wstETH_, owner_);
        outrunWstETHSYStorage.stETH = stETH_;
    }

    /// @notice Returns the Lido stETH token address.
    function stETH() public view returns (address) {
        return outrunWstETHSYStorage.stETH;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _stETH = stETH();
        address _yieldBearingToken = yieldBearingToken();
        if (tokenIn == NATIVE) {
            // Stake ETH via wstETH's receive() shortcut which does stETH.submit + _mint in one step.
            // This is Lido's canonical ETH->wstETH path (WstETH.receive) and is a single floor
            // `getSharesByPooledEth`, matching _previewDeposit and avoiding the extra
            // getPooledEthByShares->wrap round-trip that lost 1-2 wei.
            uint256 before = IERC20(_yieldBearingToken).balanceOf(address(this));
            // Recipient is the wstETH contract itself (the storage-configured yield token), not a user-supplied address.
            (bool success,) = _yieldBearingToken.call{value: amountDeposited}("");
            if (!success) revert WstETHStakeFailed();
            amountSharesOut = IERC20(_yieldBearingToken).balanceOf(address(this)) - before;
        } else if (tokenIn == _stETH) {
            // Wrap existing stETH into wstETH at current rate.
            // Exact per-call approval: the wrap pulls only this deposit's stETH amount, so no
            // standing grant remains even if a misdirected transfer strands transit tokens in the SY.
            _safeApprove(_stETH, _yieldBearingToken, amountDeposited);
            amountSharesOut = IWstETH(_yieldBearingToken).wrap(amountDeposited);
        } else {
            // 1:1, already the yield-bearing token.
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        // Redeem to stETH (unwrap wstETH) or transfer wstETH directly.
        address _stETH = stETH();
        address _yieldBearingToken = yieldBearingToken();
        if (tokenOut == _stETH) {
            amountTokenOut = IWstETH(_yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(_stETH, receiver, amountTokenOut);
        } else {
            _transferOut(_yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        }
    }

    /// @notice Returns the current exchange rate: stETH per 1 wstETH, scaled by 1e18.
    /// @return res wstETH.stEthPerToken(), which grows as Lido validators earn staking rewards.
    /// @dev Fail-closed backing reconciliation: reverts with InsufficientBacking when this adapter's
    ///      own wstETH balance falls below the outstanding SY supply (see _revertIfBackingBelowShares).
    function exchangeRate() public view override returns (uint256 res) {
        _revertIfBackingBelowShares();
        return IWstETH(yieldBearingToken()).stEthPerToken();
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        internal
        view
        override
        returns (uint256 amountSharesOut)
    {
        address _stETH = stETH();
        if (tokenIn == NATIVE || tokenIn == _stETH) {
            // ETH and stETH deposits both end as wstETH shares, so use Lido's pooled-ETH-to-share quote.
            // For direct stETH deposits the quote equals the executed wrap via the Lido identity
            // wrap(x) == getSharesByPooledEth(x) (1 wstETH unit == 1 stETH internal share, see IWstETH.wrap @dev).
            // Native deposits now stake via WstETH.receive() which is also a single
            // getSharesByPooledEth (WstETH.receive -> stETH.submit -> _mint), so the raw quote
            // matches the executed _deposit exactly at the same block (both single floor).
            // Same 50 bps conservative-headroom rationale as OutrunAsBNBSYUpgradeable._previewDeposit,
            // applied to NATIVE only. stETH preview stays exact at the same block because wrap == getSharesByPooledEth.
            uint256 raw = IStETH(_stETH).getSharesByPooledEth(amountTokenToDeposit);
            if (tokenIn == NATIVE && raw != 0) raw = raw * 9950 / 10000;
            amountSharesOut = raw;
        } else {
            // Existing wstETH is already the yield-bearing share token.
            amountSharesOut = amountTokenToDeposit;
        }
    }

    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        internal
        view
        override
        returns (uint256 amountTokenOut)
    {
        address _stETH = stETH();
        // Redeeming to stETH unwraps wstETH shares; redeeming to wstETH is 1:1.
        if (tokenOut == _stETH) amountTokenOut = IStETH(_stETH).getPooledEthByShares(amountSharesToRedeem);
        else amountTokenOut = amountSharesToRedeem;
    }

    /// @inheritdoc IStandardizedYield
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), NATIVE, stETH());
    }

    /// @inheritdoc IStandardizedYield
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), stETH());
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == NATIVE || token == stETH();
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == stETH();
    }

    /// @inheritdoc IStandardizedYield
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, stETH(), IERC20Metadata(stETH()).decimals());
    }
}
