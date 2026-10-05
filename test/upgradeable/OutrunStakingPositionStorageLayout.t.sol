// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {MockPositionUUPSV2} from "./mocks/MockUUPSVersion.sol";
import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";

contract OutrunStakingPositionStorageLayoutTest is PositionStackTestBase {
    MockGenesisLauncher internal genesisLauncher;

    /// @notice Pins the v1 ERC-7201 layout: frozen decimals and packed slot0 must survive
    /// upgrades, and every slot from 0 through the positions mapping must sit at its pinned
    /// offset. Any reorder/insertion would misread canonicalAssetDecimals/uAssetDecimals and
    /// silently mis-scale by 1e12, or misroute position entries. v1 deleted the
    /// LTV/premium/genesis-multiplier fields and the surplus mapping (pre-deployment layout
    /// reset, no migration).
    /// Layout: slot0 packs SY + both decimals; slot1 uAsset; slot2 protocolTreasury; slot3 minStake;
    /// slot4 duty; slot5 rate; slot6 rateLastSettledAt; slot7 genesisLauncher; slot8 positions
    /// mapping. The tail anchors observe live state on purpose: slot7 is anchored on the wired
    /// launcher address and the mapping on a live entry's value slots, because a mapping stores
    /// only value slots (its base slot is empty by construction) and a zero-default tail field
    /// pins nothing.
    function test_StorageLayoutIsPinned() external {
        // Warp to a distinctive init timestamp before deploy: minStake defaults to 1 and the
        // chain starts at timestamp 1, so without the warp slot3 and slot6 would hold the same
        // value and a minStake <-> rateLastSettledAt swap could pass both anchors unnoticed.
        vm.warp(1_234_567_890);
        _deployPositionStack();
        uint256 positionId = _wireLauncherAndOpenFirstPosition();

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
        // slot7 must hold the wired launcher, not the zero default: a zero-anchored tail field
        // passes under any tail mutation. A tail reorder (launcher <-> mapping) or any insertion
        // ahead of the mapping displaces this address and trips the anchor.
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 7))),
            uint256(uint160(address(genesisLauncher))),
            "genesisLauncher slot7 holds the wired launcher"
        );
        // Mappings store only value slots, so the base slot is empty by construction and pins
        // nothing by itself; the mapping's placement is pinned by the entry value-slot anchors
        // below.
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 8))), 0, "positions mapping slot8");
        // slot9 must stay empty — a tail-appended field written by a live flow spills here. A
        // zero-default tail append stays silent, but it displaces no persisted word (the mapping
        // occupies hash space from its base); insertions ahead of the mapping are caught by the
        // entry anchors below.
        assertEq(uint256(vm.load(address(position), bytes32(uint256(baseSlot) + 9))), 0, "slot9 must stay empty");

        // positions[1] entry value slots: the owner word anchors the mapping's hash placement,
        // and the syStaked word additionally pins the entry head's field order. Any base-slot
        // shift or head-field reorder breaks at least one word.
        bytes32 entrySlot = keccak256(abi.encode(positionId, uint256(baseSlot) + 8));
        assertEq(
            uint256(vm.load(address(position), entrySlot)),
            uint256(uint160(user)),
            "positions entry owner sits at keccak256(id, base+8)"
        );
        assertEq(
            uint256(vm.load(address(position), bytes32(uint256(entrySlot) + 1))),
            10e18,
            "positions entry syStaked sits one word past the entry head"
        );
    }

    /// @notice A live positions entry survives an upgrade unchanged: the entry's owner value
    /// slot, addressed through the mapping's hash placement, holds the same word before and
    /// after the code swap. Anchoring on the entry word (not the structurally-empty mapping
    /// base slot) gives the comparison a state that can actually change.
    function test_MappingEntrySlotSurvivesUpgrade() external {
        _deployPositionStack();
        uint256 positionId = _wireLauncherAndOpenFirstPosition();
        bytes32 baseSlot = _erc7201("outrun.storage.OutrunStakingPosition");
        bytes32 entrySlot = keccak256(abi.encode(positionId, uint256(baseSlot) + 8));
        assertEq(
            uint256(vm.load(address(position), entrySlot)),
            uint256(uint160(user)),
            "positions entry owner must be live before the upgrade"
        );

        MockPositionUUPSV2 v2 = new MockPositionUUPSV2();
        vm.prank(owner);
        position.upgradeToAndCall(address(v2), "");

        assertEq(
            uint256(vm.load(address(position), entrySlot)),
            uint256(uint160(user)),
            "positions entry value slot must survive the upgrade unchanged"
        );
    }

    /// @notice Seeds the non-zero tail state the layout anchors depend on: wires the genesis
    /// launcher (slot7) and opens the first position so the mapping holds a live entry.
    /// @dev The shared fixture deploys the stack only — launcher unwired, no positions — which
    ///      would leave every tail assertion anchored on zero defaults.
    function _wireLauncherAndOpenFirstPosition() internal returns (uint256 positionId) {
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));

        _mintSyFor(address(token), address(sy), user, 10e18);
        vm.startPrank(user);
        sy.approve(address(position), 10e18);
        positionId = position.stakeForGenesis(10e18, user, 42, 0);
        vm.stopPrank();
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
