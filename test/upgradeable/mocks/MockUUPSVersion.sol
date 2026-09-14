// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IUniversalAssets} from "../../../src/assets/interfaces/IUniversalAssets.sol";
import {OutrunOFTUpgradeable} from "../../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice V2 upgrade mock for OutrunUniversalAssetsUpgradeable.
/// Standalone contract that replicates the production storage namespace so it
/// does not inherit from the production contract (which will use `layout at`).
/// Inherits the OFT chain for cross-chain view functions needed by upgrade validation.
contract MockUAssetUUPSV2 is OutrunOFTUpgradeable, UUPSUpgradeable {
    /// @dev Partial mirror of OutrunUniversalAssetsUpgradeable.OutrunUniversalAssetsStorage — mirrors only mintingStatusTable; does not mirror reserveMinters (appended mapping in same ERC-7201 namespace, so prior field slot is unchanged).
    struct OutrunUniversalAssetsStorage {
        mapping(address minter => IUniversalAssets.MintingStatus) mintingStatusTable;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunUniversalAssets")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_UNIVERSAL_ASSETS_STORAGE_LOCATION =
        0x2b82e9d5002467e1c5131297c0670c5f52b39ef4cd7112616d88ce4844484100;

    constructor(uint8 localDecimals, address lzEndpoint) OutrunOFTUpgradeable(localDecimals, lzEndpoint) {}

    function _getOutrunUniversalAssetsStorage() private pure returns (OutrunUniversalAssetsStorage storage $) {
        assembly {
            $.slot := OUTRUN_UNIVERSAL_ASSETS_STORAGE_LOCATION
        }
    }

    /// @notice Returns how many more uAsset the minter can mint before hitting its cap.
    ///      Called through the proxy after upgrade, so post-upgrade minter-ledger reads keep working.
    function checkMintableAmount(address minter) external view returns (uint256 amountInMintable) {
        IUniversalAssets.MintingStatus storage status = _getOutrunUniversalAssetsStorage().mintingStatusTable[minter];
        uint256 mintingCap = status.mintingCap;
        uint256 amountInMinted = status.amountInMinted;
        amountInMintable = mintingCap > amountInMinted ? mintingCap - amountInMinted : 0;
    }

    /// @notice Returns version 2 to confirm the upgrade took effect.
    function version() external pure returns (uint256) {
        return 2;
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @notice V2 upgrade mock with a different sharedDecimals override.
/// Used to test that the upgrade validator rejects a mismatched decimalConversionRate.
contract MockUAssetUUPSV2DifferentSharedDecimals is MockUAssetUUPSV2 {
    constructor(uint8 localDecimals, address lzEndpoint) MockUAssetUUPSV2(localDecimals, lzEndpoint) {}

    function sharedDecimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @notice V2 upgrade mock with different local decimals but the same conversion rate.
/// Used to isolate the local-decimals upgrade guard from the endpoint and conversion-rate guards.
contract MockUAssetUUPSV2DifferentLocalDecimals is MockUAssetUUPSV2 {
    constructor(uint8 localDecimals, address lzEndpoint) MockUAssetUUPSV2(localDecimals, lzEndpoint) {}

    function sharedDecimals() public pure override returns (uint8) {
        return 7;
    }
}

/// @notice V2 upgrade mock for OutrunStakingPositionUpgradeable.
/// Standalone UUPS target for the storage-layout tests: it must not inherit from the production
/// contract (which uses `layout at`), and the layout assertions read raw storage slots directly,
/// so it carries no state mirrors or accessors — only the upgrade authorization.
contract MockPositionUUPSV2 is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
}
