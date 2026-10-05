// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {UAssetHelper} from "./helpers/UAssetHelper.sol";

/// @notice Freezes the persisted storage layout of the uAsset minter debt ledger and the
/// reserve-minter registry.
///
/// `OutrunUniversalAssetsStorage` (ERC-7201 namespace `outrun.storage.OutrunUniversalAssets`) holds
/// the two mappings that must survive UUPS upgrades:
///
///     ns+0 = mintingStatusTable mapping base (each minter's value slot keccak256(abi.encode(minter, ns+0));
///            the MintingStatus value is one packed slot: mintingCap in the lower 128 bits, amountInMinted in the upper 128 bits)
///     ns+1 = reserveMinters mapping base (each minter's bool value slot keccak256(abi.encode(minter, ns+1)))
///
/// The assertions below pin the raw storage words behind production-path seeds (setMintingCap, mint,
/// setReserveMinter), so any reorder, resize, or insertion of the struct fields breaks this test in CI instead
/// of silently misreading the minter debt ledger or forging reserve-minting authorization after an
/// upgrade. See the IMMUTABLE STORAGE LAYOUT comment on
/// `OutrunUniversalAssetsUpgradeable.sol::OutrunUniversalAssetsStorage`.
contract OutrunUniversalAssetsStorageLayoutTest is UAssetHelper {
    function test_StorageLayoutIsPinned() external {
        address owner = address(0xA11CE);
        address minter = address(0xB0B);
        address receiver = address(0xCAFE);
        address reserveMinter = address(0xF5E5);

        OutrunUniversalAssetsUpgradeable uAsset = _deployUAsset(owner);

        // Production-path seeds only: the owner grants a 100e18 cap and registers an independent
        // reserve minter, then the minter mints 40e18 of debt against that cap. Each asserted value
        // (100e18, 40e18, 1, 0) is mutually distinct, so any field swap, shift, or resize breaks at
        // least one assertion.
        vm.startPrank(owner);
        uAsset.setMintingCap(minter, 100e18);
        uAsset.setReserveMinter(reserveMinter, true);
        vm.stopPrank();
        vm.prank(minter);
        uAsset.mint(receiver, 40e18);

        bytes32 ns = _erc7201("outrun.storage.OutrunUniversalAssets");

        // Mapping bases sit at ns+0/ns+1 and are empty by construction (mappings store only value
        // slots), mirroring the empty-base assertion on the position mapping.
        assertEq(vm.load(address(uAsset), ns), bytes32(0), "mintingStatusTable mapping base must sit empty at ns+0");
        assertEq(
            vm.load(address(uAsset), bytes32(uint256(ns) + 1)),
            bytes32(0),
            "reserveMinters mapping base must sit empty at ns+1"
        );

        // mintingStatusTable[minter]: one packed value slot — mintingCap in the lower 128 bits,
        // amountInMinted in the upper 128 bits (declaration order in IUniversalAssets.sol).
        bytes32 debtBaseSlot = keccak256(abi.encode(minter, ns));
        assertEq(
            vm.load(address(uAsset), debtBaseSlot),
            bytes32(uint256((40e18 << 128) | 100e18)),
            "MintingStatus must pack into one value slot at keccak256(minter, ns+0): mintingCap low half, amountInMinted high half"
        );
        assertEq(
            vm.load(address(uAsset), bytes32(uint256(debtBaseSlot) + 1)),
            bytes32(0),
            "MintingStatus must not spill past its single packed value slot"
        );

        // reserveMinters[reserveMinter]: a registered bool persists as 1 in its own value slot keyed
        // off the ns+1 base.
        bytes32 reserveSlot = keccak256(abi.encode(reserveMinter, bytes32(uint256(ns) + 1)));
        assertEq(
            uint256(vm.load(address(uAsset), reserveSlot)),
            1,
            "reserveMinters bool must sit at keccak256(reserveMinter, ns+1)"
        );

        // ns+2 must stay empty — a tail-appended value-type field written by this flow spills here.
        // A tail-appended mapping lands here as an empty base (its values live in the hash domain),
        // leaving this sentinel silent — an allowed frozen-contract append. Insertion before
        // reserveMinters shifts its base and is caught by the value-slot assertions above.
        assertEq(uint256(vm.load(address(uAsset), bytes32(uint256(ns) + 2))), 0, "slot ns+2 must stay empty");
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
