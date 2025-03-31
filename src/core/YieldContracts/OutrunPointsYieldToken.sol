//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { OutrunERC6909 } from "../common/OutrunERC6909.sol";
import { Initializable } from "../libraries/Initializable.sol";
import { IOutrunPointsYieldToken } from "./interfaces/IOutrunPointsYieldToken.sol";

/**
 * @title Outrun Staking Position
 */
contract OutrunPointsYieldToken is IOutrunPointsYieldToken, OutrunERC6909, Initializable, Pausable, Ownable {
    address public SP;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _owner
    ) OutrunERC6909(_name, _symbol, _decimals) Ownable(_owner) {}

    function initialize(address _SP) external override onlyOwner initializer {
        SP = _SP;
    }

    function mint(address receiver, uint256 id, uint256 amount) external whenNotPaused override {
        require(msg.sender == SP, PermissionDenied());
        _mint(receiver, id, amount);
    }
}
