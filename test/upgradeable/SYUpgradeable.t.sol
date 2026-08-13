// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {SYUpgradeableMockToken, TestSYUpgradeable, TestSYUpgradeableV2} from "./mocks/SYUpgradeableMocks.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";

contract SYUpgradeableTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);

    SYUpgradeableMockToken internal token;
    TestSYUpgradeable internal sy;

    function setUp() external {
        token = new SYUpgradeableMockToken();
        sy = _deploySY();
    }

    function testSYBaseInitializerSetsOwnerMetadataAndYieldBearingToken() external {
        assertEq(sy.name(), "SY Token");
        assertEq(sy.symbol(), "SYT");
        assertEq(sy.decimals(), 18);
        assertEq(sy.owner(), owner);
        assertEq(sy.yieldBearingToken(), address(token));
    }

    function testSYBaseInitializerCannotRunTwice() external {
        vm.expectRevert();
        sy.initialize("x", "x", address(token), owner);
    }

    function testSYBaseZeroYieldBearingTokenReverts() external {
        TestSYUpgradeable implementation = new TestSYUpgradeable();
        vm.expectRevert();
        ProxyTestHelper.deploy(
            address(implementation),
            abi.encodeCall(TestSYUpgradeable.initialize, ("SY Token", "SYT", address(0), owner))
        );
    }

    function testSYBaseOwnerCanUpgrade() external {
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        sy.deposit(user, address(token), 10e18, 0);
        vm.stopPrank();

        TestSYUpgradeableV2 implementationV2 = new TestSYUpgradeableV2();
        vm.prank(owner);
        sy.upgradeToAndCall(address(implementationV2), "");

        assertEq(sy.balanceOf(user), 10e18);
        assertEq(TestSYUpgradeableV2(payable(address(sy))).version(), 2);
    }

    function testSYBaseNonOwnerCannotUpgrade() external {
        TestSYUpgradeableV2 implementationV2 = new TestSYUpgradeableV2();
        vm.prank(user);
        vm.expectRevert();
        sy.upgradeToAndCall(address(implementationV2), "");
    }

    // The deposit-phase probe below jointly anchors both entry points: removing either
    // nonReentrant guard makes the nested redeem revert with a non-guard selector, turning
    // this test red (see TestSYUpgradeable._deposit).
    function testNestedRedeemDuringDepositBlockedByNonReentrantGuard() external {
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        sy.deposit(user, address(token), 10e18, 0);
        sy.redeem(user, 5e18, address(token), 0, false);
        vm.stopPrank();

        assertTrue(sy.reentryBlocked());
        assertEq(sy.balanceOf(user), 5e18);
        assertEq(token.balanceOf(user), 5e18);
    }

    function _deploySY() internal returns (TestSYUpgradeable) {
        TestSYUpgradeable implementation = new TestSYUpgradeable();
        return TestSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(implementation),
                    abi.encodeCall(TestSYUpgradeable.initialize, ("SY Token", "SYT", address(token), owner))
                ))
        );
    }
}
