// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {MockLzEndpoint} from "../mocks/OFTMocks.sol";
import {ProxyTestHelper} from "./ProxyTestHelper.sol";

/// @title UAssetHelper
/// @notice Shared uAsset deployment fixture deduplicated from PSM and USR suites.
/// @dev Suites previously duplicated `MockLzEndpoint + new OutrunUniversalAssetsUpgradeable(18, endpoint) + Proxy deploy + initialize(name,symbol,owner)` in their own setUp; a parameter change missed in one copy left suites silently asserting against diverged stacks. Centralising here keeps a single implementation and a single canonical tuple (name/symbol/decimals), so a name/symbol/decimals change is one edit.
abstract contract UAssetHelper is Test {
    /// @dev Single source for the canonical tuple: renaming is one edit here.
    string internal constant CANONICAL_NAME = "Outrun Universal USD";
    string internal constant CANONICAL_SYMBOL = "UUSD";

    /// @notice Deploys a proxy-backed uAsset with the canonical wiring: "Outrun Universal USD"/"UUSD", 18 decimals.
    /// @dev Canonical 18-decimals form; delegates to the decimals overload, which holds the single wiring block.
    /// @param owner_ Owner for `OutrunUniversalAssetsUpgradeable.initialize`.
    /// @return uAsset Proxy instance wired to a fresh mock LZ endpoint.
    function _deployUAsset(address owner_) internal returns (OutrunUniversalAssetsUpgradeable uAsset) {
        return _deployUAsset(owner_, 18);
    }

    /// @notice Deploys a proxy-backed uAsset with the canonical name/symbol and custom decimals.
    /// @param owner_ Owner for `OutrunUniversalAssetsUpgradeable.initialize`.
    /// @param decimals_ Decimals for the uAsset implementation.
    /// @return uAsset Proxy instance wired to a fresh mock LZ endpoint.
    function _deployUAsset(address owner_, uint8 decimals_) internal returns (OutrunUniversalAssetsUpgradeable uAsset) {
        MockLzEndpoint endpoint = new MockLzEndpoint();
        OutrunUniversalAssetsUpgradeable uAssetImplementation =
            new OutrunUniversalAssetsUpgradeable(decimals_, address(endpoint));
        uAsset = OutrunUniversalAssetsUpgradeable(
            ProxyTestHelper.deploy(
                address(uAssetImplementation),
                abi.encodeCall(OutrunUniversalAssetsUpgradeable.initialize, (CANONICAL_NAME, CANONICAL_SYMBOL, owner_))
            )
        );
    }
}
