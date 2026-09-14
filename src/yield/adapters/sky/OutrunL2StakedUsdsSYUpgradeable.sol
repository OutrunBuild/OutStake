// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {IStandardizedYield} from "../../interfaces/IStandardizedYield.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {IPSM3} from "../../../integrations/sky/interfaces/IPSM3.sol";
import {IRateProviderLike} from "../../../integrations/sky/interfaces/IRateProviderLike.sol";

/// @title Outrun L2 Sky sUSDS SY adapter
/// @notice L2 SY adapter for Sky sUSDS. Uses PSM3 for swap execution (USDC/USDS↔sUSDS)
///      and an independent SSR RateProvider for accounting. Deposit paths: USDC → swap
///      to sUSDS via PSM3, USDS → swap to sUSDS via PSM3, or sUSDS directly.
///      Exchange rate from RateProvider.getConversionRate() (SSR cross-chain mirror, 1e27)
///      with a PSM deviation guard; PSM remains execution-only.
// solhint-disable-next-line gas-small-strings
contract OutrunL2StakedUsdsSYUpgradeable layout at erc7201("outrun.storage.OutrunL2StakedUsdsSY") is SYBaseUpgradeable {
    struct OutrunL2StakedUsdsSYStorage {
        address usdc;
        address usds;
        address psm3;
        address rateProvider;
        uint16 maxDeviationBps;
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
        // Bind RateProvider directly from canonical PSM3; misconfigured PSM must fail at deployment.
        // No try/catch — pre-deployment has no historical proxies to keep compatible.
        $.rateProvider = IPSM3(psm3_).rateProvider();
        if ($.rateProvider == address(0)) revert RateProviderCallFailed();
        $.maxDeviationBps = 100;
    }

    /// @notice Returns the USDC token address (stablecoin input on L2).
    function usdc() public view returns (address) {
        // Stablecoin input (USDC on L2)
        return outrunL2StakedUsdsSYStorage.usdc;
    }

    /// @notice Returns the USDS token address (Sky's native stablecoin on L2).
    function usds() public view returns (address) {
        // Sky's native stablecoin (also on L2 via bridge)
        return outrunL2StakedUsdsSYStorage.usds;
    }

    /// @notice Returns the PSM3 (Peg Stability Module) contract address.
    function psm3() public view returns (address) {
        // Peg Stability Module that handles swaps between USDC, USDS, and sUSDS
        return outrunL2StakedUsdsSYStorage.psm3;
    }

    /// @notice Returns the independent SSR RateProvider (1e27) used for exchangeRate.
    function rateProvider() public view returns (address) {
        return outrunL2StakedUsdsSYStorage.rateProvider;
    }

    /// @notice Returns the max PSM vs SSR deviation in bps before exchangeRate reverts.
    /// @return Deviation bound (e.g. 100 = 1%). Zero means default 100 bps.
    function maxDeviationBps() public view returns (uint16) {
        uint16 v = outrunL2StakedUsdsSYStorage.maxDeviationBps;
        return v == 0 ? 100 : v;
    }

    /// @notice Sets the SSR RateProvider. Owner-only.
    /// @param newRateProvider The new rate provider (1e27). Must not be zero.
    function setRateProvider(address newRateProvider) external onlyOwner {
        if (newRateProvider == address(0)) revert SYZeroAddress();
        outrunL2StakedUsdsSYStorage.rateProvider = newRateProvider;
    }

    /// @notice Sets the max PSM deviation bound. Owner-only.
    /// @param newMaxBps New bound in bps (e.g. 100 = 1%). Must be <= 10000.
    function setMaxDeviationBps(uint16 newMaxBps) external onlyOwner {
        if (newMaxBps == 0 || newMaxBps > 10000) revert InvalidMaxDeviationBps();
        outrunL2StakedUsdsSYStorage.maxDeviationBps = newMaxBps;
    }

    error InvalidMaxDeviationBps();
    error RateDeviationExceeded(uint256 psmRate, uint256 ssrRate, uint256 maxBps);
    error RateProviderCallFailed();

    error PSM3IncompleteConsumption(uint256 expectedConsumed, uint256 actualConsumed);

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _yieldBearingToken = yieldBearingToken();
        // Deposit: if depositing sUSDS directly, 1:1. Otherwise, swap the input token to sUSDS via PSM3 at the current pool rate.
        if (tokenIn == _yieldBearingToken) {
            amountSharesOut = amountDeposited;
        } else {
            // Enforce full consumption of the input token (no sweep residual):
            // the PSM3 must pull the entire amountDeposited; any partial fill would
            // leave user funds stranded in SY and sweepable via SYBaseUpgradeable.sol::sweep.
            uint256 balanceBefore = _selfBalance(tokenIn);
            address _psm = psm3();
            // Exact per-call approval: the pull covers only this swap's input amount, so no
            // standing grant remains even if a misdirected transfer strands transit tokens in the SY.
            _safeApprove(tokenIn, _psm, amountDeposited);
            amountSharesOut = IPSM3(_psm).swapExactIn(tokenIn, _yieldBearingToken, amountDeposited, 0, address(this), 0);
            uint256 balanceAfter = _selfBalance(tokenIn);
            if (balanceAfter != balanceBefore - amountDeposited) {
                revert PSM3IncompleteConsumption(amountDeposited, balanceBefore - balanceAfter);
            }
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
            // Exact per-call approval: the yield-bearing token is the SY's resident share backing, so the
            // allowance must cover only this swap's pull and leave no standing grant to PSM3.
            _safeApprove(_yieldBearingToken, _psm, amountSharesToRedeem);
            amountTokenOut = IPSM3(_psm).swapExactIn(_yieldBearingToken, tokenOut, amountSharesToRedeem, 0, receiver, 0);
        }
    }

    /// @notice Returns the current exchangeRate: USDS per 1 sUSDS, scaled by 1e18, from SSR RateProvider.
    /// @return res SSR-derived rate (sUSDS 18 -> USDS 18 via rate/1e27) with PSM deviation guard.
    /// @dev Accounting uses independent RateProvider and reverts with RateProviderCallFailed if none is configured
    ///      (fail-closed, no PSM fallback). If PSM quote deviates from SSR by more than maxDeviationBps, reverts
    ///      to fail-closed (prevents pool-imbalance or stale-oracle pollution of position minting).
    ///      Also runs the shared fail-closed backing reconciliation (SYBaseUpgradeable.sol::
    ///      _revertIfBackingBelowShares) and reverts with InsufficientBacking when the adapter's own
    ///      sUSDS balance falls below the outstanding SY supply.
    function exchangeRate() public view override returns (uint256 res) {
        address _yieldBearingToken = yieldBearingToken();
        // Backing reconciliation runs before any rate source is read (fail-closed); the assertion's
        // scope, snapshot semantics, and preconditions live with the shared base helper.
        _revertIfBackingBelowShares();

        address rp = rateProvider();
        if (rp == address(0)) revert RateProviderCallFailed();
        uint256 rate;
        try IRateProviderLike(rp).getConversionRate() returns (uint256 r) {
            rate = r;
        } catch {
            revert RateProviderCallFailed();
        }
        // rate is always assigned on this path: the try branch assigns it and the catch reverts;
        // the zero check catches a provider that returns 0.
        if (rate == 0) revert RateProviderCallFailed();
        // sUSDS 18, USDS 18: 1 sUSDS = rate/1e27 USDS => 1e18 * rate / 1e27
        uint256 ssrRate = (1 ether * rate) / 1e27;
        uint256 psmRate = IPSM3(psm3()).previewSwapExactIn(_yieldBearingToken, usds(), 1 ether);
        uint256 maxBps = maxDeviationBps();
        if (psmRate != ssrRate && ssrRate != 0) {
            uint256 diff = psmRate > ssrRate ? psmRate - ssrRate : ssrRate - psmRate;
            uint256 bps = (diff * 10000) / ssrRate;
            if (bps > maxBps) revert RateDeviationExceeded(psmRate, ssrRate, maxBps);
        }
        return ssrRate;
    }

    /// @notice Previews the sUSDS shares that would be received for depositing a given token.
    /// @dev USDC/USDS path forwards to `IPSM3.previewSwapExactIn` (floor quote). Sky SSR accrues per block,
    ///      shifting the PSM3 rate between preview and execution by a few wei, bidirectional (deposit preview
    ///      may be higher than execution, redeem preview may be lower). This bounded drift is a PSM3 preview-
    ///      vs-execution caveat, not locally fixable; adapter keeps faithful pass-through without 9950/10000
    ///      discount. Callers should not use preview verbatim as `SYBaseUpgradeable.sol::deposit` minSharesOut;
    ///      leave 1 wei headroom (e.g. `preview > 1 ? preview - 1 : preview`) or small bps margin, consistent
    ///      with `OutrunStakedUsdsSYUpgradeable` family. sUSDS direct branch is 1:1 and has no conversion drift.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // sUSDS deposits are already shares; USDC/USDS deposits are quoted through PSM3.
        if (tokenIn == yieldBearingToken()) return amountTokenToDeposit;
        return IPSM3(psm3()).previewSwapExactIn(tokenIn, yieldBearingToken(), amountTokenToDeposit);
    }

    /// @notice Previews the output tokens that would be received for redeeming SY shares.
    /// @dev sUSDS direct branch is 1:1. USDC/USDS path forwards to `IPSM3.previewSwapExactIn` (floor quote)
    ///      with same SSR per-block drift caveat as `_previewDeposit` — a few wei bidirectional preview-vs-
    ///      execution drift, faithful pass-through, no discount; callers should leave 1 wei/bps headroom when
    ///      using preview as `SYBaseUpgradeable.sol::redeem` minTokenOut.
    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        // Redeeming to sUSDS is 1:1; redeeming to USDC/USDS is quoted through PSM3.
        if (tokenOut == yieldBearingToken()) return amountSharesToRedeem;
        return IPSM3(psm3()).previewSwapExactIn(yieldBearingToken(), tokenOut, amountSharesToRedeem);
    }

    /// @inheritdoc IStandardizedYield
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(usdc(), usds(), yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(usdc(), usds(), yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == usdc() || token == usds() || token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == usdc() || token == usds() || token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, usds(), 18);
    }
}
