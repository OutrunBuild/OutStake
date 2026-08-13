// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// SY adapter for Aster asBNB (BSC). The yield-bearing token is asBNB.
// Deposit paths: (a) native BNB → mint asBNB via AsBnbMinter, (b) slisBNB → mint asBNB via AsBnbMinter,
// (c) existing asBNB directly.
// Exchange rate: asBNB→slisBNB via Minter, then slisBNB→BNB via Lista StakeManager.

import {IAsBnbMinter} from "../../../integrations/aster/interfaces/IAsBnbMinter.sol";
import {IListaBNBStakeManager} from "../../../integrations/aster/interfaces/IListaBNBStakeManager.sol";
import {IYieldProxy} from "../../../integrations/aster/interfaces/IYieldProxy.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";

contract OutrunAsBNBSYUpgradeable layout at erc7201("outrun.storage.OutrunAsBNBSY") is SYBaseUpgradeable {
    struct OutrunAsBNBSYStorage {
        address AS_BNB_MINTER;
        address SLIS_BNB;
        address YIELD_PROXY;
        address STAKE_MANAGER;
    }
    OutrunAsBNBSYStorage private outrunAsBNBSYStorage;

    error AsBnbMintQueued();
    error AsBnbMintZeroShares();
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
        (address yieldProxy, address stakeManager) = _validateMinter(asBNB_, slisBNB_, asBnbMinter_);
        // Store the validated integration addresses used by deposit and preview paths.
        outrunAsBNBSYStorage.AS_BNB_MINTER = asBnbMinter_;
        outrunAsBNBSYStorage.SLIS_BNB = slisBNB_;
        outrunAsBNBSYStorage.YIELD_PROXY = yieldProxy;
        outrunAsBNBSYStorage.STAKE_MANAGER = stakeManager;
    }

    function _validateMinter(address asBNB_, address slisBNB_, address asBnbMinter_)
        private
        view
        returns (address yieldProxy, address stakeManager)
    {
        // Validate that the minter really mints the configured asBNB from the configured slisBNB.
        address actualAsBnb = IAsBnbMinter(asBnbMinter_).asBnb();
        if (actualAsBnb != asBNB_) revert InvalidAsBnbMinterAsBnb(asBNB_, actualAsBnb);
        address actualToken = IAsBnbMinter(asBnbMinter_).token();
        if (actualToken != slisBNB_) revert InvalidAsBnbMinterToken(slisBNB_, actualToken);
        // The YieldProxy exposes the Lista StakeManager used later for exchange-rate conversion.
        yieldProxy = IAsBnbMinter(asBnbMinter_).yieldProxy();
        if (yieldProxy == address(0)) revert InvalidYieldProxy();
        stakeManager = IYieldProxy(yieldProxy).stakeManager();
        if (stakeManager == address(0)) revert InvalidStakeManager();
    }

    /// @notice Returns the AsBnbMinter contract address.
    /// @return The AsBnbMinter address.
    function AS_BNB_MINTER() public view returns (address) {
        return outrunAsBNBSYStorage.AS_BNB_MINTER;
    }

    /// @notice Returns the slisBNB token address.
    /// @return The slisBNB token address.
    function SLIS_BNB() public view returns (address) {
        return outrunAsBNBSYStorage.SLIS_BNB;
    }

    /// @notice Returns the YieldProxy contract address.
    /// @return The YieldProxy address.
    function YIELD_PROXY() public view returns (address) {
        return outrunAsBNBSYStorage.YIELD_PROXY;
    }

    /// @notice Returns the Lista StakeManager contract address.
    /// @return The StakeManager address.
    function STAKE_MANAGER() public view returns (address) {
        return outrunAsBNBSYStorage.STAKE_MANAGER;
    }

    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _minter = AS_BNB_MINTER();
        // Branch 1 (NATIVE): Mint asBNB from native BNB via the Aster Minter.
        // Reverts with specific error if yield proxy has ongoing activities (cooldown period).
        if (tokenIn == NATIVE) {
            amountSharesOut = IAsBnbMinter(_minter).mintAsBnb{value: amountDeposited}();
            if (amountSharesOut == 0) _revertOnZeroShares();
            return amountSharesOut;
        }
        // Branch 2 (SLIS_BNB): Mint asBNB from slisBNB via the Aster Minter.
        if (tokenIn == SLIS_BNB()) {
            address _slisBNB = SLIS_BNB();
            _safeApproveInf(_slisBNB, _minter);
            amountSharesOut = IAsBnbMinter(_minter).mintAsBnb(amountDeposited);
            if (amountSharesOut == 0) _revertOnZeroShares();
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
    function exchangeRate() public view override returns (uint256 res) {
        uint256 slisBnbPerShare = IAsBnbMinter(AS_BNB_MINTER()).convertToTokens(1 ether);
        return IListaBNBStakeManager(STAKE_MANAGER()).convertSnBnbToBnb(slisBnbPerShare);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        address _minter = AS_BNB_MINTER();
        if (tokenIn == NATIVE) {
            // Preview mirrors the live path: BNB -> slisBNB -> asBNB.
            uint256 slisBnbAmount = IListaBNBStakeManager(STAKE_MANAGER()).convertBnbToSnBnb(amountTokenToDeposit);
            return IAsBnbMinter(_minter).convertToAsBnb(slisBnbAmount);
        }
        // slisBNB deposits convert through the Aster minter; asBNB deposits stay 1:1.
        if (tokenIn == SLIS_BNB()) return IAsBnbMinter(_minter).convertToAsBnb(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(NATIVE, SLIS_BNB(), yieldBearingToken());
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == NATIVE || token == SLIS_BNB() || token == yieldBearingToken();
    }

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

    // Aster Minter returns 0 shares when yield proxy is processing a batch.
    // Distinguish between ongoing cooldown (retry later) and true zero-output failure.
    function _revertOnZeroShares() private view {
        if (IYieldProxy(YIELD_PROXY()).activitiesOnGoing()) revert AsBnbMintQueued();
        revert AsBnbMintZeroShares();
    }
}
