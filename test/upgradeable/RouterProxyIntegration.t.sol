// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {MockLzEndpoint} from "./mocks/OFTMocks.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {PositionMockOracle, PositionMockToken} from "./mocks/PositionMocks.sol";
import {EmptyMockLauncher} from "./mocks/EmptyMockLauncher.sol";

contract RouterProxyIntegrationTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal revenuePool = address(0xFEE);

    PositionMockToken internal token;
    OutrunL2StakedTokenSYUpgradeable internal sy;
    OutrunUniversalAssetsUpgradeable internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunRouter internal router;

    function setUp() external {
        token = new PositionMockToken();
        PositionMockOracle oracle = new PositionMockOracle();

        sy = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY Token", "SYT", owner, address(token), address(oracle), address(token), 18)
                    )
                ))
        );

        MockLzEndpoint endpoint = new MockLzEndpoint();
        uAsset = OutrunUniversalAssetsUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunUniversalAssetsUpgradeable(18, address(endpoint))),
                abi.encodeCall(OutrunUniversalAssetsUpgradeable.initialize, ("UAsset", "UAST", 18, owner))
            )
        );

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), address(0xC0FFEE))
                )
            )
        );

        vm.prank(owner);
        uAsset.setMintingCap(address(position), type(uint256).max);

        router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        token.mint(user, 100e18);
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
