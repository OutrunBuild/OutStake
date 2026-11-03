// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.38;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AaveAdapterLib} from "../../../src/libraries/AaveAdapterLib.sol";
import {WadRayMath} from "../../../src/libraries/WadRayMath.sol";

/// @notice Mock contract exposing guarded actions for ReentrancyGuard tests.
contract MockGuarded is ReentrancyGuardTransient {
    function guardedAction() external nonReentrant returns (uint256) {
        return 42;
    }

    function tryReenter() external nonReentrant {
        this.guardedAction(); // should revert
    }
}

/// @notice Helper contract that forwards calls to WadRayMath so reverts are testable via external calls.
contract WadRayMathHelper {
    using WadRayMath for uint256;

    function rayDivZero(uint256 a) external pure {
        a.rayDiv(0);
    }

    function rayDivOverflow(uint256 a, uint256 b) external pure {
        a.rayDiv(b);
    }
}

/// @notice Helper that forwards to AaveAdapterLib so library reverts are observable through an
///         external call (internal library calls are inlined and invisible to vm.expectRevert).
contract AaveAdapterLibHelper {
    function calcSharesFromAssetHalfUp(uint256 assets, uint256 index) external pure returns (uint256) {
        return AaveAdapterLib.calcSharesFromAssetHalfUp(assets, index);
    }

    function calcSharesToAssetDown(uint256 shares, uint256 index) external pure returns (uint256) {
        return AaveAdapterLib.calcSharesToAssetDown(shares, index);
    }

    function calcSharesFromAssetDown(uint256 assets, uint256 index) external pure returns (uint256) {
        return AaveAdapterLib.calcSharesFromAssetDown(assets, index);
    }
}
