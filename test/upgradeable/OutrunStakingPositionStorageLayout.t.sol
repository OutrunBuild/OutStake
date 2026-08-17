// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";

contract OutrunStakingPositionStorageLayoutTest is PositionStackTestBase {
    function test_DecimalsShareTheSyStorageSlot() external {
        _deployPositionStack();

        bytes32 storageSlot = _erc7201("outrun.storage.OutrunStakingPosition");
        uint256 storageWord = uint256(vm.load(address(position), storageSlot));

        assertEq(address(uint160(storageWord)), address(sy));
        assertEq(uint8(storageWord >> 160), 18);
        assertEq(uint8(storageWord >> 168), 18);
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
