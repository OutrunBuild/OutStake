// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {EmptyMockLauncher} from "./mocks/EmptyMockLauncher.sol";

contract RouterProxyIntegrationTest is PositionStackTestBase {
    OutrunRouter internal router;

    function setUp() external {
        _deployPositionStack();
        router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
    }

    function testRouterStakeFromTokenUsesProxyBackedContracts() external {
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 10e18, owner: user, receiver: user
        });

        vm.startPrank(user);
        token.approve(address(router), type(uint256).max);
        (uint256 positionId, uint256 minted) =
            router.stakeFromToken(address(position), address(token), 10e18, stakeParam);
        vm.stopPrank();

        assertEq(positionId, 1);
        assertEq(minted, 10e18);
        assertEq(uAsset.balanceOf(user), 10e18);
        assertEq(position.syTotalStaking(), 10e18);
    }

    function testRouterStakeThenPositionRedeemUsesProxyBackedContracts() external {
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 10e18, owner: user, receiver: user
        });

        vm.startPrank(user);
        token.approve(address(router), type(uint256).max);
        (uint256 positionId,) = router.stakeFromToken(address(position), address(token), 10e18, stakeParam);
        uAsset.approve(address(position), 10e18);
        vm.warp(block.timestamp + 30 days);
        (uint256 burned, uint256 amountOut) = position.redeem(positionId, 10e18, user, address(token), 0);
        vm.stopPrank();

        assertEq(burned, 10e18);
        assertEq(amountOut, 10e18);
        assertEq(position.syTotalStaking(), 0);
    }

    function testRouterWrapStakeFromTokenUsesProxyBackedContracts() external {
        vm.startPrank(user);
        token.approve(address(router), type(uint256).max);
        uint256 minted = router.wrapStakeFromToken(address(position), address(token), 10e18, 0, user, 0);
        vm.stopPrank();

        assertEq(minted, 10e18);
        assertEq(uAsset.balanceOf(user), 10e18);
        assertEq(position.syWrapStaking(), 10e18);
        assertEq(position.wrapUAssetDebt(), 10e18);
    }
}
