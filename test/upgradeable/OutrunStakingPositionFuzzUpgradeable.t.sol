// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {SYUtils} from "../../src/libraries/SYUtils.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";

/**
 * @title Fuzz tests for OutrunStakingPosition
 * @dev Covers arithmetic correctness, pro-rata calculations, rounding, preview consistency,
 *      and accounting invariants under various input ranges and exchange rates.
 */
contract OutrunStakingPositionFuzzTest is Test {
    MockERC20 internal underlying;
    MockSY internal sy;
    MockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;

    address internal owner = address(0xA11CE);
    address internal keeper = address(0xB0B);
    address internal revenuePool = address(0xFEE);
    address internal user1 = address(0x1111);
    address internal user2 = address(0x2222);

    // Constants for bounds
    uint256 internal constant MIN_STAKE = 1;
    uint256 internal constant MAX_STAKE = 10_000e18;
    uint256 internal constant RATE_MIN = 1e17; // 0.1
    uint256 internal constant RATE_MAX = 5e18; // 5.0

    function setUp() external {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, MIN_STAKE, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );

        uAsset.setMintingCap(address(position), type(uint256).max);

        // Mint SY to users
        sy.mintShares(owner, 100_000e18);
        sy.mintShares(keeper, 100_000e18);
        sy.mintShares(user1, 100_000e18);
        sy.mintShares(user2, 100_000e18);

        // Approve position to spend SY
        vm.prank(owner);
        sy.approve(address(position), type(uint256).max);
        vm.prank(keeper);
        sy.approve(address(position), type(uint256).max);
        vm.prank(user1);
        sy.approve(address(position), type(uint256).max);
        vm.prank(user2);
        sy.approve(address(position), type(uint256).max);

        // Approve position to spend uAsset
        vm.prank(owner);
        uAsset.approve(address(position), type(uint256).max);
        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);
        vm.prank(user1);
        uAsset.approve(address(position), type(uint256).max);
        vm.prank(user2);
        uAsset.approve(address(position), type(uint256).max);
    }

    // ============================================
    // Helper functions
    // ============================================

    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return bound(amount, MIN_STAKE, MAX_STAKE);
    }

    function _boundRate(uint256 rate) internal pure returns (uint256) {
        return bound(rate, RATE_MIN, RATE_MAX);
    }

    function _syToAsset(uint256 syAmount, uint256 rate) internal pure returns (uint256) {
        return SYUtils.syToAsset(rate, syAmount);
    }

    function _assetToSy(uint256 assetAmount, uint256 rate) internal pure returns (uint256) {
        return SYUtils.assetToSy(rate, assetAmount);
    }

    function _assetToSyUp(uint256 assetAmount, uint256 rate) internal pure returns (uint256) {
        return SYUtils.assetToSyUp(rate, assetAmount);
    }

    function _expectedRedeemBurn(uint256 positionUAssetMinted, uint256 syRedeemed, uint256 syStaked)
        internal
        pure
        returns (uint256)
    {
        if (syRedeemed == syStaked) return positionUAssetMinted;
        return Math.mulDiv(positionUAssetMinted, syRedeemed, syStaked, Math.Rounding.Ceil);
    }

    // ============================================
    // 1. Stake + DrawUAsset Fuzz
    // ============================================

    function testFuzz_StakeAndDrawUAsset(uint256 amountInSY, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        // Require at least 100% appreciation (rate = 2e18) to ensure drawable amount exists even for tiny amounts
        // For amountInSY=1: at rate 1e18, minted=1; at rate 2e18, value=2, drawable=1
        newRate = bound(newRate, 2e18, RATE_MAX);

        // Stake at initial rate 1e18
        vm.prank(owner);
        (uint256 positionId, uint256 initialMinted) = position.stake(amountInSY, 30, owner, owner);

        assertEq(initialMinted, amountInSY, "initial mint should equal amount at rate 1e18");

        // Change rate to appreciate
        sy.setExchangeRate(newRate);

        // Draw additional uAsset
        vm.prank(owner);
        uint256 drawAmount = position.drawUAsset(positionId, owner);

        uint256 expectedCurrentValue = _syToAsset(amountInSY, newRate);
        uint256 expectedDrawAmount = expectedCurrentValue - initialMinted;

        assertEq(drawAmount, expectedDrawAmount, "draw amount should match appreciation");

        // Verify position state after draw
        (, uint256 syStaked, uint256 positionUAssetMinted,) = position.positions(positionId);
        assertEq(syStaked, amountInSY, "syStaked should remain unchanged");
        assertEq(positionUAssetMinted, expectedCurrentValue, "UAssetMinted should equal current value after draw");
        assertEq(uAsset.balanceOf(owner), expectedCurrentValue, "owner should have total minted uAsset");
    }

    // ============================================
    // 2. Pro-Rata Redeem Fuzz
    // ============================================

    function testFuzz_ProRataRedeem(uint256 amountInSY, uint256 syRedeemed, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        syRedeemed = bound(syRedeemed, 1, amountInSY);
        // Require at least 100% appreciation to ensure drawable amount exists even for tiny amounts
        newRate = bound(newRate, 2e18, RATE_MAX);

        // Stake
        vm.prank(owner);
        (uint256 positionId,) = position.stake(amountInSY, 30, owner, owner);

        // Change rate and draw
        sy.setExchangeRate(newRate);
        vm.prank(owner);
        position.drawUAsset(positionId, owner);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position with SY for redemption
        sy.mintShares(address(position), syRedeemed);

        // Redeem
        vm.prank(owner);
        (uint256 uAssetBurned, uint256 syOut) = position.redeem(positionId, syRedeemed, owner, address(sy), 0);

        // Calculate expected pro-rata burn
        uint256 totalUAssetMinted = _syToAsset(amountInSY, newRate);
        uint256 expectedBurn = _expectedRedeemBurn(totalUAssetMinted, syRedeemed, amountInSY);

        assertEq(uAssetBurned, expectedBurn, "pro-rata burn should match calculation");
        assertEq(syOut, syRedeemed, "SY out should equal redeemed amount");

        // Verify remaining position state
        (, uint256 remainingSyStaked, uint256 remainingUAssetMinted,) = position.positions(positionId);
        assertEq(remainingSyStaked, amountInSY - syRedeemed, "remaining syStaked incorrect");
        assertEq(remainingUAssetMinted, totalUAssetMinted - expectedBurn, "remaining UAssetMinted incorrect");
    }

    function testRedeem_PartialLowRateRevertsWhenRoundedBurnConsumesAllDebt() public {
        bytes4 partialCloseError = bytes4(keccak256("PartialRedeemMustLeaveDebt()"));

        sy.setExchangeRate(5e17);

        vm.prank(owner);
        (uint256 positionId, uint256 minted) = position.stake(2, 30, owner, owner);
        assertEq(minted, 1, "minted debt should be 1 at low rate");

        vm.warp(block.timestamp + 31 days);

        vm.expectRevert(partialCloseError);
        position.previewRedeem(positionId, 1, address(sy));

        vm.prank(owner);
        vm.expectRevert(partialCloseError);
        position.redeem(positionId, 1, owner, address(sy), 0);
    }

    function testRedeem_PartialRoundsDebtBurnUpForPreviewAndExecution() public {
        sy.setExchangeRate(8e17);

        vm.prank(owner);
        (uint256 positionId, uint256 minted) = position.stake(3, 30, owner, owner);
        assertEq(minted, 2, "minted debt should be 2 at low rate");

        vm.warp(block.timestamp + 31 days);

        (uint256 previewBurn, uint256 previewSyOut) = position.previewRedeem(positionId, 1, address(sy));
        assertEq(previewBurn, 1, "preview should round debt burn up");
        assertEq(previewSyOut, 1, "preview SY out should match redeemed SY");

        vm.prank(owner);
        (uint256 actualBurn, uint256 actualSyOut) = position.redeem(positionId, 1, owner, address(sy), 0);

        assertEq(actualBurn, 1, "redeem should round debt burn up");
        assertEq(actualSyOut, 1, "redeem SY out should match redeemed SY");

        (, uint256 remainingSyStaked, uint256 remainingUAssetMinted,) = position.positions(positionId);
        assertEq(remainingSyStaked, 2, "remaining SY should be preserved");
        assertEq(remainingUAssetMinted, 1, "remaining debt should reflect rounded burn");
    }

    function testRedeem_FullLowRateBurnsExactRemainingDebt() public {
        sy.setExchangeRate(5e17);

        vm.prank(owner);
        (uint256 positionId, uint256 minted) = position.stake(2, 30, owner, owner);
        assertEq(minted, 1, "minted debt should be 1 at low rate");

        vm.warp(block.timestamp + 31 days);

        (uint256 previewBurn, uint256 previewSyOut) = position.previewRedeem(positionId, 2, address(sy));
        assertEq(previewBurn, minted, "full preview should burn all remaining debt");
        assertEq(previewSyOut, 2, "full preview SY out should match redeemed SY");

        vm.prank(owner);
        (uint256 actualBurn, uint256 actualSyOut) = position.redeem(positionId, 2, owner, address(sy), 0);

        assertEq(actualBurn, minted, "full redeem should burn exact remaining debt");
        assertEq(actualSyOut, 2, "full redeem SY out should match redeemed SY");

        (address positionOwner, uint256 remainingSyStaked, uint256 remainingUAssetMinted,) =
            position.positions(positionId);
        assertEq(positionOwner, address(0), "position should be deleted after full redeem");
        assertEq(remainingSyStaked, 0, "full redeem should leave no SY");
        assertEq(remainingUAssetMinted, 0, "full redeem should leave no debt");
    }

    // ============================================
    // 3. Full Redeem Deletes Position
    // ============================================

    function testFuzz_FullRedeemDeletesPosition(uint256 amountInSY) public {
        amountInSY = _boundAmount(amountInSY);

        // Stake
        vm.prank(owner);
        (uint256 positionId,) = position.stake(amountInSY, 30, owner, owner);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        uint256 syTotalBefore = position.syTotalStaking();

        // Fund position with SY for redemption
        sy.mintShares(address(position), amountInSY);

        // Full redeem
        vm.prank(owner);
        position.redeem(positionId, amountInSY, owner, address(sy), 0);

        // Verify position deleted
        (address positionOwner,,,) = position.positions(positionId);
        assertEq(positionOwner, address(0), "position should be deleted after full redeem");

        // Verify accounting
        assertEq(position.syTotalStaking(), syTotalBefore - amountInSY, "syTotalStaking should be reduced");
    }

    // ============================================
    // 4. KeepRedeem Split Fuzz
    // ============================================

    function testFuzz_KeepRedeemSplit(uint256 amountInSY, uint256 burnUAsset, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        // Keep rate at or above 1e18 to ensure totalMinted >= amountInSY > 0
        newRate = bound(newRate, 1e18, RATE_MAX);

        // Change rate first if needed
        if (newRate != 1e18) {
            sy.setExchangeRate(newRate);
        }

        // Stake at current rate
        vm.prank(owner);
        (uint256 positionId, uint256 totalMinted) = position.stake(amountInSY, 30, owner, owner);

        // Skip if totalMinted is 0 (shouldn't happen with rate >= 1e18 and amountInSY >= 1)
        vm.assume(totalMinted > 0);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Bound the burn amount so the proportional SY share is never zero (floor rounding) and the
        // keeper's debt-equivalent SY is at least 1 wei (keeper-side dust guard); both dust revert
        // paths and the undercollateralized path are covered by unit tests.
        uint256 keeperDustFloor = Math.ceilDiv(newRate, 1e18);
        uint256 minBurn = Math.max(Math.ceilDiv(totalMinted, amountInSY), keeperDustFloor);
        // Stakes whose whole debt cannot fund even 1 wei of keeper SY have no non-dust keepRedeem.
        vm.assume(minBurn <= totalMinted);
        burnUAsset = bound(burnUAsset, minBurn, totalMinted);
        uint256 syRedeemed = Math.mulDiv(amountInSY, burnUAsset, totalMinted);

        // Transfer uAsset to keeper
        vm.prank(owner);
        uAsset.transfer(keeper, burnUAsset);

        // Calculate expected values. Under the solvency guard the keeper's debt-equivalent share
        // never exceeds the proportional share; an undercollateralized position reverts with
        // InsufficientSyCollateral instead (unit-tested).
        uint256 keeperPrincipalSYRaw = _assetToSy(burnUAsset, newRate);
        uint256 expectedKeeperPrincipalSY = keeperPrincipalSYRaw;
        uint256 expectedOwnerExcessSY = syRedeemed - expectedKeeperPrincipalSY;

        // Fund position with SY for transfers
        sy.mintShares(address(position), syRedeemed);

        // KeepRedeem
        vm.prank(keeper);
        (uint256 uAssetBurned, uint256 keeperPrincipalSY, uint256 ownerExcessSY) =
            position.keepRedeem(positionId, burnUAsset, keeper);

        assertEq(uAssetBurned, burnUAsset, "burned amount should match input");
        assertLe(keeperPrincipalSY, syRedeemed, "keeperPrincipalSY never exceeds syRedeemed");
        assertEq(keeperPrincipalSY, expectedKeeperPrincipalSY, "keeperPrincipalSY calculation incorrect");
        assertEq(ownerExcessSY, expectedOwnerExcessSY, "ownerExcessSY calculation incorrect");
        assertEq(keeperPrincipalSY + ownerExcessSY, syRedeemed, "split should sum to syRedeemed");
    }

    // ============================================
    // 5. WrapStake + WrapRedeem Roundtrip
    // ============================================

    function testFuzz_WrapStakeRedeemRoundtrip(uint256 amountInSY, uint256 redeemUAsset, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        // Rate >= 1e18 keeps the pool healthy (wrap SY value covers debt face), so keepWrapRedeem
        // redeems at face value instead of reverting WrapPoolUndercollateralized.
        newRate = bound(newRate, 1e18, RATE_MAX);

        // WrapStake at initial rate 1e18
        vm.prank(owner);
        uint256 uAssetMinted = position.wrapStake(amountInSY, owner);

        assertEq(uAssetMinted, amountInSY, "wrap stake should mint equal uAsset at rate 1e18");
        assertEq(position.syWrapStaking(), amountInSY, "syWrapStaking incorrect");
        assertEq(position.wrapUAssetDebt(), amountInSY, "wrapUAssetDebt incorrect");

        // Change rate
        sy.setExchangeRate(newRate);

        redeemUAsset = bound(redeemUAsset, 1, uAssetMinted);

        // Independent expectation, not the contract's own preview: a healthy pool redeems at face
        // value (_assetToSy). Undercollateralized pools now revert (covered separately).
        uint256 expectedSYOut = _assetToSy(redeemUAsset, newRate);
        vm.assume(expectedSYOut > 0);

        // The depositor hands the wrap-minted uAsset to the keeper, who burns it on redemption.
        vm.prank(owner);
        uAsset.transfer(keeper, redeemUAsset);

        // KeepWrapRedeem (keeper-only)
        vm.prank(keeper);
        uint256 syOut = position.keepWrapRedeem(redeemUAsset, owner);

        assertEq(syOut, expectedSYOut, "wrap redeem SY out incorrect");

        // Verify accounting updates
        assertEq(position.syWrapStaking(), amountInSY - expectedSYOut, "syWrapStaking after redeem incorrect");
        assertEq(position.wrapUAssetDebt(), amountInSY - redeemUAsset, "wrapUAssetDebt after redeem incorrect");
        assertEq(position.syTotalStaking(), amountInSY - expectedSYOut, "syTotalStaking should track wrap pool changes");
    }

    // ============================================
    // 6. Preview vs Actual Consistency
    // ============================================

    function testFuzz_PreviewStakeMatchesActual(uint256 amountInSY) public {
        amountInSY = _boundAmount(amountInSY);

        uint256 previewed = position.previewStake(amountInSY);

        vm.prank(owner);
        (, uint256 actual) = position.stake(amountInSY, 30, owner, owner);

        assertEq(actual, previewed, "preview stake should match actual mint");
    }

    function testFuzz_PreviewRedeemMatchesActual(uint256 amountInSY, uint256 syRedeemed, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        syRedeemed = bound(syRedeemed, 1, amountInSY);
        // Require at least 100% appreciation to ensure drawable amount exists even for tiny amounts
        newRate = bound(newRate, 2e18, RATE_MAX);

        // Stake
        vm.prank(owner);
        (uint256 positionId,) = position.stake(amountInSY, 30, owner, owner);

        // Change rate and draw
        sy.setExchangeRate(newRate);
        vm.prank(owner);
        position.drawUAsset(positionId, owner);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Preview
        (uint256 previewedBurn, uint256 previewedOut) = position.previewRedeem(positionId, syRedeemed, address(sy));

        // Fund position for redemption
        sy.mintShares(address(position), syRedeemed);

        // Actual redeem
        vm.prank(owner);
        (uint256 actualBurn, uint256 actualOut) = position.redeem(positionId, syRedeemed, owner, address(sy), 0);

        assertEq(actualBurn, previewedBurn, "preview redeem burn should match actual");
        assertEq(actualOut, previewedOut, "preview redeem SY out should match actual");
    }

    function testFuzz_PreviewWrapRedeemMatchesActual(uint256 amountInSY, uint256 redeemUAsset, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        // Rate >= 1e18 keeps the pool healthy so preview and execution both succeed at face value;
        // below 1e18 the pool is undercollateralized and both preview and keepWrapRedeem revert.
        newRate = bound(newRate, 1e18, RATE_MAX);

        // WrapStake at rate 1e18
        vm.prank(owner);
        uint256 uAssetMinted = position.wrapStake(amountInSY, owner);

        // Change rate
        sy.setExchangeRate(newRate);

        redeemUAsset = bound(redeemUAsset, 1, uAssetMinted);
        uint256 expectedSYOut = _assetToSy(redeemUAsset, newRate);
        vm.assume(expectedSYOut > 0);

        // Preview (quote-only, mirrors keepWrapRedeem including the undercollateralized revert).
        uint256 previewed = position.previewWrapRedeem(redeemUAsset);

        // The depositor hands the wrap-minted uAsset to the keeper for burning.
        vm.prank(owner);
        uAsset.transfer(keeper, redeemUAsset);

        // Actual (keeper-only)
        vm.prank(keeper);
        uint256 actual = position.keepWrapRedeem(redeemUAsset, owner);

        assertEq(actual, previewed, "preview wrap redeem should match actual");
    }

    function testFuzz_PreviewDrawUAssetMatchesActual(uint256 amountInSY, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        // Require at least 100% appreciation to ensure drawable amount exists even for tiny amounts
        newRate = bound(newRate, 2e18, RATE_MAX);

        // Stake
        vm.prank(owner);
        (uint256 positionId,) = position.stake(amountInSY, 30, owner, owner);

        // Change rate
        sy.setExchangeRate(newRate);

        // Preview
        uint256 previewed = position.previewDrawUAsset(positionId);

        // Actual
        vm.prank(owner);
        uint256 actual = position.drawUAsset(positionId, owner);

        assertEq(actual, previewed, "preview draw should match actual");
    }

    // ============================================
    // 7. HarvestWrapYield Fuzz
    // ============================================

    function testHarvestWrapYieldRetainsCeilingDebtCoverageForNonDivisibleRate() public {
        uint256 amountInSY = 1e18;

        vm.prank(owner);
        uint256 wrapUAssetMinted = position.wrapStake(amountInSY, owner);
        assertEq(wrapUAssetMinted, amountInSY, "wrap stake should mint debt at rate 1e18");

        sy.setExchangeRate(3e18);

        vm.prank(owner);
        position.harvestWrapYield(address(sy), 0);

        uint256 remainingWrapSY = position.syWrapStaking();
        uint256 expectedRemainingWrapSY = SYUtils.assetToSyUp(3e18, position.wrapUAssetDebt());

        assertEq(remainingWrapSY, expectedRemainingWrapSY, "harvest should retain ceiling debt coverage");
        assertGe(
            SYUtils.syToAsset(3e18, remainingWrapSY),
            position.wrapUAssetDebt(),
            "remaining wrap SY must still cover wrap debt"
        );
    }

    function testFuzz_HarvestWrapYield(uint256 amountInSY, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        newRate = bound(newRate, 1e18, RATE_MAX);

        // WrapStake at rate 1e18
        vm.prank(owner);
        position.wrapStake(amountInSY, owner);

        // Change rate (appreciation creates yield)
        sy.setExchangeRate(newRate);

        // Calculate expected harvest
        uint256 wrapPoolSY = amountInSY;
        uint256 wrapDebtInSY = _assetToSyUp(amountInSY, newRate);
        uint256 expectedHarvest = wrapPoolSY > wrapDebtInSY ? wrapPoolSY - wrapDebtInSY : 0;

        // Harvest
        vm.prank(owner);
        uint256 harvested = position.harvestWrapYield(address(sy), 0);

        assertEq(harvested, expectedHarvest, "harvested amount incorrect");
        assertEq(sy.balanceOf(revenuePool), expectedHarvest, "revenue pool should receive harvest");

        // After harvest, syWrapStaking must retain ceiling SY coverage for wrap debt.
        uint256 remainingWrapSY = position.syWrapStaking();
        uint256 remainingDebtSY = _assetToSyUp(position.wrapUAssetDebt(), newRate);
        assertGe(remainingWrapSY, remainingDebtSY, "remaining wrap SY should cover debt");
        assertGe(
            SYUtils.syToAsset(newRate, remainingWrapSY),
            position.wrapUAssetDebt(),
            "remaining wrap SY asset value should cover debt"
        );
    }

    function testFuzz_HarvestWrapYieldReturnsZeroWhenNoYield(uint256 amountInSY, uint256 newRate) public {
        amountInSY = _boundAmount(amountInSY);
        newRate = bound(newRate, RATE_MIN, 1e18); // Rate <= 1e18 means no yield

        // WrapStake at rate 1e18
        vm.prank(owner);
        position.wrapStake(amountInSY, owner);

        // Change rate to same or lower
        sy.setExchangeRate(newRate);

        // Harvest should return 0
        vm.prank(owner);
        uint256 harvested = position.harvestWrapYield(address(sy), 0);

        assertEq(harvested, 0, "harvest should be zero when no yield");
        assertEq(sy.balanceOf(revenuePool), 0, "revenue pool should receive nothing");
    }

    // ============================================
    // 8. Multi-Position Accounting
    // ============================================

    function testFuzz_MultiPositionAccounting(uint256[4] memory amounts, uint256 newRate) public {
        // Bound all amounts
        for (uint256 i = 0; i < 4; i++) {
            amounts[i] = _boundAmount(amounts[i]);
        }
        // Ensure meaningful appreciation (at least 100% / 2x) to have drawable amounts
        newRate = bound(newRate, 2e18, RATE_MAX);

        // Create multiple positions
        uint256[] memory positionIds = new uint256[](4);
        uint256 totalStaked = 0;

        vm.prank(owner);
        (positionIds[0],) = position.stake(amounts[0], 30, owner, owner);
        totalStaked += amounts[0];

        vm.prank(user1);
        (positionIds[1],) = position.stake(amounts[1], 30, user1, user1);
        totalStaked += amounts[1];

        vm.prank(user2);
        (positionIds[2],) = position.stake(amounts[2], 30, user2, user2);
        totalStaked += amounts[2];

        // Wrap stake as well
        vm.prank(owner);
        position.wrapStake(amounts[3], owner);
        totalStaked += amounts[3];

        // Verify initial accounting
        assertEq(position.syTotalStaking(), totalStaked, "syTotalStaking should equal sum of all stakes");

        // Change rate
        sy.setExchangeRate(newRate);

        // Draw on some positions (will have drawable amount since rate doubled)
        vm.prank(owner);
        position.drawUAsset(positionIds[0], owner);

        vm.prank(user1);
        position.drawUAsset(positionIds[1], user1);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Partial redemption on first position
        uint256 partialRedeem = amounts[0] / 2;
        if (partialRedeem > 0) {
            sy.mintShares(address(position), partialRedeem);
            vm.prank(owner);
            position.redeem(positionIds[0], partialRedeem, owner, address(sy), 0);
        }

        // Verify accounting after partial redemption
        uint256 expectedTotal = (amounts[0] - partialRedeem) + amounts[1] + amounts[2] + amounts[3];
        assertEq(position.syTotalStaking(), expectedTotal, "syTotalStaking after partial redeem incorrect");
    }

    // ============================================
    // 9. Edge Cases - Zero Appreciation
    // ============================================

    function testFuzz_DrawUAssetZeroWhenNoAppreciation(uint256 amountInSY, uint256 rate) public {
        amountInSY = _boundAmount(amountInSY);
        rate = bound(rate, RATE_MIN, 1e18); // Rate <= 1e18

        // Stake
        vm.prank(owner);
        (uint256 positionId,) = position.stake(amountInSY, 30, owner, owner);

        // Set rate to same or lower
        sy.setExchangeRate(rate);

        // Preview should return 0
        uint256 previewed = position.previewDrawUAsset(positionId);
        assertEq(previewed, 0, "preview should be zero when no appreciation");
    }

    // ============================================
    // 10. Edge Cases - Rate Below 1
    // ============================================

    function testFuzz_WrapRedeemAtLowRate(uint256 amountInSY, uint256 lowRate, uint256 redeemBp) public {
        amountInSY = _boundAmount(amountInSY);
        lowRate = bound(lowRate, RATE_MIN, 9e17); // Rate < 1e18
        redeemBp = bound(redeemBp, 1, 100);

        // WrapStake at rate 1e18
        vm.prank(owner);
        uint256 uAssetMinted = position.wrapStake(amountInSY, owner);

        // Drop rate below 1: pool value < debt face → undercollateralized, keepWrapRedeem reverts
        // (all-or-nothing semantics; previously this paid pro-rata).
        sy.setExchangeRate(lowRate);

        uint256 redeemUAsset = Math.mulDiv(uAssetMinted, redeemBp, 100, Math.Rounding.Floor);
        vm.assume(redeemUAsset > 0); // skip dust redeem amounts (floor to zero)

        vm.prank(keeper);
        vm.expectRevert(IOutrunStakeManager.WrapPoolUndercollateralized.selector);
        position.keepWrapRedeem(redeemUAsset, keeper);
    }

    // ============================================
    // 11. Large Amount Handling (Beyond uint128)
    // ============================================

    function testFuzz_LargeAmountStake(uint128 amountInSY) public {
        // Use uint128 to avoid overflow in fuzzing, but still test large values
        // forge-lint: disable-next-line(unsafe-typecast)
        vm.assume(amountInSY >= uint128(MIN_STAKE));

        uint256 largeAmount = uint256(amountInSY);

        // Mint enough SY
        sy.mintShares(owner, largeAmount);

        vm.prank(owner);
        (uint256 positionId, uint256 uAssetMinted) = position.stake(largeAmount, 30, owner, owner);

        assertEq(uAssetMinted, largeAmount, "large amount stake mint incorrect");
        assertEq(position.syTotalStaking(), largeAmount, "syTotalStaking for large amount incorrect");

        (, uint256 syStaked, uint256 positionUAssetMinted,) = position.positions(positionId);
        assertEq(syStaked, largeAmount, "position syStaked incorrect");
        assertEq(positionUAssetMinted, largeAmount, "position UAssetMinted incorrect");
    }

    // ============================================
    // 12. Rounding Direction Tests
    // ============================================

    function testFuzz_RoundingDirectionSYConversion(uint256 amountInSY, uint256 rate) public pure {
        amountInSY = _boundAmount(amountInSY);
        rate = _boundRate(rate);

        // syToAsset rounds down: (syAmount * rate) / 1e18
        uint256 asset = _syToAsset(amountInSY, rate);

        // assetToSy rounds down: (asset * 1e18) / rate
        uint256 syBack = _assetToSy(asset, rate);

        // Due to rounding, syBack <= amountInSY
        assertLe(syBack, amountInSY, "round trip should not increase SY amount");
    }

    // ============================================
    // 13. Accounting Invariants After Multiple Operations
    // ============================================

    function testFuzz_AccountingInvariantsAfterMixedOps(
        uint256 stakeAmount1,
        uint256 stakeAmount2,
        uint256 wrapAmount,
        uint256 rate1,
        uint256 rate2
    ) public {
        stakeAmount1 = _boundAmount(stakeAmount1);
        stakeAmount2 = _boundAmount(stakeAmount2);
        wrapAmount = _boundAmount(wrapAmount);
        // Ensure meaningful appreciation (at least 100%) for drawable amounts
        rate1 = bound(rate1, 2e18, RATE_MAX);
        rate2 = bound(rate2, 2e18, RATE_MAX);

        // Create positions and wrap stake
        vm.prank(owner);
        (uint256 pos1,) = position.stake(stakeAmount1, 30, owner, owner);

        vm.prank(user1);
        position.stake(stakeAmount2, 30, user1, user1);

        vm.prank(owner);
        position.wrapStake(wrapAmount, owner);

        uint256 expectedTotal = stakeAmount1 + stakeAmount2 + wrapAmount;
        assertEq(position.syTotalStaking(), expectedTotal, "initial total incorrect");

        // Change rate and draw (guaranteed to have drawable amount with 100%+ appreciation)
        sy.setExchangeRate(rate1);
        vm.prank(owner);
        position.drawUAsset(pos1, owner);

        // Verify syTotalStaking unchanged after draw
        assertEq(position.syTotalStaking(), expectedTotal, "total should not change on draw");

        // Change rate again
        sy.setExchangeRate(rate2);

        // Warp and partial redeem
        vm.warp(block.timestamp + 31 days);

        uint256 partialRedeem = stakeAmount1 / 2;
        if (partialRedeem > 0) {
            sy.mintShares(address(position), partialRedeem);
            vm.prank(owner);
            position.redeem(pos1, partialRedeem, owner, address(sy), 0);

            expectedTotal -= partialRedeem;
            assertEq(position.syTotalStaking(), expectedTotal, "total after partial redeem incorrect");
        }

        // Harvest wrap yield if any
        vm.prank(owner);
        uint256 harvested = position.harvestWrapYield(address(sy), 0);

        if (harvested > 0) {
            expectedTotal -= harvested;
            assertEq(position.syTotalStaking(), expectedTotal, "total after harvest incorrect");
        }
    }

    // ============================================
    // 14. KeepRedeem Split Edge Cases
    // ============================================

    function testFuzz_KeepRedeemSplitAtLowRate(uint256 amountInSY, uint256 lowRate) public {
        lowRate = bound(lowRate, RATE_MIN, 5e17); // Very low rate

        // Dust stakes revert with DustRoundedToZero, so bound the stake amount to always mint at least
        // 1 uAsset (bound maps inputs instead of discarding them, per repo test rules).
        amountInSY = bound(amountInSY, Math.ceilDiv(1e18, lowRate), MAX_STAKE);

        // Set low rate
        sy.setExchangeRate(lowRate);

        // Stake at low rate
        vm.prank(owner);
        (uint256 positionId, uint256 totalMinted) = position.stake(amountInSY, 30, owner, owner);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Full keepRedeem
        vm.prank(owner);
        uAsset.transfer(keeper, totalMinted);

        uint256 syRedeemed = amountInSY;
        uint256 keeperPrincipalRaw = _assetToSy(totalMinted, lowRate);

        sy.mintShares(address(position), syRedeemed);

        vm.prank(keeper);
        (, uint256 keeperPrincipalSY, uint256 ownerExcessSY) = position.keepRedeem(positionId, totalMinted, keeper);

        // Under the full-position solvency guard, the keeper's debt-equivalent share can never exceed
        // the proportional SY share; an undercollateralized position reverts with
        // InsufficientSyCollateral instead (covered by unit tests). Floor conversion rounds down.
        assertEq(keeperPrincipalSY, keeperPrincipalRaw, "keeper principal should equal debt-equivalent SY");
        assertEq(ownerExcessSY, syRedeemed - keeperPrincipalRaw, "owner gets remainder");

        assertEq(keeperPrincipalSY + ownerExcessSY, syRedeemed, "total should equal syRedeemed");
    }
}
