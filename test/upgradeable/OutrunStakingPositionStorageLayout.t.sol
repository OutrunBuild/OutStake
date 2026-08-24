// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {MockPositionUUPSV2} from "./mocks/MockUUPSVersion.sol";

contract OutrunStakingPositionStorageLayoutTest is PositionStackTestBase {
    function test_DecimalsShareTheSyStorageSlot() external {
        _deployPositionStack();

        bytes32 storageSlot = _erc7201("outrun.storage.OutrunStakingPosition");
        uint256 storageWord = uint256(vm.load(address(position), storageSlot));

        // The storage word is intentionally packed; each cast reads fixed low bits of the same slot.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(storageWord)), address(sy));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(storageWord >> 160), 18);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(storageWord >> 168), 18);
    }

    /// @notice Pins the full ERC-7201 layout for G-022: frozen decimals must survive upgrades,
    /// so field order, width, and count are frozen. Any reorder/insertion would misread
    /// canonicalAssetDecimals/uAssetDecimals and silently mis-scale by 1e12.
    function test_StorageLayoutIsPinnedWithBoundsAndMapping() external {
        _deployPositionStack();

        bytes32 baseSlot = _erc7201("outrun.storage.OutrunStakingPosition");

        // slot0: SY (20 bytes) + canonicalAssetDecimals + uAssetDecimals packed
        uint256 slot0 = uint256(vm.load(address(position), baseSlot));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(slot0)), address(sy), "SY must sit in low 160 bits of slot0");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(slot0 >> 160), 18, "canonicalAssetDecimals must sit at byte 20");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(slot0 >> 168), 18, "uAssetDecimals must sit at byte 21");

        // slot1: minStake
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 1))), 1, "minStake slot1");
        // slot2: syTotalStaking (0 before any stake)
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 2))), 0, "syTotalStaking slot2");
        // slot3: syWrapStaking
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 3))), 0, "syWrapStaking slot3");
        // slot4: wrapUAssetDebt
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 4))), 0, "wrapUAssetDebt slot4");
        // slot5: uAsset address
        assertEq(
            address(uint160(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 5))))),
            address(uAsset),
            "uAsset slot5"
        );
        // slot6: revenuePool
        assertEq(
            address(uint160(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 6))))),
            revenuePool,
            "revenuePool slot6"
        );
        // slot7: keeper
        assertEq(
            address(uint160(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 7))))),
            keeper,
            "keeper slot7"
        );
        // slot8: deprecated minExchangeRate must stay 0
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8))), 0, "deprecated minExchangeRate slot8"
        );
        // slot9: deprecated maxExchangeRate must stay 0
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 9))), 0, "deprecated maxExchangeRate slot9"
        );
        // slot10: mapping positions base slot must be empty before any position
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 10))),
            0,
            "positions mapping slot10 must stay empty"
        );
        // slot11: must stay empty — any appended field would spill here
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 11))), 0, "slot11 must stay empty");
    }

    /// @notice Deprecated bounds slots (G-020) are reserved at slot8/9 and must stay zero and not be reused.
    function test_DeprecatedBoundsSlotsAreReservedAndZero() external {
        _deployPositionStack();
        bytes32 baseSlot = _erc7201("outrun.storage.OutrunStakingPosition");
        // Deprecated slots must remain zero after init and must not be repurposed
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8))),
            0,
            "deprecated minExchangeRate must stay 0 at slot8"
        );
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 9))),
            0,
            "deprecated maxExchangeRate must stay 0 at slot9"
        );
        // read deprecated slots via vm.load before upgrade
        uint256 depMinBefore = uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8)));
        uint256 depMaxBefore = uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 9)));
        MockPositionUUPSV2 v2 = new MockPositionUUPSV2();
        vm.prank(owner);
        position.upgradeToAndCall(address(v2), "");
        uint256 depMinAfter = uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8)));
        uint256 depMaxAfter = uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 9)));
        assertEq(depMinAfter, depMinBefore, "deprecated slot8 must survive upgrade unchanged");
        assertEq(depMaxAfter, depMaxBefore, "deprecated slot9 must survive upgrade unchanged");
        assertEq(depMinAfter, 0, "deprecated slot8 still zero after upgrade");
        assertEq(depMaxAfter, 0, "deprecated slot9 still zero after upgrade");
        // Use mock deprecated getter as well
        (uint256 depMinMock, uint256 depMaxMock) = MockPositionUUPSV2(address(position)).deprecatedBounds();
        assertEq(depMinMock, 0);
        assertEq(depMaxMock, 0);
        // Mapping integrity: syTotalStaking remains 0 when no stakes done
        assertEq(MockPositionUUPSV2(address(position)).syTotalStaking(), 0);
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
