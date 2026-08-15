// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";
import {MockPositionUUPSV2} from "./mocks/MockUUPSVersion.sol";
import {RejectZeroTransferMockSY} from "./mocks/PositionMocks.sol";

contract OutrunStakingPositionUpgradeableTest is PositionStackTestBase {
    MockERC20 internal mixedUnderlying;
    MockSY internal mixedSy;
    MockUAsset internal mixedUAsset;
    OutrunStakingPositionUpgradeable internal mixedPosition;

    function setUp() external {
        _deployPositionStack();

        vm.startPrank(user);
        token.approve(address(sy), type(uint256).max);
        sy.deposit(user, address(token), 100e18, 0);
        sy.approve(address(position), type(uint256).max);
        vm.stopPrank();
    }

    function testInitializeSetsOwnerSyUAssetRevenuePoolMinStake() external view {
        assertEq(position.owner(), owner);
        assertEq(position.SY(), address(sy));
        assertEq(position.uAsset(), address(uAsset));
        assertEq(position.revenuePool(), revenuePool);
        assertEq(position.keeper(), keeper);
        assertEq(position.minStake(), 1);
    }

    function testSyHasNoSetterAndRemainsFixed() external {
        (bool success,) = address(position).call(abi.encodeWithSignature("setSY(address)", address(0x1234)));

        assertFalse(success);
        assertEq(position.SY(), address(sy));
    }

    function testInitializeCannotRunTwice() external {
        vm.expectRevert();
        position.initialize(owner, 1, revenuePool, address(sy), address(uAsset), keeper);
    }

    function testInitializeRevertsWhenKeeperIsZero() external {
        OutrunStakingPositionUpgradeable positionImpl = new OutrunStakingPositionUpgradeable();

        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        ProxyTestHelper.deploy(
            address(positionImpl),
            abi.encodeCall(
                OutrunStakingPositionUpgradeable.initialize,
                (owner, 1, revenuePool, address(sy), address(uAsset), address(0))
            )
        );
    }

    function testKeepRedeemWorksWithInitializerKeeper() external {
        vm.prank(user);
        (uint256 positionId,) = position.stake(10e18, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.startPrank(keeper);
        uAsset.approve(address(position), 10e18);
        (uint256 burned, uint256 keeperPrincipalSY, uint256 ownerExcessSY) =
            position.keepRedeem(positionId, 10e18, keeper);
        vm.stopPrank();

        assertEq(burned, 10e18);
        assertEq(keeperPrincipalSY, 10e18);
        assertEq(ownerExcessSY, 0);
        assertEq(sy.balanceOf(keeper), 10e18);
        assertEq(uAsset.balanceOf(keeper), 0);
    }

    function testKeepRedeemSkipsOwnerZeroSyTransferForRejectingToken() external {
        MockERC20 underlying = new MockERC20("Mock Asset", "mAST");
        RejectZeroTransferMockSY zeroRejectSy = new RejectZeroTransferMockSY(address(underlying));
        MockUAsset localUAsset = new MockUAsset();
        OutrunStakingPositionUpgradeable localPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(zeroRejectSy), address(localUAsset), keeper)
                )
            )
        );

        localUAsset.setMintingCap(address(localPosition), type(uint256).max);
        zeroRejectSy.mintShares(user, 10e18);

        vm.prank(user);
        zeroRejectSy.approve(address(localPosition), type(uint256).max);

        vm.prank(user);
        (uint256 positionId,) = localPosition.stake(10e18, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.startPrank(keeper);
        localUAsset.approve(address(localPosition), 10e18);
        (uint256 burned, uint256 keeperPrincipalSY, uint256 ownerExcessSY) =
            localPosition.keepRedeem(positionId, 10e18, keeper);
        vm.stopPrank();

        assertEq(burned, 10e18);
        assertEq(keeperPrincipalSY, 10e18);
        assertEq(ownerExcessSY, 0);
        assertEq(zeroRejectSy.balanceOf(keeper), 10e18);
        assertEq(zeroRejectSy.balanceOf(user), 0);
    }

    function testStakeThroughProxyAndUpgradePreservesState() external {
        vm.prank(user);
        (uint256 positionId, uint256 minted) = position.stake(10e18, 30, user, user);

        assertEq(positionId, 1);
        assertEq(minted, 10e18);
        assertEq(position.syTotalStaking(), 10e18);
        assertEq(uAsset.balanceOf(user), 10e18);

        MockPositionUUPSV2 implementationV2 = new MockPositionUUPSV2();
        vm.prank(owner);
        position.upgradeToAndCall(address(implementationV2), "");

        assertEq(position.syTotalStaking(), 10e18);
        assertEq(position.SY(), address(sy));
        assertEq(MockPositionUUPSV2(address(position)).version(), 2);
    }

    function testStakeRevertsWhenDeadlineWouldExceedUint128() external {
        // floor((2^128 - 1) / 86400) is the largest lockup whose day-product still fits uint128, yet at
        // any realistic timestamp it pushes the deadline past uint128.max. The guard must reject it;
        // otherwise the narrowing cast would wrap the stored deadline into the past and bypass the lock.
        vm.warp(1_700_000_000);
        uint128 truncating = type(uint128).max / 1 days;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.LockupDaysOutOfRange.selector, truncating));
        position.stake(10e18, truncating, user, user);
    }

    function testStakeComputesDeadlineAsNowPlusLockupDays() external {
        vm.prank(user);
        (uint256 positionId,) = position.stake(10e18, 3650, user, user);

        (,,, uint128 deadline) = position.positions(positionId);
        assertEq(deadline, uint128(block.timestamp + 3650 * 1 days), "deadline must equal now + lockupDays");
    }

    function testStakeZeroLockupDaysIsImmediatelyRedeemable() external {
        vm.prank(user);
        (uint256 positionId,) = position.stake(10e18, 0, user, user);

        (,,, uint128 deadline) = position.positions(positionId);
        assertEq(deadline, uint128(block.timestamp), "zero-day deadline equals now");

        // No time warp: the lock check passes in the same block, so the position redeems at once.
        vm.startPrank(user);
        uAsset.approve(address(position), 10e18);
        position.redeem(positionId, 10e18, user, address(sy), 0);
        vm.stopPrank();
        assertEq(position.syTotalStaking(), 0, "position redeemed same block as stake");
    }

    function testNonOwnerCannotUpgrade() external {
        MockPositionUUPSV2 implementationV2 = new MockPositionUUPSV2();
        vm.prank(user);
        vm.expectRevert();
        position.upgradeToAndCall(address(implementationV2), "");
    }

    function testRedeemDirectSYHonorsMinTokenOut() external {
        vm.prank(user);
        (uint256 positionId,) = position.stake(10e18, 30, user, user);

        vm.warp(block.timestamp + 31 days);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.InsufficientTokenOut.selector, 10e18, 10e18 + 1));
        position.redeem(positionId, 10e18, user, address(sy), 10e18 + 1);

        (, uint256 syStaked, uint256 uAssetMinted,) = position.positions(positionId);
        assertEq(syStaked, 10e18);
        assertEq(uAssetMinted, 10e18);
        assertEq(sy.balanceOf(user), 90e18);
        assertEq(sy.balanceOf(address(position)), 10e18);
        assertEq(uAsset.balanceOf(user), 10e18);
    }

    function testMixedDecimalsStakeMintsUAssetInEighteenDecimals() external {
        _setupMixedDecimalsPosition();

        assertEq(mixedPosition.previewStake(1e6), 1e18);

        vm.prank(user);
        (uint256 positionId, uint256 minted) = mixedPosition.stake(1e6, 30, user, user);

        (, uint256 syStaked, uint256 uAssetMinted,) = mixedPosition.positions(positionId);
        assertEq(minted, 1e18);
        assertEq(syStaked, 1e6);
        assertEq(uAssetMinted, 1e18);
        assertEq(mixedUAsset.balanceOf(user), 1e18);
    }

    function testMixedDecimalsPreviewsStakeAndWrapStakeInUAssetUnits() external {
        _setupMixedDecimalsPosition();

        assertEq(mixedPosition.previewStake(1e6), 1e18);
        assertEq(mixedPosition.previewWrapStake(1e6), 1e18);
    }

    function testMixedDecimalsWrapStakeRevertsWhenUAssetRoundsToZero() external {
        _setupMixedDecimalsPosition();
        mixedSy.setExchangeRate(1);

        uint256 syWrapStakingBefore = mixedPosition.syWrapStaking();
        uint256 syTotalStakingBefore = mixedPosition.syTotalStaking();
        uint256 wrapUAssetDebtBefore = mixedPosition.wrapUAssetDebt();
        uint256 userSYBefore = mixedSy.balanceOf(user);
        uint256 userUAssetBefore = mixedUAsset.balanceOf(user);

        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.previewWrapStake(1);

        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.wrapStake(1, user);

        assertEq(mixedPosition.syWrapStaking(), syWrapStakingBefore);
        assertEq(mixedPosition.syTotalStaking(), syTotalStakingBefore);
        assertEq(mixedPosition.wrapUAssetDebt(), wrapUAssetDebtBefore);
        assertEq(mixedSy.balanceOf(user), userSYBefore);
        assertEq(mixedUAsset.balanceOf(user), userUAssetBefore);
    }

    function testMixedDecimalsStakeRevertsWhenDustRoundsToZero() external {
        _setupMixedDecimalsPosition();
        mixedSy.setExchangeRate(1);

        uint256 syTotalStakingBefore = mixedPosition.syTotalStaking();
        uint256 userSYBefore = mixedSy.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.stake(1, 30, user, user);

        // No state may change: SY must not be pulled, and no position may be created.
        assertEq(mixedPosition.syTotalStaking(), syTotalStakingBefore);
        assertEq(mixedSy.balanceOf(user), userSYBefore);
        (address positionOwner,,,) = mixedPosition.positions(1);
        assertEq(positionOwner, address(0));

        // The failed dust stake must not have consumed the position id counter: a fresh stake at a
        // normal rate still receives id 1.
        mixedSy.setExchangeRate(1e18);
        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, user);
        assertEq(positionId, 1);
    }

    function testStakeWithZeroAmountRevertsZeroInput() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        mixedPosition.stake(0, 30, user, user);
    }

    function testMixedDecimalsDrawUAssetUsesEighteenDecimalsAfterRateIncrease() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, user);

        mixedSy.setExchangeRate(15e17);

        assertEq(mixedPosition.previewDrawUAsset(positionId), 5e17);

        vm.prank(user);
        uint256 drawn = mixedPosition.drawUAsset(positionId, user);

        (, uint256 syStaked, uint256 uAssetMinted,) = mixedPosition.positions(positionId);
        assertEq(drawn, 5e17);
        assertEq(syStaked, 1e6);
        assertEq(uAssetMinted, 15e17);
        assertEq(mixedUAsset.balanceOf(user), 15e17);
    }

    function testMixedDecimalsKeepWrapRedeemConvertsEighteenDecimalsUAssetToSixDecimalsSY() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        uint256 minted = mixedPosition.wrapStake(1e6, user);

        assertEq(minted, 1e18);
        assertEq(mixedPosition.previewWrapRedeem(1e18), 1e6);

        // The depositor hands the wrap-minted uAsset to the keeper, who burns it on redemption.
        vm.prank(user);
        mixedUAsset.transfer(keeper, 1e18);

        vm.prank(keeper);
        mixedUAsset.approve(address(mixedPosition), 1e18);

        vm.prank(keeper);
        uint256 amountOut = mixedPosition.keepWrapRedeem(1e18, user);

        assertEq(amountOut, 1e6);
        assertEq(mixedSy.balanceOf(user), 10e6);
        assertEq(mixedUAsset.balanceOf(user), 0);
        assertEq(mixedPosition.syWrapStaking(), 0);
        assertEq(mixedPosition.wrapUAssetDebt(), 0);
    }

    function testPreviewWrapRedeemRevertsWhenAmountExceedsWrapDebt() external {
        vm.prank(user);
        position.wrapStake(100e18, user);

        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.ExceedsWrapDebt.selector, 101e18, 100e18));
        position.previewWrapRedeem(101e18);
    }

    function testPreviewWrapRedeemRevertsWhenPoolSYIsInsufficient() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        mixedPosition.wrapStake(1e6, user);

        mixedSy.setExchangeRate(5e17);

        // Rate 0.5: pool 1e6 SY (worth 5e5) < debt 1e18 uAsset (face 1e6 canonical).
        // Undercollateralized pools now revert instead of paying pro-rata (all-or-nothing).
        vm.expectRevert(IOutrunStakeManager.WrapPoolUndercollateralized.selector);
        mixedPosition.previewWrapRedeem(1e18);
    }

    function testPreviewWrapRedeemRevertsWhenDustUAssetRoundsToZeroSY() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        mixedPosition.wrapStake(1e6, user);

        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.previewWrapRedeem(1);
    }

    function testMixedDecimalsKeepWrapRedeemRevertsWhenDustUAssetRoundsToZeroSY() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        uint256 minted = mixedPosition.wrapStake(1e6, user);

        uint256 syWrapStakingBefore = mixedPosition.syWrapStaking();
        uint256 syTotalStakingBefore = mixedPosition.syTotalStaking();
        uint256 wrapUAssetDebtBefore = mixedPosition.wrapUAssetDebt();
        uint256 userSYBefore = mixedSy.balanceOf(user);
        uint256 userUAssetBefore = mixedUAsset.balanceOf(user);

        // Dust check (1 uAsset → 0 SY after decimal downscale) reverts before any state change;
        // the keeper therefore needs no uAsset balance for this revert path.
        vm.prank(keeper);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.keepWrapRedeem(1, keeper);

        assertEq(minted, 1e18);
        assertEq(syWrapStakingBefore, 1e6);
        assertEq(syTotalStakingBefore, 1e6);
        assertEq(wrapUAssetDebtBefore, 1e18);
        assertEq(mixedPosition.syWrapStaking(), syWrapStakingBefore);
        assertEq(mixedPosition.syTotalStaking(), syTotalStakingBefore);
        assertEq(mixedPosition.wrapUAssetDebt(), wrapUAssetDebtBefore);
        assertEq(mixedSy.balanceOf(user), userSYBefore);
        assertEq(mixedUAsset.balanceOf(user), userUAssetBefore);
    }

    function testRedeemUpdatesPositionStateBeforeRepay() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, user);

        vm.warp(block.timestamp + 31 days);

        vm.prank(user);
        mixedUAsset.approve(address(mixedPosition), 5e17);
        mixedUAsset.probePositionDuringRepay(mixedPosition, positionId);

        vm.prank(user);
        mixedPosition.redeem(positionId, 5e5, user, address(mixedSy), 5e5);

        (, uint256 syStakedDuringRepay, uint256 uAssetMintedDuringRepay,) = mixedPosition.positions(positionId);
        assertEq(syStakedDuringRepay, 5e5);
        assertEq(uAssetMintedDuringRepay, 5e17);
        assertEq(mixedUAsset.syStakedDuringRepay(), 5e5);
        assertEq(mixedUAsset.uAssetMintedDuringRepay(), 5e17);
        assertEq(mixedUAsset.syTotalStakingDuringRepay(), 5e5);
    }

    function testWrapRedeemUpdatesWrapPoolStateBeforeRepay() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        mixedPosition.wrapStake(1e6, user);

        // The probe reads wrap-pool state during the repay() callback inside keepWrapRedeem.
        mixedUAsset.probePositionDuringRepay(mixedPosition, 0);

        // Depositor transfers the wrap-minted uAsset to the keeper, who burns 5e17 on redemption.
        vm.prank(user);
        mixedUAsset.transfer(keeper, 5e17);
        vm.prank(keeper);
        mixedUAsset.approve(address(mixedPosition), 5e17);

        vm.prank(keeper);
        mixedPosition.keepWrapRedeem(5e17, keeper);

        assertEq(mixedUAsset.syTotalStakingDuringRepay(), 5e5);
        assertEq(mixedUAsset.syWrapStakingDuringRepay(), 5e5);
        assertEq(mixedUAsset.wrapUAssetDebtDuringRepay(), 5e17);
    }

    function testKeepWrapRedeemRevertsWhenCallerIsNotKeeper() external {
        vm.prank(user);
        position.wrapStake(100e18, user);

        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.PermissionDenied.selector);
        position.keepWrapRedeem(100e18, user);
    }

    function testMixedDecimalsKeepRedeemSplitsKeeperPrincipalAndOwnerExcessInSYUnits() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        mixedSy.setExchangeRate(2e18);
        vm.warp(block.timestamp + 31 days);

        vm.startPrank(keeper);
        mixedUAsset.approve(address(mixedPosition), type(uint256).max);
        (uint256 burned, uint256 keeperPrincipalSY, uint256 ownerExcessSY) =
            mixedPosition.keepRedeem(positionId, 1e18, keeper);
        vm.stopPrank();

        assertEq(burned, 1e18);
        assertEq(keeperPrincipalSY, 5e5);
        assertEq(ownerExcessSY, 5e5);
        assertEq(mixedSy.balanceOf(keeper), 5e5);
        assertEq(mixedSy.balanceOf(user), 9_500000);
    }

    function testKeepRedeemRevertsWhenPositionIsUndercollateralized() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        mixedSy.setExchangeRate(5e17);
        vm.warp(block.timestamp + 31 days);

        (, uint256 syStakedBefore, uint256 uAssetMintedBefore,) = mixedPosition.positions(positionId);
        uint256 userSYBefore = mixedSy.balanceOf(user);
        uint256 keeperUAssetBefore = mixedUAsset.balanceOf(keeper);

        vm.startPrank(keeper);
        mixedUAsset.approve(address(mixedPosition), type(uint256).max);
        vm.expectRevert(IOutrunStakeManager.InsufficientSyCollateral.selector);
        mixedPosition.keepRedeem(positionId, 1e18, keeper);
        vm.stopPrank();

        // Revert must be atomic: keeper uAsset is not burned and position state is unchanged.
        (, uint256 syStakedAfter, uint256 uAssetMintedAfter,) = mixedPosition.positions(positionId);
        assertEq(syStakedAfter, syStakedBefore);
        assertEq(uAssetMintedAfter, uAssetMintedBefore);
        assertEq(mixedSy.balanceOf(user), userSYBefore);
        assertEq(mixedUAsset.balanceOf(keeper), keeperUAssetBefore);
    }

    function testKeepRedeemRevertsOnZeroAmount() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.startPrank(keeper);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        mixedPosition.keepRedeem(positionId, 0, keeper);
        vm.stopPrank();
    }

    function testKeepRedeemRevertsWhenDustUAssetRoundsToZeroSY() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.startPrank(keeper);
        mixedUAsset.approve(address(mixedPosition), type(uint256).max);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.keepRedeem(positionId, 1, keeper);
        vm.stopPrank();
    }

    function testPreviewKeepRedeemMatchesKeepRedeemSplit() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        mixedSy.setExchangeRate(2e18);
        vm.warp(block.timestamp + 31 days);

        (uint256 keeperPrincipalSY, uint256 ownerExcessSY) = mixedPosition.previewKeepRedeem(positionId, 1e18);
        assertEq(keeperPrincipalSY, 5e5);
        assertEq(ownerExcessSY, 5e5);
    }

    function testPreviewKeepRedeemRevertsWhenUndercollateralized() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        mixedSy.setExchangeRate(5e17);
        vm.warp(block.timestamp + 31 days);

        vm.expectRevert(IOutrunStakeManager.InsufficientSyCollateral.selector);
        mixedPosition.previewKeepRedeem(positionId, 1e18);
    }

    function testPreviewKeepRedeemRevertsWhenAmountExceedsPositionDebt() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.ExceedsPositionDebt.selector, 1e18 + 1, 1e18));
        mixedPosition.previewKeepRedeem(positionId, 1e18 + 1);
    }

    function testPreviewKeepRedeemRevertsBeforeDeadline() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        (,,, uint128 deadline) = mixedPosition.positions(positionId);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.LockTimeNotExpired.selector, deadline));
        mixedPosition.previewKeepRedeem(positionId, 1e18);
    }

    function testPreviewKeepRedeemRevertsWhenPositionMissing() external {
        _setupMixedDecimalsPosition();

        vm.expectRevert(IOutrunStakeManager.PositionAccessDenied.selector);
        mixedPosition.previewKeepRedeem(999, 1e18);
    }

    function testPreviewKeepRedeemRevertsOnZeroAmount() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        mixedPosition.previewKeepRedeem(positionId, 0);
    }

    function testPreviewKeepRedeemRevertsWhenDustRoundsToZeroSY() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        (uint256 positionId,) = mixedPosition.stake(1e6, 30, user, keeper);

        vm.warp(block.timestamp + 31 days);

        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        mixedPosition.previewKeepRedeem(positionId, 1);
    }

    function testMixedDecimalsHarvestWrapYieldHarvestsOnlyExcessWithUpRounding() external {
        _setupMixedDecimalsPosition();

        vm.prank(user);
        uint256 minted = mixedPosition.wrapStake(1_000001, user);
        assertEq(minted, 1000001e12);

        mixedSy.setExchangeRate(3e18);

        vm.prank(owner);
        uint256 harvested = mixedPosition.harvestWrapYield(address(mixedSy), 0);

        uint256 expectedDebtInSY = 333334;
        uint256 expectedHarvest = 666667;
        assertEq(harvested, expectedHarvest);
        assertEq(mixedPosition.syWrapStaking(), expectedDebtInSY);
        assertEq(mixedPosition.wrapUAssetDebt(), minted);
        assertEq(mixedSy.balanceOf(revenuePool), expectedHarvest);
    }

    function _setupMixedDecimalsPosition() internal {
        mixedUnderlying = new MockERC20("Mock USDC", "mUSDC");
        mixedUnderlying.setDecimals(6);
        mixedSy = new MockSY(address(mixedUnderlying));
        mixedSy.setDecimals(6, 6);
        mixedUAsset = new MockUAsset();

        mixedPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(mixedSy), address(mixedUAsset), keeper)
                )
            )
        );

        mixedUAsset.setMintingCap(address(mixedPosition), type(uint256).max);
        mixedSy.mintShares(user, 10e6);

        vm.prank(user);
        mixedSy.approve(address(mixedPosition), type(uint256).max);
    }
}
