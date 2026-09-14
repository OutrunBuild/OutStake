// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {IStandardizedYield} from "../../interfaces/IStandardizedYield.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";

/// @title Outrun Ethena sUSDe SY adapter
/// @notice SY adapter for Ethena sUSDe. The yield-bearing token is sUSDe (staked USDe — an ERC4626 vault).
///      Deposit paths: (a) USDe → deposit into 4626 vault to get sUSDe shares, (b) existing sUSDe directly.
///      Exchange rate from ERC4626 convertToAssets.
// solhint-disable-next-line gas-small-strings
contract OutrunStakedUSDeSYUpgradeable layout at erc7201("outrun.storage.OutrunStakedUSDeSY") is SYBaseUpgradeable {
    struct OutrunStakedUSDeSYStorage {
        address usde;
    }
    OutrunStakedUSDeSYStorage private outrunStakedUSDeSYStorage;

    /// @notice Initializes the SY adapter for Ethena sUSDe.
    /// @param owner_ The contract owner address.
    /// @param usde_ Address of the USDe stablecoin.
    /// @param sUSDe_ Address of the sUSDe yield-bearing token (ERC4626 vault).
    function initialize(address owner_, address usde_, address sUSDe_) external initializer {
        if (usde_ == address(0)) revert SYZeroAddress();
        __SYBase_init("SY Ethena sUSDe", "SY sUSDe", sUSDe_, owner_);
        outrunStakedUSDeSYStorage.usde = usde_;
    }

    /// @notice Returns the address of the USDe stablecoin.
    function usde() public view returns (address) {
        return outrunStakedUSDeSYStorage.usde;
    }

    /// @param tokenIn The input token address (USDe or sUSDe).
    /// @param amountDeposited The amount of the input token deposited.
    /// @return amountSharesOut The amount of sUSDe shares received (minted 1:1 as SY shares; 1 SY = 1 sUSDe).
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _usde = usde();
        address _yieldBearingToken = yieldBearingToken();
        // Branch 1: deposit USDe into the ERC4626 sUSDe vault.
        // Branch 2: deposit sUSDe directly 1:1.
        if (tokenIn == _usde) {
            // Exact per-call approval: the vault deposit pulls only this deposit's USDe amount, so
            // no standing grant remains even if a misdirected transfer strands transit tokens in the SY.
            _safeApprove(_usde, _yieldBearingToken, amountDeposited);
            amountSharesOut = IERC4626(_yieldBearingToken).deposit(amountDeposited, address(this));
        } else {
            amountSharesOut = amountDeposited;
        }
    }

    // Redeem by transferring sUSDe directly. Note: this does NOT withdraw from the 4626 vault —
    // the receiver gets sUSDe which they can redeem for USDe on their own.
    /// @param receiver The address receiving the sUSDe tokens.
    /// @param amountSharesToRedeem The amount of sUSDe shares to redeem (1 SY = 1 sUSDe).
    /// @return The amount of sUSDe sent to the receiver.
    function _redeem(address receiver, address, uint256 amountSharesToRedeem) internal override returns (uint256) {
        _transferOut(yieldBearingToken(), receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    /// @notice Returns the USDe amount for 1 sUSDe using ERC4626 convertToAssets.
    /// @return res The amount of USDe equivalent to 1 sUSDe (scaled by 1e18).
    /// @dev Fail-closed backing reconciliation: reverts with InsufficientBacking when this adapter's
    ///      own sUSDe balance falls below the outstanding SY supply (see _revertIfBackingBelowShares).
    function exchangeRate() public view override returns (uint256 res) {
        _revertIfBackingBelowShares();
        return IERC4626(yieldBearingToken()).convertToAssets(1 ether);
    }

    /// @notice Previews the amount of sUSDe shares that would be received for depositing a given token.
    /// @dev USDe path forwards to `IERC4626(yieldBearingToken()).previewDeposit` (floor quote).
    ///      Standard ERC4626 `previewDeposit` may over-quote the shares actually minted by
    ///      `IERC4626(yieldBearingToken()).deposit` by at most 1 wei depending on the vault's
    ///      virtual offset (`totalSupply + 10 ** offset` / `totalAssets + 1`) and on inter-block
    ///      `totalAssets` drift (Ethena `StakedUSDe.totalAssets()` vests `balance - unvested` over 8h).
    ///      Callers should not use the preview verbatim as `SYBaseUpgradeable.sol::deposit` `minSharesOut`;
    ///      leave 1 wei headroom (e.g. `preview > 1 ? preview - 1 : preview`) or a small bps margin.
    ///      No local vault-math fix is applied here; the bound is an ERC4626 preview-vs-execution caveat.
    /// @param tokenIn The input token address.
    /// @param amountTokenToDeposit The amount of the input token to deposit.
    /// @return The expected amount of sUSDe shares received.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        if (tokenIn == usde()) return IERC4626(yieldBearingToken()).previewDeposit(amountTokenToDeposit);
        return amountTokenToDeposit;
    }

    /// @notice Previews the amount of output tokens (always sUSDe) that would be received for redeeming shares.
    /// @param amountSharesToRedeem The amount of sUSDe shares to redeem.
    /// @return The expected amount of output tokens (1:1 with shares).
    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    /// @inheritdoc IStandardizedYield
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken(), usde());
    }

    /// @inheritdoc IStandardizedYield
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken() || token == usde();
    }

    /// @inheritdoc IStandardizedYield
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @inheritdoc IStandardizedYield
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, usde(), 18);
    }
}
