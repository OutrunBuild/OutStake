// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {OFTReceipt, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {MockLzEndpoint} from "./mocks/OFTMocks.sol";
import {
    MockUAssetUUPSV2,
    MockUAssetUUPSV2DifferentLocalDecimals,
    MockUAssetUUPSV2DifferentSharedDecimals
} from "./mocks/MockUUPSVersion.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";

contract OutrunUniversalAssetsUpgradeableTest is Test {
    OutrunUniversalAssetsUpgradeable internal uAsset;
    MockLzEndpoint internal endpoint;

    address internal owner = address(0xA11CE);
    address internal minter = address(0xB0B);
    address internal otherMinter = address(0xB0B2);
    address internal receiver = address(0xCAFE);

    function setUp() external {
        endpoint = new MockLzEndpoint();
        OutrunUniversalAssetsUpgradeable implementation = new OutrunUniversalAssetsUpgradeable(18, address(endpoint));
        bytes memory initData = abi.encodeCall(
            OutrunUniversalAssetsUpgradeable.initialize, ("Omnichain Universal Assets ETH", "UETH", owner)
        );
        uAsset = OutrunUniversalAssetsUpgradeable(ProxyTestHelper.deploy(address(implementation), initData));
    }

    function testInitializeSetsMetadataAndOwner() external {
        assertEq(uAsset.name(), "Omnichain Universal Assets ETH");
        assertEq(uAsset.symbol(), "UETH");
        assertEq(uAsset.decimals(), 18);
        assertEq(uAsset.owner(), owner);
    }

    function testInitializeRevertsWhenCalledTwice() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        uAsset.initialize("x", "x", owner);
    }

    function testImplementationCannotBeInitializedDirectly() external {
        OutrunUniversalAssetsUpgradeable implementation = new OutrunUniversalAssetsUpgradeable(18, address(endpoint));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize("x", "x", owner);
    }

    function testDecimalsDeriveFromConstructorLocalDecimals() external {
        // Use a non-18 localDecimals so the assertion distinguishes "decimals derived from the
        // constructor-frozen localDecimals()" from a metadata hardcoded to 18.
        OutrunUniversalAssetsUpgradeable dec = new OutrunUniversalAssetsUpgradeable(6, address(endpoint));
        bytes memory initData = abi.encodeCall(OutrunUniversalAssetsUpgradeable.initialize, ("Dec", "DEC", owner));
        dec = OutrunUniversalAssetsUpgradeable(ProxyTestHelper.deploy(address(dec), initData));
        assertEq(dec.decimals(), dec.localDecimals());
        assertEq(dec.decimals(), 6);
    }

    function testOwnerCanUpgradeAndStateSurvives() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, 100e18);

        // Seed real state in every storage namespace that must survive an upgrade (ERC20
        // balances/totalSupply, rate-limiter ledger, pause) so the post-upgrade reads prove the
        // new implementation still reads the same storage. Mint precedes pause: mint is whenNotPaused.
        vm.prank(minter);
        uAsset.mint(receiver, 40e18);
        vm.prank(owner);
        uAsset.setOutboundRateLimit(101, 10e18, 1 days);
        vm.prank(owner);
        uAsset.pause();

        uint256 amountReceivedBefore = _quoteAmountReceived(1e18);
        MockUAssetUUPSV2 implementationV2 = new MockUAssetUUPSV2(18, address(endpoint));
        vm.prank(owner);
        uAsset.upgradeToAndCall(address(implementationV2), "");

        // Minter ledger survives: checkMintableAmount is 60e18 = 100e18 cap − 40e18 minted
        // debt, so both the cap and the debt persisted across the upgrade.
        assertEq(uAsset.checkMintableAmount(minter), 60e18);
        assertEq(uAsset.owner(), owner);
        assertEq(MockUAssetUUPSV2(address(uAsset)).version(), 2);
        assertEq(_quoteAmountReceived(1e18), amountReceivedBefore);

        // ERC20 state, rate-limiter ledger, pause, and metadata survive the upgrade.
        assertEq(uAsset.balanceOf(receiver), 40e18);
        assertEq(uAsset.totalSupply(), 40e18);
        (, uint256 amountCanBeSent) = uAsset.getAmountCanBeSent(101);
        assertEq(amountCanBeSent, 10e18);
        assertTrue(uAsset.paused());
        assertEq(uAsset.name(), "Omnichain Universal Assets ETH");
        assertEq(uAsset.symbol(), "UETH");
        assertEq(uAsset.decimals(), 18);
    }

    function testNonOwnerCannotUpgrade() external {
        OutrunUniversalAssetsUpgradeable implementationV2 = new OutrunUniversalAssetsUpgradeable(18, address(endpoint));
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, minter));
        uAsset.upgradeToAndCall(address(implementationV2), "");
    }

    function testOwnerCannotUpgradeToDifferentEndpoint() external {
        MockLzEndpoint otherEndpoint = new MockLzEndpoint();
        MockUAssetUUPSV2 implementationV2 = new MockUAssetUUPSV2(18, address(otherEndpoint));

        vm.prank(owner);
        vm.expectRevert(OutrunUniversalAssetsUpgradeable.InvalidOFTUpgradeConfig.selector);
        uAsset.upgradeToAndCall(address(implementationV2), "");
    }

    function testOwnerCannotUpgradeToDifferentLocalDecimals() external {
        MockUAssetUUPSV2 implementationV2 = new MockUAssetUUPSV2(6, address(endpoint));

        vm.prank(owner);
        vm.expectRevert(OutrunUniversalAssetsUpgradeable.InvalidOFTUpgradeConfig.selector);
        uAsset.upgradeToAndCall(address(implementationV2), "");
    }

    function testOwnerCannotUpgradeToDifferentLocalDecimalsWithSameOtherOFTConfig() external {
        MockUAssetUUPSV2DifferentLocalDecimals implementationV2 =
            new MockUAssetUUPSV2DifferentLocalDecimals(19, address(endpoint));

        assertEq(address(implementationV2.endpoint()), address(endpoint));
        assertEq(implementationV2.decimalConversionRate(), uAsset.decimalConversionRate());
        assertTrue(implementationV2.localDecimals() != uAsset.localDecimals());

        vm.prank(owner);
        vm.expectRevert(OutrunUniversalAssetsUpgradeable.InvalidOFTUpgradeConfig.selector);
        uAsset.upgradeToAndCall(address(implementationV2), "");
    }

    function testOwnerCannotUpgradeToDifferentDecimalConversionRate() external {
        MockUAssetUUPSV2DifferentSharedDecimals implementationV2 =
            new MockUAssetUUPSV2DifferentSharedDecimals(18, address(endpoint));

        vm.prank(owner);
        vm.expectRevert(OutrunUniversalAssetsUpgradeable.InvalidOFTUpgradeConfig.selector);
        uAsset.upgradeToAndCall(address(implementationV2), "");
    }

    function testMintRepayAndMintCapThroughProxy() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, 100e18);

        vm.prank(minter);
        uAsset.mint(receiver, 40e18);

        vm.prank(receiver);
        uAsset.approve(minter, 15e18);

        vm.prank(minter);
        uAsset.repay(receiver, 15e18);

        assertEq(uAsset.balanceOf(receiver), 25e18);
        assertEq(uAsset.totalSupply(), 25e18);
        assertEq(uAsset.checkMintableAmount(minter), 75e18);
    }

    function testMintNearUint256BoundaryRevertsWithReachMintCap() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, type(uint256).max);

        vm.prank(minter);
        uAsset.mint(receiver, type(uint256).max - 1);

        vm.prank(minter);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        uAsset.mint(receiver, 2);
    }

    function testRevokeKeepsDebtClearsCapBlocksMintAndAllowsRepay() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, 100e18);

        vm.prank(minter);
        uAsset.mint(receiver, 40e18);

        vm.prank(owner);
        uAsset.revokeMinter(minter);

        IUniversalAssets.MintingStatus memory status = uAsset.mintingStatusTable(minter);
        assertEq(status.mintingCap, 0);
        assertEq(status.amountInMinted, 40e18);
        assertEq(uAsset.checkMintableAmount(minter), 0);

        vm.prank(minter);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        uAsset.mint(receiver, 1);

        vm.prank(receiver);
        uAsset.approve(minter, 10e18);

        vm.prank(minter);
        uAsset.repay(receiver, 10e18);

        status = uAsset.mintingStatusTable(minter);
        assertEq(status.amountInMinted, 30e18);
        assertEq(uAsset.balanceOf(receiver), 30e18);
        assertEq(uAsset.totalSupply(), 30e18);
    }

    function testRepayRejectsZeroAmount() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, 100e18);

        vm.prank(minter);
        uAsset.mint(receiver, 40e18);

        IUniversalAssets.MintingStatus memory statusBefore = uAsset.mintingStatusTable(minter);
        uint256 balanceBefore = uAsset.balanceOf(receiver);
        uint256 totalSupplyBefore = uAsset.totalSupply();

        vm.prank(minter);
        vm.expectRevert(IUniversalAssets.ZeroInput.selector);
        uAsset.repay(receiver, 0);

        IUniversalAssets.MintingStatus memory statusAfter = uAsset.mintingStatusTable(minter);
        assertEq(statusAfter.mintingCap, statusBefore.mintingCap);
        assertEq(statusAfter.amountInMinted, statusBefore.amountInMinted);
        assertEq(uAsset.balanceOf(receiver), balanceBefore);
        assertEq(uAsset.totalSupply(), totalSupplyBefore);
    }

    function testOwnerCanTransferMinterDebtWithoutChangingSupplyOrBalances() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, 100e18);
        vm.prank(owner);
        uAsset.setMintingCap(otherMinter, 50e18);

        vm.prank(minter);
        uAsset.mint(receiver, 60e18);

        uint256 totalSupplyBefore = uAsset.totalSupply();
        uint256 receiverBalanceBefore = uAsset.balanceOf(receiver);
        uint256 minterBalanceBefore = uAsset.balanceOf(minter);
        uint256 otherMinterBalanceBefore = uAsset.balanceOf(otherMinter);

        vm.prank(owner);
        uAsset.transferMinterDebt(minter, otherMinter, 25e18);

        IUniversalAssets.MintingStatus memory fromStatus = uAsset.mintingStatusTable(minter);
        IUniversalAssets.MintingStatus memory toStatus = uAsset.mintingStatusTable(otherMinter);
        assertEq(fromStatus.amountInMinted, 35e18);
        assertEq(toStatus.amountInMinted, 25e18);
        assertEq(fromStatus.mintingCap, 100e18);
        assertEq(toStatus.mintingCap, 50e18);
        assertEq(uAsset.totalSupply(), totalSupplyBefore);
        assertEq(uAsset.balanceOf(receiver), receiverBalanceBefore);
        assertEq(uAsset.balanceOf(minter), minterBalanceBefore);
        assertEq(uAsset.balanceOf(otherMinter), otherMinterBalanceBefore);
    }

    function testTransferMinterDebtRejectsInvalidInputsAndCapOverflow() external {
        vm.startPrank(owner);
        uAsset.setMintingCap(minter, 100e18);
        uAsset.setMintingCap(otherMinter, 20e18);
        vm.stopPrank();

        vm.prank(minter);
        uAsset.mint(receiver, 60e18);

        vm.startPrank(owner);
        vm.expectRevert(IUniversalAssets.InvalidTransferParams.selector);
        uAsset.transferMinterDebt(address(0), otherMinter, 1);

        vm.expectRevert(IUniversalAssets.InvalidTransferParams.selector);
        uAsset.transferMinterDebt(minter, address(0), 1);

        vm.expectRevert(IUniversalAssets.InvalidTransferParams.selector);
        uAsset.transferMinterDebt(minter, otherMinter, 0);

        vm.expectRevert(IUniversalAssets.ReachBurnCap.selector);
        uAsset.transferMinterDebt(minter, otherMinter, 61e18);

        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        uAsset.transferMinterDebt(minter, otherMinter, 21e18);
        vm.stopPrank();
    }

    function testTransferMinterDebtRejectsSameAddressWithoutChangingState() external {
        vm.prank(owner);
        uAsset.setMintingCap(minter, 100e18);

        vm.prank(minter);
        uAsset.mint(receiver, 40e18);

        uint256 totalSupplyBefore = uAsset.totalSupply();
        uint256 receiverBalanceBefore = uAsset.balanceOf(receiver);

        vm.prank(owner);
        vm.expectRevert(IUniversalAssets.InvalidTransferParams.selector);
        uAsset.transferMinterDebt(minter, minter, 10e18);

        IUniversalAssets.MintingStatus memory status = uAsset.mintingStatusTable(minter);
        assertEq(status.mintingCap, 100e18);
        assertEq(status.amountInMinted, 40e18);
        assertEq(uAsset.totalSupply(), totalSupplyBefore);
        assertEq(uAsset.balanceOf(receiver), receiverBalanceBefore);
    }

    function testNonOwnerCannotTransferMinterDebt() external {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, minter));
        uAsset.transferMinterDebt(minter, otherMinter, 1);
    }

    function testOutboundRateLimitThroughProxy() external {
        vm.prank(owner);
        uAsset.setOutboundRateLimit(101, 10e18, 1 days);

        (, uint256 amountCanBeSent) = uAsset.getAmountCanBeSent(101);
        assertEq(amountCanBeSent, 10e18);
    }

    function testUnconfiguredPeerQuoteNotLocallyBlocked() external {
        SendParam memory sendParam = SendParam({
            dstEid: 101,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: 1e18,
            minAmountLD: 0,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        (,, uint256 amountReceivedLD) = _quoteReceipt(sendParam);
        assertEq(amountReceivedLD, 1e18);
    }

    function _quoteReceipt(SendParam memory sendParam) internal view returns (uint256, uint256, uint256) {
        (,, OFTReceipt memory receipt) = uAsset.quoteOFT(sendParam);
        return (0, receipt.amountSentLD, receipt.amountReceivedLD);
    }

    function _quoteAmountReceived(uint256 amount) internal view returns (uint256) {
        SendParam memory sendParam = SendParam({
            dstEid: 101,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        (,, uint256 amountReceivedLD) = _quoteReceipt(sendParam);
        return amountReceivedLD;
    }
}
