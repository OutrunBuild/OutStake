// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunAaveV3SYUpgradeable} from "../../src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol";
import {OutrunWstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol";
import {OutrunL2StakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {MockToken, MockAToken, MockAavePool, MockStETH, MockWstETH, MockPSM3} from "./mocks/SYAdapterMocks.sol";

/**
 * @title CrossBlockPreviewDriftUpgradeableTest
 * @notice Cross-block preview-vs-execution consistency for the three preview architectures.
 * @dev Existing preview tests (SYAdaptersUpgradeable / Router fuzz) compare quotes and executions in
 *      the same block. These tests insert vm.warp + a rate/index move between quote and execution and
 *      pin the three-state contract: across a rate move, a preview
 *      taken at T0 is either still exact, or the execution is lower and the call with
 *      minSharesOut = preview(T0) reverts (SYInsufficientSharesOut) — it can never silently pass at
 *      a lower amount. Discounted (50 bps) NATIVE branches additionally survive small cross-block
 *      drift by design.
 */
contract CrossBlockPreviewDriftUpgradeableTest is Test {
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    // --- Aave stack ------------------------------------------------------------
    MockToken internal aaveUnderlying;
    MockAToken internal aToken;
    MockAavePool internal aavePool;
    OutrunAaveV3SYUpgradeable internal aaveSy;

    // --- Lido wstETH stack -----------------------------------------------------
    MockStETH internal stETH;
    MockWstETH internal wstETH;
    OutrunWstETHSYUpgradeable internal wstEthSy;

    // --- Sky L2 sUSDS stack ----------------------------------------------------
    MockToken internal usdc;
    MockToken internal usds;
    MockToken internal sUsds;
    MockPSM3 internal psm3;
    OutrunL2StakedUsdsSYUpgradeable internal skyL2Sy;

    function setUp() external {
        vm.warp(1 days);

        // Aave: underlying + aToken at a non-par liquidity index (2e27) so preview/execution math is real.
        aaveUnderlying = new MockToken("Underlying", "UND", 18);
        aToken = new MockAToken(address(aaveUnderlying));
        aavePool = new MockAavePool();
        aavePool.setReserve(address(aaveUnderlying), aToken, 2e27);
        aaveSy = OutrunAaveV3SYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunAaveV3SYUpgradeable()),
                    abi.encodeCall(
                        OutrunAaveV3SYUpgradeable.initialize,
                        ("SY Aave", "SYA", address(aToken), address(aavePool), owner)
                    )
                ))
        );

        // Lido: stETH/wstETH at a non-par rate so the conversion path is exercised.
        stETH = new MockStETH();
        wstETH = new MockWstETH(address(stETH));
        stETH.setPooledEthPerShare(1.1e18);
        wstETH.setStEthPerToken(1.1e18);
        wstEthSy = OutrunWstETHSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunWstETHSYUpgradeable()),
                    abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
                ))
        );

        // Sky L2: PSM3 with a non-par share rate (drives both swap execution and SSR-synced quote).
        usdc = new MockToken("USDC", "USDC", 6);
        usds = new MockToken("USDS", "USDS", 18);
        sUsds = new MockToken("sUSDS", "sUSDS", 18);
        psm3 = new MockPSM3();
        psm3.setRate(address(sUsds), 1.05e18);
        skyL2Sy = OutrunL2StakedUsdsSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedUsdsSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedUsdsSYUpgradeable.initialize,
                        (owner, address(usdc), address(usds), address(sUsds), address(psm3))
                    )
                ))
        );

        aaveUnderlying.mint(user, 1e24);
        stETH.mint(user, 1e24);
        usdc.mint(user, 1e24);
        vm.deal(user, 1e24);
    }

    // --------------------------------------------------------------------------
    // Aave: underlying branch
    // --------------------------------------------------------------------------

    /// @notice A stale preview is an upper bound: after the index grows, execution is <= preview.
    function testFuzz_AaveUnderlyingCrossBlockPreviewIsUpperBound(uint96 amount, uint64 bumpBps) external {
        amount = uint96(bound(amount, 1e6, 1e22));
        bumpBps = uint64(bound(bumpBps, 1, 10_000));

        vm.startPrank(user);
        aaveUnderlying.approve(address(aaveSy), type(uint256).max);
        uint256 preview = IStandardizedYield(address(aaveSy)).previewDeposit(address(aaveUnderlying), amount);

        // Same-block sanity: preview is exact (0-1 wei under-quote on the floor branch).
        uint256 sameBlock = IStandardizedYield(address(aaveSy)).deposit(user, address(aaveUnderlying), amount, 0);
        assertApproxEqAbs(sameBlock, preview, 1, "same-block preview not exact");

        // Cross-block: index grows, shares per asset shrink — the old preview becomes an upper bound.
        aavePool.setReserve(address(aaveUnderlying), aToken, 2e27 * (10_000 + uint256(bumpBps)) / 10_000);
        uint256 crossBlock = IStandardizedYield(address(aaveSy)).deposit(user, address(aaveUnderlying), amount, 0);
        assertLe(crossBlock, preview, "execution exceeded stale preview after index growth");
        vm.stopPrank();
    }

    /// @notice Using the stale preview verbatim as minSharesOut fails closed, never silently passes.
    function test_AaveUnderlyingStalePreviewAsMinFailsClosed() external {
        uint256 amount = 1e18;
        vm.startPrank(user);
        aaveUnderlying.approve(address(aaveSy), type(uint256).max);
        uint256 preview = IStandardizedYield(address(aaveSy)).previewDeposit(address(aaveUnderlying), amount);

        // A 10% index jump makes the execution strictly lower than the stale preview.
        aavePool.setReserve(address(aaveUnderlying), aToken, 2.2e27);
        uint256 executed = IStandardizedYield(address(aaveSy)).deposit(user, address(aaveUnderlying), amount, 0);
        assertLt(executed, preview, "drifted execution must be strictly below the stale preview");
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInsufficientSharesOut.selector, executed, preview));
        IStandardizedYield(address(aaveSy)).deposit(user, address(aaveUnderlying), amount, preview);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------
    // Lido wstETH: stETH conversion branch (same-block exact, no discount)
    // --------------------------------------------------------------------------

    /// @notice The stETH branch keeps preview == execution in the same block and preview becomes an
    ///      upper bound after the stETH rate grows (shares per stETH shrink).
    function testFuzz_WstETHStETHBranchCrossBlockPreviewIsUpperBound(uint96 amount, uint64 bumpBps) external {
        amount = uint96(bound(amount, 1e6, 1e22));
        bumpBps = uint64(bound(bumpBps, 1, 10_000));

        vm.startPrank(user);
        stETH.approve(address(wstEthSy), type(uint256).max);
        uint256 preview = IStandardizedYield(address(wstEthSy)).previewDeposit(address(stETH), amount);

        uint256 sameBlock = IStandardizedYield(address(wstEthSy)).deposit(user, address(stETH), amount, 0);
        assertEq(sameBlock, preview, "same-block stETH preview not exact");

        // Grow the stETH-per-share rate on both paired mocks (they must move together).
        uint256 newRate = 1.1e18 * (10_000 + uint256(bumpBps)) / 10_000;
        stETH.setPooledEthPerShare(newRate);
        wstETH.setStEthPerToken(newRate);
        uint256 crossBlock = IStandardizedYield(address(wstEthSy)).deposit(user, address(stETH), amount, 0);
        assertLe(crossBlock, preview, "execution exceeded stale preview after stETH rate growth");
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------
    // Lido wstETH: NATIVE branch (50 bps discounted preview)
    // --------------------------------------------------------------------------

    /// @notice The discounted NATIVE preview survives small cross-block drift: a +40 bps rate move
    ///      still leaves execution >= preview, so minSharesOut = preview keeps passing.
    function test_WstETHNativeDiscountedPreviewSurvivesSmallCrossBlockDrift() external {
        uint256 amount = 1e18;
        uint256 preview = IStandardizedYield(address(wstEthSy)).previewDeposit(address(0), amount);
        assertGt(preview, 0, "discounted preview must be non-zero");

        // +40 bps is inside the 50 bps margin the discount reserves for cross-block drift.
        uint256 newRate = 1.1e18 * 10_040 / 10_000;
        stETH.setPooledEthPerShare(newRate);
        wstETH.setStEthPerToken(newRate);

        vm.prank(user);
        uint256 executed =
            IStandardizedYield(address(wstEthSy)).deposit{value: amount}(user, address(0), amount, preview);
        assertGe(executed, preview, "discounted preview did not survive small cross-block drift");
    }

    /// @notice A large cross-block move (+100%) exhausts the 50 bps margin and the stale preview
    ///      fails closed — demonstrating the third state of the contract.
    function test_WstETHNativeDiscountedPreviewFailsClosedOnLargeDrift() external {
        uint256 amount = 1e18;
        uint256 preview = IStandardizedYield(address(wstEthSy)).previewDeposit(address(0), amount);

        stETH.setPooledEthPerShare(2.2e18);
        wstETH.setStEthPerToken(2.2e18);

        vm.startPrank(user);
        uint256 executed = IStandardizedYield(address(wstEthSy)).deposit{value: amount}(user, address(0), amount, 0);
        assertLt(executed, preview, "drifted execution must fall below the stale discounted preview");
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInsufficientSharesOut.selector, executed, preview));
        IStandardizedYield(address(wstEthSy)).deposit{value: amount}(user, address(0), amount, preview);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------
    // Sky L2 sUSDS: PSM3 passthrough branch
    // --------------------------------------------------------------------------

    /// @notice Deposit direction: rate growth shrinks sUSDS out per USDC in, so a stale preview is
    ///      an upper bound and fails closed as minSharesOut. Redeem direction: the same growth
    ///      raises USDC out per sUSDS, so a stale preview is a lower bound and still passes.
    function testFuzz_SkyL2PsmPreviewBoundsFlipByDirection(uint96 amount, uint64 bumpBps) external {
        amount = uint96(bound(amount, 1e9, 1e20));
        bumpBps = uint64(bound(bumpBps, 1, 10_000));

        vm.startPrank(user);
        usdc.approve(address(skyL2Sy), type(uint256).max);
        sUsds.approve(address(skyL2Sy), type(uint256).max);

        // Deposit leg: preview at T0, execute after the PSM rate grows.
        uint256 depositPreview = IStandardizedYield(address(skyL2Sy)).previewDeposit(address(usdc), amount);
        psm3.setRate(address(sUsds), 1.05e18 * (10_000 + uint256(bumpBps)) / 10_000);
        uint256 depositExecuted = IStandardizedYield(address(skyL2Sy)).deposit(user, address(usdc), amount, 0);
        assertLe(depositExecuted, depositPreview, "deposit execution exceeded stale preview after rate growth");

        // The stale preview verbatim as minSharesOut must fail closed, never silently pass lower.
        psm3.setRate(address(sUsds), 1.05e18 * (10_000 + bound(bumpBps, 100, 10_000)) / 10_000);
        uint256 lowerExecution = IStandardizedYield(address(skyL2Sy)).deposit(user, address(usdc), amount, 0);
        assertLt(lowerExecution, depositPreview, "second bump did not lower the execution");
        vm.expectRevert(
            abi.encodeWithSelector(IStandardizedYield.SYInsufficientSharesOut.selector, lowerExecution, depositPreview)
        );
        IStandardizedYield(address(skyL2Sy)).deposit(user, address(usdc), amount, depositPreview);
        vm.stopPrank();
    }

    /// @notice Redeem direction: rate growth means more USDC per sUSDS share, so execution meets or
    ///      exceeds the stale preview and minTokenOut = preview(T0) keeps passing.
    function test_SkyL2RedeemStalePreviewStillPassesWhenRateRises() external {
        vm.startPrank(user);
        usdc.approve(address(skyL2Sy), type(uint256).max);
        uint256 shares = IStandardizedYield(address(skyL2Sy)).deposit(user, address(usdc), 1e18, 0);
        uint256 redeemPreview = IStandardizedYield(address(skyL2Sy)).previewRedeem(address(usdc), shares);

        psm3.setRate(address(sUsds), 1.1e18);
        uint256 redeemed =
            IStandardizedYield(address(skyL2Sy)).redeem(user, shares, address(usdc), redeemPreview, false);
        assertGe(redeemed, redeemPreview, "redeem execution fell below stale preview after rate growth");
        vm.stopPrank();
    }
}
