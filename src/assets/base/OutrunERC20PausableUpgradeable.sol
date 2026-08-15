// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {OutrunERC20Upgradeable} from "./OutrunERC20Upgradeable.sol";

/// @title Outrun pausable ERC20 base contract
/// @notice Upgradeable ERC20 base combining the Outrun ERC20 implementation with OpenZeppelin's Pausable and
///      Ownable; `_update` blocks every transfer while paused and only the owner may pause/unpause. Inherited by
///      SYBaseUpgradeable (base of every SY adapter) and by the omnichannel OutrunOFTUpgradeable.
abstract contract OutrunERC20PausableUpgradeable is OutrunERC20Upgradeable, PausableUpgradeable, OwnableUpgradeable {
    function __OutrunERC20Pausable_init(string memory name_, string memory symbol_, uint8 decimals_, address owner_)
        internal
        onlyInitializing
    {
        __OutrunERC20_init(name_, symbol_, decimals_);
        __Pausable_init();
        __Ownable_init(owner_);
    }

    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
