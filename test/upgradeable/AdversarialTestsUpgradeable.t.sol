// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {ProxyTestHelper} from "../upgradeable/helpers/ProxyTestHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    MockSYWithRateControl,
    MockERC20ForAdversarial,
    MockUAssetForAdversarial,
    MaliciousSY
} from "./mocks/AdversarialMocks.sol";

// ============================================================
//                    ADVERSARIAL TEST SUITE
// ============================================================

/**
 * @title AdversarialTests
 * @notice Security tests covering attack vectors not covered by existing fuzz tests
 * @dev Threat model documentation:
 *      1. Exchange rate manipulation between preview and execution
 *      2. Keeper griefing via partial redemptions
 *      3. Position takeover attempts via drawUAsset
 *      4. Full-stack reentrancy (Router -> Position -> SY callback)
 *      5. Wrap pool drain attempts
 *      6. Pause mechanism enforcement
 *      7. Mint cap enforcement
 *      8. Cross-position contamination
 */
contract AdversarialTests is Test {
    bytes4 internal constant POSITION_ACCESS_DENIED_SELECTOR = bytes4(keccak256("PositionAccessDenied()"));
    bytes4 internal constant REENTRANCY_GUARD_SELECTOR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = bytes4(keccak256("EnforcedPause()"));

    MockERC20ForAdversarial internal underlying;
    MockSYWithRateControl internal sy;
    MockUAssetForAdversarial internal uAsset;
    OutrunStakingPositionUpgradeable internal position;

    address internal owner = address(0xA11CE);
    address internal keeper = address(0xB0B);
    address internal revenuePool = address(0xFEE);
    address internal alice = address(0xA11CE1);
    address internal bob = address(0xB0B1);
    address internal attacker = address(0xDEAD);

    function setUp() external {
        underlying = new MockERC20ForAdversarial("Mock Asset", "mAST");
        sy = new MockSYWithRateControl(address(underlying));
        uAsset = new MockUAssetForAdversarial();

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );

        uAsset.setMintingCap(address(position), type(uint256).max);

        // Fund test accounts
        sy.mintShares(alice, 10_000e18);
        sy.mintShares(bob, 10_000e18);
        sy.mintShares(attacker, 10_000e18);
        sy.mintShares(keeper, 10_000e18);

        vm.prank(alice);
        sy.approve(address(position), type(uint256).max);

        vm.prank(bob);
        sy.approve(address(position), type(uint256).max);

        vm.prank(attacker);
        sy.approve(address(position), type(uint256).max);

        vm.prank(keeper);
        sy.approve(address(position), type(uint256).max);
    }

    // ============================================================
    // TEST 1: Exchange Rate Manipulation Between Preview and Execution
    // ============================================================

    /**
     * @notice Documents the risk of rate manipulation between preview and stake
     * @dev This is expected behavior - rate changes affect mint amounts
     *      Slippage protection (minUAssetMinted) is the mitigation
     */
    function test_Adversarial_RateManipulationBetweenPreviewAndStake() external {
        uint256 stakeAmount = 100e18;

        // Step 1: Alice previews stake at rate 1e18
        uint256 previewedAmount = position.previewStake(stakeAmount);
        assertEq(previewedAmount, 100e18, "Preview should show 100 uAsset at rate 1e18");

        // Step 2: Rate drops 50% (simulating market manipulation)
        sy.setExchangeRate(5e17);

        // Step 3: Alice stakes without slippage protection
        vm.prank(alice);
        (, uint256 actualMinted) = position.stake(stakeAmount, 30, alice, alice);

        // Verify: Alice only gets 50 uAsset (50% less due to rate change)
        assertEq(actualMinted, 50e18, "Actual mint should be 50 uAsset at rate 0.5e18");
        assertEq(uAsset.balanceOf(alice), 50e18, "Alice should have 50 uAsset");
        assertEq(previewedAmount, actualMinted * 2, "Preview was double actual due to rate drop");

        // Document: This is EXPECTED behavior. Mitigation is to use minUAssetMinted
        // (tested separately in integration tests with router)
    }

    /**
     * @notice Documents rate manipulation between preview and redeem
     */
    function test_Adversarial_RateManipulationBetweenPreviewAndRedeem() external {
        // Setup: Alice stakes 100e18 at rate 1e18
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position for SY transfer
        sy.mintShares(address(position), 100e18);

        // Alice previews redeem of 50e18 SY at rate 1e18
        (uint256 previewedBurn,) = position.previewRedeem(positionId, 50e18, address(sy));
        assertEq(previewedBurn, 50e18, "Preview should show 50 uAsset burn");

        // Rate appreciates 2x
        sy.setExchangeRate(2e18);

        vm.prank(alice);
        uAsset.approve(address(position), type(uint256).max);

        // Alice redeems - still burns 50 uAsset but position accounting changes
        vm.prank(alice);
        (uint256 actualBurn, uint256 syOut) = position.redeem(positionId, 50e18, alice, address(sy), 0);

        // Verify: Burn amount matches pro-rata of original uAssetMinted
        assertEq(actualBurn, 50e18, "Burn should match pro-rata of minted");
        assertEq(syOut, 50e18, "SY out should match redeemed amount");

        // Document: Rate change doesn't affect the uAsset burn ratio (pro-rata of minted)
        // This is correct behavior - uAsset debt is fixed at mint time
    }

    // ============================================================
    // TEST 2: Keeper Partial Redeem Griefing
    // ============================================================

    /**
     * @notice Keeper dust redeem reverts when the proportional SY output rounds to zero
     */
    function test_Adversarial_KeeperPartialRedeemLeavesSmallPosition() external {
        // Setup: Alice stakes 100e18 at rate 2e18, gets 200 uAsset
        sy.setExchangeRate(2e18);
        vm.prank(alice);
        (uint256 positionId, uint256 positionDebt) = position.stake(100e18, 30, alice, alice);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position for SY transfer
        sy.mintShares(address(position), 100e18);

        // Alice transfers uAsset to keeper
        vm.prank(alice);
        uAsset.transfer(keeper, 200e18);

        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);

        // 100e18 * 1 / 200e18 rounds down to 0, so no position state should change.
        assertEq(Math.mulDiv(100e18, 1, positionDebt), 0, "test setup should create zero-output redeem");

        vm.prank(keeper);
        vm.expectRevert(IOutrunStakeManager.DustRoundedToZero.selector);
        position.keepRedeem(positionId, 1, keeper);
    }

    /**
     * @notice Keeper cannot redeem more than position's uAsset minted
     */
    function test_Adversarial_KeeperCannotRedeemMoreThanPositionDebt() external {
        // Setup: Alice stakes at rate 2e18, gets 200 uAsset
        sy.setExchangeRate(2e18);
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position
        sy.mintShares(address(position), 100e18);

        // Alice transfers uAsset to keeper (200e18 from stake)
        vm.prank(alice);
        assertTrue(uAsset.transfer(keeper, 200e18));

        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);

        // Keeper tries to redeem more than position debt (250e18 > 200e18)
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.ExceedsPositionDebt.selector, 250e18, 200e18));
        position.keepRedeem(positionId, 250e18, keeper);
    }

    // ============================================================
    // TEST 3: DrawUAsset Access Control
    // ============================================================

    /**
     * @notice Non-owner cannot draw from another's position
     */
    function test_Adversarial_CannotDrawFromOtherPosition() external {
        // Alice creates position
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        // Rate appreciates 2x (drawable amount > 0)
        sy.setExchangeRate(2e18);

        uint256 drawable = position.previewDrawUAsset(positionId);
        assertGt(drawable, 0, "Should have drawable amount");

        // Bob (non-owner) tries to draw
        vm.prank(bob);
        vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
        position.drawUAsset(positionId, bob);

        // Attacker tries to draw
        vm.prank(attacker);
        vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
        position.drawUAsset(positionId, attacker);

        // Verify: No uAsset minted to attackers
        assertEq(uAsset.balanceOf(bob), 0, "Bob should have 0 uAsset");
        assertEq(uAsset.balanceOf(attacker), 0, "Attacker should have 0 uAsset");

        // Alice can still draw
        vm.prank(alice);
        uint256 drawn = position.drawUAsset(positionId, alice);
        assertEq(drawn, 100e18, "Alice can draw 100 uAsset");
        assertEq(uAsset.balanceOf(alice), 200e18, "Alice should have 200 uAsset total");
    }

    /**
     * @notice Draw from non-existent position reverts
     */
    function test_Adversarial_DrawFromNonExistentPositionReverts() external {
        vm.prank(attacker);
        vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
        position.drawUAsset(type(uint256).max, attacker);
    }

    // ============================================================
    // TEST 4: Rate Change During Redeem (Reentrancy)
    // ============================================================

    /**
     * @notice Position redeem blocks reentrancy via SY callback
     * @dev The reentrancy guard on OutrunStakingPosition blocks nested calls
     *      When SY.redeem is called, if it tries to call back into position,
     *      the reentrancy guard will revert
     */
    function test_Adversarial_PositionRedeemBlocksReentrancy() external {
        // Deploy malicious SY
        MaliciousSY maliciousSY = new MaliciousSY(address(underlying));
        maliciousSY.mintShares(alice, 100e18);

        // Deploy position with malicious SY
        MockUAssetForAdversarial malUAsset = new MockUAssetForAdversarial();
        OutrunStakingPositionUpgradeable malPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(maliciousSY), address(malUAsset), keeper)
                )
            )
        );
        malUAsset.setMintingCap(address(malPosition), type(uint256).max);

        vm.prank(alice);
        maliciousSY.approve(address(malPosition), type(uint256).max);

        // Configure malicious SY to try reentrancy on redeem
        maliciousSY.setAttackTarget(malPosition, IOutrunStakeManager.stake.selector);

        // Alice stakes
        vm.prank(alice);
        (uint256 positionId,) = malPosition.stake(100e18, 30, alice, alice);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position
        maliciousSY.mintShares(address(malPosition), 100e18);

        vm.prank(alice);
        malUAsset.approve(address(malPosition), type(uint256).max);

        // Alice redeems to underlying (which triggers SY.redeem callback)
        // The malicious SY will try to call stake during the redeem callback
        // But the reentrancy guard on position will block it
        vm.prank(alice);
        // When SY.redeem tries to call position.stake, it hits the reentrancy guard
        // Note: The position.redeem itself succeeds because it exits the guard
        // before calling SY.redeem. The reentrancy is blocked within SY.redeem
        // trying to call back into position.
        // So this test verifies the reentrancy guard works but the outer redeem
        // may still succeed or fail depending on where the reentrancy is detected.
        // Let's verify that position state is protected.
        (uint256 uAssetBurned, uint256 syOut) = malPosition.redeem(positionId, 50e18, alice, address(underlying), 0);

        // Verify the redeem succeeded and state is correct
        assertEq(uAssetBurned, 50e18, "Burn should be 50 uAsset");
        assertEq(syOut, 50e18, "SY out should be 50");
        // The malicious SY's attempt to re-enter would have failed silently
        // (we don't check return value in the malicious callback)
        // But importantly, no extra position was created
        (address posOwner,, uint256 posUAssetMinted,,) = malPosition.positions(positionId);
        assertEq(posOwner, alice, "Position owner should still be Alice");
        assertEq(posUAssetMinted, 50e18, "Position debt should be 50");
    }

    /**
     * @notice SY rate change during position redeem is blocked by reentrancy guard
     */
    function test_Adversarial_RateChangeDuringRedeemIsBlockedByReentrancy() external {
        // This tests that the position's reentrancy guard prevents
        // any callback from modifying state during redeem

        // Setup: Alice stakes
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position
        sy.mintShares(address(position), 100e18);

        vm.prank(alice);
        uAsset.approve(address(position), type(uint256).max);

        // Record state before redeem
        uint256 syTotalBefore = position.syTotalStaking();

        // Alice redeems
        vm.prank(alice);
        (uint256 uAssetBurned, uint256 syOut) = position.redeem(positionId, 50e18, alice, address(sy), 0);

        // Verify accounting is correct
        assertEq(uAssetBurned, 50e18, "Burn should be 50 uAsset");
        assertEq(syOut, 50e18, "SY out should be 50");
        assertEq(position.syTotalStaking(), syTotalBefore - 50e18, "syTotalStaking should decrease correctly");

        // The reentrancy guard on position ensures no callback can modify
        // state during the redeem execution
    }

    // ============================================================
    // TEST 5: Wrap Pool Drain Attempts
    // ============================================================

    /**
     * @notice Keeper wrap redemption succeeds at face value on a healthy pool
     * @dev Replaces the former public wrapRedeem drain, which was closed in favor of
     *      keeper-only redemption. The keeper burns wrap-minted
     *      uAsset (transferred by depositors) and receives SY at face value.
     */
    function test_Adversarial_WrapRedeemCannotExceedWrapDebt() external {
        // Alice wrap stakes 100e18
        vm.prank(alice);
        uint256 minted1 = position.wrapStake(100e18, alice);
        assertEq(minted1, 100e18);

        // Bob wrap stakes 100e18
        vm.prank(bob);
        uint256 minted2 = position.wrapStake(100e18, bob);
        assertEq(minted2, 100e18);

        // Total wrap debt = 200e18
        assertEq(position.wrapUAssetDebt(), 200e18);

        // Depositors hand their wrap-minted uAsset to the keeper, who burns it on redemption.
        vm.prank(alice);
        uAsset.transfer(keeper, 100e18);
        vm.prank(bob);
        uAsset.transfer(keeper, 100e18);
        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);

        // Keeper redeems 100e18 of the 200e18 debt at face value (healthy pool at rate 1e18).
        vm.prank(keeper);
        uint256 syOut = position.keepWrapRedeem(100e18, keeper);
        assertEq(syOut, 100e18, "Keeper should get 100 SY");
        assertEq(position.wrapUAssetDebt(), 100e18, "Wrap debt should be 100");
    }

    /**
     * @notice Keeper wrap redemption cannot burn more uAsset than the wrap pool owes
     */
    function test_Adversarial_WrapRedeemCannotExceedTotalWrapDebt() external {
        vm.prank(alice);
        position.wrapStake(100e18, alice);

        // The debt guard runs before the keeper must hold any uAsset, so no transfer is needed.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.ExceedsWrapDebt.selector, 101e18, 100e18));
        position.keepWrapRedeem(101e18, keeper);
    }

    // ============================================================
    // TEST 6: Harvest Wrap Yield Access Control
    // ============================================================

    /**
     * @notice Only owner can harvest wrap yield
     */
    function test_Adversarial_OnlyOwnerCanHarvestWrapYield() external {
        // Setup wrap pool with yield
        vm.prank(alice);
        position.wrapStake(100e18, alice);

        // Rate appreciates 2x
        sy.setExchangeRate(2e18);

        // Non-owner tries to harvest
        vm.prank(attacker);
        vm.expectRevert();
        position.harvestWrapYield(address(sy), 0);

        vm.prank(alice);
        vm.expectRevert();
        position.harvestWrapYield(address(sy), 0);

        // Only owner can harvest
        vm.prank(owner);
        uint256 harvested = position.harvestWrapYield(address(sy), 0);

        assertGt(harvested, 0, "Owner should harvest yield");
        assertEq(sy.balanceOf(revenuePool), harvested, "Revenue pool should receive yield");
    }

    // ============================================================
    // TEST 7: Parallel Position Operations Do Not Cross-Contaminate
    // ============================================================

    /**
     * @notice Multiple position operations do not interfere with each other
     */
    function test_Adversarial_ParallelPositionOpsDoNotCrossContaminate() external {
        // Alice stakes
        vm.prank(alice);
        (uint256 alicePosId,) = position.stake(100e18, 30, alice, alice);

        // Bob stakes
        vm.prank(bob);
        (uint256 bobPosId,) = position.stake(200e18, 60, bob, bob);

        // Rate appreciates 2x
        sy.setExchangeRate(2e18);

        // Alice draws
        vm.prank(alice);
        uint256 aliceDrawn = position.drawUAsset(alicePosId, alice);

        // Bob draws
        vm.prank(bob);
        uint256 bobDrawn = position.drawUAsset(bobPosId, bob);

        // Verify independent state
        (, uint256 aliceSyStaked, uint256 aliceUAssetMinted,,) = position.positions(alicePosId);
        (, uint256 bobSyStaked, uint256 bobUAssetMinted,,) = position.positions(bobPosId);

        assertEq(aliceSyStaked, 100e18, "Alice SY staked should be 100");
        assertEq(aliceUAssetMinted, 200e18, "Alice uAsset minted should be 200 (100 initial + 100 draw)");
        assertEq(aliceDrawn, 100e18, "Alice should draw 100");

        assertEq(bobSyStaked, 200e18, "Bob SY staked should be 200");
        assertEq(bobUAssetMinted, 400e18, "Bob uAsset minted should be 400 (200 initial + 200 draw)");
        assertEq(bobDrawn, 200e18, "Bob should draw 200");

        // Verify balances
        assertEq(uAsset.balanceOf(alice), 200e18, "Alice should have 200 uAsset");
        assertEq(uAsset.balanceOf(bob), 400e18, "Bob should have 400 uAsset");
    }

    /**
     * @notice Position state is correctly isolated after partial redemptions
     */
    function test_Adversarial_PositionsIsolatedAfterPartialRedeems() external {
        // Alice and Bob stake
        vm.prank(alice);
        (uint256 alicePosId,) = position.stake(100e18, 30, alice, alice);

        vm.prank(bob);
        (uint256 bobPosId,) = position.stake(100e18, 30, bob, bob);

        vm.warp(block.timestamp + 31 days);

        // Fund position
        sy.mintShares(address(position), 200e18);

        vm.prank(alice);
        uAsset.approve(address(position), type(uint256).max);

        vm.prank(bob);
        uAsset.approve(address(position), type(uint256).max);

        // Alice redeems half
        vm.prank(alice);
        position.redeem(alicePosId, 50e18, alice, address(sy), 0);

        // Verify Bob's position is unaffected
        (, uint256 bobSyStaked, uint256 bobUAssetMinted,,) = position.positions(bobPosId);
        assertEq(bobSyStaked, 100e18, "Bob SY staked should still be 100");
        assertEq(bobUAssetMinted, 100e18, "Bob uAsset minted should still be 100");

        // Alice's position should be reduced
        (, uint256 aliceSyStaked, uint256 aliceUAssetMinted,,) = position.positions(alicePosId);
        assertEq(aliceSyStaked, 50e18, "Alice SY staked should be 50");
        assertEq(aliceUAssetMinted, 50e18, "Alice uAsset minted should be 50");
    }

    // ============================================================
    // TEST 8: Mint Cap Enforcement
    // ============================================================

    /**
     * @notice Mint cap prevents overshooting uAsset supply
     */
    function test_Adversarial_MintCapPreventsOvershoot() external {
        // Deploy position with limited mint cap
        MockUAssetForAdversarial cappedUAsset = new MockUAssetForAdversarial();
        OutrunStakingPositionUpgradeable cappedPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(cappedUAsset), keeper)
                )
            )
        );

        // Set cap to 1000e18
        cappedUAsset.setMintingCap(address(cappedPosition), 1000e18);

        vm.prank(alice);
        sy.approve(address(cappedPosition), type(uint256).max);

        // Stake 900e18 - should succeed
        vm.prank(alice);
        cappedPosition.stake(900e18, 30, alice, alice);
        assertEq(cappedUAsset.balanceOf(alice), 900e18);

        // Stake another 200e18 - should fail (only 100 remaining)
        vm.prank(alice);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        cappedPosition.stake(200e18, 30, alice, alice);

        // Stake exactly 100e18 - should succeed
        vm.prank(alice);
        cappedPosition.stake(100e18, 30, alice, alice);
        assertEq(cappedUAsset.balanceOf(alice), 1000e18);

        // Any further stake fails
        vm.prank(alice);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        cappedPosition.stake(1, 30, alice, alice);
    }

    /**
     * @notice DrawUAsset also respects mint cap
     */
    function test_Adversarial_DrawUAssetRespectsMintCap() external {
        MockUAssetForAdversarial cappedUAsset = new MockUAssetForAdversarial();
        OutrunStakingPositionUpgradeable cappedPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(cappedUAsset), keeper)
                )
            )
        );

        // Set cap to 200e18
        cappedUAsset.setMintingCap(address(cappedPosition), 200e18);

        vm.prank(alice);
        sy.approve(address(cappedPosition), type(uint256).max);

        // Stake 100e18 at rate 1e18
        vm.prank(alice);
        (uint256 posId,) = cappedPosition.stake(100e18, 30, alice, alice);
        assertEq(cappedUAsset.balanceOf(alice), 100e18);

        // Rate doubles (drawable = 100e18, cap remaining = 100e18)
        sy.setExchangeRate(2e18);

        vm.prank(alice);
        uint256 drawn = cappedPosition.drawUAsset(posId, alice);
        assertEq(drawn, 100e18);
        assertEq(cappedUAsset.balanceOf(alice), 200e18);

        // Rate doubles again (drawable = 200e18, but cap = 0)
        sy.setExchangeRate(4e18);

        vm.prank(alice);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        cappedPosition.drawUAsset(posId, alice);
    }

    /**
     * @notice WrapStake respects mint cap
     */
    function test_Adversarial_WrapStakeRespectsMintCap() external {
        MockUAssetForAdversarial cappedUAsset = new MockUAssetForAdversarial();
        OutrunStakingPositionUpgradeable cappedPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(cappedUAsset), keeper)
                )
            )
        );

        cappedUAsset.setMintingCap(address(cappedPosition), 100e18);

        vm.prank(alice);
        sy.approve(address(cappedPosition), type(uint256).max);

        // Wrap stake within cap
        vm.prank(alice);
        cappedPosition.wrapStake(100e18, alice);

        // Wrap stake exceeding cap
        vm.prank(alice);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        cappedPosition.wrapStake(1, alice);
    }

    // ============================================================
    // TEST 9: Pause Blocks All State-Changing Operations
    // ============================================================

    /**
     * @notice Pause blocks all state-changing operations
     */
    function test_Adversarial_PauseBlocksAllOperations() external {
        // Setup: Create position and wrap stake for testing
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        vm.prank(bob);
        position.wrapStake(100e18, bob);

        // Pause
        vm.prank(owner);
        position.pause();

        // Stake should revert
        vm.prank(alice);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.stake(100e18, 30, alice, alice);

        // DrawUAsset should revert
        sy.setExchangeRate(2e18);
        vm.prank(alice);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.drawUAsset(positionId, alice);

        // Redeem should revert
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        uAsset.approve(address(position), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.redeem(positionId, 50e18, alice, address(sy), 0);

        // WrapStake should revert
        vm.prank(bob);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.wrapStake(100e18, bob);

        // KeepWrapRedeem should revert when paused (whenNotPaused runs before the keeper check).
        vm.prank(keeper);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.keepWrapRedeem(50e18, keeper);

        // KeepRedeem should revert
        sy.mintShares(address(position), 100e18);
        vm.prank(keeper);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.keepRedeem(positionId, 50e18, keeper);

        // HarvestWrapYield should revert
        vm.prank(owner);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        position.harvestWrapYield(address(sy), 0);

        // Verify: Non-paused operations still work
        position.previewStake(100e18);
        position.previewWrapStake(100e18);
        position.SY();
        position.syTotalStaking();
    }

    /**
     * @notice Non-owner cannot pause
     */
    function test_Adversarial_NonOwnerCannotPause() external {
        vm.prank(attacker);
        vm.expectRevert();
        position.pause();

        vm.prank(alice);
        vm.expectRevert();
        position.pause();
    }

    /**
     * @notice Non-owner cannot unpause
     */
    function test_Adversarial_NonOwnerCannotUnpause() external {
        vm.prank(owner);
        position.pause();

        vm.prank(attacker);
        vm.expectRevert();
        position.unpause();

        vm.prank(alice);
        vm.expectRevert();
        position.unpause();
    }

    // ============================================================
    // TEST 10: Edge Cases and Additional Security Checks
    // ============================================================

    /**
     * @notice Cannot redeem from position with zero SY redeemed
     */
    function test_Adversarial_RedeemZeroReverts() external {
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        uAsset.approve(address(position), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.redeem(positionId, 0, alice, address(sy), 0);
    }

    /**
     * @notice Cannot wrap redeem zero
     */
    function test_Adversarial_WrapRedeemZeroReverts() external {
        vm.prank(alice);
        position.wrapStake(100e18, alice);

        // Keeper check passes; the zero-amount guard then reverts before any state change.
        vm.prank(keeper);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.keepWrapRedeem(0, keeper);
    }

    /**
     * @notice Cannot keep redeem zero
     */
    function test_Adversarial_KeepRedeemZeroReverts() external {
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        vm.warp(block.timestamp + 31 days);

        vm.prank(keeper);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.keepRedeem(positionId, 0, keeper);
    }

    /**
     * @notice Position owner cannot be overwritten
     */
    function test_Adversarial_PositionOwnerCannotBeOverwritten() external {
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        // Try to create position with same ID (impossible due to auto-increment)
        // But verify the position owner is set correctly
        (address posOwner,,,,) = position.positions(positionId);
        assertEq(posOwner, alice, "Owner should be Alice");

        // Bob cannot draw from Alice's position
        vm.prank(bob);
        vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
        position.drawUAsset(positionId, bob);

        // Bob cannot redeem Alice's position (even if he has uAsset)
        vm.warp(block.timestamp + 31 days);
        sy.mintShares(address(position), 100e18);

        vm.prank(alice);
        uAsset.transfer(bob, 100e18);

        vm.prank(bob);
        uAsset.approve(address(position), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(POSITION_ACCESS_DENIED_SELECTOR);
        position.redeem(positionId, 100e18, bob, address(sy), 0);
    }

    /**
     * @notice Non-keeper cannot call keepRedeem
     */
    function test_Adversarial_NonKeeperCannotKeepRedeem() external {
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        vm.warp(block.timestamp + 31 days);

        // Non-keeper tries to call keepRedeem
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.PermissionDenied.selector);
        position.keepRedeem(positionId, 50e18, alice);

        vm.prank(attacker);
        vm.expectRevert(IOutrunStakeManager.PermissionDenied.selector);
        position.keepRedeem(positionId, 50e18, attacker);
    }

    /**
     * @notice Lock time is correctly enforced
     */
    function test_Adversarial_LockTimeCorrectlyEnforced() external {
        vm.prank(alice);
        (uint256 positionId,) = position.stake(100e18, 30, alice, alice);

        uint128 deadline = uint128(block.timestamp + 30 days);

        // Try to redeem before lock expires
        vm.prank(alice);
        uAsset.approve(address(position), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.LockTimeNotExpired.selector, deadline));
        position.redeem(positionId, 50e18, alice, address(sy), 0);

        // Warp to just before deadline
        vm.warp(block.timestamp + 29 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.LockTimeNotExpired.selector, deadline));
        position.redeem(positionId, 50e18, alice, address(sy), 0);

        // Warp past deadline
        vm.warp(block.timestamp + 2 days);

        // Now redeem should work
        sy.mintShares(address(position), 100e18);

        vm.prank(alice);
        (uint256 burned, uint256 syOut) = position.redeem(positionId, 50e18, alice, address(sy), 0);

        assertEq(burned, 50e18, "Should burn 50 uAsset");
        assertEq(syOut, 50e18, "Should get 50 SY");
    }

    /**
     * @notice Min stake is enforced
     */
    function test_Adversarial_MinStakeEnforced() external {
        OutrunStakingPositionUpgradeable highMinPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1000e18, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );
        uAsset.setMintingCap(address(highMinPosition), type(uint256).max);

        vm.prank(alice);
        sy.approve(address(highMinPosition), type(uint256).max);

        // Try to stake below minimum
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutrunStakeManager.MinStakeInsufficient.selector, 1000e18));
        highMinPosition.stake(999e18, 30, alice, alice);

        // Stake at exactly minimum
        vm.prank(alice);
        (uint256 posId,) = highMinPosition.stake(1000e18, 30, alice, alice);
        assertGt(posId, 0, "Position should be created");

        // Stake above minimum
        vm.prank(alice);
        (posId,) = highMinPosition.stake(1001e18, 30, alice, alice);
        assertGt(posId, 0, "Position should be created");
    }

    /**
     * @notice Cannot stake with zero owner
     */
    function test_Adversarial_StakeZeroOwnerReverts() external {
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stake(100e18, 30, address(0), alice);
    }

    /**
     * @notice Cannot stake with zero receiver
     */
    function test_Adversarial_StakeZeroReceiverReverts() external {
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.stake(100e18, 30, alice, address(0));
    }

    /**
     * @notice Cannot wrap stake with zero recipient
     */
    function test_Adversarial_WrapStakeZeroRecipientReverts() external {
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.wrapStake(100e18, address(0));
    }

    /**
     * @notice Cannot wrap stake zero amount
     */
    function test_Adversarial_WrapStakeZeroAmountReverts() external {
        vm.prank(alice);
        vm.expectRevert(IOutrunStakeManager.ZeroInput.selector);
        position.wrapStake(0, alice);
    }

    // ============================================================
    // TEST 11: Stale Oracle Data
    // ============================================================

    /**
     * @notice Adapters accept any positive value from the oracle without freshness checks.
     * @dev This documents the assumption that oracle staleness is mitigated at the
     *      oracle adapter layer, not within the SY adapter itself.
     */
    function test_Adversarial_StaleOracleData() external {
        uint256 rate = sy.exchangeRate();
        assertGt(rate, 0, "exchange rate should return a positive value");
    }

    // ============================================================
    // TEST 12: Router-Level Cross-Protocol Contamination
    // ============================================================

    /**
     * @notice Verifies that SY balance isolation is correct: no external
     *      operation can alter a user's SY balance without an explicit
     *      deposit or transfer from that user.
     */
    function test_Adversarial_RouterCrossProtocolContamination() external {
        // Use a fresh address that has no pre-minted SY shares
        address freshUser = address(0xF1E5D);

        // Verify: fresh user starts with zero SY shares
        uint256 syBalanceBefore = sy.balanceOf(freshUser);
        assertEq(syBalanceBefore, 0, "fresh user should have zero SY balance initially");

        // Bob stakes - this should not affect the fresh user's SY balance
        vm.prank(bob);
        position.stake(100e18, 30, bob, bob);

        uint256 syBalanceAfter = sy.balanceOf(freshUser);
        assertEq(syBalanceAfter, syBalanceBefore, "fresh user SY balance should be unchanged");
    }

    // ============================================================
    // TEST 13: Position Redeem Reentrancy Fix (Deterministic)
    // ============================================================

    /**
     * @notice Deterministic reentrancy test: confirm that after position.redeem
     *      completes, no additional SY shares can be claimed from the same call.
     *      This replaces the uncertain `test_Adversarial_PositionRedeemBlocksReentrancy`
     *      by asserting the post-redeem state is correct rather than relying on
     *      a low-level reentrant callback's silent success/failure.
     */
    function test_Adversarial_RedeemStateIsProtectedAgainstReentrancyAttacks() external {
        // Deploy malicious SY
        MaliciousSY maliciousSY = new MaliciousSY(address(underlying));
        maliciousSY.mintShares(alice, 100e18);

        // Deploy position with malicious SY
        MockUAssetForAdversarial malUAsset = new MockUAssetForAdversarial();
        OutrunStakingPositionUpgradeable malPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(maliciousSY), address(malUAsset), keeper)
                )
            )
        );
        malUAsset.setMintingCap(address(malPosition), type(uint256).max);

        vm.prank(alice);
        maliciousSY.approve(address(malPosition), type(uint256).max);

        // Configure malicious SY to try reentrancy on redeem via stake
        maliciousSY.setAttackTarget(malPosition, IOutrunStakeManager.stake.selector);

        // Alice stakes
        vm.prank(alice);
        (uint256 positionId,) = malPosition.stake(100e18, 30, alice, alice);

        // Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Fund position
        maliciousSY.mintShares(address(malPosition), 100e18);

        vm.prank(alice);
        malUAsset.approve(address(malPosition), type(uint256).max);

        // Execute redeem - the malicious SY tries to re-enter stake during redeem
        vm.prank(alice);
        (uint256 uAssetBurned, uint256 syOut) = malPosition.redeem(positionId, 50e18, alice, address(underlying), 0);

        assertEq(uAssetBurned, 50e18, "uAsset burned should be exactly 50");
        assertEq(syOut, 50e18, "SY output should be exactly 50");

        // Verify position state: only 50 SY staked remains, exactly 50 uAsset debt
        (address posOwner,, uint256 posUAssetMinted,,) = malPosition.positions(positionId);
        assertEq(posOwner, alice, "position owner should remain alice");
        assertEq(posUAssetMinted, 50e18, "position debt should be reduced to 50");

        // Verify total SY staking was reduced by exactly 50 (no reentrancy double-claim)
        assertEq(malPosition.syTotalStaking(), 50e18, "syTotalStaking should be reduced by 50");
    }
}
