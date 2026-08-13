// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMockAUSDC} from "../../support/MockAUSDC.sol";
import {MockOutrunERC20SYUpgradeableBase} from "./MockOutrunERC20SYUpgradeableBase.sol";

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockOutrunAUSDCSYUpgradeable is MockOutrunERC20SYUpgradeableBase {
    function initialize(address owner_, address mockUSDC_, address aUSDC_, address oracle_) external initializer {
        __MockOutrunERC20SY_init(owner_, mockUSDC_, aUSDC_, oracle_, "SY Aave aUSDC", "SY aUSDC");
    }

    function _wrap(address ybt, uint256 amount) internal override returns (uint256) {
        return IMockAUSDC(ybt).wrap(amount);
    }

    function _unwrap(address ybt, uint256 amount) internal override returns (uint256) {
        return IMockAUSDC(ybt).unwrap(amount);
    }
}
