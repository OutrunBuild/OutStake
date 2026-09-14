// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunUSRVaultUpgradeable} from "../../src/usr/OutrunUSRVaultUpgradeable.sol";
import {IUSRVault} from "../../src/usr/interfaces/IUSRVault.sol";
import {ProxyTestHelper} from "../upgradeable/helpers/ProxyTestHelper.sol";
import {CommonTestHelpers} from "../upgradeable/helpers/CommonTestHelpers.sol";
import {MockUSDC} from "../support/mocks/MockUSDC.sol";

contract OutrunUSRVaultTest is CommonTestHelpers {
    // Mirrors the contract-internal conversion constant (365-day year in seconds) so the reference
    // implementation stays an exact algorithm mirror of the per-second accrual domain.
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant RATE_MAX = 1e17; // 10% annualized absolute ceiling
    uint256 internal constant RATE_STEP = 5e15; // sample rate value used across roundtrip vectors
    // Deterministic saturation ceiling of the growth power (1e18-fold price multiplier): mirrors
    // the contract constant so the reference implementation stays an exact algorithm mirror.
    uint256 internal constant SATURATION = 1e36;

    OutrunUniversalAssetsUpgradeable internal uAsset;
    OutrunUSRVaultUpgradeable internal vault;

    address internal uAssetOwner = address(0xA11CE);
    address internal vaultOwner = address(0xB0B);
    address internal alice = address(0xCAFE);
    address internal bob = address(0xFEED);
    address internal distributor = address(0xD15);

    // Absolute-timestamp tracking: every warp is issued from the tracked timestamp instead of the
    // chain register; `_warp`/`warpAt` provided by `CommonTestHelpers`.

    function setUp() external {
        uAsset = _deployUAsset(uAssetOwner);

        OutrunUSRVaultUpgradeable vaultImplementation = new OutrunUSRVaultUpgradeable();
        vault = OutrunUSRVaultUpgradeable(
            ProxyTestHelper.deploy(
                address(vaultImplementation),
                abi.encodeCall(
                    OutrunUSRVaultUpgradeable.initialize, (address(uAsset), "Outrun suUSD", "suUSD", vaultOwner)
                )
            )
        );

        // The vault needs no uAsset-side registration (it is not a minter): test uAsset is
        // distributed through a plain debt-ledger minter.
        vm.prank(uAssetOwner);
        uAsset.setMintingCap(distributor, 10_000_000e18);

        vm.startPrank(distributor);
        uAsset.mint(alice, 1_000_000e18);
        uAsset.mint(bob, 1_000_000e18);
        uAsset.mint(vaultOwner, 1_000_000e18);
        vm.stopPrank();

        vm.startPrank(vaultOwner);
        uAsset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        uAsset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        uAsset.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------

    function test_InitializeBindsParametersAndDefaults() external {
        assertEq(vault.asset(), address(uAsset));
        assertEq(vault.name(), "Outrun suUSD");
        assertEq(vault.symbol(), "suUSD");
        assertEq(vault.decimals(), 18);
        assertEq(vault.owner(), vaultOwner);
        // Unactivated on launch: rate zero, index at par, accounting timestamp at deployment.
        assertEq(vault.usrRate(), 0);
        assertEq(vault.accrualIndex(), 1e18);
        assertEq(vault.lastSettledAt(), warpAt);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_InitializeRevertsOnInvalidParametersAndReinit() external {
        OutrunUSRVaultUpgradeable implementation = new OutrunUSRVaultUpgradeable();

        vm.expectRevert(IUSRVault.ZeroInput.selector);
        _deploy(implementation, address(0), "su", "SU", vaultOwner);

        vm.expectRevert(IUSRVault.ZeroInput.selector);
        _deploy(implementation, address(uAsset), "", "SU", vaultOwner);

        vm.expectRevert(IUSRVault.ZeroInput.selector);
        _deploy(implementation, address(uAsset), "su", "", vaultOwner);

        // Zero owner is rejected by the Ownable initializer.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        _deploy(implementation, address(uAsset), "su", "SU", address(0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(uAsset), "su", "SU", vaultOwner);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(uAsset), "su", "SU", vaultOwner);
    }

    function test_InitializeRevertsOnNon18DecimalAsset() external {
        MockUSDC sixDecimalAsset = new MockUSDC("Mock USDC", "mUSDC", 6, address(this));
        OutrunUSRVaultUpgradeable implementation = new OutrunUSRVaultUpgradeable();

        vm.expectRevert(abi.encodeWithSelector(IUSRVault.UAssetDecimalsMismatch.selector, 18, 6));
        _deploy(implementation, address(sixDecimalAsset), "su", "SU", vaultOwner);
    }

    // ---------------------------------------------------------------------------------------------
    // Accrual roundtrips (acceptance 1)
    // ---------------------------------------------------------------------------------------------

    function test_RoundtripAccrualMatchesReferenceImplementation() external {
        vm.prank(vaultOwner);
        vault.fund(100e18);
        _setRate(RATE_STEP);
        assertEq(vault.accrualIndex(), 1e18, "rate activation settles nothing at par");

        // Segment 1: first deposit prices 1:1.
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000e18, alice);
        assertEq(aliceShares, 1000e18);

        // Segment 2: one year at 0.5%/yr accrues; bob's deposit settles and prices at the new index.
        _warp(SECONDS_PER_YEAR);
        uint256 expected2 = _expectedSettledIndex();
        vm.prank(bob);
        uint256 bobShares = vault.deposit(500e18, bob);
        assertEq(vault.accrualIndex(), expected2, "index after segment 2");
        assertEq(bobShares, Math.mulDiv(500e18, 1e18, expected2), "shares priced at settled index");

        // Segment 3: rate change settles the pending year at the OLD rate first.
        _warp(SECONDS_PER_YEAR);
        uint256 expected3 = _expectedSettledIndex();
        vm.prank(vaultOwner);
        vault.setUsrRate(1e16);
        assertEq(vault.accrualIndex(), expected3, "pending seconds settled at the old rate");

        // Segment 4: one year at the new rate; alice redeems all at the settled index.
        _warp(SECONDS_PER_YEAR);
        uint256 expected4 = _expectedSettledIndex();
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        assertEq(vault.accrualIndex(), expected4, "index after segment 4");
        assertGt(expected4, expected3, "new rate grows the index");
        assertEq(aliceAssets, Math.mulDiv(aliceShares, expected4, 1e18), "redeem at settled index");

        // Same-second settlement idempotency: repeated entries move nothing.
        vm.prank(bob);
        vault.deposit(1e18, bob);
        uint256 afterFirst = vault.accrualIndex();
        vm.prank(bob);
        vault.deposit(1e18, bob);
        assertEq(vault.accrualIndex(), afterFirst, "same-second settlement is idempotent");

        // usrRate == 0 segment: the index freezes.
        _setRate(0);
        assertEq(vault.usrRate(), 0);
        _warp(50 * SECONDS_PER_YEAR);
        vm.prank(bob);
        uint256 frozenShares = vault.deposit(1e18, bob);
        assertEq(vault.accrualIndex(), expected4, "zero-rate segment does not grow the index");
        assertEq(frozenShares, Math.mulDiv(1e18, 1e18, expected4));

        // Wind down and check the solvency invariant.
        uint256 bobRemaining = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobRemaining, bob, bob);
        _assertSolvency();
    }

    function test_MultiUserProportionalAccrual() external {
        vm.prank(vaultOwner);
        vault.fund(1000e18);
        _setRate(RATE_STEP);

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000e18, alice);

        // Bob deposits a year later, so his shares price at alice's grown index.
        _warp(SECONDS_PER_YEAR);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(2000e18, bob);

        _warp(2 * SECONDS_PER_YEAR);
        uint256 expected = _expectedSettledIndex();
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        assertEq(vault.accrualIndex(), expected);

        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        // Each depositor redeems exactly shares * index per the reference conversion...
        assertEq(aliceAssets, Math.mulDiv(aliceShares, expected, 1e18));
        assertEq(bobAssets, Math.mulDiv(bobShares, expected, 1e18));
        assertGt(aliceAssets, 1000e18);
        assertGt(bobAssets, 2000e18);

        // ...and the pool splits strictly by share weight (dust-level tolerance only).
        uint256 total = aliceAssets + bobAssets;
        assertApproxEqAbs(aliceAssets, Math.mulDiv(total, aliceShares, aliceShares + bobShares), 10);
        _assertSolvency();
    }

    // ---------------------------------------------------------------------------------------------
    // Budget cap: stall, suspension, recovery (acceptance 2)
    // ---------------------------------------------------------------------------------------------

    function test_CapStallsAccrualAndFundRestoresGrowth() external {
        // Budget 10e18 over 1000e18 supply: cap is exactly 1.01e18.
        vm.prank(vaultOwner);
        vault.fund(10e18);
        _setRate(RATE_STEP);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        // Warp three years (1.5% at 0.5%/yr) so the extrapolation passes the cap: accrual realizes
        // partially and stops exactly at the cap.
        _warp(3 * SECONDS_PER_YEAR);
        uint256 expectedStall = _expectedSettledIndex();
        _settleOnly();
        assertEq(expectedStall, 1.01e18, "reference expects the stall at the cap");
        assertEq(vault.accrualIndex(), 1.01e18, "index stops at the cap");

        // Later seconds keep extrapolating past the cap: no further growth.
        _warp(3 * SECONDS_PER_YEAR);
        _settleOnly();
        assertEq(vault.accrualIndex(), 1.01e18, "no growth while extrapolation exceeds the cap");

        // Deposits and withdrawals stay available at the stalled index.
        vm.prank(bob);
        uint256 bobShares = vault.deposit(100e18, bob);
        assertEq(bobShares, Math.mulDiv(100e18, 1e18, 1.01e18), "deposit prices at the stalled index");
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);
        assertEq(bobAssets, Math.mulDiv(bobShares, 1.01e18, 1e18), "redeem prices at the stalled index");

        // fund raises the cap: accrual resumes on the next settlement.
        vm.prank(vaultOwner);
        vault.fund(1000e18);
        _warp(2 * SECONDS_PER_YEAR);
        uint256 expectedResume = _expectedSettledIndex();
        _settleOnly();
        assertEq(vault.accrualIndex(), expectedResume, "resumed growth matches the reference");
        assertGt(vault.accrualIndex(), 1.01e18, "index resumed after funding");
        _assertSolvency();
    }

    function test_GrowthSaturationKeepsEntriesAliveAfterHugeGap() external {
        // Tiny budget so the settlement cap binds far below the saturation ceiling.
        vm.prank(vaultOwner);
        vault.fund(1e18);
        _setRate(RATE_STEP);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        // A 1e18-second unsettled gap at the per-second factor: the unclamped power passes the
        // uint256 mulDiv domain mid-loop, which before the saturation clamp reverted every
        // settlement entry and preview — an irreversible lock-in. With saturation the settlement
        // entry must simply succeed.
        _warp(1e18);
        vm.prank(vaultOwner);
        vault.setUsrRate(RATE_STEP);

        // The saturated extrapolation sits far above the cap, so the index stops at the cap.
        assertEq(
            vault.accrualIndex(),
            Math.mulDiv(uAsset.balanceOf(address(vault)), 1e18, vault.totalSupply()),
            "index sits at the cap after the huge gap"
        );

        // Previews and user entries keep working after the gap.
        uint256 preview = vault.previewDeposit(10e18);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(10e18, bob);
        assertEq(bobShares, preview, "preview still matches execution after the gap");
        uint256 aliceRemaining = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceRemaining, alice, alice);
        _assertSolvency();
    }

    function test_ZeroSupplySuspensionNoRetroactiveAccrual() external {
        vm.prank(vaultOwner);
        vault.fund(100e18);
        _setRate(RATE_STEP);

        // Funded but zero shares outstanding: accrual is suspended, only the accounting timestamp
        // moves.
        _warp(100 * SECONDS_PER_YEAR);
        _settleOnly();
        assertEq(vault.accrualIndex(), 1e18, "suspended state does not grow the index");
        assertEq(vault.lastSettledAt(), warpAt, "accounting timestamp still advances");
        assertEq(uAsset.balanceOf(address(vault)), 100e18, "funded budget is not consumed");

        // First deposit prices 1:1 at the current index.
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        assertEq(shares, 1000e18);

        // Accrual counts only from the deposit second: the 100 suspended years are not replayed.
        _warp(SECONDS_PER_YEAR);
        uint256 expected = _expectedSettledIndex();
        _settleOnly();
        assertEq(vault.accrualIndex(), expected);
        assertEq(
            expected,
            _refProjectedIndex(
                1e18, RATE_STEP, SECONDS_PER_YEAR, uAsset.balanceOf(address(vault)), vault.totalSupply()
            ),
            "delta is the year since the deposit, not since suspension"
        );
        assertGt(expected, 1e18);
        _assertSolvency();
    }

    // ---------------------------------------------------------------------------------------------
    // No recovery surface (acceptance 3)
    // ---------------------------------------------------------------------------------------------

    function test_NoOwnerExtractionPathForStrayAssets() external {
        // A mistaken direct transfer strands uAsset inside the vault.
        vm.prank(distributor);
        uAsset.mint(alice, 123e18);
        vm.prank(alice);
        uAsset.transfer(address(vault), 123e18);

        // The owner holds no shares, so any positive withdrawal exceeds their max (zero).
        assertEq(vault.maxWithdraw(vaultOwner), 0);
        assertEq(vault.maxRedeem(vaultOwner), 0);
        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, vaultOwner, 1, 0)
        );
        vault.withdraw(1, vaultOwner, vaultOwner);

        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, vaultOwner, 1, 0));
        vault.redeem(1, vaultOwner, vaultOwner);

        // fund is one-directional: it only adds to the balance, and the stray amount stays put.
        vm.startPrank(vaultOwner);
        vault.fund(1e18);
        vm.stopPrank();
        assertEq(uAsset.balanceOf(address(vault)), 124e18, "stray assets remain in the vault");
        assertEq(vault.totalSupply(), 0, "fund mints no shares");
        assertEq(vault.balanceOf(vaultOwner), 0, "owner received no shares");

        // No sweep/rescue/pause function exists on the vault: the selectors revert outright.
        (bool sweepOk,) = address(vault).call(abi.encodeWithSignature("sweep(address)", address(uAsset)));
        assertFalse(sweepOk);
        (bool sweepAmountOk,) =
            address(vault).call(abi.encodeWithSignature("sweep(address,uint256)", address(uAsset), 1e18));
        assertFalse(sweepAmountOk);
        (bool rescueOk,) =
            address(vault).call(abi.encodeWithSignature("rescue(address,uint256)", address(uAsset), 1e18));
        assertFalse(rescueOk);
        (bool pauseOk,) = address(vault).call(abi.encodeWithSignature("pause()"));
        assertFalse(pauseOk);
        (bool unpauseOk,) = address(vault).call(abi.encodeWithSignature("unpause()"));
        assertFalse(unpauseOk);
    }

    // ---------------------------------------------------------------------------------------------
    // Donation mitigation (acceptance 4)
    // ---------------------------------------------------------------------------------------------

    function test_DonationDoesNotDistortPricing() external {
        // Donation BEFORE the first deposit: the first depositor still prices 1:1 because the
        // conversion reads only the index, never totalAssets/totalSupply.
        vm.prank(distributor);
        uAsset.mint(alice, 500e18);
        vm.prank(alice);
        uAsset.transfer(address(vault), 500e18);
        assertEq(vault.totalAssets(), 500e18, "informational totalAssets includes the donation");

        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);
        assertEq(shares, 1000e18, "first deposit prices 1:1 despite the donation");
        assertEq(vault.accrualIndex(), 1e18, "donation leaves the index untouched");

        // Donation DURING a live position: neither the settled index nor the extrapolating preview
        // moves; only the cap headroom rises. Previews are snapshotted before the donation in the
        // same second (they already reflect the one warped year of accrual).
        _setRate(RATE_STEP);
        _warp(SECONDS_PER_YEAR);
        uint256 previewRedeemBefore = vault.previewRedeem(shares);
        uint256 previewDepositBefore = vault.previewDeposit(1e18);
        vm.prank(alice);
        uAsset.transfer(address(vault), 100e18);
        assertEq(vault.accrualIndex(), 1e18, "settled index untouched by the donation");
        assertEq(vault.previewRedeem(shares), previewRedeemBefore, "donation does not move the redeem preview");
        assertEq(vault.previewDeposit(1e18), previewDepositBefore, "donation does not move the deposit preview");

        // The donated value socializes only through later accrual: the reference counts the donated
        // balance inside the cap.
        _warp(SECONDS_PER_YEAR);
        uint256 expected = _expectedSettledIndex();
        _settleOnly();
        assertEq(vault.accrualIndex(), expected, "post-donation accrual matches the reference");
        _assertSolvency();
    }

    function test_TransientCapBindingDonationDivergesDepositQuote() external {
        (uint256 cap, uint256 projected) = _setUpTransientCapBinding();

        // The stale quote prices at the cap, the effective index of this state.
        uint256 assetsA = 100e18;
        uint256 staleQuote = vault.previewDeposit(assetsA);
        assertEq(staleQuote, Math.mulDiv(assetsA, 1e18, cap), "quote prices at the cap");
        uint256 redeemPreviewBefore = vault.previewRedeem(vault.balanceOf(alice));

        // The donation raises the cap by X * 1e18 / supply; X is small enough that the raised cap
        // still binds below the extrapolation, so the effective price follows the balance.
        uint256 donation = 1e15;
        vm.prank(alice);
        uAsset.transfer(address(vault), donation);
        uint256 capAfterDonation = Math.mulDiv(uAsset.balanceOf(address(vault)), 1e18, vault.totalSupply());
        assertLt(capAfterDonation, projected, "raised cap still binds below the extrapolation");

        uint256 quoteAfterDonation = vault.previewDeposit(assetsA);
        assertLt(quoteAfterDonation, staleQuote, "donation lowers the deposit quote (fewer shares)");
        assertGe(vault.previewRedeem(vault.balanceOf(alice)), redeemPreviewBefore, "withdraw side only benefits");

        // The victim executes at the post-donation price, below the stale quote; the deposit
        // itself settles at min(projected, raised cap) on the pre-deposit state.
        uint256 expectedSettled = _expectedSettledIndex();
        vm.prank(bob);
        uint256 minted = vault.deposit(assetsA, bob);
        assertEq(minted, quoteAfterDonation, "deposit executes at the post-donation quote");
        assertLt(minted, staleQuote, "deposit receives fewer shares than the stale quote");
        assertEq(vault.accrualIndex(), expectedSettled, "settlement writes min(projected, raised cap)");
        assertEq(expectedSettled, capAfterDonation, "the raised cap is the effective index");

        // Value neutrality: an immediate full redeem returns the deposited assets (double-floor
        // dust only) — the donation socialized to holders, it did not extract from the depositor.
        vm.prank(bob);
        uint256 redeemed = vault.redeem(minted, bob, bob);
        assertEq(redeemed, Math.mulDiv(minted, vault.accrualIndex(), 1e18), "redeem at the settled index");
        assertApproxEqAbs(redeemed, assetsA, 2, "roundtrip is value-neutral up to floor dust");
        _assertSolvency();
    }

    function test_TransientCapBindingDonationSkewsMintQuote() external {
        (uint256 cap, uint256 projected) = _setUpTransientCapBinding();

        uint256 sharesM = 100e18;
        uint256 staleQuote = vault.previewMint(sharesM);
        assertEq(staleQuote, Math.mulDiv(sharesM, cap, 1e18, Math.Rounding.Ceil), "quote prices at the cap");

        uint256 donation = 1e15;
        vm.prank(alice);
        uAsset.transfer(address(vault), donation);

        uint256 quoteAfterDonation = vault.previewMint(sharesM);
        assertGt(quoteAfterDonation, staleQuote, "donation raises the mint quote (same shares cost more)");

        vm.prank(bob);
        uint256 paid = vault.mint(sharesM, bob);
        assertEq(paid, quoteAfterDonation, "mint executes at the post-donation quote");
        assertGt(paid, staleQuote, "the victim pays more assets than the stale quote");
        assertLe(paid, Math.mulDiv(sharesM, projected, 1e18, Math.Rounding.Ceil), "bounded by the extrapolation");
        _assertSolvency();
    }

    function test_SameSecondFundInjectionDoesNotMovePreview() external {
        (uint256 cap, uint256 projected) = _setUpTransientCapBinding();

        // Quotes in the transient state: the pre-injection cap is the effective price.
        uint256 assetsA = 100e18;
        uint256 sharesM = 100e18;
        uint256 depositQuote = vault.previewDeposit(assetsA);
        uint256 mintQuote = vault.previewMint(sharesM);
        assertEq(depositQuote, Math.mulDiv(assetsA, 1e18, cap), "quote prices at the cap");

        // fund settles on the pre-injection state first — the settled value equals this same
        // second's pre-injection preview — and the zero delta afterwards degenerates the
        // projection to the settled index, so the same-second previews do not move. X stays small
        // enough that the raised cap keeps binding below the extrapolation.
        vm.prank(vaultOwner);
        vault.fund(1e15);
        uint256 capAfterInjection = Math.mulDiv(uAsset.balanceOf(address(vault)), 1e18, vault.totalSupply());
        assertLt(capAfterInjection, projected, "raised cap still binds below the extrapolation");
        assertEq(vault.previewDeposit(assetsA), depositQuote, "same-second deposit quote unchanged");
        assertEq(vault.previewMint(sharesM), mintQuote, "same-second mint quote unchanged");

        // One second later the injected budget has entered the effective price; the preview's
        // index is the same projection the next settlement would write.
        _warp(1);
        uint256 effectiveAfter = _expectedSettledIndex();
        assertGt(effectiveAfter, cap, "effective price rises past the pre-injection level");
        assertEq(
            vault.previewDeposit(assetsA),
            Math.mulDiv(assetsA, 1e18, effectiveAfter),
            "deposit preview at the post-injection effective index"
        );
        assertLt(vault.previewDeposit(assetsA), depositQuote, "injection lowers the deposit quote from the next second");
        assertEq(
            vault.previewMint(sharesM),
            Math.mulDiv(sharesM, effectiveAfter, 1e18, Math.Rounding.Ceil),
            "mint preview at the post-injection effective index"
        );
        assertGt(vault.previewMint(sharesM), mintQuote, "injection raises the mint quote from the next second");
        _assertSolvency();
    }

    // ---------------------------------------------------------------------------------------------
    // Setter and fund boundaries (acceptance 5)
    // ---------------------------------------------------------------------------------------------

    function test_SetUsrRateBoundsAndDirectSet() external {
        assertEq(vault.usrRate(), 0, "launch default is unactivated");

        vm.startPrank(vaultOwner);
        vm.expectRevert(IUSRVault.UsrRateTooHigh.selector);
        vault.setUsrRate(2e17);

        // Any value within the ceiling is settable in one call, including from zero.
        vm.expectEmit(false, false, false, true);
        emit IUSRVault.UsrRateSet(0, 6e15);
        vault.setUsrRate(6e15);

        vm.expectEmit(false, false, false, true);
        emit IUSRVault.UsrRateSet(6e15, RATE_MAX);
        vault.setUsrRate(RATE_MAX);

        // Absolute ceiling: one wei over reverts.
        vm.expectRevert(IUSRVault.UsrRateTooHigh.selector);
        vault.setUsrRate(RATE_MAX + 1);

        // Deactivation back to zero is a single call.
        vm.expectEmit(false, false, false, true);
        emit IUSRVault.UsrRateSet(RATE_MAX, 0);
        vault.setUsrRate(0);
        vm.stopPrank();
        assertEq(vault.usrRate(), 0, "direct deactivation reaches zero");
    }

    /// @notice Zero stays settable under the resolution floor: it explicitly disables accrual.
    function test_SetUsrRateZeroDisablesAccrual() external {
        _setRate(RATE_STEP);
        vm.prank(vaultOwner);
        vault.setUsrRate(0);
        assertEq(vault.usrRate(), 0, "zero rate disables accrual");
    }

    /// @notice A nonzero rate below one unit per second floors to no growth and reverts.
    function test_RevertWhen_SetUsrRateBelowResolution() external {
        vm.prank(vaultOwner);
        vm.expectRevert(IUSRVault.UsrRateBelowResolution.selector);
        vault.setUsrRate(SECONDS_PER_YEAR - 1);
    }

    /// @notice The smallest nonzero rate (one unit per second) is settable.
    function test_SetUsrRateAtResolutionFloor() external {
        vm.prank(vaultOwner);
        vault.setUsrRate(SECONDS_PER_YEAR);
        assertEq(vault.usrRate(), SECONDS_PER_YEAR, "floor rate is settable");
    }

    function test_FundZeroAmountRevertsAndMintsNoShares() external {
        vm.startPrank(vaultOwner);
        vm.expectRevert(IUSRVault.ZeroInput.selector);
        vault.fund(0);

        vm.expectEmit(false, false, false, true);
        emit IUSRVault.UsrFunded(250e18);
        vault.fund(250e18);
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(vault)), 250e18);
        assertEq(uAsset.balanceOf(vaultOwner), 1_000_000e18 - 250e18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(vaultOwner), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Accrual index settlement event
    // ---------------------------------------------------------------------------------------------

    function test_AccrualIndexSettledEmittedOnIndexGrowth() external {
        vm.prank(vaultOwner);
        vault.fund(100e18);
        _setRate(RATE_STEP);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        // One funded year at 0.5%/yr moves the projection past the settled index.
        _warp(SECONDS_PER_YEAR);
        uint256 oldIndex = vault.accrualIndex();
        uint256 expectedNew = _expectedSettledIndex();
        assertGt(expectedNew, oldIndex, "precondition: warp accrues growth");

        // The deposit settles first, so the index event is the first log of the call.
        vm.expectEmit(false, false, false, true);
        emit IUSRVault.AccrualIndexSettled(oldIndex, expectedNew);
        vm.prank(bob);
        vault.deposit(1e18, bob);

        assertEq(vault.accrualIndex(), expectedNew, "emitted newIndex matches the settled index");
    }

    function test_NoAccrualIndexSettledWithoutIndexChange() external {
        // Zero supply: budget funded but no shares — settlement moves time, not the index.
        vm.prank(vaultOwner);
        vault.fund(100e18);
        _warp(SECONDS_PER_YEAR);
        vm.recordLogs();
        _settleOnly();
        assertEq(_countAccrualIndexSettled(), 0, "zero supply emits nothing");
        assertEq(vault.accrualIndex(), 1e18, "zero supply leaves the index at par");

        // Zero rate with supply: the per-second factor is par, so the projection matches.
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        _warp(SECONDS_PER_YEAR);
        vm.recordLogs();
        _settleOnly();
        assertEq(_countAccrualIndexSettled(), 0, "zero rate emits nothing");

        // Same second: back-to-back settlements with no time passing move nothing.
        vm.recordLogs();
        _settleOnly();
        assertEq(_countAccrualIndexSettled(), 0, "same-second settlement emits nothing");

        // Cap-pinned: extrapolation stays past the cap, so settlement moves time but emits nothing.
        _setRate(RATE_STEP);
        _warp(30 * SECONDS_PER_YEAR);
        _settleOnly();
        uint256 pinned = Math.mulDiv(uAsset.balanceOf(address(vault)), 1e18, vault.totalSupply());
        assertEq(vault.accrualIndex(), pinned, "index pinned at the cap");
        _warp(3 * SECONDS_PER_YEAR);
        vm.recordLogs();
        _settleOnly();
        assertEq(_countAccrualIndexSettled(), 0, "cap-pinned settlement emits nothing");
        assertEq(vault.accrualIndex(), pinned, "cap-pinned settlement leaves the index");
        assertEq(vault.lastSettledAt(), warpAt, "cap-pinned settlement still advances time");
    }

    // ---------------------------------------------------------------------------------------------
    // Preview vs execution (acceptance 6)
    // ---------------------------------------------------------------------------------------------

    function test_PreviewMatchesExecutionInAllStates() external {
        // State A: fresh vault (zero supply, rate off) — suspended pricing at par.
        _checkPreviewExecutionRoundtrips(alice, 100e18, 123.456e18);

        // State B: funded budget with live accrual below the cap.
        vm.prank(vaultOwner);
        vault.fund(1000e18);
        _setRate(RATE_STEP);
        vm.prank(alice);
        vault.deposit(500e18, alice);
        _warp(SECONDS_PER_YEAR);
        assertEq(vault.convertToShares(1e18), vault.previewDeposit(1e18));
        assertEq(vault.convertToAssets(1e18), vault.previewRedeem(1e18));
        _checkPreviewExecutionRoundtrips(alice, 77.7e18, 88.8e18);
        assertTrue(vault.accrualIndex() > 1e18, "state B is actively accruing");

        // State C: capped — tiny budget so the extrapolation is clamped at the cap (200 years at
        // 0.5%/yr compounds past the balance-backed ceiling).
        vm.prank(vaultOwner);
        vault.fund(10e18);
        vm.prank(bob);
        vault.deposit(1000e18, bob);
        _warp(200 * SECONDS_PER_YEAR);
        _settleOnly();
        assertEq(
            vault.accrualIndex(),
            Math.mulDiv(uAsset.balanceOf(address(vault)), 1e18, vault.totalSupply()),
            "state C sits at the cap"
        );
        _checkPreviewExecutionRoundtrips(alice, 100e18, 50e18);
        _assertSolvency();
    }

    // ---------------------------------------------------------------------------------------------
    // Cross-case invariants (acceptance 7)
    // ---------------------------------------------------------------------------------------------

    function test_InvariantsHoldAcrossOperationSequence() external {
        uint256 lastIndex = vault.accrualIndex();

        vm.prank(vaultOwner);
        vault.fund(50e18);
        _setRate(RATE_STEP);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        vm.prank(alice);
        vault.deposit(1000e18, alice);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        _warp(2 * SECONDS_PER_YEAR);
        vm.prank(bob);
        vault.deposit(300e18, bob);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        // Direct donation mid-flight: liability unchanged, balance grows.
        vm.prank(alice);
        uAsset.transfer(address(vault), 25e18);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        _warp(5 * SECONDS_PER_YEAR);
        vm.prank(alice);
        vault.withdraw(100e18, alice, alice);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        _warp(SECONDS_PER_YEAR);
        uint256 bobRemaining = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobRemaining, bob, bob);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        // Back to zero supply (suspension), then re-supply.
        _warp(10 * SECONDS_PER_YEAR);
        uint256 aliceRemaining = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceRemaining, alice, alice);
        _assertInvariants(lastIndex);
        lastIndex = vault.accrualIndex();

        _warp(3 * SECONDS_PER_YEAR);
        vm.prank(alice);
        vault.deposit(10e18, alice);
        _assertInvariants(lastIndex);
    }

    // ---------------------------------------------------------------------------------------------
    // Asset pause propagation (spec: fail-closed)
    // ---------------------------------------------------------------------------------------------

    function test_UAssetPauseFailsClosed() external {
        vm.prank(vaultOwner);
        vault.fund(100e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        _setRate(RATE_STEP);
        _warp(5);

        vm.prank(uAssetOwner);
        uAsset.pause();

        // Both directions revert on the uAsset transfer leg; each whole call rolls back atomically,
        // including the settlement it attempted.
        vm.startPrank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.deposit(1e18, alice);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.mint(1e18, alice);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.redeem(1, alice, alice);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.withdraw(1, alice, alice);
        vm.stopPrank();

        vm.startPrank(vaultOwner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.fund(1e18);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares, "no partial state survives");
        assertEq(uAsset.balanceOf(address(vault)), 200e18, "no partial state survives");
        assertEq(vault.accrualIndex(), 1e18, "the settlement attempted by reverted calls rolled back");
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions and standard ERC4626 two-path roundtrips
    // ---------------------------------------------------------------------------------------------

    function test_NonOwnerCannotManageOrUpgradeAndOwnerCanUpgrade() external {
        bytes4 unauthorized = OwnableUpgradeable.OwnableUnauthorizedAccount.selector;

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        vault.fund(1e18);

        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        vault.setUsrRate(1e15);
        vm.stopPrank();

        OutrunUSRVaultUpgradeable newImplementation = new OutrunUSRVaultUpgradeable();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        vault.upgradeToAndCall(address(newImplementation), "");

        // The owner can rewire the implementation; namespaced state survives.
        vm.prank(vaultOwner);
        vault.upgradeToAndCall(address(newImplementation), "");
        assertEq(vault.owner(), vaultOwner);
        assertEq(vault.lastSettledAt(), warpAt);
        assertEq(vault.accrualIndex(), 1e18);
    }

    function test_ERC4626DepositWithdrawAndMintRedeemEquivalence() external {
        vm.prank(vaultOwner);
        vault.fund(100e18);
        _setRate(RATE_STEP);

        // Same second at par: both paths take in the same assets and mint the same shares.
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000e18, alice);
        vm.prank(bob);
        uint256 bobAssetsIn = vault.mint(1000e18, bob);
        assertEq(bobAssetsIn, 1000e18);
        assertEq(vault.balanceOf(alice), vault.balanceOf(bob));

        _warp(2 * SECONDS_PER_YEAR);
        uint256 expected = _expectedSettledIndex();
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(1000e18, bob, bob);

        assertEq(vault.accrualIndex(), expected);
        assertEq(aliceAssets, bobAssets, "equal shares redeem equal assets");
        assertEq(aliceAssets, Math.mulDiv(aliceShares, expected, 1e18));
        assertGt(aliceAssets, 1000e18, "accrued interest is paid out");

        // Informational totalAssets stays the plain balance view.
        assertEq(vault.totalAssets(), uAsset.balanceOf(address(vault)));
        _assertSolvency();
    }

    // ---------------------------------------------------------------------------------------------
    // Bounded fuzz: random operation sequence
    // ---------------------------------------------------------------------------------------------

    function testFuzz_RandomOperationsPreserveInvariantsAndPreviewConsistency(uint256 seed) external {
        vm.prank(vaultOwner);
        vault.fund(1_000e18);
        _setRate(RATE_STEP);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // 12 steps per run; each step derives the actor, the operation, and a bounded amount from a
        // hash chain over the fuzz seed. Amounts are clamped to what the actor holds so no
        // legitimate operation reverts; withdrawal/redeem legs take fractions of the covered
        // balance so ERC4626 ceiling rounding never overshoots the holder.
        uint256 state = seed;
        uint256 lastIndex = vault.accrualIndex();
        for (uint256 step = 0; step < 12; step++) {
            state = uint256(keccak256(abi.encode(state)));
            address user = (state & 1) == 0 ? alice : bob;
            uint256 op = (state >> 4) % 6;
            uint256 pct = 1 + (state >> 8) % 100;

            if (op == 0) {
                // deposit: same-second preview == execution (inbound direction).
                uint256 assets = Math.min(100e18, uAsset.balanceOf(user));
                if (assets == 0) continue;
                uint256 preview = vault.previewDeposit(assets);
                vm.prank(user);
                uint256 minted = vault.deposit(assets, user);
                assertEq(minted, preview, "previewDeposit == deposit");
            } else if (op == 1) {
                uint256 assets = Math.mulDiv(vault.convertToAssets(vault.balanceOf(user)), pct, 100);
                if (assets == 0) continue;
                vm.prank(user);
                vault.withdraw(assets, user, user);
            } else if (op == 2) {
                uint256 shares = Math.min(100e18, vault.totalSupply());
                uint256 cost = vault.previewMint(shares);
                if (cost == 0 || cost > uAsset.balanceOf(user)) continue;
                vm.prank(user);
                vault.mint(shares, user);
            } else if (op == 3) {
                // redeem: same-second preview == execution (outbound direction).
                uint256 shares = Math.mulDiv(vault.balanceOf(user), pct, 100);
                if (shares == 0) continue;
                uint256 preview = vault.previewRedeem(shares);
                vm.prank(user);
                uint256 paid = vault.redeem(shares, user, user);
                assertEq(paid, preview, "previewRedeem == redeem");
            } else if (op == 4) {
                uint256 amount = Math.min(50e18, uAsset.balanceOf(vaultOwner));
                if (amount == 0) continue;
                vm.prank(vaultOwner);
                vault.fund(amount);
            } else {
                _warp((state >> 8) % 600);
            }

            _assertInvariants(lastIndex);
            lastIndex = vault.accrualIndex();
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reference implementation and helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Independent re-derivation of the per-second growth power: factor = 1e18 + rate /
    ///      SECONDS_PER_YEAR, then MSB-first exponentiation-by-squaring with immediate mulDiv
    ///      reduction and the same deterministic saturation ceiling (SATURATION). Written from the
    ///      spec text, not from the contract internals.
    function _refGrowth(uint256 rate, uint256 deltaSeconds) internal pure returns (uint256 r) {
        uint256 factor = 1e18 + rate / SECONDS_PER_YEAR;
        if (deltaSeconds == 0) return 1e18;

        uint256 msb = 0;
        for (uint256 rest = deltaSeconds; rest > 1; rest >>= 1) {
            msb++;
        }

        r = factor;
        for (uint256 bit = msb; bit > 0; bit--) {
            r = Math.mulDiv(r, r, 1e18);
            if (((deltaSeconds >> (bit - 1)) & 1) == 1) {
                r = Math.mulDiv(r, factor, 1e18);
            }
            if (r > SATURATION) {
                r = SATURATION;
            }
        }
    }

    /// @dev Independent re-derivation of the projected (extrapolated and cap-clamped) index:
    ///      max(current, min(current * growth, balance * 1e18 / supply)), with the zero-supply
    ///      suspension returning the current index.
    function _refProjectedIndex(uint256 index, uint256 rate, uint256 deltaSeconds, uint256 balance, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        if (supply == 0) return index;
        uint256 projected = Math.mulDiv(index, _refGrowth(rate, deltaSeconds), 1e18);
        uint256 cap = Math.mulDiv(balance, 1e18, supply);
        uint256 clamped = projected < cap ? projected : cap;
        return clamped > index ? clamped : index;
    }

    /// @dev Expected settled index for the next settlement entry: the reference projected on the
    ///      current on-chain state, snapshotted before the triggering call.
    function _expectedSettledIndex() internal view returns (uint256) {
        return _refProjectedIndex(
            vault.accrualIndex(),
            vault.usrRate(),
            warpAt - vault.lastSettledAt(),
            uAsset.balanceOf(address(vault)),
            vault.totalSupply()
        );
    }

    /// @dev Triggers a settlement without touching the balance or the supply: re-setting the
    ///      current rate is a valid settlement entry (step zero) and changes nothing else. The rate
    ///      is read before the prank so the prank applies to the state-changing call.
    function _settleOnly() internal {
        uint256 currentRate = vault.usrRate();
        vm.prank(vaultOwner);
        vault.setUsrRate(currentRate);
    }

    /// @dev Counts AccrualIndexSettled logs since the last vm.recordLogs: filters by topic0 so the
    ///      UsrRateSet log that _settleOnly also emits is ignored.
    function _countAccrualIndexSettled() internal returns (uint256 hits) {
        bytes32 settledTopic = IUSRVault.AccrualIndexSettled.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == settledTopic) {
                hits++;
            }
        }
    }

    /// @dev Sets the rate to `target` directly in one call (same-second settlement is a no-op).
    function _setRate(uint256 target) internal {
        vm.prank(vaultOwner);
        vault.setUsrRate(target);
    }

    /// @dev Shared construction for the transient cap-binding donation vectors: one year of 0.5%/yr
    ///      on par settles below the 1.01e18 cap (10e18 budget over 1000e18 supply), then a second
    ///      un-settled year extrapolates past it. Returns the on-chain cap and the un-clamped
    ///      projection and asserts the transient precondition accrualIndex < cap < projected.
    function _setUpTransientCapBinding() internal returns (uint256 cap, uint256 projected) {
        vm.prank(vaultOwner);
        vault.fund(10e18);
        _setRate(RATE_STEP);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        _warp(SECONDS_PER_YEAR);
        _settleOnly();
        _warp(SECONDS_PER_YEAR);

        cap = Math.mulDiv(uAsset.balanceOf(address(vault)), 1e18, vault.totalSupply());
        projected = Math.mulDiv(vault.accrualIndex(), _refGrowth(vault.usrRate(), warpAt - vault.lastSettledAt()), 1e18);
        assertLt(vault.accrualIndex(), cap, "settled index below the cap (transient, not stalled)");
        assertLt(cap, projected, "extrapolation past the cap (the cap is the effective price)");
    }

    /// @dev Acceptance invariant: real share liability stays within the real balance and the index
    ///      never drops below par or below its previous value.
    function _assertInvariants(uint256 lastIndex) internal view {
        uint256 index = vault.accrualIndex();
        assertGe(index, 1e18, "index never below par");
        assertGe(index, lastIndex, "index monotonic non-decreasing");
        assertLe(Math.mulDiv(vault.totalSupply(), index, 1e18), uAsset.balanceOf(address(vault)), "solvency");
    }

    function _assertSolvency() internal view {
        assertGe(vault.accrualIndex(), 1e18);
        assertLe(Math.mulDiv(vault.totalSupply(), vault.accrualIndex(), 1e18), uAsset.balanceOf(address(vault)));
    }

    /// @dev For each preview/execution pair the preview is taken immediately before the call in the
    ///      same second and same state; the withdrawal leg uses an exactly-covered amount so ERC4626
    ///      ceiling rounding can never overshoot the holder's balance.
    function _checkPreviewExecutionRoundtrips(address user, uint256 depositAssets, uint256 mintShares) internal {
        uint256 previewDeposit = vault.previewDeposit(depositAssets);
        vm.prank(user);
        uint256 mintedShares = vault.deposit(depositAssets, user);
        assertEq(mintedShares, previewDeposit, "previewDeposit == deposit");

        uint256 redeemShares = vault.balanceOf(user);
        uint256 previewRedeem = vault.previewRedeem(redeemShares);
        vm.prank(user);
        uint256 redeemedAssets = vault.redeem(redeemShares, user, user);
        assertEq(redeemedAssets, previewRedeem, "previewRedeem == redeem");

        uint256 previewMint = vault.previewMint(mintShares);
        vm.prank(user);
        uint256 paidAssets = vault.mint(mintShares, user);
        assertEq(paidAssets, previewMint, "previewMint == mint");

        uint256 withdrawAssets = vault.convertToAssets(vault.balanceOf(user));
        uint256 previewWithdraw = vault.previewWithdraw(withdrawAssets);
        vm.prank(user);
        uint256 burnedShares = vault.withdraw(withdrawAssets, user, user);
        assertEq(burnedShares, previewWithdraw, "previewWithdraw == withdraw");
        assertLe(burnedShares, mintShares, "ceiling rounding stays inside the minted shares");
    }

    function _deploy(
        OutrunUSRVaultUpgradeable implementation,
        address asset_,
        string memory name_,
        string memory symbol_,
        address owner_
    ) internal returns (OutrunUSRVaultUpgradeable) {
        return OutrunUSRVaultUpgradeable(
            ProxyTestHelper.deploy(
                address(implementation),
                abi.encodeCall(OutrunUSRVaultUpgradeable.initialize, (asset_, name_, symbol_, owner_))
            )
        );
    }
}
