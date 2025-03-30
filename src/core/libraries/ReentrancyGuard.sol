// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @dev Outrun's ReentrancyGuard implementation, support transient variable.
 */
abstract contract ReentrancyGuard {
    uint256 private locked = 1;

    modifier nonReentrant() {
        require(locked == 1, "ReentrancyGuardReentrantCall");
        locked = 2;
        _;
        locked = 1;
    }
}
