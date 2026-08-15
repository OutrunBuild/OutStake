// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";

/// @title Outrun Sky sUSDS SY adapter
/// @notice SY adapter for Sky (Maker) sUSDS on Ethereum mainnet. The yield-bearing token is sUSDS (an ERC4626
///      vault for USDS). Deposit paths: (a) USDS → deposit into 4626 vault for sUSDS shares, (b) existing sUSDS
///      directly. Redeem can withdraw USDS from vault or send sUSDS to receiver. Exchange rate from ERC4626
///      convertToAssets.
// solhint-disable-next-line gas-small-strings
contract OutrunStakedUsdsSYUpgradeable layout at erc7201("outrun.storage.OutrunStakedUsdsSY") is SYBaseUpgradeable {
    struct OutrunStakedUsdsSYStorage {
        address USDS;
    }

    OutrunStakedUsdsSYStorage private outrunStakedUsdsSYStorage;

    function initialize(address owner_, address USDS_, address sUSDS_) external initializer {
        if (USDS_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Sky sUSDS", "SY sUSDS", sUSDS_, owner_);
        outrunStakedUsdsSYStorage.USDS = USDS_;
    }

    function USDS() public view returns (address) {
        return outrunStakedUsdsSYStorage.USDS;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _USDS = USDS();
        address _yieldBearingToken = yieldBearingToken();
        // Branch 1: deposit USDS into the ERC4626 sUSDS vault to mint sUSDS shares. Branch 2: deposit sUSDS directly 1:1.
        if (tokenIn == _USDS) {
            _safeApproveInf(_USDS, _yieldBearingToken);
            amountSharesOut = IERC4626(_yieldBearingToken).deposit(amountDeposited, address(this));
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        address _yieldBearingToken = yieldBearingToken();
        if (tokenOut == USDS()) {
            // Withdraw USDS from the sUSDS vault and send to receiver.
            amountTokenOut = IERC4626(_yieldBearingToken).redeem(amountSharesToRedeem, receiver, address(this));
        } else {
            // Transfer sUSDS directly — receiver can withdraw from vault later.
            _transferOut(_yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        }
    }

    function exchangeRate() public view override returns (uint256 res) {
        // ERC4626 convertToAssets(1 ether) returns how much USDS 1 sUSDS is worth.
        // The rate grows from 1.0 as Sky protocol yield is added to the savings rate.
        return IERC4626(yieldBearingToken()).convertToAssets(1 ether);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // USDS deposits mint sUSDS through the vault; sUSDS deposits are already shares.
        if (tokenIn == USDS()) return IERC4626(yieldBearingToken()).previewDeposit(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        // Redeeming to USDS exits the ERC4626 vault; redeeming to sUSDS is a direct share transfer.
        if (tokenOut == USDS()) return IERC4626(yieldBearingToken()).previewRedeem(amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), USDS());
    }

    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), USDS());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == USDS();
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == USDS();
    }

    /// @notice Returns asset metadata: canonical asset is USDS, the constructor-injected underlying asset.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the USDS token
    /// @return assetDecimals always 18
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, USDS(), 18);
    }
}
