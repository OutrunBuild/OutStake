// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {
    SYUpgradeableMockToken,
    TestSYUpgradeable,
    TestSYUpgradeableV2,
    TestSYUpgradeableWithoutUpdatePauseBackstop
} from "./mocks/SYUpgradeableMocks.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";

contract SYUpgradeableTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal trustedRouter = address(0xCAFE);

    bytes4 internal constant UNAUTHORIZED_INTERNAL_REDEEMER_SELECTOR =
        bytes4(keccak256("SYUnauthorizedInternalRedeemer(address)"));

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
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        sy.initialize("x", "x", address(token), owner);
    }

    function testSYBaseZeroYieldBearingTokenReverts() external {
        TestSYUpgradeable implementation = new TestSYUpgradeable();
        vm.expectRevert(IStandardizedYield.SYZeroAddress.selector);
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
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
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

    function testInternalRedeemRejectsUntrustedCaller() external {
        uint256 amount = 10e18;
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(sy), amount);
        sy.deposit(address(sy), address(token), amount, 0);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED_INTERNAL_REDEEMER_SELECTOR, user));
        vm.prank(user);
        sy.redeem(user, amount, address(token), 0, true);

        assertEq(sy.balanceOf(address(sy)), amount);
        assertEq(token.balanceOf(user), 0);
    }

    function testConfiguredRouterCanRedeemInternalBalance() external {
        uint256 amount = 10e18;
        token.mint(user, amount);

        vm.prank(owner);
        sy.setTrustedRouter(trustedRouter);

        vm.startPrank(user);
        token.approve(address(sy), amount);
        sy.deposit(address(sy), address(token), amount, 0);
        vm.stopPrank();

        vm.prank(trustedRouter);
        uint256 amountTokenOut = sy.redeem(user, amount, address(token), 0, true);

        assertEq(amountTokenOut, amount);
        assertEq(sy.balanceOf(address(sy)), 0);
        assertEq(token.balanceOf(user), amount);
    }

    function testTrustedRouterSetterIsOwnerOnlyAndZeroRevokes() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        sy.setTrustedRouter(trustedRouter);

        vm.prank(owner);
        sy.setTrustedRouter(trustedRouter);
        assertEq(sy.trustedRouter(), trustedRouter);

        vm.prank(owner);
        sy.setTrustedRouter(address(0));
        assertEq(sy.trustedRouter(), address(0));
    }

    function testReplacingTrustedRouterInvalidatesPreviousRouter() external {
        address replacementRouter = address(0xD00D);
        uint256 amount = 10e18;
        token.mint(user, amount);

        vm.startPrank(owner);
        sy.setTrustedRouter(trustedRouter);
        sy.setTrustedRouter(replacementRouter);
        vm.stopPrank();

        vm.startPrank(user);
        token.approve(address(sy), amount);
        sy.deposit(address(sy), address(token), amount, 0);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED_INTERNAL_REDEEMER_SELECTOR, trustedRouter));
        vm.prank(trustedRouter);
        sy.redeem(user, amount, address(token), 0, true);

        vm.prank(replacementRouter);
        sy.redeem(user, amount, address(token), 0, true);

        assertEq(sy.balanceOf(address(sy)), 0);
        assertEq(token.balanceOf(user), amount);
    }

    // Pause is two-layer: deposit/redeem revert at entry via whenNotPaused, and share transfers
    // revert via the ERC20 _update backstop. Preview/exchangeRate views stay usable while paused.
    function testSYBasePauseBlocksDepositAndRedeem() external {
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        sy.deposit(user, address(token), 10e18, 0);
        vm.stopPrank();

        vm.prank(owner);
        sy.pause();
        assertTrue(sy.paused());

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sy.deposit(user, address(token), 10e18, 0);

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sy.redeem(user, 5e18, address(token), 0, false);
    }

    function testSYBasePauseBlocksTransferWhilePreviewStaysUsable() external {
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        sy.deposit(user, address(token), 10e18, 0);
        vm.stopPrank();

        vm.prank(owner);
        sy.pause();

        // Share transfers are caught by the ERC20 _update whenNotPaused backstop, not the entry modifiers.
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sy.transfer(trustedRouter, 5e18);

        // View helpers carry no pause gate, so share accounting stays queryable while paused.
        assertEq(sy.previewDeposit(address(token), 1e18), 1e18);
        assertEq(sy.previewRedeem(address(token), 1e18), 1e18);
        assertEq(sy.exchangeRate(), 1e18);
        assertTrue(sy.paused());
    }

    function testSYBasePauseUnpauseAreOwnerOnly() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        sy.pause();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        sy.unpause();

        vm.startPrank(owner);
        sy.pause();
        assertTrue(sy.paused());
        sy.unpause();
        vm.stopPrank();
        assertFalse(sy.paused());
    }

    function testSYBaseZeroDepositReverts() external {
        // Nonzero allowance up front so the revert is attributable to the zero-amount guard alone.
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        vm.expectRevert(IStandardizedYield.SYZeroDeposit.selector);
        sy.deposit(user, address(token), 0, 0);
        vm.stopPrank();
    }

    function testSYBaseZeroRedeemReverts() external {
        vm.prank(user);
        vm.expectRevert(IStandardizedYield.SYZeroRedeem.selector);
        sy.redeem(user, 0, address(token), 0, false);
    }

    function testSYBaseDepositBelowMinSharesReverts() external {
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        // The mock converts 1:1, so 10e18 deposited yields exactly 10e18 shares -- one below the demanded minimum.
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInsufficientSharesOut.selector, 10e18, 10e18 + 1));
        sy.deposit(user, address(token), 10e18, 10e18 + 1);
        vm.stopPrank();
    }

    function testSYBaseZeroSharesOutReverts() external {
        token.mint(user, 10e18);
        vm.startPrank(user);
        token.approve(address(sy), 10e18);
        // Rate 0.5e18 halves the minted shares, so 1 wei of dust floors to zero output while
        // minSharesOut == 0: only the zero-output guard (not the slippage check) can catch this.
        sy.setDepositRate(0.5e18);
        vm.expectRevert(IStandardizedYield.SYZeroSharesOut.selector);
        sy.deposit(user, address(token), 1, 0);
        vm.stopPrank();
    }

    function testSYBaseRedeemBelowMinTokenOutReverts() external {
        uint256 amount = 10e18;
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(sy), amount);
        // Deposit first so the SY contract holds tokens for _redeem to transfer before the minimum check.
        sy.deposit(user, address(token), amount, 0);
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInsufficientTokenOut.selector, 5e18, 5e18 + 1));
        sy.redeem(user, 5e18, address(token), 5e18 + 1, false);
        vm.stopPrank();
    }

    // Pause layering (§8.2): the whenNotPaused modifiers on deposit/redeem and the ERC20 _update
    // backstop are independent layers. This harness bypasses the _update backstop, and the
    // mid-test transfer succeeding proves the bypass is real -- so both reverts below can only
    // come from the entry modifiers themselves.
    function testSYBasePauseEntryModifiersBlockWithoutUpdateBackstop() external {
        TestSYUpgradeable syNoBackstop = _deploySYWithoutUpdatePauseBackstop();

        token.mint(user, 20e18);
        vm.startPrank(user);
        token.approve(address(syNoBackstop), 20e18);
        syNoBackstop.deposit(user, address(token), 10e18, 0);
        vm.stopPrank();

        vm.prank(owner);
        syNoBackstop.pause();

        // Ample share balance is parked here on purpose: success proves this harness really skips
        // the _update pause backstop, otherwise the two expectRevert calls below would be
        // attributed to that backstop instead of the entry modifiers.
        vm.prank(user);
        syNoBackstop.transfer(trustedRouter, 1e18);

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syNoBackstop.deposit(user, address(token), 10e18, 0);

        // The _burn inside redeem goes through the bypassed _update, so this revert can only come
        // from redeem's own entry modifier.
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syNoBackstop.redeem(user, 5e18, address(token), 0, false);
    }

    function _deploySYWithoutUpdatePauseBackstop() internal returns (TestSYUpgradeable) {
        TestSYUpgradeableWithoutUpdatePauseBackstop implementation = new TestSYUpgradeableWithoutUpdatePauseBackstop();
        return TestSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(implementation),
                    abi.encodeCall(TestSYUpgradeable.initialize, ("SY Token", "SYT", address(token), owner))
                ))
        );
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
