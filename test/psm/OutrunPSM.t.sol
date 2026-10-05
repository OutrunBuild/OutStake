// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {IPSM} from "../../src/psm/interfaces/IPSM.sol";
import {NativeAmountMismatch, NativeTransferFailed} from "../../src/libraries/TokenHelper.sol";
import {NativeRejectingReceiver, PSMMockReserveERC20, ReenteringReserveERC20} from "./mocks/PSMMocks.sol";
import {ProxyTestHelper} from "../upgradeable/helpers/ProxyTestHelper.sol";
import {UAssetHelper} from "../upgradeable/helpers/UAssetHelper.sol";

contract OutrunPSMTest is UAssetHelper {
    // NATIVE sentinel matching TokenHelper: address(0) routes to the native currency leg.
    address internal constant NATIVE = address(0);

    // Default deployment parameters: 0.1% fees, a generous stock cap so most tests exercise the fee math.
    uint256 internal constant TIN = 1e15;
    uint256 internal constant TOUT = 1e15;
    uint256 internal constant STOCK_CAP = 1_000_000e18;

    OutrunUniversalAssetsUpgradeable internal uAsset;
    // Single-reserve instances sharing one family uAsset: the ERC20 leg and the native leg.
    OutrunPSMUpgradeable internal psm;
    OutrunPSMUpgradeable internal psmNative;
    PSMMockReserveERC20 internal usdc;

    address internal uAssetOwner = address(0xA11CE);
    address internal psmOwner = address(0xB0B);
    address internal feeRecipient = address(0xFEE);
    address internal alice = address(0xCAFE);
    address internal bob = address(0xFEED);

    function setUp() external {
        uAsset = _deployUAsset(uAssetOwner);

        usdc = new PSMMockReserveERC20("Mock USDC", "USDC", 6);

        OutrunPSMUpgradeable psmImplementation = new OutrunPSMUpgradeable();
        psm = OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(psmImplementation),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize,
                    (address(uAsset), address(usdc), psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT)
                )
            )
        );
        psmNative = OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(psmImplementation),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize,
                    (address(uAsset), NATIVE, psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT)
                )
            )
        );

        // Deployment wiring: the uAsset owner registers each single-reserve instance as reserve minter.
        vm.startPrank(uAssetOwner);
        uAsset.setReserveMinter(address(psm), true);
        uAsset.setReserveMinter(address(psmNative), true);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.deal(alice, 1_000_000e18);
        vm.deal(bob, 1_000_000e18);

        vm.startPrank(alice);
        usdc.approve(address(psm), type(uint256).max);
        uAsset.approve(address(psm), type(uint256).max);
        uAsset.approve(address(psmNative), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(psm), type(uint256).max);
        uAsset.approve(address(psm), type(uint256).max);
        uAsset.approve(address(psmNative), type(uint256).max);
        vm.stopPrank();
    }

    function test_InitializeBindsParametersAndOwner() external {
        assertEq(psm.uAsset(), address(uAsset));
        assertEq(psm.reserveToken(), address(usdc));
        assertEq(psm.owner(), psmOwner);
        assertEq(psm.feeRecipient(), feeRecipient);
        assertEq(psm.tin(), TIN);
        assertEq(psm.tout(), TOUT);
        assertEq(psm.stockCap(), STOCK_CAP);
        assertEq(psm.netUAssetMinted(), 0);

        assertEq(psmNative.uAsset(), address(uAsset));
        assertEq(psmNative.reserveToken(), NATIVE);
        assertEq(psmNative.owner(), psmOwner);
        assertEq(psmNative.netUAssetMinted(), 0);
    }

    function test_InitializeRevertsOnInvalidParametersAndReinit() external {
        OutrunPSMUpgradeable implementation = new OutrunPSMUpgradeable();

        vm.expectRevert(IPSM.ZeroInput.selector);
        _deploy(implementation, address(0), address(usdc), psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT);

        vm.expectRevert(IPSM.ZeroInput.selector);
        _deploy(implementation, address(uAsset), address(usdc), address(0), feeRecipient, STOCK_CAP, TIN, TOUT);

        vm.expectRevert(IPSM.ZeroInput.selector);
        _deploy(implementation, address(uAsset), address(usdc), psmOwner, address(0), STOCK_CAP, TIN, TOUT);

        vm.expectRevert(IPSM.ZeroInput.selector);
        _deploy(implementation, address(uAsset), address(usdc), psmOwner, feeRecipient, 0, TIN, TOUT);

        vm.expectRevert(IPSM.FeeOutOfRange.selector);
        _deploy(implementation, address(uAsset), address(usdc), psmOwner, feeRecipient, STOCK_CAP, 1e16 + 1, TOUT);

        vm.expectRevert(IPSM.FeeOutOfRange.selector);
        _deploy(implementation, address(uAsset), address(usdc), psmOwner, feeRecipient, STOCK_CAP, TIN, 1e16 + 1);

        // The NATIVE sentinel is a legal binding: no code check runs on the reserve.
        OutrunPSMUpgradeable nativeBound =
            _deploy(implementation, address(uAsset), NATIVE, psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT);
        assertEq(nativeBound.reserveToken(), NATIVE);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        psm.initialize(address(uAsset), address(usdc), psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(uAsset), address(usdc), psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT);
    }

    function test_MintRedeemRoundtripERC20SixDecimals() external {
        vm.prank(alice);
        uint256 amountOut = psm.mint(alice, 1000e6);

        // 1000e6 USDC == 1000e18 face value; tin 0.1% -> 999e18 uAsset minted, 1e18 fee retained.
        assertEq(amountOut, 999e18);
        assertEq(uAsset.balanceOf(alice), 999e18);
        assertEq(psm.netUAssetMinted(), 999e18);
        assertEq(usdc.balanceOf(address(psm)), 1000e6);
        assertEq(psm.quoteMint(1000e6), amountOut);

        vm.prank(alice);
        uint256 paidOut = psm.redeem(alice, 999e18);

        // 999e18 face * (1 - 0.1%) = 998.001e18, floored back to 6 decimals = 998_001_000 units.
        assertEq(paidOut, 998_001_000);
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 1000e6 + 998_001_000);
        assertEq(uAsset.balanceOf(alice), 0);
        assertEq(psm.netUAssetMinted(), 0);
        assertEq(psm.quoteRedeem(999e18), paidOut);
    }

    function test_MintRedeemRoundtripNativeIdentityScale() external {
        vm.prank(alice);
        uint256 amountOut = psmNative.mint{value: 1000e18}(alice, 1000e18);
        assertEq(amountOut, 999e18);

        vm.prank(alice);
        uint256 paidOut = psmNative.redeem(alice, 999e18);

        // Native is 18-dec: no rescale floor, so the payout is exactly 998.001e18.
        assertEq(paidOut, 998.001e18);
        assertEq(alice.balance, 1_000_000e18 - 1000e18 + 998.001e18);
        // Retained fees: 1e18 from mint + 0.999e18 from redeem.
        assertEq(address(psmNative).balance, 1.999e18);
        assertEq(psmNative.netUAssetMinted(), 0);
    }

    function test_DefaultFeesAreTenBasisPoints() external {
        assertEq(psm.tin(), 1e15);
        assertEq(psm.tout(), 1e15);

        // Numeric anchor for the default fee level: 1 USDC mints 0.999 UUSD...
        assertEq(psm.quoteMint(1e6), 0.999e18);
        // ... and 1 UUSD redeems 0.999 USDC (only tout applies on the redeem leg).
        assertEq(psm.quoteRedeem(1e18), 999_000);
    }

    function test_SetFeesBoundsAndZeroFeeExactness() external {
        vm.startPrank(psmOwner);
        vm.expectEmit(false, false, false, true);
        emit IPSM.SetFees(0, 0);
        psm.setFees(0, 0);

        vm.expectEmit(false, false, false, true);
        emit IPSM.SetFees(1e16, 1e16);
        psm.setFees(1e16, 1e16);

        vm.expectRevert(IPSM.FeeOutOfRange.selector);
        psm.setFees(1e16 + 1, 0);

        vm.expectRevert(IPSM.FeeOutOfRange.selector);
        psm.setFees(0, 1e16 + 1);

        // Back to zero fees for the exactness check.
        psm.setFees(0, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        uint256 amountOut = psm.mint(alice, 100e6);
        assertEq(amountOut, 100e18);

        uint256 paidOut = psm.redeem(alice, 100e18);
        assertEq(paidOut, 100e6);
        vm.stopPrank();
    }

    function test_FeeFloorRoundingAndDifferenceDerivedFees() external {
        // Native input whose face value does not divide evenly by the 0.1% fee.
        uint256 amountIn = 1e18 + 12_345;
        uint256 faceValue = amountIn;
        uint256 expectedOut = (amountIn * 999) / 1000;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IPSM.SwapMintForUAsset(NATIVE, alice, amountIn, expectedOut, faceValue - expectedOut);
        uint256 amountOut = psmNative.mint{value: amountIn}(alice, amountIn);

        assertEq(amountOut, expectedOut);
        assertEq(psmNative.quoteMint(amountIn), expectedOut);

        uint256 expectedPayout = (expectedOut * 999) / 1000;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IPSM.SwapRedeemForReserve(NATIVE, alice, expectedOut, expectedPayout, expectedOut - expectedPayout);
        uint256 paidOut = psmNative.redeem(alice, expectedOut);

        assertEq(paidOut, expectedPayout);

        // 6-dec rescale floor: a payout whose 18-dec face value has sub-unit dust keeps the dust as fee.
        vm.startPrank(psmOwner);
        psm.setFees(0, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 minted = psm.mint(bob, 1001e6);
        assertEq(minted, 1001e18);

        uint256 dustRedeem = 1000e18 + 12_345;
        vm.expectEmit(true, true, false, true);
        // 1000e18 + 12_345 wei face floors to 1000e6 units; the 12_345 wei of dust stays in the PSM.
        emit IPSM.SwapRedeemForReserve(address(usdc), bob, dustRedeem, 1000e6, 12_345);
        uint256 dustPayout = psm.redeem(bob, dustRedeem);
        assertEq(dustPayout, 1000e6);
        vm.stopPrank();
    }

    function test_MsgValueContractForBothLegs() external {
        vm.startPrank(alice);
        vm.expectRevert(NativeAmountMismatch.selector);
        psmNative.mint{value: 99e18}(alice, 100e18);

        vm.expectRevert(NativeAmountMismatch.selector);
        psmNative.mint{value: 101e18}(alice, 100e18);

        vm.expectRevert(NativeAmountMismatch.selector);
        psm.mint{value: 1}(alice, 100e6);
        vm.stopPrank();

        // redeem is non-payable, so an attached value is rejected by the compiler's implicit callvalue
        // guard before the body runs — verified through raw calls since the type system forbids the
        // direct `{value: ...}` syntax on a non-payable function. The guard reverts with empty return
        // data; any in-body failure carries an error selector instead, so the empty-data check is what
        // pins the guard itself. The calls run as the funded and approved alice: if redeem ever became
        // payable, the body would run and fail on her zero uAsset balance with a selector, failing here.
        vm.prank(alice);
        (bool nativeRedeemOk, bytes memory nativeRedeemData) =
            address(psmNative).call{value: 1}(abi.encodeCall(IPSM.redeem, (alice, 1e18)));
        assertFalse(nativeRedeemOk);
        assertEq(nativeRedeemData.length, 0);

        vm.prank(alice);
        (bool erc20RedeemOk, bytes memory erc20RedeemData) =
            address(psm).call{value: 1}(abi.encodeCall(IPSM.redeem, (alice, 1e18)));
        assertFalse(erc20RedeemOk);
        assertEq(erc20RedeemData.length, 0);

        // No native stranded by any of the reverted calls.
        assertEq(address(psm).balance, 0);
        assertEq(address(psmNative).balance, 0);
    }

    function test_StockCapBoundaryReflowAndSetterRules() external {
        vm.startPrank(psmOwner);
        psmNative.setFees(0, 0);
        psmNative.setStockCap(1000e18);
        vm.stopPrank();

        // At the line: net minted exactly equals the stock cap.
        vm.prank(alice);
        uint256 amountOut = psmNative.mint{value: 1000e18}(alice, 1000e18);
        assertEq(amountOut, 1000e18);
        assertEq(psmNative.netUAssetMinted(), 1000e18);

        // Over the line by one wei.
        vm.prank(alice);
        vm.expectRevert(IPSM.StockCapExceeded.selector);
        psmNative.mint{value: 1}(alice, 1);

        // Redeem frees headroom; minting back up to the cap succeeds again.
        vm.prank(alice);
        uint256 paidOut = psmNative.redeem(alice, 400e18);
        assertEq(paidOut, 400e18);
        assertEq(psmNative.netUAssetMinted(), 600e18);

        vm.prank(alice);
        uint256 reMinted = psmNative.mint{value: 400e18}(alice, 400e18);
        assertEq(reMinted, 400e18);
        assertEq(psmNative.netUAssetMinted(), 1000e18);

        // Caps never turn off.
        vm.prank(psmOwner);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psmNative.setStockCap(0);
    }

    function test_ReserveConservationPerInstance() external {
        // Per-instance trackers, derived from actual swap returns and the spec formulas
        // (fee = input face value - user amount, floor losses included).
        uint256 usdcFaceIn;
        uint256 usdcFacePaid;
        uint256 usdcNetMinted;
        uint256 usdcFees;
        uint256 usdcUnitsHeld;

        uint256 nativeNetMinted;
        uint256 nativeFees;
        uint256 nativeWeiHeld;

        // Swap 1: alice mints 123_456.789012 USDC (6-dec, non-round amount) on the ERC20 instance.
        vm.prank(alice);
        uint256 out1 = psm.mint(alice, 123_456_789_012);
        uint256 face1 = 123_456_789_012e12;
        assertEq(out1, (face1 * 999) / 1000);
        usdcFaceIn += face1;
        usdcNetMinted += out1;
        usdcFees += face1 - out1;
        usdcUnitsHeld += 123_456_789_012;

        // Swap 2: alice mints native on the native instance.
        vm.prank(alice);
        uint256 out2 = psmNative.mint{value: 45_678e18}(alice, 45_678e18);
        assertEq(out2, (45_678e18 * 999) / 1000);
        nativeNetMinted += out2;
        nativeFees += 45_678e18 - out2;
        nativeWeiHeld += 45_678e18;

        // Swap 3: bob mints 65_432 USDC on the ERC20 instance.
        vm.prank(bob);
        uint256 out3 = psm.mint(bob, 65_432e6);
        uint256 face3 = 65_432e18;
        assertEq(out3, (face3 * 999) / 1000);
        usdcFaceIn += face3;
        usdcNetMinted += out3;
        usdcFees += face3 - out3;
        usdcUnitsHeld += 65_432e6;

        // Swap 4: alice redeems 50_000 uAsset into USDC (uAsset is fungible across instances).
        vm.prank(alice);
        uint256 pay4 = psm.redeem(alice, 50_000e18);
        uint256 pay4Face = pay4 * 1e12;
        assertEq(pay4, 49_950e6);
        usdcNetMinted -= 50_000e18;
        usdcFees += 50_000e18 - pay4Face;
        usdcFacePaid += pay4Face;
        usdcUnitsHeld -= pay4;

        // Swap 5: bob redeems 12_345 uAsset into native on the native instance.
        vm.prank(bob);
        uint256 pay5 = psmNative.redeem(bob, 12_345e18);
        assertEq(pay5, (12_345e18 * 999) / 1000);
        nativeNetMinted -= 12_345e18;
        nativeFees += 12_345e18 - pay5;
        nativeWeiHeld -= pay5;

        // Swap 6: alice redeems a dust-tailed amount into USDC so the 6-dec rescale floor keeps wei
        // as fee (face value out is not a whole 1e12 multiple).
        vm.prank(alice);
        uint256 pay6 = psm.redeem(alice, 1_500_000_000_000_003_000);
        uint256 pay6Face = pay6 * 1e12;
        assertEq(pay6, 1_498_500);
        usdcNetMinted -= 1_500_000_000_000_003_000;
        usdcFees += 1_500_000_000_000_003_000 - pay6Face;
        usdcFacePaid += pay6Face;
        usdcUnitsHeld -= pay6;

        // Exact per-wei holdings per instance.
        assertEq(usdc.balanceOf(address(psm)), usdcUnitsHeld);
        assertEq(address(psmNative).balance, nativeWeiHeld);

        // Conservation identity per instance: held face value == net minted face + accumulated fees.
        assertEq(usdcUnitsHeld * 1e12, usdcNetMinted + usdcFees);
        assertEq(nativeWeiHeld, nativeNetMinted + nativeFees);

        // The same identity read from flow accumulators: inflow face - paid-out face == net + fees.
        assertEq(usdcFaceIn - usdcFacePaid, usdcNetMinted + usdcFees);

        // Instance ledgers are independent: each net equals only its own swaps.
        assertEq(psm.netUAssetMinted(), usdcNetMinted);
        assertEq(psmNative.netUAssetMinted(), nativeNetMinted);
    }

    /// @notice Fee accumulation on the ERC20 leg: mint + redeem fees are sweepable by anyone
    ///         (bob is not the owner) to the immutable feeRecipient, the payout equals
    ///         sweepableFees(), the FeesSwept event fires, and the sweep leaves the
    ///         reserve-cover invariant (held face >= net minted) intact without touching the ledger.
    function test_SweepFeesERC20Leg() external {
        vm.prank(alice);
        psm.mint(alice, 1000e6); // 1e18 face fee retained
        vm.prank(alice);
        psm.redeem(alice, 999e18); // 0.999e18 face fee retained, net minted back to 0

        // Surplus: 1000e6 held - 998_001_000 paid out = 1_999_000 units against a zero net minted.
        assertEq(psm.sweepableFees(), 1_999_000);

        // Permissionless: a non-owner caller sweeps; the recipient is always the bound feeRecipient.
        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit IPSM.FeesSwept(address(usdc), feeRecipient, 1_999_000);
        uint256 swept = psm.sweepFees();

        assertEq(swept, 1_999_000);
        assertEq(usdc.balanceOf(feeRecipient), 1_999_000);
        assertEq(usdc.balanceOf(address(psm)), 0);
        // The sweep drains only the surplus: net minted and the cap headroom are untouched.
        assertEq(psm.netUAssetMinted(), 0);
    }

    /// @notice Fee accumulation on the native leg: the sweep pays out native via the low-level
    ///         call path to the feeRecipient with the same surplus formula.
    function test_SweepFeesNativeLeg() external {
        vm.prank(alice);
        psmNative.mint{value: 1000e18}(alice, 1000e18); // 1e18 fee
        vm.prank(alice);
        psmNative.redeem(alice, 999e18); // 0.999e18 fee, net minted back to 0

        assertEq(psmNative.sweepableFees(), 1.999e18);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit IPSM.FeesSwept(NATIVE, feeRecipient, 1.999e18);
        uint256 swept = psmNative.sweepFees();

        assertEq(swept, 1.999e18);
        assertEq(feeRecipient.balance, 1.999e18);
        assertEq(address(psmNative).balance, 0);
        assertEq(psmNative.netUAssetMinted(), 0);
    }

    /// @notice A native sweep to a feeRecipient that rejects native transfers reverts
    ///         NativeTransferFailed and leaves the sweepable surplus and the held native intact:
    ///         the feeRecipient is immutable, so until it can receive native the surplus stays
    ///         reserve cover in the PSM.
    function test_RevertIf_SweepFeesToNativeRejectingFeeRecipient() external {
        NativeRejectingReceiver rejector = new NativeRejectingReceiver();
        OutrunPSMUpgradeable psmReject = _deploy(
            new OutrunPSMUpgradeable(), address(uAsset), NATIVE, psmOwner, address(rejector), STOCK_CAP, TIN, TOUT
        );
        vm.prank(uAssetOwner);
        uAsset.setReserveMinter(address(psmReject), true);

        vm.prank(alice);
        psmReject.mint{value: 1000e18}(alice, 1000e18); // 1e18 fee retained

        assertEq(psmReject.sweepableFees(), 1e18);

        vm.prank(bob);
        vm.expectRevert(NativeTransferFailed.selector);
        psmReject.sweepFees();

        // The reverted payout is atomic: no native left the PSM and the quote is unchanged.
        assertEq(address(psmReject).balance, 1000e18);
        assertEq(psmReject.sweepableFees(), 1e18);
    }

    /// @notice A native redeem to a recipient that rejects native transfers reverts
    ///         NativeTransferFailed (redeem pays out through the same native call path as
    ///         sweepFees); the whole swap rolls back, so no uAsset is burned and no native leaves.
    function test_RevertIf_RedeemToNativeRejectingRecipient() external {
        vm.prank(alice);
        psmNative.mint{value: 1000e18}(alice, 1000e18);

        NativeRejectingReceiver rejector = new NativeRejectingReceiver();

        vm.prank(alice);
        vm.expectRevert(NativeTransferFailed.selector);
        psmNative.redeem(address(rejector), 999e18);

        // Atomic rollback: balances and the ledger read exactly as before the failed redeem.
        assertEq(address(psmNative).balance, 1000e18);
        assertEq(uAsset.balanceOf(alice), 999e18);
        assertEq(psmNative.netUAssetMinted(), 999e18);
    }

    /// @notice A zero surplus reverts ZeroInput — both on a fresh instance with no fees and after a
    ///         sweep has already drained the surplus.
    function test_RevertWhen_SweepFeesWithZeroSurplus() external {
        assertEq(psm.sweepableFees(), 0);

        vm.prank(alice);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.sweepFees();

        // Accumulate and drain, then the second sweep has nothing left to pay.
        vm.prank(alice);
        psm.mint(alice, 1000e6);
        vm.prank(alice);
        psm.redeem(alice, 999e18);
        vm.prank(bob);
        psm.sweepFees();

        assertEq(psm.sweepableFees(), 0);
        vm.prank(alice);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.sweepFees();
    }

    /// @notice Floor rounding on a 6-dec reserve: a fee surplus whose face value is not a whole
    ///         1e12 multiple sweeps only the whole reserve units; the sub-unit face dust stays in
    ///         the PSM and is not payable (a dust-only surplus reverts ZeroInput).
    function test_SweepFeesFloorToReserveUnitOnSixDecimals() external {
        // amountIn not divisible by 1000: the 0.1% mint fee is amountIn * 1e9 wei of face value,
        // here 1_001_000 units + 7e9 wei of dust.
        uint256 amountIn = 1_001_000_007;
        vm.prank(bob);
        psm.mint(bob, amountIn);

        assertEq(psm.sweepableFees(), 1_001_000);

        vm.prank(alice);
        uint256 swept = psm.sweepFees();

        assertEq(swept, 1_001_000);
        assertEq(usdc.balanceOf(feeRecipient), 1_001_000);
        // The 7e9 wei of face dust stays behind as cover.
        assertEq(usdc.balanceOf(address(psm)), amountIn - 1_001_000);
        // Conservation inequality after the floored sweep.
        assertGe(usdc.balanceOf(address(psm)) * 1e12, psm.netUAssetMinted());

        // The remaining dust floors to zero sweepable units: no hollow payout.
        assertEq(psm.sweepableFees(), 0);
        vm.prank(alice);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.sweepFees();
    }

    function test_MinterLedgerExemptionAndKillSwitch() external {
        vm.prank(alice);
        psm.mint(alice, 100e6);

        // Reserve-path swaps never touch the PSM's minter debt ledger.
        IUniversalAssets.MintingStatus memory status = uAsset.mintingStatusTable(address(psm));
        assertEq(status.mintingCap, 0);
        assertEq(status.amountInMinted, 0);
        assertEq(uAsset.checkMintableAmount(address(psm)), 0);

        // Debt-ledger revocation does not affect the reserve path.
        vm.startPrank(uAssetOwner);
        uAsset.setMintingCap(address(psm), 0);
        uAsset.revokeMinter(address(psm));
        vm.stopPrank();

        vm.startPrank(alice);
        uint256 amountOut = psm.mint(alice, 1e6);
        assertEq(amountOut, 0.999e18);
        uint256 paidOut = psm.redeem(alice, 0.999e18);
        assertEq(paidOut, 998_001);
        vm.stopPrank();

        // Kill switch: revoking the reserve-minter registration blocks both directions, fail-closed.
        vm.prank(uAssetOwner);
        uAsset.setReserveMinter(address(psm), false);

        vm.startPrank(alice);
        vm.expectRevert(IUniversalAssets.NotReserveMinter.selector);
        psm.mint(alice, 1e6);

        vm.expectRevert(IUniversalAssets.NotReserveMinter.selector);
        psm.redeem(alice, 0.999e18);
        vm.stopPrank();
    }

    function test_ZeroOracleQuoteDeterminismAgainstSupplySwapsAndTime() external {
        uint256 quoteUsdcIn = psm.quoteMint(7_654e6);
        uint256 quoteUsdcOut = psm.quoteRedeem(543_210e18);
        assertEq(quoteUsdcIn, (7_654e18 * 999) / 1000);
        assertEq(quoteUsdcOut, (543_210e18 * 999) / 1000 / 1e12);

        // Grow the uAsset supply through an unrelated debt-ledger minter: quotes must ignore it.
        vm.prank(uAssetOwner);
        uAsset.setMintingCap(bob, 1_000_000e18);
        vm.prank(bob);
        uAsset.mint(alice, 25_000e18);

        // Intervening swaps by another party change held reserves and net minted: no quote moves.
        vm.prank(bob);
        psm.mint(bob, 10_000e6);
        vm.prank(bob);
        psmNative.mint{value: 20_000e18}(bob, 20_000e18);
        vm.prank(bob);
        psm.redeem(bob, 5_000e18);

        // Block time and height move: quotes depend on neither.
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 100_000);

        assertEq(psm.quoteMint(7_654e6), quoteUsdcIn);
        assertEq(psm.quoteRedeem(543_210e18), quoteUsdcOut);
    }

    function testFuzz_QuoteMatchesExecutionForBoundedAmounts(uint256 amountIn) external {
        // Native leg: face value is the identity, so the bound covers the fee math only. The lower
        // bound stays above the dust level that would floor to a zero mint after the default 0.1% fee;
        // the upper bound is the full stock cap, keeping the mint inside the cap headroom domain.
        amountIn = bound(amountIn, 1e6, STOCK_CAP);

        vm.startPrank(alice);
        uint256 minted = psmNative.mint{value: amountIn}(alice, amountIn);
        // The execution path and the preview path run the same fee math with no external state input.
        assertEq(minted, psmNative.quoteMint(amountIn));

        uint256 paidOut = psmNative.redeem(alice, minted);
        assertEq(paidOut, psmNative.quoteRedeem(minted));
        vm.stopPrank();
    }

    function test_RedeemOfForeignMintedUAssetSaturatesNetMintedAtZero() external {
        // PSM mints a small amount: netUAssetMinted = X = 999e18 against 1_000e18 of native held.
        vm.prank(alice);
        uint256 mintedOut = psmNative.mint{value: 1_000e18}(alice, 1_000e18);
        assertEq(mintedOut, 999e18);
        assertEq(psmNative.netUAssetMinted(), 999e18);

        // An unrelated debt-ledger minter mints foreign uAsset directly on the uAsset (outside the PSM).
        vm.prank(uAssetOwner);
        uAsset.setMintingCap(bob, 1_000_000e18);
        vm.prank(bob);
        uAsset.mint(alice, 5_000e18);

        // Redeem strictly more than the PSM's own net minted (1_000e18 > 999e18, still within the
        // fee-buffered reserve cover): no underflow panic, payout is the full 1:1 x (1 - tout) math.
        vm.prank(alice);
        uint256 paidOut = psmNative.redeem(alice, 1_000e18);
        assertEq(paidOut, 999e18);
        assertEq(psmNative.netUAssetMinted(), 0);

        // Saturation restored the full stock-cap headroom: with no per-swap flow cap, a single mint
        // fills the whole raised cap — per-swap size is bounded only by the headroom.
        vm.startPrank(psmOwner);
        psmNative.setFees(0, 0);
        psmNative.setStockCap(2_000_000e18);
        vm.stopPrank();

        vm.deal(bob, 2_000_000e18);
        vm.prank(bob);
        uint256 fullMint = psmNative.mint{value: 2_000_000e18}(bob, 2_000_000e18);
        assertEq(fullMint, 2_000_000e18);
        assertEq(psmNative.netUAssetMinted(), 2_000_000e18);
    }

    function test_BindingIsImmutableAndIsolatedAcrossInstances() external {
        assertEq(psm.reserveToken(), address(usdc));
        assertEq(psmNative.reserveToken(), NATIVE);

        // No setter and no registry: the old registry entrypoints have no target and revert.
        (bool setOk,) =
            address(psm).call(abi.encodeWithSelector(bytes4(keccak256("setReserveToken(address,bool)")), NATIVE, true));
        assertFalse(setOk, "setReserveToken must not exist");
        (bool getOk,) =
            address(psm).call(abi.encodeWithSelector(bytes4(keccak256("activeReserveTokens(address)")), NATIVE));
        assertFalse(getOk, "activeReserveTokens must not exist");

        // Ledgers are isolated: a USDC mint moves only the ERC20 instance's net.
        vm.prank(alice);
        psm.mint(alice, 1000e6);
        assertEq(psm.netUAssetMinted(), 999e18);
        assertEq(psmNative.netUAssetMinted(), 0);

        // A native mint moves only the native instance's net.
        vm.prank(alice);
        psmNative.mint{value: 1000e18}(alice, 1000e18);
        assertEq(psmNative.netUAssetMinted(), 999e18);
        assertEq(psm.netUAssetMinted(), 999e18);

        // uAsset is fungible across instances: USDC-minted uAsset redeems for native and frees
        // headroom only on the instance that paid out.
        vm.prank(alice);
        uint256 paidOut = psmNative.redeem(alice, 999e18);
        assertEq(paidOut, 998.001e18);
        assertEq(psmNative.netUAssetMinted(), 0);
        assertEq(psm.netUAssetMinted(), 999e18);
    }

    function test_BoundReserveWithNoCodeFailsClosed() external {
        // The reserve leg is validated at initialization: a codeless reserve reverts the deploy
        // instead of binding an instance whose every swap would revert on the decimals read.
        OutrunPSMUpgradeable implementation = new OutrunPSMUpgradeable();
        address codeless = makeAddr("codeless");
        vm.expectRevert();
        _deploy(implementation, address(uAsset), codeless, psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT);

        // A >18-dec reserve reverts with the decimals mismatch instead of underflowing
        // the face-value scale at swap time.
        PSMMockReserveERC20 wideReserve = new PSMMockReserveERC20("Wide", "WIDE", 19);
        vm.expectRevert(abi.encodeWithSelector(IPSM.UAssetDecimalsMismatch.selector, 18, 19));
        _deploy(implementation, address(uAsset), address(wideReserve), psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT);
    }

    function test_EmitsAllFourEvents() external {
        vm.startPrank(psmOwner);
        vm.expectEmit(false, false, false, true);
        emit IPSM.SetStockCap(1234e18);
        psmNative.setStockCap(1234e18);

        vm.expectEmit(false, false, false, true);
        emit IPSM.SetFees(2e15, 3e15);
        psmNative.setFees(2e15, 3e15);
        vm.stopPrank();

        // tin 0.2% / tout 0.3%: 1000e18 native mints 998e18 (2e18 fee); redeeming that pays 995.006e18.
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IPSM.SwapMintForUAsset(NATIVE, alice, 1000e18, 998e18, 2e18);
        uint256 amountOut = psmNative.mint{value: 1000e18}(alice, 1000e18);
        assertEq(amountOut, 998e18);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IPSM.SwapRedeemForReserve(NATIVE, alice, 998e18, 995_006e15, 998e18 - 995_006e15);
        uint256 paidOut = psmNative.redeem(alice, 998e18);
        assertEq(paidOut, 995_006e15);
    }

    function test_ZeroInputAndZeroOutputGuards() external {
        vm.startPrank(alice);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.mint(address(0), 1e6);

        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.mint(alice, 0);

        vm.expectRevert(IPSM.ZeroInput.selector);
        psmNative.mint{value: 1}(address(0), 1);

        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.redeem(address(0), 1e18);

        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.redeem(alice, 0);
        vm.stopPrank();

        // Zero-output mint: 1 wei of face value under a 1% fee floors to zero minted uAsset.
        vm.prank(psmOwner);
        psmNative.setFees(1e16, 0);

        vm.prank(alice);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psmNative.mint{value: 1}(alice, 1);

        // Zero-output redeem: a uAsset amount whose 6-dec payout floors to zero reserve units.
        vm.prank(psmOwner);
        psmNative.setFees(0, 0);

        vm.prank(alice);
        psmNative.mint{value: 1e18}(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(IPSM.ZeroInput.selector);
        psm.redeem(alice, 12_345);
    }

    function test_UAssetPauseBlocksBothDirections() external {
        vm.prank(alice);
        psmNative.mint{value: 1e18}(alice, 1e18);

        vm.prank(uAssetOwner);
        uAsset.pause();

        vm.startPrank(alice);
        // Both directions revert on the uAsset leg while paused — no partial state survives (the
        // reserve pull and ledger updates roll back with the call).
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        psmNative.mint{value: 1e18}(alice, 1e18);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        psmNative.redeem(alice, 0.999e18);
        vm.stopPrank();

        assertEq(alice.balance, 1_000_000e18 - 1e18);
        assertEq(uAsset.balanceOf(alice), 0.999e18);
    }

    function test_NonOwnerCannotSetParameters() external {
        vm.startPrank(alice);
        bytes4 unauthorized = OwnableUpgradeable.OwnableUnauthorizedAccount.selector;

        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        psm.setFees(0, 0);

        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        psm.setStockCap(1);
        vm.stopPrank();

        // No reserve setter exists for anyone, owner included.
        vm.prank(psmOwner);
        (bool ok,) =
            address(psm).call(abi.encodeWithSelector(bytes4(keccak256("setReserveToken(address,bool)")), NATIVE, true));
        assertFalse(ok, "setReserveToken must not exist");
    }

    /// @notice A malicious bound reserve re-entering mint and redeem from its transferFrom
    ///         callback (the reserve pull leg) is blocked by the transient guard on both nested
    ///         attempts, and the outer mint still completes with exact fee/stock-cap accounting
    ///         and reserve/uAsset conservation.
    function test_ReentrantMintViaMaliciousReservePullIsBlocked() external {
        (ReenteringReserveERC20 evil, OutrunPSMUpgradeable evilPsm) = _deployEvilBoundInstance();

        evil.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        evil.approve(address(evilPsm), type(uint256).max);
        uAsset.approve(address(evilPsm), type(uint256).max);
        evil.arm();
        uint256 amountOut = evilPsm.mint(alice, 1000e6);
        vm.stopPrank();

        assertEq(evil.firstFailure(), evil.NO_FAILURE(), "reentrant entry was not blocked by the guard");
        // Same math as an honest 6-dec mint: 1000e6 face -> 999e18 uAsset, 1e18 fee retained.
        assertEq(amountOut, 999e18);
        assertEq(uAsset.balanceOf(alice), 999e18);
        assertEq(evilPsm.netUAssetMinted(), 999e18);
        assertEq(evil.balanceOf(alice), 999_000e6);
        // Conservation: held reserve face value == net minted uAsset + accumulated fees.
        assertEq(evil.balanceOf(address(evilPsm)) * 1e12, 999e18 + 1e18);
    }

    /// @notice A malicious bound reserve re-entering mint and redeem from its transfer callback
    ///         during the reserve disbursement leg is blocked on both nested attempts, and the
    ///         outer redeem still completes with exact payout and accounting.
    function test_ReentrantRedeemViaMaliciousReservePayoutIsBlocked() external {
        (ReenteringReserveERC20 evil, OutrunPSMUpgradeable evilPsm) = _deployEvilBoundInstance();

        // Honest setup mint (callback disarmed) so the PSM holds reserve cover for the redeem.
        evil.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        evil.approve(address(evilPsm), type(uint256).max);
        uAsset.approve(address(evilPsm), type(uint256).max);
        uint256 minted = evilPsm.mint(alice, 1000e6);
        assertEq(minted, 999e18);

        evil.arm();
        uint256 paidOut = evilPsm.redeem(alice, 999e18);
        vm.stopPrank();

        assertEq(evil.firstFailure(), evil.NO_FAILURE(), "reentrant entry was not blocked by the guard");
        // Same math as an honest redeem: 999e18 face * (1 - 0.1%) floored to 6 decimals.
        assertEq(paidOut, 998_001_000);
        assertEq(evil.balanceOf(alice), 999_000e6 + 998_001_000);
        assertEq(uAsset.balanceOf(alice), 0);
        assertEq(evilPsm.netUAssetMinted(), 0);
        // Conservation: the remaining 1_999_000 units of cover equal the mint fee (1e18) plus
        // the redeem fee (0.999e18) in face value.
        assertEq(evil.balanceOf(address(evilPsm)) * 1e12, 1.999e18);
    }

    /// @dev Deploys a fresh single-reserve instance bound to a malicious reentering reserve, with
    ///      the uAsset-side minter registration in place. The token is created with a placeholder
    ///      target and re-pointed at the instance, breaking the token/instance construction cycle.
    function _deployEvilBoundInstance() internal returns (ReenteringReserveERC20 evil, OutrunPSMUpgradeable evilPsm) {
        evil = new ReenteringReserveERC20(address(0), "Evil Reserve", "EVL", 6);
        evilPsm = _deploy(
            new OutrunPSMUpgradeable(), address(uAsset), address(evil), psmOwner, feeRecipient, STOCK_CAP, TIN, TOUT
        );
        evil.setPsm(address(evilPsm));
        vm.prank(uAssetOwner);
        uAsset.setReserveMinter(address(evilPsm), true);
    }

    function _deploy(
        OutrunPSMUpgradeable implementation,
        address uAsset_,
        address reserve_,
        address owner_,
        address feeRecipient_,
        uint256 stockCap_,
        uint256 tin_,
        uint256 tout_
    ) internal returns (OutrunPSMUpgradeable) {
        return OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(implementation),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize, (uAsset_, reserve_, owner_, feeRecipient_, stockCap_, tin_, tout_)
                )
            )
        );
    }
}
