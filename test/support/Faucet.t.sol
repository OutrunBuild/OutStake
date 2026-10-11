// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    Faucet,
    InvalidTokenAddress,
    InvalidDailyLimit,
    UnsupportedToken,
    ClaimTooSoon,
    InsufficientFaucetBalance
} from "./Faucet.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Open-mint ERC20 stand-in for held tokens (GenesisCredit pots cannot be minted by the
///      faucet — its real drip path is transfer-based, mirrored here by pre-funding the faucet).
contract HeldToken is ERC20 {
    constructor() ERC20("Held", "HELD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FaucetTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    Faucet internal faucet;
    MockUSDC internal mintable;
    HeldToken internal held;

    function setUp() external {
        vm.prank(owner);
        faucet = new Faucet(owner);
        mintable = new MockUSDC("Mock USDC", "USDC", 18, address(faucet));
        held = new HeldToken();
    }

    // -------------------------------------------------- addHeldToken config

    function testAddHeldTokenSetsDailyLimit() external {
        vm.prank(owner);
        faucet.addHeldToken(address(held), 100e18);
        uint256 dailyLimit = faucet.heldTokenInfos(address(held));
        assertEq(dailyLimit, 100e18);
    }

    function testAddHeldTokenOnlyOwner() external {
        vm.prank(alice);
        vm.expectRevert();
        faucet.addHeldToken(address(held), 100e18);
    }

    function testAddHeldTokenRejectsZeroTokenAndZeroLimit() external {
        vm.startPrank(owner);
        vm.expectRevert(InvalidTokenAddress.selector);
        faucet.addHeldToken(address(0), 100e18);
        vm.expectRevert(InvalidDailyLimit.selector);
        faucet.addHeldToken(address(held), 0);
        vm.stopPrank();
    }

    // -------------------------------------------------- claimHeld drips

    function testClaimHeldTransfersDailyLimitFromPot() external {
        held.mint(address(faucet), 1_000e18);
        vm.prank(owner);
        faucet.addHeldToken(address(held), 100e18);

        vm.prank(alice);
        faucet.claimHeld(address(held));

        assertEq(held.balanceOf(alice), 100e18);
        assertEq(held.balanceOf(address(faucet)), 900e18);
    }

    function testClaimHeldEnforcesDailyCooldown() external {
        held.mint(address(faucet), 1_000e18);
        vm.prank(owner);
        faucet.addHeldToken(address(held), 100e18);

        vm.startPrank(alice);
        faucet.claimHeld(address(held));
        vm.expectRevert(ClaimTooSoon.selector);
        faucet.claimHeld(address(held));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        faucet.claimHeld(address(held));
        assertEq(held.balanceOf(alice), 200e18);
    }

    function testClaimHeldRejectsUnregisteredToken() external {
        vm.prank(alice);
        vm.expectRevert(UnsupportedToken.selector);
        faucet.claimHeld(address(held));
    }

    function testClaimHeldEmptyPotDoesNotBurnCooldown() external {
        vm.prank(owner);
        faucet.addHeldToken(address(held), 100e18);

        // Empty pot: reverts InsufficientFaucetBalance and leaves the cooldown untouched...
        vm.prank(alice);
        vm.expectRevert(InsufficientFaucetBalance.selector);
        faucet.claimHeld(address(held));

        // ...so funding the pot afterwards lets the same day's claim through.
        held.mint(address(faucet), 100e18);
        vm.prank(alice);
        faucet.claimHeld(address(held));
        assertEq(held.balanceOf(alice), 100e18);
    }

    function testBatchClaimHeldDripsAllRegisteredTokens() external {
        HeldToken held2 = new HeldToken();
        held.mint(address(faucet), 1_000e18);
        held2.mint(address(faucet), 1_000e18);
        vm.startPrank(owner);
        faucet.addHeldToken(address(held), 100e18);
        faucet.addHeldToken(address(held2), 50e18);
        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = address(held);
        tokens[1] = address(held2);
        vm.prank(alice);
        faucet.batchClaimHeld(tokens);

        assertEq(held.balanceOf(alice), 100e18);
        assertEq(held2.balanceOf(alice), 50e18);
    }

    // -------------------------------------------------- legacy mint path (regression)

    function testClaimMintsRegisteredMockToken() external {
        vm.prank(owner);
        faucet.addToken(address(mintable), 500e6);

        vm.prank(alice);
        faucet.claim(address(mintable));

        assertEq(mintable.balanceOf(alice), 500e6);
    }

    function testClaimMintPathRejectsUnknownToken() external {
        vm.prank(alice);
        vm.expectRevert(UnsupportedToken.selector);
        faucet.claim(address(mintable));
    }
}
