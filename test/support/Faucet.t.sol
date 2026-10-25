// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {
    Faucet,
    InvalidTokenAddress,
    InvalidDailyLimit,
    UnsupportedToken,
    ClaimTooSoon,
    InsufficientFaucetBalance,
    BootstrapAlreadyDone
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

/// @dev Minimal GenesisCredit stand-in: msg.sender-bound merkle claim mirroring the real
///      contract's double-hash leaf and one-claim-per-address guard.
contract MockMerkleCredit is ERC20 {
    bytes32 public merkleRoot;
    mapping(address => uint256) public claimed;

    constructor() ERC20("Credit", "CRT") {}

    function setMerkleRoot(bytes32 root) external {
        merkleRoot = root;
    }

    function claim(uint256 amount, bytes32[] calldata proof) external {
        require(claimed[msg.sender] == 0, "claimed");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        bytes32 node = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            node = node < proof[i] ? keccak256(bytes.concat(node, proof[i])) : keccak256(bytes.concat(proof[i], node));
        }
        require(node == merkleRoot, "proof");
        claimed[msg.sender] = amount;
        _mint(msg.sender, amount);
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
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

    // -------------------------------------------------- credit pot bootstrap

    function testBootstrapGenesisCreditMintsPotIntoFaucet() external {
        MockMerkleCredit credit = new MockMerkleCredit();
        uint256 pot = 1_000_000e18;
        // single-leaf tree: root = leaf(faucet, pot)
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(faucet), pot))));
        credit.setMerkleRoot(leaf);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(owner);
        faucet.bootstrapGenesisCredit(address(credit), pot, proof);

        assertEq(credit.balanceOf(address(faucet)), pot);
        assertTrue(faucet.bootstrappedCredits(address(credit)));

        // pot immediately serves held drips
        vm.prank(owner);
        faucet.addHeldToken(address(credit), 100e18);
        vm.prank(alice);
        faucet.claimHeld(address(credit));
        assertEq(credit.balanceOf(alice), 100e18);
    }

    function testBootstrapGenesisCreditOnlyOwner() external {
        MockMerkleCredit credit = new MockMerkleCredit();
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        faucet.bootstrapGenesisCredit(address(credit), 1e18, proof);
    }

    function testBootstrapGenesisCreditIsOneShot() external {
        MockMerkleCredit credit = new MockMerkleCredit();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(faucet), 1e18))));
        credit.setMerkleRoot(leaf);
        bytes32[] memory proof = new bytes32[](0);
        vm.startPrank(owner);
        faucet.bootstrapGenesisCredit(address(credit), 1e18, proof);
        vm.expectRevert(BootstrapAlreadyDone.selector);
        faucet.bootstrapGenesisCredit(address(credit), 1e18, proof);
        vm.stopPrank();
    }
}
