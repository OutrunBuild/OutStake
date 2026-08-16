// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {NativeAmountMismatch, NativeTransferFailed} from "../../src/libraries/TokenHelper.sol";
import {TokenHelperHarness, MockERC20, RevertingReceiver} from "./mocks/TokenHelperMocks.sol";

contract TokenHelperTest is Test {
    TokenHelperHarness internal harness;
    MockERC20 internal token;

    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal recipient = address(0xCAFE);

    function setUp() external {
        harness = new TokenHelperHarness();
        token = new MockERC20("Test Token", "TST", 18);
    }

    // ============ _transferIn tests ============

    function testTransferInNativeChecksMsgValue() external {
        // ERC20 input with msg.value > 0 should revert
        vm.deal(address(harness), 0);

        vm.expectRevert(NativeAmountMismatch.selector);
        harness.exposedTransferIn{value: 1 ether}(address(token), user, 100 ether);
    }

    function testTransferInNativeWithValueMismatch() external {
        // Native input where msg.value != amount should revert
        vm.deal(address(harness), 2 ether);

        vm.expectRevert(NativeAmountMismatch.selector);
        harness.exposedTransferIn{value: 1 ether}(address(0), user, 2 ether);
    }

    function testTransferInNativeSucceeds() external {
        // Native input with correct msg.value should succeed.
        vm.deal(user, 2 ether);

        vm.prank(user);
        // Route through the exposed wrapper so _transferIn's native success branch actually runs.
        // A plain empty-calldata call would only hit the harness receive() and skip _transferIn entirely.
        harness.exposedTransferIn{value: 1 ether}(address(0), user, 1 ether);
        assertEq(address(harness).balance, 1 ether);
    }

    function testTransferInERC20Succeeds() external {
        token.mint(user, 100 ether);

        vm.prank(user);
        token.approve(address(harness), 100 ether);

        harness.exposedTransferIn(address(token), user, 100 ether);

        assertEq(token.balanceOf(address(harness)), 100 ether);
        assertEq(token.balanceOf(user), 0);
    }

    function testTransferInERC20SkipsOnZeroAmount() external {
        // Zero amount should skip the transfer
        harness.exposedTransferIn(address(token), user, 0);
        assertEq(token.balanceOf(address(harness)), 0);
    }

    // ============ _transferOut tests ============

    function testTransferOutNativeSucceeds() external {
        vm.deal(address(harness), 1 ether);

        harness.exposedTransferOut(address(0), recipient, 0.5 ether);

        assertEq(recipient.balance, 0.5 ether);
        assertEq(address(harness).balance, 0.5 ether);
    }

    function testTransferOutNativeRevertsOnFailure() external {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.deal(address(harness), 1 ether);

        vm.expectRevert(NativeTransferFailed.selector);
        harness.exposedTransferOut(address(0), address(receiver), 0.5 ether);
    }

    function testTransferOutSkipsOnZeroAmount() external {
        vm.deal(address(harness), 1 ether);

        // Should not transfer anything
        harness.exposedTransferOut(address(token), recipient, 0);

        assertEq(token.balanceOf(recipient), 0);
        assertEq(address(harness).balance, 1 ether); // unchanged
    }

    function testTransferOutERC20Succeeds() external {
        token.mint(address(harness), 100 ether);

        harness.exposedTransferOut(address(token), recipient, 50 ether);

        assertEq(token.balanceOf(recipient), 50 ether);
        assertEq(token.balanceOf(address(harness)), 50 ether);
    }

    // ============ _safeApprove tests ============

    function testSafeApproveSetsAllowance() external {
        token.mint(address(harness), 100 ether);

        harness.exposedSafeApprove(address(token), recipient, 50 ether);

        assertEq(token.allowance(address(harness), recipient), 50 ether);
    }

    function testSafeApproveSetsToZero() external {
        token.mint(address(harness), 100 ether);

        harness.exposedSafeApprove(address(token), recipient, 50 ether);
        assertEq(token.allowance(address(harness), recipient), 50 ether);

        harness.exposedSafeApprove(address(token), recipient, 0);
        assertEq(token.allowance(address(harness), recipient), 0);
    }

    // ============ _safeApproveInf tests ============

    function testSafeApproveInfSetsToMax() external {
        token.mint(address(harness), 100 ether);

        // Current allowance is 0, which is < LOWER_BOUND_APPROVAL
        harness.exposedSafeApproveInf(address(token), recipient);

        assertEq(token.allowance(address(harness), recipient), type(uint256).max);
    }

    function testSafeApproveInfSkipsWhenSufficient() external {
        token.mint(address(harness), 100 ether);

        // Set allowance to a value >= LOWER_BOUND_APPROVAL
        harness.exposedSafeApprove(address(token), recipient, harness.exposedLowerBoundApproval());

        uint256 allowanceBefore = token.allowance(address(harness), recipient);
        assertEq(allowanceBefore, harness.exposedLowerBoundApproval());

        // Should skip since allowance is already >= LOWER_BOUND_APPROVAL
        harness.exposedSafeApproveInf(address(token), recipient);

        // Allowance should remain unchanged
        assertEq(token.allowance(address(harness), recipient), allowanceBefore);
    }

    function testSafeApproveInfSetsToMaxWhenBelowLowerBound() external {
        token.mint(address(harness), 100 ether);

        // Set allowance to a value < LOWER_BOUND_APPROVAL
        harness.exposedSafeApprove(address(token), recipient, 100 ether);
        assertEq(token.allowance(address(harness), recipient), 100 ether);

        // Should set to max since current < LOWER_BOUND_APPROVAL
        harness.exposedSafeApproveInf(address(token), recipient);

        assertEq(token.allowance(address(harness), recipient), type(uint256).max);
    }

    function testSafeApproveInfSkipsForNative() external {
        // Should return immediately for native token without any approval
        harness.exposedSafeApproveInf(address(0), recipient);
        // No assertion needed, just ensure no revert
    }

    // ============ _selfBalance tests ============

    function testSelfBalanceNative() external {
        vm.deal(address(harness), 5 ether);

        uint256 balance = harness.exposedSelfBalance(address(0));
        assertEq(balance, 5 ether);
    }

    function testSelfBalanceERC20() external {
        token.mint(address(harness), 100 ether);

        uint256 balance = harness.exposedSelfBalance(address(token));
        assertEq(balance, 100 ether);
    }

    function testSelfBalanceZeroNative() external {
        uint256 balance = harness.exposedSelfBalance(address(0));
        assertEq(balance, 0);
    }

    function testSelfBalanceZeroERC20() external {
        uint256 balance = harness.exposedSelfBalance(address(token));
        assertEq(balance, 0);
    }

    // ============ LOWER_BOUND_APPROVAL constant test ============

    function testLowerBoundApprovalValue() external {
        // Anchor the production constant (exposed via the harness) to its intended value
        assertEq(harness.exposedLowerBoundApproval(), type(uint96).max / 2);
    }
}
