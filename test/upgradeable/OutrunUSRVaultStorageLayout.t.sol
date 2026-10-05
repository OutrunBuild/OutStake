// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunUSRVaultUpgradeable} from "../../src/usr/OutrunUSRVaultUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {UAssetHelper} from "./helpers/UAssetHelper.sol";

/// @notice Freezes the persisted storage layout of the USR vault rate, share-price index, and
/// accrual clock.
///
/// `OutrunUSRVaultStorage` (ERC-7201 namespace `outrun.storage.OutrunUSRVault`) is the only own
/// variable of the contract, so it sits at the namespace base slot with one whole slot per field:
///
///     ns+0 = usrRate | ns+1 = accrualIndex | ns+2 = lastSettledAt
///
/// The assertions below pin the raw storage words behind production-path seeds (initialize at a
/// warped timestamp plus setUsrRate), so any reorder or insertion of the struct fields breaks this
/// test in CI instead of silently repricing every depositor's shares after an upgrade (accrualIndex
/// is the per-share price for the whole supply). See the IMMUTABLE STORAGE LAYOUT comment on
/// `OutrunUSRVaultUpgradeable.sol::OutrunUSRVaultStorage`.
contract OutrunUSRVaultStorageLayoutTest is UAssetHelper {
    function test_StorageLayoutIsPinned() external {
        address vaultOwner = address(0xB0B);

        // Warp first so initialize stamps a deterministic accrual baseline; the literal (not a
        // block.timestamp read) is asserted below, pinning the persisted value itself.
        vm.warp(1_700_000_000);

        OutrunUniversalAssetsUpgradeable uAsset = _deployUAsset(vaultOwner);
        OutrunUSRVaultUpgradeable vaultImplementation = new OutrunUSRVaultUpgradeable();
        OutrunUSRVaultUpgradeable vault = OutrunUSRVaultUpgradeable(
            ProxyTestHelper.deploy(
                address(vaultImplementation),
                abi.encodeCall(
                    OutrunUSRVaultUpgradeable.initialize, (address(uAsset), "Outrun suUSD", "suUSD", vaultOwner)
                )
            )
        );

        // Production-path seed: activate the rate in the same second as initialize, so the
        // pre-write settlement is a no-op (delta 0) and only usrRate moves.
        vm.prank(vaultOwner);
        vault.setUsrRate(5e15);

        bytes32 ns = _erc7201("outrun.storage.OutrunUSRVault");

        assertEq(uint256(vm.load(address(vault), ns)), 5e15, "usrRate must sit at ns+0");
        // accrualIndex starts at par (1e18) and the same-second settlement leaves it untouched.
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(ns) + 1))), 1e18, "accrualIndex must sit at ns+1");
        // lastSettledAt holds the initialize timestamp (setUsrRate settled zero elapsed seconds).
        assertEq(
            uint256(vm.load(address(vault), bytes32(uint256(ns) + 2))),
            1_700_000_000,
            "lastSettledAt must sit at ns+2 holding the initialize timestamp"
        );

        // ns+3 must stay empty — an inserted field shifts the non-zero lastSettledAt into this slot,
        // and a tail-appended field lands here once this flow (or a successor) writes it.
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(ns) + 3))), 0, "slot ns+3 must stay empty");
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
