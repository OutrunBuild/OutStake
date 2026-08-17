// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {RouterMockSY, RouterMockERC20, RouterMockUAsset, RouterMockLauncher} from "./mocks/RouterMocks.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {ProxyTestHelper} from "../upgradeable/helpers/ProxyTestHelper.sol";

/**
 * @title OutrunRouterFuzzTest
 * @notice Fuzz tests for OutrunRouter covering fund routing, slippage protection,
 *         owner/receiver separation, native token forwarding, and genesis flows.
 * @dev Threat model:
 *      1. Fund routing correctness - tokens don't get stuck in router
 *      2. Slippage protection on stake (minUAssetMinted)
 *      3. Owner/receiver separation
 *      4. Native token forwarding
 *      5. Genesis uint128 boundary check
 */
contract OutrunRouterFuzzTest is Test {
    RouterMockERC20 internal underlying;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunRouter internal router;
    RouterMockLauncher internal launcher;

    address internal owner = address(0xA11CE);
    address internal revenuePool = address(0xFEE);
    address internal user = address(0xB0B);
    address internal receiver = address(0xBEEF);

    function setUp() external {
        underlying = new RouterMockERC20("Mock Asset", "mAST");
        sy = new RouterMockSY(address(underlying));
        uAsset = new RouterMockUAsset();
        launcher = new RouterMockLauncher(address(uAsset));

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), address(0xC0FFEE))
                )
            )
        );
        router = new OutrunRouter(owner, address(launcher));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));

        uAsset.setMintingCap(address(position), type(uint256).max);

        // Fund user with tokens
        underlying.mint(user, 1_000_000e18);
        sy.mintShares(user, 1_000_000e18);

        // Set up approvals for user
        vm.startPrank(user);
        underlying.approve(address(router), type(uint256).max);
        sy.approve(address(router), type(uint256).max);
        sy.approve(address(position), type(uint256).max);
        uAsset.approve(address(router), type(uint256).max);
        uAsset.approve(address(position), type(uint256).max);
        vm.stopPrank();

        // Fund owner with tokens
        underlying.mint(owner, 1_000_000e18);
        sy.mintShares(owner, 1_000_000e18);

        vm.startPrank(owner);
        underlying.approve(address(router), type(uint256).max);
        sy.approve(address(router), type(uint256).max);
        sy.approve(address(position), type(uint256).max);
        uAsset.approve(address(router), type(uint256).max);
        uAsset.approve(address(position), type(uint256).max);
        vm.stopPrank();
    }

    // ==================== Mint SY From Token Tests ====================

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_MintSYFromTokenRoundtrip(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 userBalanceBefore = underlying.balanceOf(user);
        uint256 routerBalanceBefore = underlying.balanceOf(address(router));
        uint256 syBalanceBefore = sy.balanceOf(receiver);

        vm.prank(user);
        uint256 syOut = router.mintSYFromToken(address(sy), address(underlying), receiver, amount, 0);

        // Verify shares minted == amount (1:1 in mock)
        assertEq(syOut, amount, "syOut should equal amount");

        // Verify user's underlying was deducted
        assertEq(underlying.balanceOf(user), userBalanceBefore - amount, "user underlying balance mismatch");

        // Verify router has no leftover tokens
        assertEq(underlying.balanceOf(address(router)), routerBalanceBefore, "router should not hold underlying");

        // Verify SY minted to receiver
        assertEq(sy.balanceOf(receiver), syBalanceBefore + amount, "receiver SY balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_MintAndRedeemSYRoundtrip(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 userSYBefore = sy.balanceOf(user);

        // Mint SY from token
        vm.prank(user);
        uint256 syOut = router.mintSYFromToken(address(sy), address(underlying), user, amount, 0);
        assertEq(syOut, amount, "mint: syOut mismatch");

        // Redeem SY back to token
        vm.prank(user);
        uint256 tokenOut = router.redeemSyToToken(address(sy), user, address(underlying), amount, 0);
        assertEq(tokenOut, amount, "redeem: tokenOut mismatch");

        // Assert: user gets back original amount (minus what's in SY contract)
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "user should get back original underlying");
        assertEq(sy.balanceOf(user), userSYBefore, "user SY balance should return to original");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_MintSYFromTokenWithNative(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        vm.deal(user, amount);

        uint256 userNativeBefore = user.balance;
        uint256 syBalanceBefore = sy.balanceOf(receiver);

        vm.prank(user);
        uint256 syOut = router.mintSYFromToken{value: amount}(address(sy), address(0), receiver, amount, 0);

        assertEq(syOut, amount, "syOut mismatch");
        assertEq(user.balance, userNativeBefore - amount, "user native balance mismatch");
        assertEq(sy.balanceOf(receiver), syBalanceBefore + amount, "receiver SY balance mismatch");
    }

    // ==================== Stake From Token Tests ====================

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeFromToken(uint256 amount, uint128 lockupDays) public {
        amount = bound(amount, 1, 1000e18);
        lockupDays = uint128(bound(uint256(lockupDays), 1, 3650));

        uint256 userBalanceBefore = underlying.balanceOf(user);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: lockupDays, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: address(0)
        });

        vm.prank(user);
        (uint256 positionId, uint256 uAssetMinted) =
            router.stakeFromToken(address(position), address(underlying), amount, stakeParam);

        // Verify position created with correct state
        (address positionOwner, uint256 syStaked, uint256 positionUAssetMinted, uint128 deadline) =
            position.positions(positionId);

        assertEq(positionOwner, user, "position owner mismatch");
        assertEq(syStaked, amount, "syStaked mismatch");
        assertEq(positionUAssetMinted, amount, "positionUAssetMinted mismatch");
        assertEq(deadline, block.timestamp + lockupDays * 1 days, "deadline mismatch");

        // Verify uAsset minted to owner (since receiver is address(0))
        assertEq(uAssetMinted, amount, "uAssetMinted mismatch");
        assertEq(uAsset.balanceOf(user), amount, "user uAsset balance mismatch");

        // Verify router has no leftover tokens
        assertEq(underlying.balanceOf(address(router)), 0, "router should not hold underlying");
        assertEq(sy.balanceOf(address(router)), 0, "router should not hold SY");

        // Verify user's underlying was deducted
        assertEq(underlying.balanceOf(user), userBalanceBefore - amount, "user underlying balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeFromSY(uint256 amount, uint128 lockupDays) public {
        amount = bound(amount, 1, 1000e18);
        lockupDays = uint128(bound(uint256(lockupDays), 1, 3650));

        uint256 userSYBefore = sy.balanceOf(user);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: lockupDays, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: address(0)
        });

        vm.prank(user);
        (uint256 positionId, uint256 uAssetMinted) = router.stakeFromSY(address(position), amount, stakeParam);

        // Verify position created with correct state
        (address positionOwner, uint256 syStaked, uint256 positionUAssetMinted, uint128 deadline) =
            position.positions(positionId);

        assertEq(positionOwner, user, "position owner mismatch");
        assertEq(syStaked, amount, "syStaked mismatch");
        assertEq(positionUAssetMinted, amount, "positionUAssetMinted mismatch");
        assertEq(deadline, block.timestamp + lockupDays * 1 days, "deadline mismatch");

        // Verify uAsset minted to owner
        assertEq(uAssetMinted, amount, "uAssetMinted mismatch");
        assertEq(uAsset.balanceOf(user), uAssetMinted, "user uAsset balance mismatch");

        // Verify router has no leftover SY
        assertEq(sy.balanceOf(address(router)), 0, "router should not hold SY");

        // Verify user's SY was deducted
        assertEq(sy.balanceOf(user), userSYBefore - amount, "user SY balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeReceiverSeparation(uint256 amount, address customReceiver) public {
        amount = bound(amount, 1, 1000e18);
        // Bound receiver to non-zero, non-user address
        vm.assume(customReceiver != address(0));
        vm.assume(customReceiver != user);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: customReceiver
        });

        vm.prank(user);
        (uint256 positionId, uint256 uAssetMinted) =
            router.stakeFromToken(address(position), address(underlying), amount, stakeParam);

        // Verify: position owned by owner
        (address positionOwner,, uint256 positionUAssetMinted,) = position.positions(positionId);
        assertEq(positionOwner, user, "position should be owned by owner");
        assertEq(positionUAssetMinted, amount, "positionUAssetMinted mismatch");

        // Verify: uAsset sent to receiver
        assertEq(uAsset.balanceOf(customReceiver), uAssetMinted, "receiver should have uAsset");
        assertEq(uAsset.balanceOf(user), 0, "owner should not have uAsset");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeFromSYReceiverSeparation(uint256 amount, address customReceiver) public {
        amount = bound(amount, 1, 1000e18);
        vm.assume(customReceiver != address(0));
        vm.assume(customReceiver != user);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: customReceiver
        });

        vm.prank(user);
        (uint256 positionId, uint256 uAssetMinted) = router.stakeFromSY(address(position), amount, stakeParam);

        // Verify: position owned by owner
        (address positionOwner,, uint256 positionUAssetMinted,) = position.positions(positionId);
        assertEq(positionOwner, user, "position should be owned by owner");
        assertEq(positionUAssetMinted, amount, "positionUAssetMinted mismatch");

        // Verify: uAsset sent to receiver
        assertEq(uAsset.balanceOf(customReceiver), uAssetMinted, "receiver should have uAsset");
        assertEq(uAsset.balanceOf(user), 0, "owner should not have uAsset");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeSlippageReverts(uint256 amount, uint256 minUAssetMinted) public {
        amount = bound(amount, 1, 1000e18);
        // Set minUAssetMinted > amount to trigger revert
        minUAssetMinted = bound(minUAssetMinted, amount + 1, amount + 100e18);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: minUAssetMinted, owner: user, receiver: address(0)
        });

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.InsufficientUAssetMinted.selector, amount, minUAssetMinted)
        );
        router.stakeFromToken(address(position), address(underlying), amount, stakeParam);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeFromSYSlippageReverts(uint256 amount, uint256 minUAssetMinted) public {
        amount = bound(amount, 1, 1000e18);
        minUAssetMinted = bound(minUAssetMinted, amount + 1, amount + 100e18);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: minUAssetMinted, owner: user, receiver: address(0)
        });

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.InsufficientUAssetMinted.selector, amount, minUAssetMinted)
        );
        router.stakeFromSY(address(position), amount, stakeParam);
    }

    // ==================== Wrap Stake Tests ====================

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_WrapStakeFromToken(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 userBalanceBefore = underlying.balanceOf(user);

        vm.prank(user);
        (bool ok, bytes memory data) = address(router)
            .call(
                abi.encodeWithSelector(
                    IOutrunRouter.wrapStakeFromToken.selector,
                    address(position),
                    address(underlying),
                    amount,
                    0,
                    receiver,
                    0
                )
            );
        assertTrue(ok, "wrapStakeFromToken call failed");
        uint256 uAssetMinted = abi.decode(data, (uint256));

        // Verify uAsset minted to recipient
        assertEq(uAssetMinted, amount, "uAssetMinted mismatch");
        assertEq(uAsset.balanceOf(receiver), amount, "recipient uAsset balance mismatch");

        // Verify syWrapStaking increased
        assertEq(position.syWrapStaking(), amount, "syWrapStaking mismatch");

        // Verify router has no leftover tokens
        assertEq(underlying.balanceOf(address(router)), 0, "router should not hold underlying");
        assertEq(sy.balanceOf(address(router)), 0, "router should not hold SY");

        // Verify user's underlying was deducted
        assertEq(underlying.balanceOf(user), userBalanceBefore - amount, "user underlying balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_WrapStakeFromSY(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        (bool ok, bytes memory data) = address(router)
            .call(
                abi.encodeWithSelector(IOutrunRouter.wrapStakeFromSY.selector, address(position), amount, receiver, 0)
            );
        assertTrue(ok, "wrapStakeFromSY call failed");
        uint256 uAssetMinted = abi.decode(data, (uint256));

        // Verify uAsset minted to recipient
        assertEq(uAssetMinted, amount, "uAssetMinted mismatch");
        assertEq(uAsset.balanceOf(receiver), amount, "recipient uAsset balance mismatch");

        // Verify syWrapStaking increased
        assertEq(position.syWrapStaking(), amount, "syWrapStaking mismatch");

        // Verify router has no leftover SY
        assertEq(sy.balanceOf(address(router)), 0, "router should not hold SY");

        // Verify user's SY was deducted
        assertEq(sy.balanceOf(user), userSYBefore - amount, "user SY balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_WrapStakeFromTokenWithNative(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        vm.deal(user, amount);

        vm.prank(user);
        (bool ok, bytes memory data) = address(router).call{value: amount}(
            abi.encodeWithSelector(
                IOutrunRouter.wrapStakeFromToken.selector,
                address(position),
                address(0), // native token
                amount,
                0,
                receiver,
                0
            )
        );
        assertTrue(ok, "wrapStakeFromToken native call failed");
        uint256 uAssetMinted = abi.decode(data, (uint256));

        // Verify uAsset minted to recipient
        assertEq(uAssetMinted, amount, "uAssetMinted mismatch");
        assertEq(uAsset.balanceOf(receiver), amount, "recipient uAsset balance mismatch");

        // Verify syWrapStaking increased
        assertEq(position.syWrapStaking(), amount, "syWrapStaking mismatch");
    }

    // ==================== Preview Functions Tests ====================

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_PreviewStakeFromTokenMatchesActual(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: address(0)
        });

        sy.setDepositRate(2e18);
        assertEq(sy.previewDeposit(address(underlying), amount), amount * 2, "deposit preview should be non-identity");

        uint256 preview = router.previewStakeFromToken(address(position), address(underlying), amount, stakeParam);

        vm.prank(user);
        (, uint256 actualUAsset) = router.stakeFromToken(address(position), address(underlying), amount, stakeParam);

        assertEq(preview, actualUAsset, "preview should match actual");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_PreviewStakeFromSYMatchesActual(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: address(0)
        });

        uint256 preview = router.previewStakeFromSY(address(position), amount, stakeParam);

        vm.prank(user);
        (, uint256 actualUAsset) = router.stakeFromSY(address(position), amount, stakeParam);

        assertEq(preview, actualUAsset, "preview should match actual");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_PreviewWrapStakeMatchesActual(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        sy.setDepositRate(2e18);
        assertEq(sy.previewDeposit(address(underlying), amount), amount * 2, "deposit preview should be non-identity");

        uint256 preview = router.previewWrapStakeFromToken(address(position), address(underlying), amount);

        vm.prank(user);
        (bool ok, bytes memory data) = address(router)
            .call(
                abi.encodeWithSelector(
                    IOutrunRouter.wrapStakeFromToken.selector,
                    address(position),
                    address(underlying),
                    amount,
                    0,
                    user,
                    0
                )
            );
        assertTrue(ok, "wrapStakeFromToken call failed");
        uint256 actualUAsset = abi.decode(data, (uint256));

        assertEq(preview, actualUAsset, "preview should match actual");
    }

    // ==================== Genesis Flow Tests ====================

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_GenesisByToken(uint256 amount, uint128 lockupDays, uint256 verseId) public {
        amount = bound(amount, 1, 1000e18);
        lockupDays = uint128(bound(uint256(lockupDays), 1, 3650));
        verseId = bound(verseId, 1, type(uint256).max - 1);

        uint256 userBalanceBefore = underlying.balanceOf(user);

        vm.prank(user);
        router.genesisByToken{value: 0}(address(position), address(underlying), amount, 0, lockupDays, verseId, user, 0);

        // Verify position created
        (address positionOwner, uint256 syStaked, uint256 uAssetMinted, uint128 deadline) = position.positions(1);
        assertEq(positionOwner, user, "position owner mismatch");
        assertEq(syStaked, amount, "syStaked mismatch");
        assertEq(uAssetMinted, amount, "uAssetMinted mismatch");
        assertEq(deadline, block.timestamp + lockupDays * 1 days, "deadline mismatch");

        // Verify genesis called correctly
        (uint256 launcherVerseId, uint128 launcherUAsset, address launcherUser) = launcher.snapshot();
        assertEq(launcherVerseId, verseId, "verseId mismatch");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(launcherUAsset, uint128(amount), "launcher uAsset mismatch");
        assertEq(launcherUser, user, "genesisUser mismatch");

        // Verify syTotalStaking increased (genesis uses locked stake, not wrap)
        assertEq(position.syTotalStaking(), amount, "syTotalStaking mismatch");
        assertEq(position.syWrapStaking(), 0, "syWrapStaking should be 0");

        // Verify uAsset transferred to launcher
        assertEq(uAsset.balanceOf(address(launcher)), amount, "launcher should have uAsset");
        assertEq(uAsset.balanceOf(user), 0, "user should not have uAsset");
        assertEq(uAsset.balanceOf(address(router)), 0, "router should not have uAsset");

        // Verify user's underlying was deducted
        assertEq(underlying.balanceOf(user), userBalanceBefore - amount, "user underlying balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_GenesisBySY(uint128 amount, uint128 lockupDays, uint256 verseId) public {
        amount = uint128(bound(uint256(amount), 1, 1000e18));
        lockupDays = uint128(bound(uint256(lockupDays), 1, 3650));
        verseId = bound(verseId, 1, type(uint256).max - 1);

        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        router.genesisBySY(address(position), amount, lockupDays, verseId, user, 0);

        // Verify position created
        (address positionOwner, uint256 syStaked, uint256 uAssetMinted, uint128 deadline) = position.positions(1);
        assertEq(positionOwner, user, "position owner mismatch");
        assertEq(syStaked, uint256(amount), "syStaked mismatch");
        assertEq(uAssetMinted, uint256(amount), "uAssetMinted mismatch");
        assertEq(deadline, block.timestamp + lockupDays * 1 days, "deadline mismatch");

        // Verify genesis called correctly
        (uint256 launcherVerseId, uint128 launcherUAsset, address launcherUser) = launcher.snapshot();
        assertEq(launcherVerseId, verseId, "verseId mismatch");
        assertEq(launcherUAsset, amount, "launcher uAsset mismatch");
        assertEq(launcherUser, user, "genesisUser mismatch");

        // Verify syTotalStaking increased (genesis uses locked stake, not wrap)
        assertEq(position.syTotalStaking(), uint256(amount), "syTotalStaking mismatch");
        assertEq(position.syWrapStaking(), 0, "syWrapStaking should be 0");

        // Verify uAsset transferred to launcher
        assertEq(uAsset.balanceOf(address(launcher)), uint256(amount), "launcher should have uAsset");
        assertEq(uAsset.balanceOf(user), 0, "user should not have uAsset");
        assertEq(uAsset.balanceOf(address(router)), 0, "router should not have uAsset");

        // Verify user's SY was deducted
        assertEq(sy.balanceOf(user), userSYBefore - uint256(amount), "user SY balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_GenesisByTokenWithNative(uint256 amount, uint128 lockupDays, uint256 verseId) public {
        amount = bound(amount, 1, 1000e18);
        lockupDays = uint128(bound(uint256(lockupDays), 1, 3650));
        verseId = bound(verseId, 1, type(uint256).max - 1);

        vm.deal(user, amount);

        vm.prank(user);
        router.genesisByToken{value: amount}(address(position), address(0), amount, 0, lockupDays, verseId, user, 0);

        // Verify genesis called correctly
        (uint256 launcherVerseId, uint128 launcherUAsset, address launcherUser) = launcher.snapshot();
        assertEq(launcherVerseId, verseId, "verseId mismatch");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(launcherUAsset, uint128(amount), "launcher uAsset mismatch");
        assertEq(launcherUser, user, "genesisUser mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_GenesisByTokenMaxUint128(uint128 amount) public {
        // Test with max uint128 to verify the boundary check passes
        amount = uint128(bound(uint256(amount), 1, type(uint128).max));

        // Ensure user has enough tokens
        underlying.mint(user, uint256(amount));
        vm.prank(user);
        underlying.approve(address(router), type(uint256).max);

        vm.prank(user);
        router.genesisByToken{value: 0}(address(position), address(underlying), uint256(amount), 0, 30, 1, user, 0);

        // Verify genesis called correctly
        (, uint128 launcherUAsset,) = launcher.snapshot();
        assertEq(launcherUAsset, amount, "launcher uAsset mismatch");
    }

    // ==================== Edge Cases ====================

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_MultipleStakesFromSameUser(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 500e18);
        amount2 = bound(amount2, 1, 500e18);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: address(0)
        });

        vm.prank(user);
        (uint256 positionId1,) = router.stakeFromToken(address(position), address(underlying), amount1, stakeParam);

        vm.prank(user);
        (uint256 positionId2,) = router.stakeFromToken(address(position), address(underlying), amount2, stakeParam);

        // Verify two different positions created
        assertTrue(positionId1 != positionId2, "position IDs should be different");

        // Verify total uAsset
        assertEq(uAsset.balanceOf(user), amount1 + amount2, "user uAsset balance mismatch");

        // Verify total staking
        assertEq(position.syTotalStaking(), amount1 + amount2, "syTotalStaking mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_WrapStakeAndLockedStakeAccounting(uint256 wrapAmount, uint256 stakeAmount) public {
        wrapAmount = bound(wrapAmount, 1, 500e18);
        stakeAmount = bound(stakeAmount, 1, 500e18);

        // Wrap stake
        vm.prank(user);
        (bool wrapOk,) = address(router)
            .call(
                abi.encodeWithSelector(
                    IOutrunRouter.wrapStakeFromToken.selector,
                    address(position),
                    address(underlying),
                    wrapAmount,
                    0,
                    user,
                    0
                )
            );
        assertTrue(wrapOk, "wrapStakeFromToken call failed");

        // Locked stake
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: address(0)
        });

        vm.prank(user);
        router.stakeFromToken(address(position), address(underlying), stakeAmount, stakeParam);

        // Verify accounting separation
        assertEq(position.syWrapStaking(), wrapAmount, "syWrapStaking mismatch");
        assertEq(position.syTotalStaking(), wrapAmount + stakeAmount, "syTotalStaking mismatch");
        assertEq(uAsset.balanceOf(user), wrapAmount + stakeAmount, "user uAsset balance mismatch");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_SlippageProtectionBoundary(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        // Test with minUAssetMinted == amount (should pass)
        IOutrunRouter.StakeParam memory stakeParamPass = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: amount, owner: user, receiver: address(0)
        });

        vm.prank(user);
        (, uint256 uAssetMinted) = router.stakeFromToken(address(position), address(underlying), amount, stakeParamPass);
        assertEq(uAssetMinted, amount, "uAssetMinted should equal amount");

        // Reset state for next test - give user more tokens
        underlying.mint(user, amount);

        // Test with minUAssetMinted == amount + 1 (should fail)
        IOutrunRouter.StakeParam memory stakeParamFail = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: amount + 1, owner: user, receiver: address(0)
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.InsufficientUAssetMinted.selector, amount, amount + 1));
        router.stakeFromToken(address(position), address(underlying), amount, stakeParamFail);
    }
}
