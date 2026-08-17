// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {ProxyTestHelper} from "../upgradeable/helpers/ProxyTestHelper.sol";
import {RouterMockSY, RouterMockERC20, RouterMockUAsset, RouterMockLauncher} from "./mocks/RouterMocks.sol";

contract OutrunRouterTest is Test {
    bytes4 internal constant NATIVE_AMOUNT_MISMATCH_SELECTOR = IOutrunRouter.NativeAmountMismatch.selector;
    bytes4 internal constant INVALID_MEMEVERSE_LAUNCHER_SELECTOR = IOutrunRouter.InvalidMemeverseLauncher.selector;
    RouterMockERC20 internal underlying;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunRouter internal router;
    RouterMockLauncher internal launcher;

    address internal owner = address(0xA11CE);
    address internal revenuePool = address(0xFEE);
    bytes4 internal constant INVALID_PARAM_SELECTOR = bytes4(keccak256("InvalidParam()"));

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

        underlying.mint(owner, 1_000e18);
        sy.mintShares(owner, 1_000e18);

        vm.prank(owner);
        underlying.approve(address(router), type(uint256).max);

        vm.prank(owner);
        sy.approve(address(router), type(uint256).max);

        vm.prank(owner);
        sy.approve(address(position), type(uint256).max);

        vm.prank(owner);
        uAsset.approve(address(router), type(uint256).max);
    }

    function testConstructorRevertsWhenMemeverseLauncherIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(INVALID_MEMEVERSE_LAUNCHER_SELECTOR, address(0)));
        new OutrunRouter(owner, address(0));
    }

    function testConstructorRevertsWhenMemeverseLauncherHasNoCode() external {
        address eoaLauncher = address(0x1234);

        vm.expectRevert(abi.encodeWithSelector(INVALID_MEMEVERSE_LAUNCHER_SELECTOR, eoaLauncher));
        new OutrunRouter(owner, eoaLauncher);
    }

    function testSetMemeverseLauncherRevertsWhenZero() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(INVALID_MEMEVERSE_LAUNCHER_SELECTOR, address(0)));
        router.setMemeverseLauncher(address(0));
    }

    function testSetMemeverseLauncherRevertsWhenNoCode() external {
        address eoaLauncher = address(0x1234);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(INVALID_MEMEVERSE_LAUNCHER_SELECTOR, eoaLauncher));
        router.setMemeverseLauncher(eoaLauncher);
    }

    function testSetMemeverseLauncherAcceptsContract() external {
        RouterMockLauncher newLauncher = new RouterMockLauncher(address(uAsset));

        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.SetMemeverseLauncher(address(launcher), address(newLauncher));

        vm.prank(owner);
        router.setMemeverseLauncher(address(newLauncher));

        assertEq(router.memeverseLauncher(), address(newLauncher));
    }

    function testMintSYFromTokenPullsCallerFundsAndKeepsRouterPrefund() external {
        address receiver = address(0xBEEF);

        underlying.mint(address(router), 50e18);

        vm.prank(owner);
        uint256 syOut =
            IOutrunRouter(address(router)).mintSYFromToken(address(sy), address(underlying), receiver, 100e18, 0);

        assertEq(syOut, 100e18);
        assertEq(underlying.balanceOf(owner), 900e18);
        assertEq(underlying.balanceOf(address(router)), 50e18);
        assertEq(underlying.balanceOf(address(sy)), 100e18);
        assertEq(sy.balanceOf(receiver), 100e18);
    }

    function testMintSYFromTokenRevertsWhenERC20InputCarriesMsgValue() external {
        vm.deal(owner, 1);

        vm.prank(owner);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        IOutrunRouter(address(router)).mintSYFromToken{value: 1}(address(sy), address(underlying), owner, 100e18, 0);
    }

    function testMintSYFromTokenSupportsNativePath() external {
        address receiver = address(0xBEEF);

        vm.deal(owner, 100e18);

        vm.prank(owner);
        uint256 syOut =
            IOutrunRouter(address(router)).mintSYFromToken{value: 100e18}(address(sy), address(0), receiver, 100e18, 0);

        (address tokenIn, uint256 amount, uint256 value) = sy.lastDeposit();

        assertEq(syOut, 100e18);
        assertEq(sy.balanceOf(receiver), 100e18);
        assertEq(tokenIn, address(0));
        assertEq(amount, 100e18);
        assertEq(value, 100e18);
    }

    function testRedeemSyToTokenPullsCallerSharesAndKeepsPrefundedInternalBalance() external {
        address receiver = address(0xBEEF);

        underlying.mint(address(sy), 100e18);
        sy.mintShares(address(sy), 40e18);

        vm.prank(owner);
        uint256 tokenOut =
            IOutrunRouter(address(router)).redeemSyToToken(address(sy), receiver, address(underlying), 100e18, 0);

        assertEq(tokenOut, 100e18);
        assertEq(sy.balanceOf(owner), 900e18);
        assertEq(sy.balanceOf(address(sy)), 40e18);
        assertEq(underlying.balanceOf(receiver), 100e18);
    }

    function testRedeemSyToTokenRevertsWhenTokenOutputIsBelowMinimum() external {
        underlying.mint(address(sy), 100e18);
        sy.mintShares(address(sy), 40e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInsufficientTokenOut.selector, 100e18, 101e18));
        router.redeemSyToToken(address(sy), owner, address(underlying), 100e18, 101e18);
    }

    function testRedeemSyToTokenRevertsWhenRedeemAmountIsZero() external {
        vm.prank(owner);
        vm.expectRevert(IStandardizedYield.SYZeroRedeem.selector);
        router.redeemSyToToken(address(sy), owner, address(underlying), 0, 0);
    }

    function testRedeemSyToTokenRevertsWhenTokenOutIsInvalid() external {
        address invalidTokenOut = address(0xBAD);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInvalidTokenOut.selector, invalidTokenOut));
        router.redeemSyToToken(address(sy), owner, invalidTokenOut, 100e18, 0);
    }

    function testWrapStakeFromSYMintsUAssetToRecipient() external {
        vm.prank(owner);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory data) = address(router)
            .call(abi.encodeWithSelector(IOutrunRouter.wrapStakeFromSY.selector, address(position), 100e18, owner, 0));

        assertTrue(ok, "wrapStakeFromSY missing");
        uint256 uAssetMinted = abi.decode(data, (uint256));

        assertEq(uAssetMinted, 100e18);
        assertEq(uAsset.balanceOf(owner), 100e18);
        assertEq(position.syWrapStaking(), 100e18);
    }

    function testRouterSuccessfulCallsLeaveNoResidualAllowanceWithoutExplicitApprovalClears() external {
        IOutrunRouter.StakeParam memory stakeParam =
            IOutrunRouter.StakeParam({lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: owner, receiver: owner});

        underlying.resetZeroApproveCount();
        sy.resetZeroApproveCount();
        uAsset.resetZeroApproveCount();

        vm.startPrank(owner);
        router.mintSYFromToken(address(sy), address(underlying), owner, 1e18, 0);
        assertEq(underlying.allowance(address(router), address(sy)), 0);
        assertEq(underlying.getZeroApproveCount(), 0);

        router.stakeFromToken(address(position), address(underlying), 1e18, stakeParam);
        assertEq(underlying.allowance(address(router), address(sy)), 0);
        assertEq(sy.allowance(address(router), address(position)), 0);
        assertEq(underlying.getZeroApproveCount(), 0);
        assertEq(sy.getZeroApproveCount(), 0);

        router.stakeFromSY(address(position), 1e18, stakeParam);
        assertEq(sy.allowance(address(router), address(position)), 0);
        assertEq(sy.getZeroApproveCount(), 0);

        router.wrapStakeFromToken(address(position), address(underlying), 1e18, 0, owner, 0);
        assertEq(underlying.allowance(address(router), address(sy)), 0);
        assertEq(sy.allowance(address(router), address(position)), 0);
        assertEq(underlying.getZeroApproveCount(), 0);
        assertEq(sy.getZeroApproveCount(), 0);

        router.wrapStakeFromSY(address(position), 1e18, owner, 0);
        assertEq(sy.allowance(address(router), address(position)), 0);
        assertEq(sy.getZeroApproveCount(), 0);

        router.genesisByToken(address(position), address(underlying), 1e18, 0, 30, 1, owner, 0);
        assertEq(underlying.allowance(address(router), address(sy)), 0);
        assertEq(sy.allowance(address(router), address(position)), 0);
        assertEq(uAsset.allowance(address(router), address(launcher)), 0);
        assertEq(underlying.getZeroApproveCount(), 0);
        assertEq(sy.getZeroApproveCount(), 0);
        assertEq(uAsset.getZeroApproveCount(), 0);

        router.genesisBySY(address(position), 1e18, 30, 1, owner, 0);
        assertEq(sy.allowance(address(router), address(position)), 0);
        assertEq(uAsset.allowance(address(router), address(launcher)), 0);
        assertEq(sy.getZeroApproveCount(), 0);
        assertEq(uAsset.getZeroApproveCount(), 0);
        vm.stopPrank();
    }

    function testMintSYFromTokenRevertsWhenApprovalAmountIsUint256Max() external {
        RouterMockSY freshSy = new RouterMockSY(address(underlying));
        uint256 maxDepositAmount = type(uint256).max;

        underlying.mint(owner, maxDepositAmount - underlying.balanceOf(owner));

        vm.prank(owner);
        router.setTrustedSY(address(freshSy), true);

        vm.prank(owner);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.mintSYFromToken(address(freshSy), address(underlying), owner, maxDepositAmount, 0);
    }

    function testMintSYFromTokenRevertsWhenSYIsNotTrustedBeforePullingFunds() external {
        RouterMockSY untrustedSy = new RouterMockSY(address(underlying));
        uint256 ownerBalanceBefore = underlying.balanceOf(owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.UntrustedRouterTarget.selector, address(untrustedSy)));
        router.mintSYFromToken(address(untrustedSy), address(underlying), owner, 100e18, 0);

        assertEq(underlying.balanceOf(owner), ownerBalanceBefore);
        assertEq(underlying.balanceOf(address(router)), 0);
    }

    function testStakeFromSYRevertsWhenSPIsRevokedBeforePullingFunds() external {
        IOutrunRouter.StakeParam memory stakeParam =
            IOutrunRouter.StakeParam({lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: owner, receiver: owner});
        uint256 ownerBalanceBefore = sy.balanceOf(owner);

        vm.prank(owner);
        router.setTrustedSP(address(position), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.UntrustedRouterTarget.selector, address(position)));
        router.stakeFromSY(address(position), 100e18, stakeParam);

        assertEq(sy.balanceOf(owner), ownerBalanceBefore);
        assertEq(sy.balanceOf(address(router)), 0);
    }

    function testSetTrustedSPRevertsWhenRegisteredSYDoesNotMatchSP() external {
        vm.mockCall(
            address(position), abi.encodeWithSelector(IOutrunStakeManager.SY.selector), abi.encode(address(underlying))
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOutrunRouter.RouterTargetMismatch.selector, address(position), address(sy), address(underlying)
            )
        );
        router.setTrustedSP(address(position), address(sy));
    }

    function testGenesisBySYUsesLockedStakeInsteadOfWrapStake() external {
        vm.prank(owner);
        router.genesisBySY(address(position), 100e18, 30, 1, owner, 0);

        (address positionOwner, uint256 syStaked, uint256 uAssetMinted, uint128 deadline) = position.positions(1);
        (uint256 verseId, uint128 launcherUAsset, address launcherUser) = launcher.snapshot();

        assertEq(positionOwner, owner);
        assertEq(syStaked, 100e18);
        assertEq(uAssetMinted, 100e18);
        assertEq(position.syWrapStaking(), 0);
        assertEq(position.syTotalStaking(), 100e18);
        assertEq(uAsset.balanceOf(owner), 0);
        assertEq(uAsset.balanceOf(address(router)), 0);
        assertEq(uAsset.balanceOf(address(launcher)), 100e18);
        assertEq(verseId, 1);
        assertEq(launcherUAsset, 100e18);
        assertEq(launcherUser, owner);
        assertEq(deadline, block.timestamp + 30 days);
    }

    function testStakeFromSYRevertsWhenMintedBelowMinimumUAsset() external {
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 101e18, owner: owner, receiver: address(0)
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.InsufficientUAssetMinted.selector, 100e18, 101e18));
        router.stakeFromSY(address(position), 100e18, stakeParam);
    }

    function testStakeFromSYMintsUAssetToReceiverWhenSpecified() external {
        address receiver = address(0xBEEF);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: owner, receiver: receiver
        });

        vm.prank(owner);
        (uint256 positionId, uint256 uAssetMinted) = router.stakeFromSY(address(position), 100e18, stakeParam);

        (address positionOwner, uint256 syStaked, uint256 positionUAssetMinted, uint128 deadline) =
            position.positions(positionId);

        // Position is owned by owner
        assertEq(positionOwner, owner);
        assertEq(syStaked, 100e18);
        assertEq(positionUAssetMinted, 100e18);
        // uAsset is minted to receiver
        assertEq(uAsset.balanceOf(receiver), 100e18);
        assertEq(uAsset.balanceOf(owner), 0);
        assertEq(uAssetMinted, 100e18);
        assertEq(deadline, block.timestamp + 30 days);
    }

    function testStakeFromSYDefaultsReceiverToOwnerWhenZero() external {
        // receiver = address(0) should behave like the old code: uAsset goes to owner
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: owner, receiver: address(0)
        });

        vm.prank(owner);
        (uint256 positionId, uint256 uAssetMinted) = router.stakeFromSY(address(position), 100e18, stakeParam);

        (address positionOwner, uint256 syStaked, uint256 positionUAssetMinted,) = position.positions(positionId);

        // Position is owned by owner
        assertEq(positionOwner, owner);
        assertEq(syStaked, 100e18);
        assertEq(positionUAssetMinted, 100e18);
        // uAsset is minted to owner since receiver is address(0)
        assertEq(uAsset.balanceOf(owner), 100e18);
        assertEq(uAssetMinted, 100e18);
    }

    function testStakeFromTokenMintsUAssetToReceiverWhenSpecified() external {
        address receiver = address(0xBEEF);

        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: owner, receiver: receiver
        });

        vm.prank(owner);
        (uint256 positionId, uint256 uAssetMinted) =
            router.stakeFromToken(address(position), address(underlying), 100e18, stakeParam);

        (address positionOwner, uint256 syStaked, uint256 positionUAssetMinted, uint128 deadline) =
            position.positions(positionId);

        // Position is owned by owner
        assertEq(positionOwner, owner);
        assertEq(syStaked, 100e18);
        assertEq(positionUAssetMinted, 100e18);
        // uAsset is minted to receiver
        assertEq(uAsset.balanceOf(receiver), 100e18);
        assertEq(uAsset.balanceOf(owner), 0);
        assertEq(uAssetMinted, 100e18);
        assertEq(deadline, block.timestamp + 30 days);
    }

    function testStakeFromTokenDefaultsReceiverToOwnerWhenZero() external {
        // receiver = address(0) should behave like the old code: uAsset goes to owner
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 0, minUAssetMinted: 0, owner: owner, receiver: address(0)
        });

        vm.prank(owner);
        (uint256 positionId, uint256 uAssetMinted) =
            router.stakeFromToken(address(position), address(underlying), 100e18, stakeParam);

        (address positionOwner, uint256 syStaked, uint256 positionUAssetMinted,) = position.positions(positionId);

        // Position is owned by owner
        assertEq(positionOwner, owner);
        assertEq(syStaked, 100e18);
        assertEq(positionUAssetMinted, 100e18);
        // uAsset is minted to owner since receiver is address(0)
        assertEq(uAsset.balanceOf(owner), 100e18);
        assertEq(uAssetMinted, 100e18);
    }

    function testStakeFromTokenRevertsWhenSyBelowMinimum() external {
        IOutrunRouter.StakeParam memory stakeParam = IOutrunRouter.StakeParam({
            lockupDays: 30, minSyOut: 101e18, minUAssetMinted: 0, owner: owner, receiver: address(0)
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouterMockSY.RouterInsufficientSharesOut.selector, 100e18, 101e18));
        router.stakeFromToken(address(position), address(underlying), 100e18, stakeParam);
    }

    function testWrapStakeFromTokenRevertsWhenSyBelowMinimum() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouterMockSY.RouterInsufficientSharesOut.selector, 100e18, 101e18));
        router.wrapStakeFromToken(address(position), address(underlying), 100e18, 101e18, owner, 0);
    }

    function testWrapStakeFromSYRevertsWhenUAssetBelowMinimum() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.InsufficientUAssetMinted.selector, 100e18, 101e18));
        router.wrapStakeFromSY(address(position), 100e18, owner, 101e18);
    }

    function testGenesisByTokenRevertsWhenSyBelowMinimum() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouterMockSY.RouterInsufficientSharesOut.selector, 100e18, 101e18));
        router.genesisByToken(address(position), address(underlying), 100e18, 101e18, 30, 1, owner, 0);
    }

    function testGenesisBySYRevertsWhenUAssetBelowMinimum() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.InsufficientUAssetMinted.selector, 100e18, 101e18));
        router.genesisBySY(address(position), 100e18, 30, 1, owner, 101e18);
    }

    function testGenesisBySYRevertsWhenMintedUAssetExceedsUint128Max() external {
        uint256 amountAboveCap = uint256(type(uint128).max) + 1;
        sy.mintShares(owner, amountAboveCap - sy.balanceOf(owner));
        vm.prank(owner);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.genesisBySY(address(position), amountAboveCap, 30, 1, owner, 0);
    }
}
