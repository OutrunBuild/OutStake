// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// L2 SY adapter for Sky sUSDS. Uses PSM3 (Peg Stability Module) to swap between USDC, USDS, and sUSDS.
// Deposit paths: USDC → swap to sUSDS via PSM3, USDS → swap to sUSDS via PSM3, or sUSDS directly.
// Exchange rate from PSM3.previewSwapExactIn(sUSDS→USDS).

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {IPSM3} from "../../../integrations/sky/interfaces/IPSM3.sol";

// solhint-disable-next-line gas-small-strings
contract OutrunL2StakedUsdsSYUpgradeable layout at erc7201("outrun.storage.OutrunL2StakedUsdsSY") is SYBaseUpgradeable {
    struct OutrunL2StakedUsdsSYStorage {
        address USDC;
        address USDS;
        address PSM3;
    }
    OutrunL2StakedUsdsSYStorage private outrunL2StakedUsdsSYStorage;

    function initialize(address owner_, address USDC_, address USDS_, address sUSDS_, address PSM3_)
        external
        initializer
    {
        if (USDC_ == address(0) || USDS_ == address(0) || PSM3_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Sky sUSDS", "SY sUSDS", sUSDS_, owner_);
        OutrunL2StakedUsdsSYStorage storage $ = outrunL2StakedUsdsSYStorage;
        $.USDC = USDC_;
        $.USDS = USDS_;
        $.PSM3 = PSM3_;
    }

    function USDC() public view returns (address) {
        // Stablecoin input (USDC on L2)
        return outrunL2StakedUsdsSYStorage.USDC;
    }

    function USDS() public view returns (address) {
        // Sky's native stablecoin (also on L2 via bridge)
        return outrunL2StakedUsdsSYStorage.USDS;
    }

    function PSM3() public view returns (address) {
        // Peg Stability Module that handles swaps between USDC, USDS, and sUSDS
        return outrunL2StakedUsdsSYStorage.PSM3;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _yieldBearingToken = yieldBearingToken();
        // Deposit: if depositing sUSDS directly, 1:1. Otherwise, swap the input token to sUSDS via PSM3 at the current pool rate.
        if (tokenIn == _yieldBearingToken) {
            amountSharesOut = amountDeposited;
        } else {
            address _psm = PSM3();
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
            address _psm = PSM3();
            _safeApproveInf(_yieldBearingToken, _psm);
            amountTokenOut = IPSM3(_psm).swapExactIn(_yieldBearingToken, tokenOut, amountSharesToRedeem, 0, receiver, 0);
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        // PSM3 previewSwapExactIn(sUSDS→USDS, 1 ether) gives the current exchange rate.
        // PSM3 maintains a USDS/USDC peg, so this rate reflects the sUSDS savings rate multiplied by any PSM3 pool imbalance.
        return IPSM3(PSM3()).previewSwapExactIn(yieldBearingToken(), USDS(), 1 ether);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // sUSDS deposits are already shares; USDC/USDS deposits are quoted through PSM3.
        if (tokenIn == yieldBearingToken()) return amountTokenToDeposit;
        return IPSM3(PSM3()).previewSwapExactIn(tokenIn, yieldBearingToken(), amountTokenToDeposit);
    }

    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        // Redeeming to sUSDS is 1:1; redeeming to USDC/USDS is quoted through PSM3.
        if (tokenOut == yieldBearingToken()) return amountSharesToRedeem;
        return IPSM3(PSM3()).previewSwapExactIn(yieldBearingToken(), tokenOut, amountSharesToRedeem);
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(USDC(), USDS(), yieldBearingToken());
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(USDC(), USDS(), yieldBearingToken());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == USDC() || token == USDS() || token == yieldBearingToken();
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == USDC() || token == USDS() || token == yieldBearingToken();
    }

    /// @notice Returns asset metadata: canonical asset is USDS, the constructor-injected underlying asset.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the USDS token
    /// @return assetDecimals always 18
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, USDS(), 18);
    }
}
