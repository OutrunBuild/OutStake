// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {MockPositionUUPSV2} from "./mocks/MockUUPSVersion.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";

contract OutrunStakingPositionStorageLayoutTest is PositionStackTestBase {
    /// @notice Pins the v1 ERC-7201 layout: frozen decimals and packed slot0 must survive
    /// upgrades, and the mappings must sit at their pinned base slots. Any reorder/insertion would
    /// misread canonicalAssetDecimals/uAssetDecimals and silently mis-scale by 1e12, or misroute
    /// position entries. v1 deleted the LTV/premium/genesis-multiplier fields and the surplus
    /// mapping (pre-deployment layout reset, no migration).
    /// Layout: slot0 packs SY + both decimals; slot1 uAsset; slot2 protocolTreasury; slot3 minStake;
    /// slot4 duty; slot5 rate; slot6 rateLastSettledAt; slot7 genesisLauncher; slot8 positions
    /// mapping.
    function test_StorageLayoutIsPinned() external {
        _deployPositionStack();

        bytes32 baseSlot = _erc7201("outrun.storage.OutrunStakingPosition");

        uint256 slot0 = uint256(vm.load(address(position), baseSlot));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(slot0)), address(sy), "SY must sit in low 160 bits of slot0");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(slot0 >> 160), 18, "canonicalAssetDecimals must sit at byte 20");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(slot0 >> 168), 18, "uAssetDecimals must sit at byte 21");

        assertEq(
            address(uint160(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 1))))),
            address(uAsset),
            "uAsset slot1"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 2))))),
            treasury,
            "protocolTreasury slot2"
        );
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 3))), 1, "minStake slot3");
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 4))), SPTestDefaults.DUTY, "duty slot4");
        // Rate slot5 starts at RAY: the cumulative rate is 1e27 at initialize and compounds from there.
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 5))), 1e27, "rate slot5");
        // The init timestamp is the first settlement baseline, so slot6 is non-zero from birth.
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 6))),
            block.timestamp,
            "rateLastSettledAt slot6 holds the init timestamp"
        );
        // genesisLauncher slot7 is zero from birth (not an initialize parameter; wired post-deploy
        // via setGenesisLauncher, zero = stakeForGenesis entry disabled).
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 7))), 0, "genesisLauncher slot7 zero");
        // Mapping base slot must be empty before any entry exists.
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8))), 0, "positions mapping slot8");
        // slot9 must stay empty — any appended field would spill here.
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 9))), 0, "slot9 must stay empty");
    }

    /// @notice Positions mapping base slot survives an upgrade unchanged.
    function test_MappingSlotsSurviveUpgrade() external {
        _deployPositionStack();
        bytes32 baseSlot = _erc7201("outrun.storage.OutrunStakingPosition");
        uint256 positionsSlotBefore = uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8)));
        assertEq(positionsSlotBefore, 0, "positions mapping slot8 must be empty before upgrade");

        MockPositionUUPSV2 v2 = new MockPositionUUPSV2();
        vm.prank(owner);
        position.upgradeToAndCall(address(v2), "");

        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8))),
            positionsSlotBefore,
            "positions mapping slot8 must survive upgrade unchanged"
        );
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
