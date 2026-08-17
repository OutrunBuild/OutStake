// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {EmptyMockLauncher} from "./mocks/EmptyMockLauncher.sol";

contract RouterProxyIntegrationTest is PositionStackTestBase {
    OutrunRouter internal router;

    function setUp() external {
        _deployPositionStack();
        router = new OutrunRouter(owner, address(new EmptyMockLauncher()));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));
        vm.prank(owner);
        sy.setTrustedRouter(address(router));
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

    function testRouterRedeemSyToTokenUsesProxyBackedContracts() external {
        uint256 prefund = 1e18;
        uint256 amountInSY = 10e18;
        address receiver = address(0xCAFE);
        _prepareRedeem(amountInSY, prefund);

        vm.prank(user);
        uint256 amountOut = router.redeemSyToToken(address(sy), receiver, address(token), amountInSY, amountInSY);

        assertEq(amountOut, amountInSY);
        assertEq(token.balanceOf(receiver), amountInSY);
        assertEq(sy.balanceOf(user), 0);
        assertEq(sy.balanceOf(address(sy)), prefund);
        assertEq(token.balanceOf(address(sy)), prefund);
        assertEq(sy.allowance(user, address(router)), 0);
    }

    function testRouterRedeemSyToTokenRevertsWhenMinimumIsTooHigh() external {
        uint256 prefund = 1e18;
        uint256 amountInSY = 10e18;
        address receiver = address(0xCAFE);
        _prepareRedeem(amountInSY, prefund);

        uint256 userSyBefore = sy.balanceOf(user);
        uint256 internalSyBefore = sy.balanceOf(address(sy));
        uint256 backingBefore = token.balanceOf(address(sy));
        uint256 receiverTokenBefore = token.balanceOf(receiver);
        uint256 allowanceBefore = sy.allowance(user, address(router));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardizedYield.SYInsufficientTokenOut.selector, amountInSY, amountInSY + 1)
        );
        router.redeemSyToToken(address(sy), receiver, address(token), amountInSY, amountInSY + 1);

        assertEq(sy.balanceOf(user), userSyBefore);
        assertEq(sy.balanceOf(address(sy)), internalSyBefore);
        assertEq(token.balanceOf(address(sy)), backingBefore);
        assertEq(token.balanceOf(receiver), receiverTokenBefore);
        assertEq(sy.allowance(user, address(router)), allowanceBefore);
    }

    function _prepareRedeem(uint256 amountInSY, uint256 prefund) internal {
        token.mint(address(this), prefund);
        token.approve(address(sy), prefund);
        sy.deposit(address(sy), address(token), prefund, prefund);

        vm.startPrank(user);
        token.approve(address(sy), amountInSY);
        sy.deposit(user, address(token), amountInSY, amountInSY);
        sy.approve(address(router), amountInSY);
        vm.stopPrank();
    }
}
