// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IOutrunStakeManager} from "../../../src/position/interfaces/IOutrunStakeManager.sol";
import {IUniversalAssets} from "../../../src/assets/interfaces/IUniversalAssets.sol";
import {OutrunOFTUpgradeable} from "../../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice V2 upgrade mock for OutrunUniversalAssetsUpgradeable.
/// Standalone contract that replicates the production storage namespace so it
/// does not inherit from the production contract (which will use `layout at`).
/// Inherits the OFT chain for cross-chain view functions needed by upgrade validation.
contract MockUAssetUUPSV2 is OutrunOFTUpgradeable, UUPSUpgradeable {
    /// @dev Matches OutrunUniversalAssetsUpgradeable.OutrunUniversalAssetsStorage exactly.
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

/// @notice V2 upgrade mock for OutrunStakingPositionUpgradeable.
/// Standalone contract that replicates the production storage namespace so it
/// does not inherit from the production contract (which will use `layout at`).
contract MockPositionUUPSV2 is UUPSUpgradeable {
    /// @dev Matches OutrunStakingPositionUpgradeable.OutrunStakingPositionStorage exactly.
    struct OutrunStakingPositionStorage {
        address SY;
        uint8 canonicalAssetDecimals;
        uint8 uAssetDecimals;
        uint256 minStake;
        uint256 syTotalStaking;
        uint256 syWrapStaking;
        uint256 wrapUAssetDebt;
        address uAsset;
        address revenuePool;
        address keeper;
        mapping(uint256 positionId => IOutrunStakeManager.Position) positions;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunStakingPosition")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_STAKING_POSITION_STORAGE_LOCATION =
        0xd6ebf98633cd133425e2ec4f5c3d5a1e15a1a3a82505bb0f6ed101932bed5200;

    function _getStorage() private pure returns (OutrunStakingPositionStorage storage $) {
        assembly {
            $.slot := OUTRUN_STAKING_POSITION_STORAGE_LOCATION
        }
    }

    /// @notice Returns the total SY staked across all positions and the wrap pool.
    function syTotalStaking() public view returns (uint256) {
        return _getStorage().syTotalStaking;
    }

    /// @notice Returns the Standardized Yield token address.
    function SY() public view returns (address) {
        return _getStorage().SY;
    }

    /// @notice Returns version 2 to confirm the upgrade took effect.
    function version() external pure returns (uint256) {
        return 2;
    }

    function _authorizeUpgrade(address) internal override {}
}
