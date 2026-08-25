// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IAsBnbMinter} from "../../../integrations/aster/interfaces/IAsBnbMinter.sol";
import {IListaStakeManager} from "../../../integrations/lista/interfaces/IListaStakeManager.sol";
import {IYieldProxy} from "../../../integrations/aster/interfaces/IYieldProxy.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {IStandardizedYield} from "../../interfaces/IStandardizedYield.sol";

/// @title Outrun Aster asBNB SY adapter
/// @notice SY adapter for Aster asBNB (BSC). The yield-bearing token is asBNB. Deposit paths: (a) native BNB →
///      mint asBNB via AsBnbMinter, (b) slisBNB → mint asBNB via AsBnbMinter, (c) existing asBNB directly.
///      Exchange rate: asBNB→slisBNB via Minter, then slisBNB→BNB via Lista StakeManager.
contract OutrunAsBNBSYUpgradeable layout at erc7201("outrun.storage.OutrunAsBNBSY") is SYBaseUpgradeable {
    struct OutrunAsBNBSYStorage {
        address asBnbMinter;
        address slisBnb;
        address yieldProxy;
        address stakeManager;
    }
    OutrunAsBNBSYStorage private outrunAsBNBSYStorage;

    error AsBnbMintQueued();
    error AsBnbMintZeroShares();
    error AsBnbMintIncompleteConsumption(uint256 expectedConsumed, uint256 actualRemaining);
    error InvalidAsBnbMinterAsBnb(address expected, address actual);
    error InvalidAsBnbMinterToken(address expected, address actual);
    error InvalidYieldProxy();
    error InvalidStakeManager();

    /// @notice Initializes the SY adapter for Aster asBNB, validating the minter configuration.
    /// @param owner_ The contract owner address.
    /// @param asBNB_ Address of the asBNB yield-bearing token.
    /// @param slisBNB_ Address of the slisBNB token.
    /// @param asBnbMinter_ Address of the AsBnbMinter contract.
    function initialize(address owner_, address asBNB_, address slisBNB_, address asBnbMinter_) external initializer {
        if (asBNB_ == address(0) || slisBNB_ == address(0) || asBnbMinter_ == address(0)) revert SYZeroAddress();

        __SYBase_init("SY Aster asBNB", "SY asBNB", asBNB_, owner_);
        (address yieldProxyAddress, address stakeManagerAddress) = _validateMinter(asBNB_, slisBNB_, asBnbMinter_);
        // Store the validated integration addresses used by deposit and preview paths.
        outrunAsBNBSYStorage.asBnbMinter = asBnbMinter_;
        outrunAsBNBSYStorage.slisBnb = slisBNB_;
        outrunAsBNBSYStorage.yieldProxy = yieldProxyAddress;
        outrunAsBNBSYStorage.stakeManager = stakeManagerAddress;
    }

    function _validateMinter(address asBNB_, address slisBNB_, address asBnbMinter_)
        private
        view
        returns (address yieldProxyAddress, address stakeManagerAddress)
    {
        // Validate that the minter really mints the configured asBNB from the configured slisBNB.
        address actualAsBnb = IAsBnbMinter(asBnbMinter_).asBnb();
        if (actualAsBnb != asBNB_) revert InvalidAsBnbMinterAsBnb(asBNB_, actualAsBnb);
        address actualToken = IAsBnbMinter(asBnbMinter_).token();
        if (actualToken != slisBNB_) revert InvalidAsBnbMinterToken(slisBNB_, actualToken);
        // The YieldProxy exposes the Lista StakeManager used later for exchange-rate conversion.
        yieldProxyAddress = IAsBnbMinter(asBnbMinter_).yieldProxy();
        if (yieldProxyAddress == address(0)) revert InvalidYieldProxy();
        stakeManagerAddress = IYieldProxy(yieldProxyAddress).stakeManager();
        if (stakeManagerAddress == address(0)) revert InvalidStakeManager();
    }

    /// @notice Returns the AsBnbMinter contract address.
    function asBnbMinter() public view returns (address) {
        return outrunAsBNBSYStorage.asBnbMinter;
    }

    /// @notice Returns the slisBNB token address.
    function slisBnb() public view returns (address) {
        return outrunAsBNBSYStorage.slisBnb;
    }

    /// @notice Returns the YieldProxy contract address.
    function yieldProxy() public view returns (address) {
        return outrunAsBNBSYStorage.yieldProxy;
    }

    /// @notice Returns the Lista StakeManager contract address.
    function stakeManager() public view returns (address) {
        return outrunAsBNBSYStorage.stakeManager;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _minter = asBnbMinter();
        // Branch 1 (NATIVE): Mint asBNB from native BNB via the Aster Minter.
        // Reverts with specific error if yield proxy has ongoing activities (cooldown period).
        if (tokenIn == NATIVE) {
            amountSharesOut = IAsBnbMinter(_minter).mintAsBnb{value: amountDeposited}();
            if (amountSharesOut == 0) _revertOnZeroShares();
            return amountSharesOut;
        }
        // Branch 2 (SLIS_BNB): Mint asBNB from slisBNB via the Aster Minter.
        if (tokenIn == slisBnb()) {
            address _slisBnb = slisBnb();
            // Capture slisBNB balance before external call to enforce full consumption.
            // _transferIn already moved amountDeposited into this contract, so before
            // includes the user's deposit plus any prior stranded balance.
            uint256 slisBalanceBefore = _selfBalance(_slisBnb);
            _safeApproveInf(_slisBnb, _minter);
            amountSharesOut = IAsBnbMinter(_minter).mintAsBnb(amountDeposited);
            if (amountSharesOut == 0) _revertOnZeroShares();
            // Enforce that the minter fully consumed the input: any partial fill would
            // leave user funds as stranded ERC20 that SYBaseUpgradeable.sol::sweep could
            // extract (residual input). Use balance diff rather than return value, because
            // the external contract could return a non-zero share amount while still
            // retaining part of the input.
            uint256 slisBalanceAfter = _selfBalance(_slisBnb);
            if (slisBalanceAfter != slisBalanceBefore - amountDeposited) {
                revert AsBnbMintIncompleteConsumption(amountDeposited, slisBalanceBefore - slisBalanceAfter);
            }
            return amountSharesOut;
        }
        // Branch 3 (asBNB itself): 1:1.
        return amountDeposited;
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        // asBNB redemption path only supports returning asBNB itself, so transfer 1:1.
        amountTokenOut = amountSharesToRedeem;
        _transferOut(tokenOut, receiver, amountTokenOut);
    }

    // Two-step conversion: asBNB→slisBNB (via Minter), then slisBNB→BNB (via Lista StakeManager).
    /// @notice Returns the current exchange rate: BNB per 1 asBNB, scaled by 1e18.
    /// @return res BNB value of 1 asBNB (asBNB→slisBNB via Minter, then slisBNB→BNB via StakeManager).
    function exchangeRate() public view override returns (uint256 res) {
        uint256 slisBnbPerShare = IAsBnbMinter(asBnbMinter()).convertToTokens(1 ether);
        return IListaStakeManager(stakeManager()).convertSnBnbToBnb(slisBnbPerShare);
    }

    /// @notice Preview asBNB shares for a deposit (quote-only, not reserved).
    /// @dev NATIVE: `convertBnbToSnBnb@P_old -> convertToAsBnb@P_old` two views; slisBNB: `convertToAsBnb@P_old`
    ///      single view. Execution mints via `mintAsBnb` at `P_new` with `AsBnbMintIncompleteConsumption` guard;
    ///      same Floor family but different snapshot, composed two floors may overquote `execution` by ≤2 wei
    ///      when remainder straddles (single-point fork `preview==execution` at 98_653_065 does not guarantee).
    ///      Preview does NOT account for Aster queue state: if `IYieldProxy.activitiesOnGoing()==true`
    ///      execution returns 0 and reverts `AsBnbMintQueued` (retry liveness) while preview still quotes the
    ///      view rate (100% delta, fail-closed).
    ///      Apply 50 bps conservative headroom so a verbatim `previewDeposit` as `minSharesOut`
    ///      cannot revert on ≤2 wei floor rounding or inter-block drift. The 9950/10000 bound is
    ///      generic across adapters and dominates the bounded error. Callers should still handle
    ///      `AsBnbMintQueued` retry.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        address _minter = asBnbMinter();
        if (tokenIn == NATIVE) {
            // Preview mirrors the live path: BNB -> slisBNB -> asBNB.
            uint256 slisBnbAmount = IListaStakeManager(stakeManager()).convertBnbToSnBnb(amountTokenToDeposit);
            uint256 raw = IAsBnbMinter(_minter).convertToAsBnb(slisBnbAmount);
            if (raw != 0) raw = raw * 9950 / 10000;
            return raw;
        }
        // slisBNB deposits convert through the Aster minter; asBNB deposits stay 1:1.
        if (tokenIn == slisBnb()) {
            uint256 raw = IAsBnbMinter(_minter).convertToAsBnb(amountTokenToDeposit);
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
        return ArrayLib.create(NATIVE, slisBnb(), yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == NATIVE || token == slisBnb() || token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }

    // Aster Minter returns 0 shares when yield proxy is processing a batch.
    // Distinguish between ongoing cooldown (retry later) and true zero-output failure.
    function _revertOnZeroShares() private view {
        if (IYieldProxy(yieldProxy()).activitiesOnGoing()) revert AsBnbMintQueued();
        revert AsBnbMintZeroShares();
    }
}
