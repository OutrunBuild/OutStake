// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// SY adapter for Ethena sUSDe. The yield-bearing token is sUSDe (staked USDe — an ERC4626 vault).
// Deposit paths: (a) USDe → deposit into 4626 vault to get sUSDe shares, (b) existing sUSDe directly.
// Exchange rate from ERC4626 convertToAssets.

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";

// solhint-disable-next-line gas-small-strings
contract OutrunStakedUSDeSYUpgradeable layout at erc7201("outrun.storage.OutrunStakedUSDeSY") is SYBaseUpgradeable {
    struct OutrunStakedUSDeSYStorage {
        address USDE;
    }
    OutrunStakedUSDeSYStorage private outrunStakedUSDeSYStorage;

    /// @notice Initializes the SY adapter for Ethena sUSDe.
    /// @param owner_ The contract owner address.
    /// @param USDe_ Address of the USDe stablecoin.
    /// @param sUSDe_ Address of the sUSDe yield-bearing token (ERC4626 vault).
    function initialize(address owner_, address USDe_, address sUSDe_) external initializer {
        if (USDe_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Ethena sUSDe", "SY sUSDe", sUSDe_, owner_);
        outrunStakedUSDeSYStorage.USDE = USDe_;
    }

    /// @notice Returns the address of the USDe stablecoin.
    /// @return The USDe token address.
    function USDE() public view returns (address) {
        return outrunStakedUSDeSYStorage.USDE;
    }

    /// @param tokenIn The input token address (USDe or sUSDe).
    /// @param amountDeposited The amount of the input token deposited.
    /// @return amountSharesOut The amount of sUSDe shares received.
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _USDE = USDE();
        address _yieldBearingToken = yieldBearingToken();
        // Branch 1: deposit USDe into the ERC4626 sUSDe vault.
        // Branch 2: deposit sUSDe directly 1:1.
        if (tokenIn == _USDE) {
            _safeApproveInf(_USDE, _yieldBearingToken);
            amountSharesOut = IERC4626(_yieldBearingToken).deposit(amountDeposited, address(this));
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    // Redeem by transferring sUSDe directly. Note: this does NOT withdraw from the 4626 vault —
    // the receiver gets sUSDe which they can redeem for USDe on their own.
    /// @param receiver The address receiving the sUSDe tokens.
    /// @param amountSharesToRedeem The amount of sUSDe shares to redeem.
    /// @return The amount of sUSDe sent to the receiver.
    function _redeem(address receiver, address, uint256 amountSharesToRedeem) internal override returns (uint256) {
        _transferOut(yieldBearingToken(), receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    // This rate grows as protocol yield is added to the vault.
    /// @notice Returns the USDe amount for 1 sUSDe using ERC4626 convertToAssets.
    /// @return res The amount of USDe equivalent to 1 sUSDe (scaled by 1e18).
    function exchangeRate() public view override returns (uint256 res) {
        return IERC4626(yieldBearingToken()).convertToAssets(1 ether);
    }

    /// @notice Previews the amount of sUSDe shares that would be received for depositing a given token.
    /// @param tokenIn The input token address.
    /// @param amountTokenToDeposit The amount of the input token to deposit.
    /// @return The expected amount of sUSDe shares received.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        if (tokenIn == USDE()) return IERC4626(yieldBearingToken()).previewDeposit(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    /// @notice Previews the amount of output tokens (always sUSDe) that would be received for redeeming shares.
    /// @param amountSharesToRedeem The amount of sUSDe shares to redeem.
    /// @return The expected amount of output tokens (1:1 with shares).
    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    /// @notice Returns the list of accepted input tokens.
    /// @return res Array containing sUSDe and USDe addresses.
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), USDE());
    }

    /// @notice Returns the list of accepted output tokens.
    /// @return res Array containing only sUSDe.
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @notice Checks whether a token is accepted as input.
    /// @param token The token address to check.
    /// @return True if the token is sUSDe or USDe.
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == USDE();
    }

    /// @notice Checks whether a token is accepted as output.
    /// @param token The token address to check.
    /// @return True if the token is sUSDe.
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @notice Returns the asset type and details this SY represents.
    /// @return assetType Always TOKEN.
    /// @return assetAddress The USDe token address.
    /// @return assetDecimals Always 18.
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, USDE(), 18);
    }
}
