// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStETH} from "../../../integrations/lido/interfaces/IStETH.sol";
import {IWstETH} from "../../../integrations/lido/interfaces/IWstETH.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";

// SY adapter for Lido wstETH on Ethereum mainnet.
// The yield-bearing token is wstETH (wrapped stETH).
// Deposit paths:
//   (a) native ETH → stETH via Lido submit → wrap to wstETH,
//   (b) existing stETH → wrap to wstETH,
//   (c) existing wstETH directly.
// Exchange rate from wstETH.stEthPerToken().
contract OutrunWstETHSYUpgradeable layout at erc7201("outrun.storage.OutrunWstETHSY") is SYBaseUpgradeable {
    struct OutrunWstETHSYStorage {
        address STETH;
    }
    OutrunWstETHSYStorage private outrunWstETHSYStorage;

    function initialize(address owner_, address stETH_, address wstETH_) external initializer {
        if (stETH_ == address(0) || wstETH_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Lido wstETH", "SY wstETH", wstETH_, owner_);
        outrunWstETHSYStorage.STETH = stETH_;
    }

    function STETH() public view returns (address) {
        return outrunWstETHSYStorage.STETH;
    }

    // slither-disable-next-line reentrancy-eth,reentrancy-benign
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _STETH = STETH();
        address _yieldBearingToken = yieldBearingToken();
        if (tokenIn == NATIVE) {
            // Submit ETH to Lido to receive stETH, then wrap stETH into wstETH.
            // Uses getPooledEthByShares to convert the stETH share amount
            // to a precise stETH balance before wrapping.
            uint256 stETHShareAmount = IStETH(_STETH).submit{value: amountDeposited}(address(0));
            _safeApproveInf(_STETH, _yieldBearingToken);
            amountSharesOut = IWstETH(_yieldBearingToken).wrap(IStETH(_STETH).getPooledEthByShares(stETHShareAmount));
        } else if (tokenIn == _STETH) {
            // Wrap existing stETH into wstETH at current rate.
            _safeApproveInf(_STETH, _yieldBearingToken);
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
        address _STETH = STETH();
        address _yieldBearingToken = yieldBearingToken();
        if (tokenOut == _STETH) {
            amountTokenOut = IWstETH(_yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(_STETH, receiver, amountTokenOut);
        } else {
            _transferOut(_yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        }
    }

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
        address _STETH = STETH();
        if (tokenIn == NATIVE || tokenIn == _STETH) {
            // ETH and stETH deposits both end as wstETH shares, so use Lido's pooled-ETH-to-share quote.
            amountSharesOut = IStETH(_STETH).getSharesByPooledEth(amountTokenToDeposit);
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
        address _STETH = STETH();
        // Redeeming to stETH unwraps wstETH shares; redeeming to wstETH is 1:1.
        if (tokenOut == _STETH) amountTokenOut = IStETH(_STETH).getPooledEthByShares(amountSharesToRedeem);
        else amountTokenOut = amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), NATIVE, STETH());
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), STETH());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == NATIVE || token == STETH();
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == STETH();
    }

    /// @notice Returns asset metadata: canonical asset is stETH, the constructor-injected underlying asset.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the stETH token
    /// @return assetDecimals decimals of stETH
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, STETH(), IERC20Metadata(STETH()).decimals());
    }
}
