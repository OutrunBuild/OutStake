// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStETH} from "../../../integrations/lido/interfaces/IStETH.sol";
import {IWstETH} from "../../../integrations/lido/interfaces/IWstETH.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";

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
    /// @return The stETH address.
    function stETH() public view returns (address) {
        return outrunWstETHSYStorage.stETH;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _stETH = stETH();
        address _yieldBearingToken = yieldBearingToken();
        if (tokenIn == NATIVE) {
            // Submit ETH to Lido to receive stETH, then wrap stETH into wstETH.
            // Uses getPooledEthByShares to convert the stETH share amount
            // to a precise stETH balance before wrapping.
            uint256 stETHShareAmount = IStETH(_stETH).submit{value: amountDeposited}(address(0));
            _safeApproveInf(_stETH, _yieldBearingToken);
            amountSharesOut = IWstETH(_yieldBearingToken).wrap(IStETH(_stETH).getPooledEthByShares(stETHShareAmount));
        } else if (tokenIn == _stETH) {
            // Wrap existing stETH into wstETH at current rate.
            _safeApproveInf(_stETH, _yieldBearingToken);
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
    function exchangeRate() public view override returns (uint256 res) {
        // stEthPerToken() returns how much stETH (which is ETH-equivalent)
        // one wstETH is worth. This is the exchange rate that grows
        // as Lido validators earn staking rewards.
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
            // Native deposits instead execute submit -> getPooledEthByShares -> wrap upstream (two floor
            // roundings), so actual shares out can be up to a few wei below this quote (composite 2-3 wei
            // across the three floors); callers must leave slippage headroom rather than pass the quote
            // verbatim as minSharesOut.
            amountSharesOut = IStETH(_stETH).getSharesByPooledEth(amountTokenToDeposit);
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

    /// @notice Returns all tokens accepted for deposit: wstETH, native ETH, and stETH.
    /// @return res Array of accepted deposit token addresses.
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), NATIVE, stETH());
    }

    /// @notice Returns all tokens accepted for redemption: wstETH and stETH.
    /// @return res Array of accepted redemption token addresses.
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), stETH());
    }

    /// @notice Checks whether the token is accepted for deposit (wstETH, native ETH, or stETH).
    /// @param token The token address to check.
    /// @return True if the token is a valid deposit token.
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == NATIVE || token == stETH();
    }

    /// @notice Checks whether the token is accepted for redemption (wstETH or stETH).
    /// @param token The token address to check.
    /// @return True if the token is a valid redemption token.
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == stETH();
    }

    /// @notice Returns asset metadata: canonical asset is stETH, the constructor-injected underlying asset.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the stETH token
    /// @return assetDecimals decimals of stETH
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, stETH(), IERC20Metadata(stETH()).decimals());
    }
}
