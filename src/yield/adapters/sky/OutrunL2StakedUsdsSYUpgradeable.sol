// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {IPSM3} from "../../../integrations/sky/interfaces/IPSM3.sol";

/// @title Outrun L2 Sky sUSDS SY adapter
/// @notice L2 SY adapter for Sky sUSDS. Uses PSM3 (Peg Stability Module) to swap between USDC, USDS, and sUSDS.
///      Deposit paths: USDC → swap to sUSDS via PSM3, USDS → swap to sUSDS via PSM3, or sUSDS directly.
///      Exchange rate from PSM3.previewSwapExactIn(sUSDS→USDS).
// solhint-disable-next-line gas-small-strings
contract OutrunL2StakedUsdsSYUpgradeable layout at erc7201("outrun.storage.OutrunL2StakedUsdsSY") is SYBaseUpgradeable {
    struct OutrunL2StakedUsdsSYStorage {
        address usdc;
        address usds;
        address psm3;
    }
    OutrunL2StakedUsdsSYStorage private outrunL2StakedUsdsSYStorage;

    /// @notice Initializes the SY adapter for Sky sUSDS on L2.
    /// @param owner_ The contract owner address.
    /// @param usdc_ Address of the USDC token.
    /// @param usds_ Address of the USDS token.
    /// @param sUSDS_ Address of the sUSDS yield-bearing token.
    /// @param psm3_ Address of the Sky PSM3 (Peg Stability Module) contract.
    /// @dev Reverts with SYZeroAddress if usdc_, usds_, or psm3_ is zero, or via __SYBase_init if sUSDS_ is zero.
    function initialize(address owner_, address usdc_, address usds_, address sUSDS_, address psm3_)
        external
        initializer
    {
        if (usdc_ == address(0) || usds_ == address(0) || psm3_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Sky sUSDS", "SY sUSDS", sUSDS_, owner_);
        OutrunL2StakedUsdsSYStorage storage $ = outrunL2StakedUsdsSYStorage;
        $.usdc = usdc_;
        $.usds = usds_;
        $.psm3 = psm3_;
    }

    /// @notice Returns the USDC token address (stablecoin input on L2).
    /// @return The USDC address.
    function usdc() public view returns (address) {
        // Stablecoin input (USDC on L2)
        return outrunL2StakedUsdsSYStorage.usdc;
    }

    /// @notice Returns the USDS token address (Sky's native stablecoin on L2).
    /// @return The USDS address.
    function usds() public view returns (address) {
        // Sky's native stablecoin (also on L2 via bridge)
        return outrunL2StakedUsdsSYStorage.usds;
    }

    /// @notice Returns the PSM3 (Peg Stability Module) contract address.
    /// @return The PSM3 address.
    function psm3() public view returns (address) {
        // Peg Stability Module that handles swaps between USDC, USDS, and sUSDS
        return outrunL2StakedUsdsSYStorage.psm3;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _yieldBearingToken = yieldBearingToken();
        // Deposit: if depositing sUSDS directly, 1:1. Otherwise, swap the input token to sUSDS via PSM3 at the current pool rate.
        if (tokenIn == _yieldBearingToken) {
            amountSharesOut = amountDeposited;
        } else {
            address _psm = psm3();
            _safeApproveInf(tokenIn, _psm);
            amountSharesOut = IPSM3(_psm).swapExactIn(tokenIn, _yieldBearingToken, amountDeposited, 0, address(this), 0);
        }
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        address _yieldBearingToken = yieldBearingToken();
        // Redeem: if tokenOut is sUSDS, transfer directly. Otherwise, swap sUSDS to tokenOut via PSM3.
        if (tokenOut == _yieldBearingToken) {
            _transferOut(_yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        } else {
            address _psm = psm3();
            _safeApproveInf(_yieldBearingToken, _psm);
            amountTokenOut = IPSM3(_psm).swapExactIn(_yieldBearingToken, tokenOut, amountSharesToRedeem, 0, receiver, 0);
        }
    }

    /// @notice Returns the current exchange rate: USDS per 1 sUSDS, scaled by 1e18, quoted via PSM3.
    /// @return res PSM3.previewSwapExactIn(sUSDS→USDS, 1 ether) — the sUSDS savings rate combined with
    ///      any PSM3 pool imbalance.
    function exchangeRate() public view override returns (uint256 res) {
        // PSM3 previewSwapExactIn(sUSDS→USDS, 1 ether) gives the current exchange rate.
        // PSM3 maintains a USDS/USDC peg, so this rate reflects the sUSDS savings rate multiplied by any PSM3 pool imbalance.
        return IPSM3(psm3()).previewSwapExactIn(yieldBearingToken(), usds(), 1 ether);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // sUSDS deposits are already shares; USDC/USDS deposits are quoted through PSM3.
        if (tokenIn == yieldBearingToken()) return amountTokenToDeposit;
        return IPSM3(psm3()).previewSwapExactIn(tokenIn, yieldBearingToken(), amountTokenToDeposit);
    }

    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        // Redeeming to sUSDS is 1:1; redeeming to USDC/USDS is quoted through PSM3.
        if (tokenOut == yieldBearingToken()) return amountSharesToRedeem;
        return IPSM3(psm3()).previewSwapExactIn(yieldBearingToken(), tokenOut, amountSharesToRedeem);
    }

    /// @notice Returns all tokens accepted for deposit: USDC, USDS, and sUSDS.
    /// @return res Array of accepted deposit token addresses.
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(usdc(), usds(), yieldBearingToken());
    }

    /// @notice Returns all tokens accepted for redemption: USDC, USDS, and sUSDS.
    /// @return res Array of accepted redemption token addresses.
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(usdc(), usds(), yieldBearingToken());
    }

    /// @notice Checks whether the token is accepted for deposit (USDC, USDS, or sUSDS).
    /// @param token The token address to check.
    /// @return True if the token is a valid deposit token.
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == usdc() || token == usds() || token == yieldBearingToken();
    }

    /// @notice Checks whether the token is accepted for redemption (USDC, USDS, or sUSDS).
    /// @param token The token address to check.
    /// @return True if the token is a valid redemption token.
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == usdc() || token == usds() || token == yieldBearingToken();
    }

    /// @notice Returns asset metadata: canonical asset is USDS, the constructor-injected underlying asset.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the USDS token
    /// @return assetDecimals always 18
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, usds(), 18);
    }
}
