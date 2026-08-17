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
        address usds;
    }

    OutrunStakedUsdsSYStorage private outrunStakedUsdsSYStorage;

    /// @notice Initializes the SY adapter for Sky sUSDS.
    /// @param owner_ The contract owner address.
    /// @param usds_ Address of the USDS token.
    /// @param sUSDS_ Address of the sUSDS yield-bearing token.
    /// @dev Reverts with SYZeroAddress if usds_ is zero, or via __SYBase_init if sUSDS_ is zero.
    function initialize(address owner_, address usds_, address sUSDS_) external initializer {
        if (usds_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Sky sUSDS", "SY sUSDS", sUSDS_, owner_);
        outrunStakedUsdsSYStorage.usds = usds_;
    }

    /// @notice Returns the USDS token address.
    /// @return The USDS address.
    function usds() public view returns (address) {
        return outrunStakedUsdsSYStorage.usds;
    }

    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _usds = usds();
        address _yieldBearingToken = yieldBearingToken();
        // Branch 1: deposit USDS into the ERC4626 sUSDS vault to mint sUSDS shares. Branch 2: deposit sUSDS directly 1:1.
        if (tokenIn == _usds) {
            _safeApproveInf(_usds, _yieldBearingToken);
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
        if (tokenOut == usds()) {
            // Withdraw USDS from the sUSDS vault and send to receiver.
            amountTokenOut = IERC4626(_yieldBearingToken).redeem(amountSharesToRedeem, receiver, address(this));
        } else {
            // Transfer sUSDS directly — receiver can withdraw from vault later.
            _transferOut(_yieldBearingToken, receiver, amountSharesToRedeem);
            amountTokenOut = amountSharesToRedeem;
        }
    }

    /// @notice Returns the current exchange rate: USDS per 1 sUSDS, scaled by 1e18.
    /// @return res The ERC4626 convertToAssets(1 ether) rate, which grows as Sky savings yield accrues.
    function exchangeRate() public view override returns (uint256 res) {
        // ERC4626 convertToAssets(1 ether) returns how much USDS 1 sUSDS is worth.
        // The rate grows from 1.0 as Sky protocol yield is added to the savings rate.
        return IERC4626(yieldBearingToken()).convertToAssets(1 ether);
    }

    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        // USDS deposits mint sUSDS through the vault; sUSDS deposits are already shares.
        if (tokenIn == usds()) return IERC4626(yieldBearingToken()).previewDeposit(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        // Redeeming to USDS exits the ERC4626 vault; redeeming to sUSDS is a direct share transfer.
        if (tokenOut == usds()) return IERC4626(yieldBearingToken()).previewRedeem(amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    /// @notice Returns all tokens accepted for deposit: sUSDS and USDS.
    /// @return res Array of accepted deposit token addresses.
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), usds());
    }

    /// @notice Returns all tokens accepted for redemption: sUSDS and USDS.
    /// @return res Array of accepted redemption token addresses.
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), usds());
    }

    /// @notice Checks whether the token is accepted for deposit (sUSDS or USDS).
    /// @param token The token address to check.
    /// @return True if the token is a valid deposit token.
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == usds();
    }

    /// @notice Checks whether the token is accepted for redemption (sUSDS or USDS).
    /// @param token The token address to check.
    /// @return True if the token is a valid redemption token.
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == usds();
    }

    /// @notice Returns asset metadata: canonical asset is USDS, the constructor-injected underlying asset.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the USDS token
    /// @return assetDecimals always 18
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, usds(), 18);
    }
}
