// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {UAssetHelper} from "./UAssetHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOutrunStakeManager} from "../../../src/position/interfaces/IOutrunStakeManager.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

interface IMintSharesSY {
    function mintShares(address to, uint256 amount) external;
}

interface ISYDeposit {
    function deposit(address to, address token, uint256 amount, uint256 minOut) external returns (uint256);
}

/// @title CommonTestHelpers
/// @notice Shared time, math and stake helpers deduplicated from multiple SP suites.
/// @dev `AdversarialTests`, `OutrunStakingPositionUpgradeableTest`,
/// `OutrunStakingPositionPauseMatrixTest`, `OutrunStakingPositionFuzzTest` and
/// `OutrunStakingPositionPropertyTest` previously each defined an identical `_warp`
/// helper. `_stakeTenSyForGenesis`/`_mintSy` were also duplicated across
/// `AdversarialTests` and the position suites with the same 10e18 genesis-open body.
/// Centralising here keeps a single implementation so a `vm.warp` quirk fix is one edit.
/// `OutrunUSRVaultTest` consumes the same `warpAt`/`_warp`. The invariant handler keeps its
/// own `currentTimestamp` (per-suite trackers are the ghost-model family's layout), so it
/// stays outside this single source.
/// Ceil division is a single `SPTestDefaults.ceilDiv` implementation; callers use it directly.
abstract contract CommonTestHelpers is UAssetHelper {
    uint256 internal warpAt = 1;

    /// @notice Warps chain forward by `secondsDelta` and advances tracked timestamp.
    function _warp(uint256 secondsDelta) internal {
        warpAt += secondsDelta;
        vm.warp(warpAt);
    }

    /// @notice Generic mint-SY helper usable by any mock SY that follows the
    /// `token.mint` + `token.approve(sy)` + `sy.deposit` flow.
    function _mintSyFor(address token_, address sy_, address who, uint256 amount) internal {
        IMintableToken(token_).mint(who, amount);
        vm.startPrank(who);
        IERC20(token_).approve(sy_, amount);
        ISYDeposit(sy_).deposit(who, token_, amount, 0);
        vm.stopPrank();
    }

    /// @notice Generic 10e18 genesis-open helper usable by any mock SY with `mintShares`.
    /// @dev Opens through `stakeForGenesis` (the only mint entrypoint); the caller must have
    ///      wired `launcher` as the position's genesis launcher beforehand. Returns the new id
    ///      and the value-parity minted principal.
    function _stakeTenSyForGenesis(address sy_, address position_, address launcher_, address who)
        internal
        returns (uint256 positionId, uint256 principal)
    {
        IMintSharesSY(sy_).mintShares(who, 10e18);
        vm.startPrank(who);
        IERC20(sy_).approve(position_, 10e18);
        positionId = IOutrunStakeManager(position_).stakeForGenesis(10e18, who, 42, 0);
        vm.stopPrank();
        (,, principal,,) = IOutrunStakeManager(position_).positions(positionId);
        assertEq(IERC20(IOutrunStakeManager(position_).uAsset()).allowance(position_, launcher_), 0);
    }
}
