// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {PSMMockReserveERC20} from "../psm/mocks/PSMMocks.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {UAssetHelper} from "./helpers/UAssetHelper.sol";

/// @notice Freezes the persisted storage layout of the PSM swap bindings, fees, and net-minted
/// ledger.
///
/// `OutrunPSMStorage` (ERC-7201 namespace `outrun.storage.OutrunPSM`) is the only own variable of the
/// contract, so it sits at the namespace base slot with one whole slot per field:
///
///     ns+0 = uAsset | ns+1 = reserveToken | ns+2 = feeRecipient | ns+3 = tin
///     ns+4 = tout | ns+5 = stockCap | ns+6 = netUAssetMinted
///
/// The assertions below pin the raw storage words behind production-path seeds (initialize plus one
/// mint through the bound reserve), so any reorder or shift of the struct fields breaks this test in
/// CI instead of silently rewiring the swap route, the fees, and the stock cap after an upgrade. The
/// address slots also pin their upper 96 bits to zero: a field of at most 96 bits inserted after an
/// address packs into that slot's free high bytes without moving later fields, and any write to it
/// fails the high-bits assertion; a packed field never written is invisible to raw-slot pinning,
/// moves no persisted word, and remains an allowed frozen-contract append.
/// See the IMMUTABLE STORAGE LAYOUT comment on `OutrunPSMUpgradeable.sol::OutrunPSMStorage`.
contract OutrunPSMStorageLayoutTest is UAssetHelper {
    function test_StorageLayoutIsPinned() external {
        address psmOwner = address(0xB0B);
        address feeRecipient = address(0xFEE);
        address alice = address(0xCAFE);

        OutrunUniversalAssetsUpgradeable uAsset = _deployUAsset(psmOwner);
        PSMMockReserveERC20 reserve = new PSMMockReserveERC20("Mock Reserve", "MRSV", 18);

        OutrunPSMUpgradeable psmImplementation = new OutrunPSMUpgradeable();
        OutrunPSMUpgradeable psm = OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(psmImplementation),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize,
                    // Mutually distinct per-slot values: two distinct contract addresses, two
                    // distinct EOA addresses, and fees/cap/net-minted that all differ.
                    (address(uAsset), address(reserve), psmOwner, feeRecipient, 7e18, 1e15, 2e15)
                )
            )
        );

        // Wiring: the uAsset owner registers the PSM so its mint can take the reserve-mint path.
        vm.prank(psmOwner);
        uAsset.setReserveMinter(address(psm), true);

        // Production-path seed for netUAssetMinted: an 18-dec reserve makes face value 1:1, so
        // minting 2e18 with tin = 1e15 (0.1%) outputs 2e18 * (1e18 - 1e15) / 1e18 = 1.998e18.
        reserve.mint(alice, 1_000e18);
        vm.startPrank(alice);
        reserve.approve(address(psm), type(uint256).max);
        psm.mint(alice, 2e18);
        vm.stopPrank();

        bytes32 ns = _erc7201("outrun.storage.OutrunPSM");

        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(uint256(vm.load(address(psm), ns)))), address(uAsset), "uAsset must sit at ns+0");
        // Packed-insertion probe: a field of at most 96 bits appended here packs into this slot's
        // high bytes without shifting later fields, so any write to it makes the shifted word non-zero.
        assertEq(
            uint256(vm.load(address(psm), ns)) >> 160,
            0,
            "uAsset slot high bytes must stay empty - a packed-in small field breaks this"
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(
            address(uint160(uint256(vm.load(address(psm), bytes32(uint256(ns) + 1))))),
            address(reserve),
            "reserveToken must sit at ns+1"
        );
        assertEq(
            uint256(vm.load(address(psm), bytes32(uint256(ns) + 1))) >> 160,
            0,
            "reserveToken slot high bytes must stay empty - a packed-in small field breaks this"
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(
            address(uint160(uint256(vm.load(address(psm), bytes32(uint256(ns) + 2))))),
            feeRecipient,
            "feeRecipient must sit at ns+2"
        );
        assertEq(
            uint256(vm.load(address(psm), bytes32(uint256(ns) + 2))) >> 160,
            0,
            "feeRecipient slot high bytes must stay empty - a packed-in small field breaks this"
        );
        assertEq(uint256(vm.load(address(psm), bytes32(uint256(ns) + 3))), 1e15, "tin must sit at ns+3");
        assertEq(uint256(vm.load(address(psm), bytes32(uint256(ns) + 4))), 2e15, "tout must sit at ns+4");
        assertEq(uint256(vm.load(address(psm), bytes32(uint256(ns) + 5))), 7e18, "stockCap must sit at ns+5");
        assertEq(
            uint256(vm.load(address(psm), bytes32(uint256(ns) + 6))),
            1_998e15,
            "netUAssetMinted must sit at ns+6 holding the minted net amount"
        );

        // ns+7 must stay empty — an inserted field shifts the non-zero netUAssetMinted into this slot,
        // and a tail-appended field lands here once this flow (or a successor) writes it.
        assertEq(uint256(vm.load(address(psm), bytes32(uint256(ns) + 7))), 0, "slot ns+7 must stay empty");
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
