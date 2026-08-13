// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMockSUSDS} from "../../support/MockSUSDS.sol";
import {MockOutrunERC20SYUpgradeableBase} from "./MockOutrunERC20SYUpgradeableBase.sol";

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockOutrunSUSDSSYUpgradeable is MockOutrunERC20SYUpgradeableBase {
    function initialize(address owner_, address mockUSDC_, address sUSDS_, address oracle_) external initializer {
        __MockOutrunERC20SY_init(owner_, mockUSDC_, sUSDS_, oracle_, "SY Sky sUSDS", "SY sUSDS");
    }

    function _wrap(address ybt, uint256 amount) internal override returns (uint256) {
        return IMockSUSDS(ybt).wrap(amount);
    }

    function _unwrap(address ybt, uint256 amount) internal override returns (uint256) {
        return IMockSUSDS(ybt).unwrap(amount);
    }
}
