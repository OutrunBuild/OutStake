// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// L2 SY adapter where stETH exists natively on the L2 and can be wrapped/unwrapped
// against wstETH locally. Unlike OutrunL2WstETHSY, this adapter performs actual
// wrap/unwrap of stETH ↔ wstETH on-chain. The exchange rate comes from the L2
// stETH contract.

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {IL2StETH} from "../../../integrations/lido/interfaces/IL2StETH.sol";

// solhint-disable-next-line gas-small-strings
contract OutrunL2WrappableWstETHSYUpgradeable layout at erc7201("outrun.storage.OutrunL2WrappableWstETHSY")
    is
    SYBaseUpgradeable
{
    struct OutrunL2WrappableWstETHSYStorage {
        address STETH;
        // The asset this SY ultimately represents on Ethereum mainnet
        // (for cross-chain position accounting).
        address underlyingAssetOnEthAddr;
        uint8 underlyingAssetOnEthDecimals;
    }
    OutrunL2WrappableWstETHSYStorage private outrunL2WrappableWstETHSYStorage;

    /// @notice Initializes the SY adapter with L2 stETH/wstETH wrap capability.
    /// @param owner_ The contract owner address.
    /// @param stETH_ Address of the L2 stETH token.
    /// @param wstETH_ Address of the wstETH yield-bearing token.
    /// @param underlyingAssetOnEthAddr_ Address of the underlying asset on Ethereum mainnet (for cross-chain accounting).
    /// @param underlyingAssetOnEthDecimals_ Decimals of the underlying asset on Ethereum mainnet.
    function initialize(
        address owner_,
        address stETH_,
        address wstETH_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) external initializer {
        if (stETH_ == address(0) || underlyingAssetOnEthAddr_ == address(0)) {
            revert SYZeroAddress();
        }
        __SYBase_init("SY Lido wstETH", "SY wstETH", wstETH_, owner_);
        outrunL2WrappableWstETHSYStorage.STETH = stETH_;
        outrunL2WrappableWstETHSYStorage.underlyingAssetOnEthAddr = underlyingAssetOnEthAddr_;
        outrunL2WrappableWstETHSYStorage.underlyingAssetOnEthDecimals = underlyingAssetOnEthDecimals_;
    }

    /// @notice Returns the address of the L2 stETH token.
    /// @return The L2 stETH token address.
    function STETH() public view returns (address) {
        return outrunL2WrappableWstETHSYStorage.STETH;
    }

    // If depositing stETH: unwrap to get wstETH shares.
    // If depositing wstETH: 1:1 (already the yield-bearing token).
    /// @param tokenIn The input token address (stETH or wstETH).
    /// @param amountDeposited The amount of the input token deposited.
    /// @return amountSharesOut The amount of wstETH shares received.
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _STETH = STETH();
        if (tokenIn == _STETH) amountSharesOut = IL2StETH(_STETH).unwrap(amountDeposited);
        else amountSharesOut = amountDeposited;
    }

    // slither-disable-next-line reentrancy-no-eth
    // If redeeming to stETH: wrap wstETH shares into stETH and transfer.
    // If redeeming to wstETH: transfer directly.
    /// @param receiver The address receiving the output tokens.
    /// @param tokenOut The output token address (stETH or wstETH).
    /// @param amountSharesToRedeem The amount of wstETH shares to redeem.
    /// @return amountTokenOut The amount of output tokens sent to the receiver.
    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        address _STETH = STETH();
        if (tokenOut == _STETH) {
            address _yieldBearingToken = yieldBearingToken();
            _safeApproveInf(_yieldBearingToken, _STETH);
            amountTokenOut = IL2StETH(_STETH).wrap(amountSharesToRedeem);
            _transferOut(_STETH, receiver, amountTokenOut);
        } else {
            amountTokenOut = amountSharesToRedeem;
            _transferOut(yieldBearingToken(), receiver, amountTokenOut);
        }
    }

    /// @notice Returns the stETH amount for 1 wstETH using the L2 stETH.getTokensByShares.
    /// @return res The amount of stETH equivalent to 1 wstETH (scaled by 1e18).
    function exchangeRate() public view override returns (uint256 res) {
        return IL2StETH(STETH()).getTokensByShares(1 ether);
    }

    /// @notice Previews the amount of wstETH shares that would be received for depositing a given token.
    /// @param tokenIn The input token address.
    /// @param amountTokenToDeposit The amount of the input token to deposit.
    /// @return The expected amount of wstETH shares received.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        address _STETH = STETH();
        if (tokenIn == _STETH) return IL2StETH(_STETH).getSharesByTokens(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    /// @notice Previews the amount of output tokens that would be received for redeeming wstETH shares.
    /// @param tokenOut The output token address.
    /// @param amountSharesToRedeem The amount of wstETH shares to redeem.
    /// @return The expected amount of output tokens received.
    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        address _STETH = STETH();
        if (tokenOut == _STETH) return IL2StETH(_STETH).getTokensByShares(amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    /// @notice Returns the list of accepted input tokens.
    /// @return res Array containing stETH and wstETH addresses.
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(STETH(), yieldBearingToken());
    }

    /// @notice Returns the list of accepted output tokens.
    /// @return res Array containing stETH and wstETH addresses.
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(STETH(), yieldBearingToken());
    }

    /// @notice Checks whether a token is accepted as input.
    /// @param token The token address to check.
    /// @return True if the token is stETH or wstETH.
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == STETH() || token == yieldBearingToken();
    }

    /// @notice Checks whether a token is accepted as output.
    /// @param token The token address to check.
    /// @return True if the token is stETH or wstETH.
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == STETH() || token == yieldBearingToken();
    }

    /// @notice Returns the asset type and details of the underlying Ethereum mainnet asset this SY represents.
    /// @return assetType Always TOKEN.
    /// @return assetAddress The underlying asset address on Ethereum mainnet.
    /// @return assetDecimals The decimals of the underlying asset on Ethereum mainnet.
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (
            AssetType.TOKEN,
            outrunL2WrappableWstETHSYStorage.underlyingAssetOnEthAddr,
            outrunL2WrappableWstETHSYStorage.underlyingAssetOnEthDecimals
        );
    }
}
