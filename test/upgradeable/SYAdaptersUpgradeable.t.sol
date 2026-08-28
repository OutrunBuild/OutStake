// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunAaveV3SYUpgradeable} from "../../src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol";
import {OutrunWeETHSYUpgradeable} from "../../src/yield/adapters/etherfi/OutrunWeETHSYUpgradeable.sol";
import {OutrunWstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol";
import {OutrunL2WstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunL2WstETHSYUpgradeable.sol";
import {
    OutrunL2WrappableWstETHSYUpgradeable
} from "../../src/yield/adapters/lido/OutrunL2WrappableWstETHSYUpgradeable.sol";
import {OutrunStakedUSDeSYUpgradeable} from "../../src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol";
import {OutrunStakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunStakedUsdsSYUpgradeable.sol";
import {OutrunL2StakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol";
import {OutrunSlisBNBSYUpgradeable} from "../../src/yield/adapters/lista/OutrunSlisBNBSYUpgradeable.sol";
import {OutrunAsBNBSYUpgradeable} from "../../src/yield/adapters/aster/OutrunAsBNBSYUpgradeable.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {
    ScaledAmountIsZero,
    MockToken,
    MockAToken,
    MockAavePool,
    MockOracle,
    MockLiquidityPool,
    MockWeETH,
    MockStETH,
    MockWstETH,
    MockL2StETH,
    MockVault,
    MockPSM3,
    MockListaStakeManager,
    MockYieldProxy,
    MockAsBnbMinter,
    MockDepositAdapter
} from "./mocks/SYAdapterMocks.sol";
import {MockLzEndpoint} from "./mocks/OFTMocks.sol";

contract SYAdaptersUpgradeableTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal constant NATIVE = address(0);
    uint256 internal constant AMOUNT = 10 ether;
    MockToken internal token;
    MockOracle internal oracle;

    function setUp() external {
        token = new MockToken("Token", "TKN", 18);
        oracle = new MockOracle(1.2e18);
    }

    function testAllAdaptersInitializeBehindProxy() external {
        _assertSY(_deployL2Staked(), "SY Generic", "SYG", address(token));

        (address aave,, MockAToken aToken) = _deployAave(1e27);
        _assertSY(aave, "SY Aave", "SYA", address(aToken));

        _assertSY(_deployWeETH(), "SY Etherfi weETH", "SY weETH", address(token));
        _assertSY(_deployWstETH(), "SY Lido wstETH", "SY wstETH", address(token));
        _assertSY(_deployL2WstETH(), "SY Lido wstETH", "SY wstETH", address(token));
        _assertSY(_deployL2WrappableWstETH(), "SY Lido wstETH", "SY wstETH", address(token));
        _assertSY(_deployEthena(), "SY Ethena sUSDe", "SY sUSDe", address(token));
        _assertSY(_deploySky(), "SY Sky sUSDS", "SY sUSDS", address(token));
        _assertSY(_deploySkyL2(), "SY Sky sUSDS", "SY sUSDS", address(token));
        _assertSY(_deployLista(), "SY Lista slisBNB", "SY slisBNB", address(token));
        _assertSY(_deployAster(), "SY Aster asBNB", "SY asBNB", address(token));
    }

    function testWstETHInitializerRevertsWhenWstETHIsZero() external {
        OutrunWstETHSYUpgradeable impl = new OutrunWstETHSYUpgradeable();
        MockToken stETH = new MockToken("stETH", "stETH", 18);

        vm.expectRevert(IStandardizedYield.SYZeroAddress.selector);
        ProxyTestHelper.deploy(
            address(impl), abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(0)))
        );
    }

    function testListaInitializerRevertsWhenStakeManagerRateBelowParity() external {
        OutrunSlisBNBSYUpgradeable impl = new OutrunSlisBNBSYUpgradeable();
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        stakeManager.setRate(1e18 - 1);

        vm.expectRevert(OutrunSlisBNBSYUpgradeable.InvalidStakeManager.selector);
        ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(OutrunSlisBNBSYUpgradeable.initialize, (owner, address(token), address(stakeManager)))
        );
    }

    function testL2WrappableWstETHStoresUnderlyingImmediatelyAfterStETH() external {
        MockToken stETH = new MockToken("stETH", "stETH", 18);
        MockToken wstETH = new MockToken("wstETH", "wstETH", 18);
        MockToken underlyingOnEth = new MockToken("ETH", "ETH", 18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeCall(
                OutrunL2WrappableWstETHSYUpgradeable.initialize,
                (owner, address(stETH), address(wstETH), address(underlyingOnEth), 18)
            )
        );

        bytes32 storageSlot = _erc7201("outrun.storage.OutrunL2WrappableWstETHSY");

        assertEq(_storedAddress(sy, storageSlot), address(stETH));
        assertEq(_storedAddress(sy, bytes32(uint256(storageSlot) + 1)), address(underlyingOnEth));

        // Raw storage pins the ERC-7201 layout; the getter pins assetInfo()'s tuple assembly, which the
        // skipped Optimism fork setUp cannot cover.
        (, address assetAddress,) = _asSY(sy).assetInfo();
        assertEq(assetAddress, address(underlyingOnEth));
    }

    function testAaveATokenRoundtripMatchesPreviewAndExchangeRate() external {
        (address sy,, MockAToken aToken) = _deployAave(1e27);

        _assertYieldTokenRoundtrip(sy, aToken, AMOUNT);
        assertEq(_asSY(sy).exchangeRate(), 1e18);
    }

    function testAaveUnderlyingDepositMatchesAaveRayDivScaledDelta() external {
        uint256 amount = 3;
        (address sy, MockToken underlying, MockAToken aToken) = _deployAave(2e27);

        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(sy, amount);
        uint256 scaledBefore = aToken.scaledBalanceOf(sy);
        uint256 previewShares = _asSY(sy).previewDeposit(address(underlying), amount);
        uint256 sharesOut = _asSY(sy).deposit(user, address(underlying), amount, 0);
        uint256 scaledDelta = aToken.scaledBalanceOf(sy) - scaledBefore;
        vm.stopPrank();

        // Underlying preview uses floor (calcSharesFromAssetDown) while execution uses half-up rayDiv;
        // for 3 @ 2e27 the conservative preview is 1, execution 2 (1 wei under-quote, see OutrunAaveV3SYUpgradeable).
        assertEq(previewShares, 1);
        assertEq(sharesOut, 2);
        assertEq(scaledDelta, 2);
        assertGe(sharesOut, previewShares);
        assertLe(sharesOut, previewShares + 1);
    }

    function testAaveATokenDepositUsesAaveRayDivRounding() external {
        uint256 amount = 3;
        (address sy,, MockAToken aToken) = _deployAave(2e27);

        aToken.mintScaled(user, amount);
        vm.startPrank(user);
        aToken.approve(sy, amount);
        uint256 scaledBefore = aToken.scaledBalanceOf(sy);
        uint256 previewShares = _asSY(sy).previewDeposit(address(aToken), amount);
        uint256 sharesOut = _asSY(sy).deposit(user, address(aToken), amount, 0);
        uint256 scaledDelta = aToken.scaledBalanceOf(sy) - scaledBefore;
        vm.stopPrank();

        assertEq(previewShares, 2);
        assertEq(sharesOut, 2);
        assertEq(sharesOut, scaledDelta);
    }

    function testAaveUnderlyingDepositPropagatesPoolZeroScaledAmountRevert() external {
        uint256 amount = 1;
        (address sy, MockToken underlying,) = _deployAave(3e27);

        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(sy, amount);
        // The pool's zero-scaled-amount guard is the deepest observable revert on this path;
        // the adapter's own zero-shares guard is covered by the aToken-branch test below.
        vm.expectRevert(ScaledAmountIsZero.selector);
        _asSY(sy).deposit(user, address(underlying), amount, 0);
        vm.stopPrank();
    }

    function testAaveATokenDepositThatRoundsToZeroReverts() external {
        (address sy,, MockAToken aToken) = _deployAave(3e27);

        aToken.mint(user, 1);
        vm.startPrank(user);
        aToken.approve(sy, 1);
        // 1 wei aToken at a 3e27 liquidity index scales to zero shares; the adapter's own
        // zero-shares guard fires before any minSharesOut check.
        vm.expectRevert(OutrunAaveV3SYUpgradeable.AaveZeroShares.selector);
        _asSY(sy).deposit(user, address(aToken), 1, 0);
        vm.stopPrank();
    }

    function testAdapterMatrixTokensPreviewExchangeRateAndInvalidTokenReverts() external {
        (address aave, MockToken underlying, MockAToken aToken) = _deployAave(1e27);
        _assertAdapterMatrix(
            aave, _tokens(address(underlying), address(aToken)), _tokens(address(underlying), address(aToken))
        );

        MockToken eETH = new MockToken("eETH", "eETH", 18);
        address weETH = _deployWeETHWith(eETH);
        _assertAdapterMatrix(
            weETH, _tokens(NATIVE, address(eETH), address(token)), _tokens(address(eETH), address(token))
        );

        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        address lido = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );
        _assertAdapterMatrix(
            lido, _tokens(address(wstETH), NATIVE, address(stETH)), _tokens(address(wstETH), address(stETH))
        );

        _assertAdapterMatrix(_deployL2WstETH(), _tokens(address(token)), _tokens(address(token)));

        MockToken l2WstEth = new MockToken("wstETH", "wstETH", 18);
        MockL2StETH l2StEth = new MockL2StETH(address(l2WstEth), 2 ether);
        address l2Wrappable = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeWithSelector(
                OutrunL2WrappableWstETHSYUpgradeable.initialize.selector,
                owner,
                address(l2StEth),
                address(l2WstEth),
                address(l2StEth),
                18
            )
        );
        _assertAdapterMatrix(
            l2Wrappable, _tokens(address(l2StEth), address(l2WstEth)), _tokens(address(l2StEth), address(l2WstEth))
        );

        MockToken usde = new MockToken("USDe", "USDe", 18);
        MockVault sUSDe = new MockVault(address(usde));
        address ethena = ProxyTestHelper.deploy(
            address(new OutrunStakedUSDeSYUpgradeable()),
            abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, address(usde), address(sUSDe)))
        );
        _assertAdapterMatrix(ethena, _tokens(address(sUSDe), address(usde)), _tokens(address(sUSDe)));

        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockVault sUSDS = new MockVault(address(usds));
        address sky = ProxyTestHelper.deploy(
            address(new OutrunStakedUsdsSYUpgradeable()),
            abi.encodeCall(OutrunStakedUsdsSYUpgradeable.initialize, (owner, address(usds), address(sUSDS)))
        );
        _assertAdapterMatrix(sky, _tokens(address(sUSDS), address(usds)), _tokens(address(sUSDS), address(usds)));

        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken l2Usds = new MockToken("USDS", "USDS", 18);
        MockToken l2sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        address skyL2 = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usdc), address(l2Usds), address(l2sUSDS), address(new MockPSM3()))
            )
        );
        _assertAdapterMatrix(
            skyL2,
            _tokens(address(usdc), address(l2Usds), address(l2sUSDS)),
            _tokens(address(usdc), address(l2Usds), address(l2sUSDS))
        );

        _assertAdapterMatrix(_deployLista(), _tokens(NATIVE, address(token)), _tokens(address(token)));

        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockToken slis = new MockToken("slisBNB", "slisBNB", 18);
        MockAsBnbMinter minter = new MockAsBnbMinter(address(token), address(slis), address(yieldProxy));
        address aster = ProxyTestHelper.deploy(
            address(new OutrunAsBNBSYUpgradeable()),
            abi.encodeCall(OutrunAsBNBSYUpgradeable.initialize, (owner, address(token), address(slis), address(minter)))
        );
        _assertAdapterMatrix(aster, _tokens(NATIVE, address(slis), address(token)), _tokens(address(token)));

        _assertAdapterMatrix(_deployL2Staked(), _tokens(address(token)), _tokens(address(token)));
    }

    function testL2StakedRedeemTransfersRequestedTokenOut() external {
        address sy = _deployL2Staked();

        // Give user SY shares via deposit so public redeem() can burn them.
        token.mint(user, AMOUNT);
        vm.startPrank(user);
        token.approve(sy, AMOUNT);
        _asSY(sy).deposit(user, address(token), AMOUNT, 0);

        // Redeem via public interface; tokenOut is the yieldBearingToken.
        uint256 redeemed = _asSY(sy).redeem(user, AMOUNT, address(token), 0, false);
        vm.stopPrank();

        assertEq(redeemed, AMOUNT);
        assertEq(token.balanceOf(user), AMOUNT);
    }

    function testWeEtheEthRoundtripMatchesPreviewAndExchangeRate() external {
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        MockWeETH weETH = new MockWeETH(address(eETH));
        MockLiquidityPool pool = new MockLiquidityPool();
        // Non-identity rate so the preview path (LiquidityPool.sharesForAmount) and the execution
        // path (weETH.wrap) are no longer tautologically equal.
        uint256 rate = 1.25e18;
        weETH.setShareRate(rate);
        pool.setShareRate(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(new MockDepositAdapter()), address(pool))
            )
        );

        uint256 expectedShares = AMOUNT * 1e18 / rate;
        eETH.mint(user, AMOUNT);
        vm.startPrank(user);
        eETH.approve(sy, AMOUNT);
        uint256 previewShares = _asSY(sy).previewDeposit(address(eETH), AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit(user, address(eETH), AMOUNT, 0);
        uint256 previewOut = _asSY(sy).previewRedeem(address(eETH), sharesOut);
        uint256 redeemed = _asSY(sy).redeem(user, sharesOut, address(eETH), 0, false);
        vm.stopPrank();

        assertEq(previewShares, expectedShares);
        assertEq(sharesOut, expectedShares);
        assertEq(sharesOut, previewShares);
        assertEq(previewOut, AMOUNT);
        assertEq(redeemed, previewOut);
        assertEq(redeemed, AMOUNT);
        assertEq(eETH.balanceOf(user), AMOUNT);
        assertEq(weETH.balanceOf(sy), 0);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    function testWstEthStEthRoundtripMatchesPreviewAndExchangeRate() external {
        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        // Non-identity rate (1.25 stETH per wstETH): the preview path (getSharesByPooledEth) and the
        // execution path (wrap) now traverse genuinely different arithmetic, so preview == actual is
        // no longer tautological.
        uint256 rate = 1.25e18;
        stETH.setPooledEthPerShare(rate);
        wstETH.setStEthPerToken(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );

        uint256 expectedShares = AMOUNT * 1e18 / rate;
        stETH.mint(user, AMOUNT);
        vm.startPrank(user);
        stETH.approve(sy, AMOUNT);
        uint256 previewShares = _asSY(sy).previewDeposit(address(stETH), AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit(user, address(stETH), AMOUNT, 0);
        uint256 previewOut = _asSY(sy).previewRedeem(address(stETH), sharesOut);
        uint256 redeemed = _asSY(sy).redeem(user, sharesOut, address(stETH), 0, false);
        vm.stopPrank();

        assertEq(previewShares, expectedShares);
        assertEq(sharesOut, expectedShares);
        assertEq(sharesOut, previewShares);
        assertEq(previewOut, AMOUNT);
        assertEq(redeemed, previewOut);
        assertEq(redeemed, AMOUNT);
        assertEq(stETH.balanceOf(user), AMOUNT);
        assertEq(wstETH.balanceOf(sy), 0);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    function testWstEthNativeDepositAndRedeemMatchesPreviewAtNonIdentityRate() external {
        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        // Non-identity rate (1.25 stETH per wstETH): the native path (submit -> getPooledEthByShares
        // -> wrap) traverses genuinely different arithmetic than the getSharesByPooledEth preview.
        uint256 rate = 1.25e18;
        stETH.setPooledEthPerShare(rate);
        wstETH.setStEthPerToken(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );

        // 10 ether divides evenly by 1.25, so the share amount and the stETH roundtrip are exact.
        uint256 expectedShares = AMOUNT * 1e18 / rate;
        uint256 expectedPreview = expectedShares * 9950 / 10000;
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        // The wrap step leaves the SY holding the wstETH backing for the minted shares.
        assertEq(wstETH.balanceOf(sy), sharesOut);
        uint256 previewOut = _asSY(sy).previewRedeem(address(stETH), sharesOut);
        uint256 redeemed = _asSY(sy).redeem(user, sharesOut, address(stETH), 0, false);
        vm.stopPrank();

        assertEq(previewShares, expectedPreview);
        assertEq(sharesOut, expectedShares);
        assertEq(previewShares, expectedShares * 9950 / 10000);
        assertEq(previewOut, AMOUNT);
        assertEq(redeemed, previewOut);
        assertEq(redeemed, AMOUNT);
        assertEq(stETH.balanceOf(user), AMOUNT);
        assertEq(wstETH.balanceOf(sy), 0);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    function testWeEtheEthDepositPinsFloorRounding() external {
        uint256 amount = 5;
        uint256 rate = 2e18;
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        MockWeETH weETH = new MockWeETH(address(eETH));
        MockLiquidityPool pool = new MockLiquidityPool();
        weETH.setShareRate(rate);
        pool.setShareRate(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(new MockDepositAdapter()), address(pool))
            )
        );

        eETH.mint(user, amount);
        vm.startPrank(user);
        eETH.approve(sy, amount);
        uint256 previewShares = _asSY(sy).previewDeposit(address(eETH), amount);
        uint256 sharesOut = _asSY(sy).deposit(user, address(eETH), amount, 0);
        vm.stopPrank();

        // 5 / 2 rounds down to 2; a ceil implementation would return 3.
        assertEq(previewShares, 2);
        assertEq(sharesOut, 2);
        assertEq(weETH.balanceOf(sy), 2);
    }

    function testWstEthStEthDepositPinsFloorRounding() external {
        uint256 amount = 5;
        uint256 rate = 2e18;
        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        stETH.setPooledEthPerShare(rate);
        wstETH.setStEthPerToken(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );

        stETH.mint(user, amount);
        vm.startPrank(user);
        stETH.approve(sy, amount);
        uint256 previewShares = _asSY(sy).previewDeposit(address(stETH), amount);
        uint256 sharesOut = _asSY(sy).deposit(user, address(stETH), amount, 0);
        vm.stopPrank();

        // 5 / 2 rounds down to 2; a ceil implementation would return 3.
        assertEq(previewShares, 2);
        assertEq(sharesOut, 2);
        assertEq(wstETH.balanceOf(sy), 2);
    }

    function testMockL2StEthUsesShareBalancesForTransfersAndTokenAllowances() external {
        MockToken l2WstEth = new MockToken("wstETH", "wstETH", 18);
        MockL2StETH l2StEth = new MockL2StETH(address(l2WstEth), 2 ether);
        address receiver = address(0xCAFE);
        address spender = address(0xD00D);

        l2StEth.mint(user, 5 ether);
        assertEq(l2StEth.balanceOf(user), 10 ether);

        vm.prank(user);
        l2StEth.transfer(receiver, 4 ether);
        assertEq(l2StEth.balanceOf(user), 6 ether);
        assertEq(l2StEth.balanceOf(receiver), 4 ether);

        vm.prank(receiver);
        l2StEth.approve(spender, 2 ether);
        vm.prank(spender);
        l2StEth.transferFrom(receiver, user, 2 ether);

        assertEq(l2StEth.allowance(receiver, spender), 0);
        assertEq(l2StEth.balanceOf(user), 8 ether);
        assertEq(l2StEth.balanceOf(receiver), 2 ether);
    }

    function testVaultBackedAdaptersUseDepositRedeemAndExchangeRate() external {
        // Non-identity vault/PSM rates so deposit preview and execution are no longer tautological.
        uint256 rate = 1.25e18;
        uint256 expectedShares = AMOUNT * 1e18 / rate;

        MockToken usde = new MockToken("USDe", "USDe", 18);
        MockVault sUSDe = new MockVault(address(usde));
        sUSDe.setAssetsPerShare(rate);
        address ethena = ProxyTestHelper.deploy(
            address(new OutrunStakedUSDeSYUpgradeable()),
            abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, address(usde), address(sUSDe)))
        );

        usde.mint(user, AMOUNT);
        vm.startPrank(user);
        usde.approve(ethena, AMOUNT);
        uint256 ethenaPreviewShares = _asSY(ethena).previewDeposit(address(usde), AMOUNT);
        uint256 ethenaShares = _asSY(ethena).deposit(user, address(usde), AMOUNT, 0);
        // The vault really pulled the deposited USDe (ERC-4626 deposit semantics), so the minted
        // sUSDe shares are backed by vault-held assets.
        assertEq(usde.balanceOf(address(sUSDe)), AMOUNT);
        assertEq(sUSDe.balanceOf(ethena), expectedShares);
        uint256 ethenaPreviewOut = _asSY(ethena).previewRedeem(address(sUSDe), ethenaShares);
        uint256 ethenaRedeemed = _asSY(ethena).redeem(user, ethenaShares, address(sUSDe), 0, false);
        vm.stopPrank();

        assertEq(ethenaPreviewShares, expectedShares);
        assertEq(ethenaShares, expectedShares);
        assertEq(ethenaShares, ethenaPreviewShares);
        assertEq(ethenaPreviewOut, expectedShares);
        assertEq(ethenaRedeemed, ethenaPreviewOut);
        assertEq(_asSY(ethena).exchangeRate(), rate);

        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockVault sUSDS = new MockVault(address(usds));
        sUSDS.setAssetsPerShare(rate);
        address sky = ProxyTestHelper.deploy(
            address(new OutrunStakedUsdsSYUpgradeable()),
            abi.encodeCall(OutrunStakedUsdsSYUpgradeable.initialize, (owner, address(usds), address(sUSDS)))
        );

        usds.mint(user, AMOUNT);
        vm.startPrank(user);
        usds.approve(sky, AMOUNT);
        uint256 skyPreviewShares = _asSY(sky).previewDeposit(address(usds), AMOUNT);
        uint256 skyShares = _asSY(sky).deposit(user, address(usds), AMOUNT, 0);
        // Same vault-pull check for Sky: the sUSDS vault now holds the deposited USDS.
        assertEq(usds.balanceOf(address(sUSDS)), AMOUNT);
        assertEq(sUSDS.balanceOf(sky), expectedShares);
        uint256 skyPreviewOut = _asSY(sky).previewRedeem(address(usds), skyShares);
        uint256 skyRedeemed = _asSY(sky).redeem(user, skyShares, address(usds), 0, false);
        vm.stopPrank();

        assertEq(skyPreviewShares, expectedShares);
        assertEq(skyShares, expectedShares);
        assertEq(skyShares, skyPreviewShares);
        assertEq(skyPreviewOut, AMOUNT);
        assertEq(skyRedeemed, skyPreviewOut);
        assertEq(skyRedeemed, AMOUNT);
        assertEq(usds.balanceOf(user), AMOUNT);
        // Redeeming to USDS exits the vault, which transfers its entire USDS backing back out.
        assertEq(usds.balanceOf(address(sUSDS)), 0);
        assertEq(_asSY(sky).exchangeRate(), rate);

        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken l2Usds = new MockToken("USDS", "USDS", 18);
        MockToken l2sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        MockPSM3 psm = new MockPSM3();
        // sUSDS is the appreciating share token; USDC/USDS swap into it at the configured rate.
        psm.setRate(address(l2sUSDS), rate);
        address skyL2 = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usdc), address(l2Usds), address(l2sUSDS), address(psm))
            )
        );

        usdc.mint(user, AMOUNT);
        vm.startPrank(user);
        usdc.approve(skyL2, AMOUNT);
        uint256 skyL2PreviewShares = _asSY(skyL2).previewDeposit(address(usdc), AMOUNT);
        uint256 skyL2Shares = _asSY(skyL2).deposit(user, address(usdc), AMOUNT, 0);
        uint256 skyL2PreviewOut = _asSY(skyL2).previewRedeem(address(l2Usds), skyL2Shares);
        uint256 skyL2Redeemed = _asSY(skyL2).redeem(user, skyL2Shares, address(l2Usds), 0, false);
        vm.stopPrank();

        assertEq(skyL2PreviewShares, expectedShares);
        assertEq(skyL2Shares, expectedShares);
        assertEq(skyL2Shares, skyL2PreviewShares);
        assertEq(skyL2PreviewOut, AMOUNT);
        assertEq(skyL2Redeemed, skyL2PreviewOut);
        assertEq(skyL2Redeemed, AMOUNT);
        assertEq(l2Usds.balanceOf(user), AMOUNT);
        assertEq(_asSY(skyL2).exchangeRate(), rate);
    }

    function testSkyL2PsmUsdsDepositPinsFloorRounding() external {
        uint256 amount = 5;
        uint256 rate = 2e18;
        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockToken sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        MockPSM3 psm = new MockPSM3();
        psm.setRate(address(sUSDS), rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usds), address(usds), address(sUSDS), address(psm))
            )
        );

        usds.mint(user, amount);
        vm.startPrank(user);
        usds.approve(sy, amount);
        uint256 previewShares = _asSY(sy).previewDeposit(address(usds), amount);
        uint256 sharesOut = _asSY(sy).deposit(user, address(usds), amount, 0);
        vm.stopPrank();

        // 5 / 2 rounds down to 2; a ceil implementation would return 3.
        assertEq(previewShares, 2);
        assertEq(sharesOut, 2);
        assertEq(sUSDS.balanceOf(sy), 2);
    }

    // Dust deposits below the exchange-rate quantum floor to zero shares in the unguarded adapter
    // families (4626 vault, PSM3 swap, wrap, unwrap). Each test below pins one family and relies
    // on the SYBase zero-output guard, not an adapter-local check, to revert the stranded input.
    function testEthenaUsdeDustDepositRevertsOnZeroSharesOut() external {
        uint256 amount = 1;
        MockToken usde = new MockToken("USDe", "USDe", 18);
        MockVault sUSDe = new MockVault(address(usde));
        sUSDe.setAssetsPerShare(2e18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunStakedUSDeSYUpgradeable()),
            abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, address(usde), address(sUSDe)))
        );

        _assertDustDepositReverts(sy, usde, amount);
    }

    function testSkyL2PsmDustDepositRevertsOnZeroSharesOut() external {
        uint256 amount = 1;
        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockToken sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        MockPSM3 psm = new MockPSM3();
        psm.setRate(address(sUSDS), 2e18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usds), address(usds), address(sUSDS), address(psm))
            )
        );

        _assertDustDepositReverts(sy, usds, amount);
    }

    function testWstEthStEthDustDepositRevertsOnZeroSharesOut() external {
        uint256 amount = 1;
        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        stETH.setPooledEthPerShare(2e18);
        wstETH.setStEthPerToken(2e18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );

        _assertDustDepositReverts(sy, stETH, amount);
    }

    function testL2WrappableWstEthDustDepositRevertsOnZeroSharesOut() external {
        uint256 amount = 1;
        MockToken l2WstEth = new MockToken("wstETH", "wstETH", 18);
        MockL2StETH l2StEth = new MockL2StETH(address(l2WstEth), 2 ether);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeWithSelector(
                OutrunL2WrappableWstETHSYUpgradeable.initialize.selector,
                owner,
                address(l2StEth),
                address(l2WstEth),
                address(l2StEth),
                18
            )
        );

        _assertDustDepositReverts(sy, l2StEth, amount);
    }

    function testWeEtheEthDustDepositRevertsOnZeroSharesOut() external {
        uint256 amount = 1;
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        MockWeETH weETH = new MockWeETH(address(eETH));
        MockLiquidityPool pool = new MockLiquidityPool();
        weETH.setShareRate(2e18);
        pool.setShareRate(2e18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(new MockDepositAdapter()), address(pool))
            )
        );

        _assertDustDepositReverts(sy, eETH, amount);
    }

    function testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate() external {
        address generic = _deployL2Staked();
        _assertYieldTokenRoundtrip(generic, token, AMOUNT);
        assertEq(_asSY(generic).exchangeRate(), 1.2e18);

        address l2Wst = _deployL2WstETH();
        _assertYieldTokenRoundtrip(l2Wst, token, AMOUNT);
        assertEq(_asSY(l2Wst).exchangeRate(), 1.2e18);

        MockToken l2WstEth = new MockToken("wstETH", "wstETH", 18);
        MockL2StETH l2StEth = new MockL2StETH(address(l2WstEth), 2 ether);
        address l2Wrappable = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeWithSelector(
                OutrunL2WrappableWstETHSYUpgradeable.initialize.selector,
                owner,
                address(l2StEth),
                address(l2WstEth),
                address(l2StEth),
                18
            )
        );

        l2StEth.mint(user, AMOUNT);
        vm.startPrank(user);
        l2StEth.approve(l2Wrappable, AMOUNT);
        uint256 l2PreviewShares = _asSY(l2Wrappable).previewDeposit(address(l2StEth), AMOUNT);
        uint256 l2Shares = _asSY(l2Wrappable).deposit(user, address(l2StEth), AMOUNT, 0);
        uint256 l2PreviewOut = _asSY(l2Wrappable).previewRedeem(address(l2StEth), l2Shares);
        uint256 l2Redeemed = _asSY(l2Wrappable).redeem(user, l2Shares, address(l2StEth), 0, false);
        vm.stopPrank();

        assertEq(l2Shares, l2PreviewShares);
        assertEq(l2Redeemed, l2PreviewOut);
        assertEq(l2Redeemed, AMOUNT);
        assertEq(_asSY(l2Wrappable).exchangeRate(), l2StEth.getTokensByShares(1 ether));

        address lista = _deployLista();
        _assertYieldTokenRoundtrip(lista, token, AMOUNT);
        assertEq(_asSY(lista).previewDeposit(NATIVE, AMOUNT), AMOUNT * 9950 / 10000);
        assertEq(_asSY(lista).exchangeRate(), 1e18);

        address aster = _deployAster();
        _assertYieldTokenRoundtrip(aster, token, AMOUNT);
        assertEq(_asSY(aster).previewDeposit(NATIVE, AMOUNT), AMOUNT * 9950 / 10000);
        assertEq(_asSY(aster).exchangeRate(), 1e18);
    }

    function testListaNativeDepositMatchesPreviewAndExchangeRate() external {
        // Non-identity rate plus a real deposit-minting stake manager make the native BNB deposit
        // branch exercisable; preview (convertBnbToSnBnb) and actual (minted slisBNB delta) are no
        // longer tautologically equal.
        uint256 rate = 1.1e18;
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        stakeManager.setRate(rate);
        stakeManager.setSlisBnbToken(token);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunSlisBNBSYUpgradeable()),
            abi.encodeCall(OutrunSlisBNBSYUpgradeable.initialize, (owner, address(token), address(stakeManager)))
        );

        uint256 expectedShares = AMOUNT * 1e18 / rate;
        uint256 expectedPreview = expectedShares * 9950 / 10000;
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedPreview);
        assertEq(sharesOut, expectedShares);
        assertEq(previewShares, expectedShares * 9950 / 10000);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    function testAsterNativeDepositMatchesPreviewAndExchangeRate() external {
        // Non-identity minter rate (stake manager kept at identity) exercises the native BNB -> asBNB
        // path with a non-tautological preview/actual equality.
        uint256 rate = 1.1e18;
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockToken slis = new MockToken("slisBNB", "slisBNB", 18);
        MockAsBnbMinter minter = new MockAsBnbMinter(address(token), address(slis), address(yieldProxy));
        minter.setRate(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunAsBNBSYUpgradeable()),
            abi.encodeCall(OutrunAsBNBSYUpgradeable.initialize, (owner, address(token), address(slis), address(minter)))
        );

        uint256 expectedShares = AMOUNT * 1e18 / rate;
        uint256 expectedPreview = expectedShares * 9950 / 10000;
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedPreview);
        assertEq(sharesOut, expectedShares);
        assertEq(previewShares, expectedShares * 9950 / 10000);
        // The minter mock delivers the minted asBNB to the SY, matching the real Aster delivery seam.
        assertEq(token.balanceOf(address(sy)), sharesOut);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    function testAsterSlisBnbDepositMatchesPreviewAndExchangeRate() external {
        // The slisBNB -> asBNB converting path uses different functions for preview (convertToAsBnb)
        // and execution (mintAsBnb), so preview == actual is non-tautological at a non-identity rate.
        uint256 rate = 1.1e18;
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockToken slis = new MockToken("slisBNB", "slisBNB", 18);
        MockAsBnbMinter minter = new MockAsBnbMinter(address(token), address(slis), address(yieldProxy));
        minter.setRate(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunAsBNBSYUpgradeable()),
            abi.encodeCall(OutrunAsBNBSYUpgradeable.initialize, (owner, address(token), address(slis), address(minter)))
        );

        uint256 expectedShares = AMOUNT * 1e18 / rate;
        uint256 expectedPreview = expectedShares * 9950 / 10000;
        slis.mint(user, AMOUNT);
        vm.startPrank(user);
        slis.approve(sy, AMOUNT);
        uint256 previewShares = _asSY(sy).previewDeposit(address(slis), AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit(user, address(slis), AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedPreview);
        assertEq(sharesOut, expectedShares);
        assertEq(previewShares, expectedShares * 9950 / 10000);
        // Delivery seams: the minter pulled the SY's slisBNB and minted the asBNB shares back to it.
        assertEq(slis.balanceOf(address(minter)), AMOUNT);
        assertEq(slis.balanceOf(address(sy)), 0);
        assertEq(token.balanceOf(address(sy)), sharesOut);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    function testAsterNativeDepositRevertsWhenQueued() external {
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockToken slis = new MockToken("slisBNB", "slisBNB", 18);
        MockAsBnbMinter minter = new MockAsBnbMinter(address(token), address(slis), address(yieldProxy));
        address sy = ProxyTestHelper.deploy(
            address(new OutrunAsBNBSYUpgradeable()),
            abi.encodeCall(OutrunAsBNBSYUpgradeable.initialize, (owner, address(token), address(slis), address(minter)))
        );

        // While the yield proxy is processing a batch, mintAsBnb returns 0 and the adapter classifies
        // the native deposit as queued rather than a true zero-output failure.
        yieldProxy.setActivitiesOnGoing(true);
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vm.expectRevert(OutrunAsBNBSYUpgradeable.AsBnbMintQueued.selector);
        _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
    }

    function testWeEthNativeDepositMatchesPreviewAndExchangeRate() external {
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        MockWeETH weETH = new MockWeETH(address(eETH));
        MockLiquidityPool pool = new MockLiquidityPool();
        MockDepositAdapter depositAdapter = new MockDepositAdapter();
        uint256 rate = 1.25e18;
        weETH.setShareRate(rate);
        pool.setShareRate(rate);
        depositAdapter.setShareRate(rate);
        // Wire the weETH token so the adapter really mints the deposited amount to the SY.
        depositAdapter.setWeETHToken(weETH);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(depositAdapter), address(pool))
            )
        );

        // Native ETH preview reduces to sharesForAmount(amount) at the pool rate; execution routes ETH
        // through the deposit adapter, which mints the quoted weETH amount to the SY, so preview
        // is conservative (raw *9950/10000) and actual is the raw quote.
        uint256 expectedShares = AMOUNT * 1e18 / rate;
        uint256 expectedPreview = expectedShares * 9950 / 10000;
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedPreview);
        assertEq(sharesOut, expectedShares);
        assertEq(previewShares, expectedShares * 9950 / 10000);
        // The adapter-minted weETH backing sits on the SY, matching the fork-observed behaviour.
        assertEq(weETH.balanceOf(sy), sharesOut);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    // ---------------------------------------------------------------------------
    // Rounding-direction property tests
    //
    // Roundtrip bounded loss: deposit then immediately redeem the same token and assert the
    // output stays within the adapter's rounding quanta of the input. Preview bounds actual:
    // on the chained-floor native paths, assert the executed deposit output stays within one
    // quantum of the preview quote. Rates/indices are bounded to [1x, 2x) — the realistic
    // appreciation band. Amount lower bounds sit at or above each path's dust threshold
    // (conservatively rounded up; the dust-revert region itself is already pinned by the example
    // tests above).
    // ---------------------------------------------------------------------------

    function testFuzz_AaveATokenRoundtripLosesAtMostOneQuantum(uint128 amountSeed, uint96 indexSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        // Index stays strictly below 2e27: in the mock's accounting, at >= 2x the half-up share
        // credit can quote one more aToken than a fresh contract holds and the first roundtrip
        // would revert on the ERC20 transfer (real Aave derives balanceOf from the same scaled
        // accounting, so this cap is a mock-domain choice, not a production bound).
        uint256 index = bound(indexSeed, 1e27, 2e27 - 1);
        (address sy,, MockAToken aToken) = _deployAave(index);

        aToken.mint(user, amount);
        vm.startPrank(user);
        aToken.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(aToken), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(aToken), 0, false);
        vm.stopPrank();

        // Deposit converts asset -> scaled shares half-up (calcSharesFromAssetHalfUp) and redeem
        // converts back floor (calcSharesToAssetDown); the composed loss is at most one aToken
        // quantum while the index stays below 2x.
        assertGe(out, amount - 1, "aToken roundtrip loss exceeds one quantum");
    }

    function testFuzz_AaveUnderlyingRoundtripLosesAtMostOneQuantum(uint128 amountSeed, uint96 indexSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 index = bound(indexSeed, 1e27, 2e27 - 1);
        (address sy, MockToken underlying,) = _deployAave(index);

        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(underlying), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(underlying), 0, false);
        vm.stopPrank();

        // Same half-up -> floor composition as the aToken path, routed through pool
        // supply/withdraw; the composed loss is at most one underlying quantum below 2x index.
        assertGe(out, amount - 1, "underlying roundtrip loss exceeds one quantum");
    }

    function testFuzz_WstETHStEthRoundtripLosesAtMostTwoQuanta(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        stETH.setPooledEthPerShare(rate);
        wstETH.setStEthPerToken(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );

        stETH.mint(user, amount);
        vm.startPrank(user);
        stETH.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(stETH), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(stETH), 0, false);
        vm.stopPrank();

        // wrap floors asset -> shares and unwrap floors shares -> asset; the double floor loses
        // at most ceil(rate / 1e18) quanta, which is <= 2 while the rate stays within 2x.
        assertGe(out, amount - 2, "wstETH stETH roundtrip loss exceeds two quanta");
    }

    function testFuzz_SkyUsdsRoundtripLosesAtMostTwoQuanta(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockVault sUSDS = new MockVault(address(usds));
        sUSDS.setAssetsPerShare(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunStakedUsdsSYUpgradeable()),
            abi.encodeCall(OutrunStakedUsdsSYUpgradeable.initialize, (owner, address(usds), address(sUSDS)))
        );

        usds.mint(user, amount);
        vm.startPrank(user);
        usds.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(usds), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(usds), 0, false);
        vm.stopPrank();

        // convertToShares and convertToAssets are both floors, so the vault roundtrip loses at
        // most ceil(rate / 1e18) quanta — <= 2 while the rate stays within 2x.
        assertGe(out, amount - 2, "sUSDS roundtrip loss exceeds two quanta");
    }

    function testFuzz_WeETHEEthRoundtripLosesAtMostTwoQuanta(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        MockWeETH weETH = new MockWeETH(address(eETH));
        weETH.setShareRate(rate);
        // The eETH roundtrip only touches wrap/unwrap; the native-path mocks are wiring-only.
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (
                    owner,
                    address(eETH),
                    address(weETH),
                    address(new MockDepositAdapter()),
                    address(new MockLiquidityPool())
                )
            )
        );

        eETH.mint(user, amount);
        vm.startPrank(user);
        eETH.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(eETH), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(eETH), 0, false);
        vm.stopPrank();

        // weETH.wrap floors eETH -> shares and unwrap floors shares -> eETH; the double floor
        // loses at most ceil(rate / 1e18) quanta, which is <= 2 while the rate stays within 2x.
        assertGe(out, amount - 2, "weETH eETH roundtrip loss exceeds two quanta");
    }

    function testFuzz_L2WrappableWstETHStEthRoundtripLosesAtMostTwoQuanta(uint128 amountSeed, uint96 rateSeed)
        external
    {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 tokensPerShare = bound(rateSeed, 1e18, 2e18);
        (address sy, MockToken wstETH, MockL2StETH l2StETH) = _deployL2WrappableWstEthSY(tokensPerShare);

        // MockL2StETH mint adds raw shares while balanceOf reports token units, so minting
        // `amount` raw shares leaves a displayed balance >= amount (tokensPerShare >= 1e18).
        l2StETH.mint(user, amount);
        vm.startPrank(user);
        l2StETH.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(l2StETH), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(l2StETH), 0, false);
        vm.stopPrank();

        // unwrap floors tokens -> shares and wrap floors shares -> tokens; the double floor loses
        // at most ceil(tokensPerShare / 1e18) quanta — <= 2 while the ratio stays within 2x.
        assertGe(out, amount - 2, "L2 wrappable wstETH stETH roundtrip loss exceeds two quanta");
        // The wrap leg approves the L2 stETH pull exactly; the resident wstETH backing keeps no allowance.
        assertEq(wstETH.allowance(sy, address(l2StETH)), 0, "stETH redeem must leave no wstETH allowance to L2 stETH");
    }

    function testL2WrappableWstEthStEthRedeemLeavesNoAllowance() external {
        MockToken wstETH = new MockToken("wstETH", "wstETH", 18);
        MockL2StETH l2StETH = new MockL2StETH(address(wstETH), 1e18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeCall(
                OutrunL2WrappableWstETHSYUpgradeable.initialize,
                (owner, address(l2StETH), address(wstETH), address(l2StETH), 18)
            )
        );

        wstETH.mint(user, AMOUNT);
        vm.startPrank(user);
        wstETH.approve(sy, AMOUNT);
        uint256 shares = _asSY(sy).deposit(user, address(wstETH), AMOUNT, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(l2StETH), 0, false);
        vm.stopPrank();

        assertEq(out, AMOUNT);
        // wstETH is the SY's resident share backing: the wrap-leg redeem must approve the L2 stETH
        // contract for exactly the wrap amount and leave no standing allowance on it.
        assertEq(wstETH.allowance(sy, address(l2StETH)), 0, "stETH redeem must leave no wstETH allowance to L2 stETH");

        // Counterfactual: with no standing allowance, an over-pull by the L2 stETH spender must be
        // rejected by the token layer rather than drawing on the SY's backing.
        address attacker = makeAddr("attacker");
        vm.prank(address(l2StETH));
        // OZ reports the offender as the spender, so the encoded first arg is the L2 stETH contract.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(l2StETH), 0, 1)
        );
        wstETH.transferFrom(sy, attacker, 1);
    }

    function testFuzz_SkyL2PsmUsdsRoundtripLosesAtMostTwoQuanta(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        (address sy, MockToken usds, MockToken l2sUSDS, MockPSM3 psm3) = _deploySkyL2UsdsPsm(rate);

        usds.mint(user, amount);
        vm.startPrank(user);
        usds.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(usds), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(usds), 0, false);
        vm.stopPrank();

        // Both PSM3 legs are floors (into the share divides by rate, out of the share multiplies
        // by rate), so the swap roundtrip loses at most ceil(rate / 1e18) quanta — <= 2 at 2x.
        assertGe(out, amount - 2, "PSM3 USDS roundtrip loss exceeds two quanta");
        // The cross-token redeem approves the PSM3 pull exactly; the resident sUSDS backing keeps no allowance.
        assertEq(l2sUSDS.allowance(sy, address(psm3)), 0, "cross-token redeem must leave no sUSDS allowance to PSM3");
    }

    function testSkyL2PsmUsdsCrossTokenRedeemLeavesNoAllowance() external {
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockToken sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        MockPSM3 psm3 = new MockPSM3();
        psm3.setRate(address(sUSDS), 1e18);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usdc), address(usds), address(sUSDS), address(psm3))
            )
        );

        usds.mint(user, AMOUNT);
        vm.startPrank(user);
        usds.approve(sy, AMOUNT);
        uint256 shares = _asSY(sy).deposit(user, address(usds), AMOUNT, 0);
        // Exact per-call approval on the deposit swap: no USDS allowance to PSM3 may persist.
        assertEq(usds.allowance(address(sy), address(psm3)), 0, "PSM3 deposit must leave no USDS allowance");
        uint256 out = _asSY(sy).redeem(user, shares, address(usds), 0, false);
        vm.stopPrank();

        assertEq(out, AMOUNT);
        // sUSDS is the SY's resident share backing: the cross-token redeem must approve PSM3 for
        // exactly this swap's pull and leave no standing allowance on it.
        assertEq(sUSDS.allowance(sy, address(psm3)), 0, "cross-token redeem must leave no sUSDS allowance to PSM3");

        // Counterfactual: with no standing allowance, an over-pull by the PSM3 spender must be
        // rejected by the token layer rather than drawing on the SY's backing.
        address attacker = makeAddr("attacker");
        vm.prank(address(psm3));
        // OZ reports the offender as the spender, so the encoded first arg is the PSM3 contract.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(psm3), 0, 1));
        sUSDS.transferFrom(sy, attacker, 1);
    }

    function testSkyL2ExchangeRateRevertsWhenBackingBelowShares() external {
        (address sy, MockToken usds, MockToken sUSDS,) = _deploySkyL2UsdsPsm(1e18);

        usds.mint(user, AMOUNT);
        vm.startPrank(user);
        usds.approve(sy, AMOUNT);
        uint256 shares = _asSY(sy).deposit(user, address(usds), AMOUNT, 0);
        vm.stopPrank();

        uint256 outstanding = _asSY(sy).totalSupply();
        assertEq(shares, outstanding);
        // Healthy path: the PSM-minted sUSDS fully backs the outstanding supply, so the quote succeeds.
        assertEq(_asSY(sy).exchangeRate(), 1e18);

        // Simulate backing leaving the adapter outside deposit/redeem: the self-held sUSDS falls
        // below the outstanding supply, so the quote must fail closed instead of pricing unbacked
        // shares at par.
        uint256 resident = outstanding - 1;
        deal(address(sUSDS), sy, resident);
        vm.expectRevert(
            abi.encodeWithSelector(OutrunL2StakedUsdsSYUpgradeable.InsufficientBacking.selector, resident, outstanding)
        );
        _asSY(sy).exchangeRate();

        // Snapshot semantics: the assertion reads only the current balance, so restoring it (here to
        // strictly more than the supply) releases the quote without any other state change.
        deal(address(sUSDS), sy, outstanding + 1 ether);
        assertEq(_asSY(sy).exchangeRate(), 1e18);
    }

    function testSkyL2ExchangeRateAllowsBackingEqualToOutstandingShares() external {
        (address sy, MockToken usds, MockToken sUSDS,) = _deploySkyL2UsdsPsm(1e18);

        usds.mint(user, AMOUNT);
        vm.startPrank(user);
        usds.approve(sy, AMOUNT);
        _asSY(sy).deposit(user, address(usds), AMOUNT, 0);
        vm.stopPrank();

        uint256 outstanding = _asSY(sy).totalSupply();
        // Boundary: deal the resident sUSDS to exactly the outstanding supply — equality is not a
        // shortfall (the guard is strict <), so the quote must succeed.
        deal(address(sUSDS), sy, outstanding);
        assertEq(_asSY(sy).exchangeRate(), 1e18);
    }

    function testSkyL2BackingShortfallHaltsStakingPositionMintsAndKeepsRedeemOpen() external {
        (address sy, MockToken usds, MockToken sUSDS,) = _deploySkyL2UsdsPsm(1e18);

        // Receipt token + staking position wired like the production stack; the mock LZ endpoint
        // only feeds the uAsset's OFT constructor.
        OutrunUniversalAssetsUpgradeable uAsset = OutrunUniversalAssetsUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunUniversalAssetsUpgradeable(18, address(new MockLzEndpoint()))),
                abi.encodeCall(OutrunUniversalAssetsUpgradeable.initialize, ("UAsset", "UAST", owner))
            )
        );
        OutrunStakingPositionUpgradeable position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, address(0xFEE), sy, address(uAsset), address(0xC0FFEE))
                )
            )
        );
        vm.prank(owner);
        uAsset.setMintingCap(address(position), type(uint256).max);

        // Healthy entry: deposit USDS for SY, approve the position, and stake with zero lockup so
        // the deadline is the current timestamp and the position is redeemable in the same block.
        usds.mint(user, AMOUNT);
        vm.startPrank(user);
        usds.approve(sy, AMOUNT);
        uint256 shares = _asSY(sy).deposit(user, address(usds), AMOUNT, 0);
        _asSY(sy).approve(address(position), shares);
        (uint256 positionId, uint256 mintedUAsset) = position.stake(shares, 0, user, user);
        vm.stopPrank();

        // Wrap-pool entry while healthy: the wrap ledger must carry debt for the keeper exit below,
        // because keepWrapRedeem checks the debt before reading the exchange rate.
        usds.mint(user, 1 ether);
        vm.startPrank(user);
        usds.approve(sy, 1 ether);
        uint256 wrapShares = _asSY(sy).deposit(user, address(usds), 1 ether, 0);
        _asSY(sy).approve(address(position), wrapShares);
        position.wrapStake(wrapShares, user);
        vm.stopPrank();

        // Simulate backing leaving the SY outside deposit/redeem: the adapter's resident sUSDS is
        // now one wei below the outstanding SY supply.
        uint256 outstanding = _asSY(sy).totalSupply();
        uint256 resident = outstanding - 1;
        deal(address(sUSDS), sy, resident);

        // Mint-side entry points read the rate through _currentExchangeRate, so the adapter's
        // InsufficientBacking guard propagates and blocks new stake/wrap-stake mints (drawUAsset
        // shares the same rate-reading home but is expiry-gated ahead of it — probed below by
        // stepping back into the lock window).
        bytes memory backingShortfall =
            abi.encodeWithSelector(OutrunL2StakedUsdsSYUpgradeable.InsufficientBacking.selector, resident, outstanding);
        uint256 uAssetSupplyBefore = uAsset.totalSupply();
        vm.startPrank(user);
        vm.expectRevert(backingShortfall);
        position.stake(AMOUNT, 0, user, user);
        vm.expectRevert(backingShortfall);
        position.wrapStake(AMOUNT, user);
        vm.stopPrank();

        // Drawing against the staked position is also shut: the lockupDays=0 deadline equals this
        // block's timestamp, so re-enter the lock window for one second to reach the rate read,
        // then restore maturity for the redeem below.
        (,,, uint128 deadline) = position.positions(positionId);
        vm.warp(deadline - 1);
        vm.prank(user);
        vm.expectRevert(backingShortfall);
        position.drawUAsset(positionId, user);
        // The draw quote shares drawUAsset's expiry gate (it reverts LockTimeExpired once matured),
        // so it is probed from the same inside-the-lock-window timestamp before maturity is restored.
        vm.expectRevert(backingShortfall);
        position.previewDrawUAsset(positionId);
        vm.warp(deadline);

        // The owner's wrap-yield harvest reads the same rate before touching the pool, so the
        // harvest door is shut alongside the mint doors.
        vm.prank(owner);
        vm.expectRevert(backingShortfall);
        position.harvestWrapYield(sy, 0);

        // The keeper's wrap-pool exit reads the same rate after its debt guard; the healthy wrap
        // stake above funds that debt, and the keeper approves the position to burn its uAsset on
        // repay, matching the production wiring of the keeper role.
        address keeper = address(0xC0FFEE);
        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(backingShortfall);
        position.keepWrapRedeem(0.1 ether, keeper);

        // The keeper's matured-position exit clears its own guard chain (keeper identity, maturity,
        // debt bound against the healthy stake above) and then reaches the same rate read, so the
        // shortfall shuts this door too; the keeper's approval above would cover the repay leg, and
        // the revert fires before any burn or SY transfer. Its quote walks the same guards and fails
        // closed the same way.
        vm.prank(keeper);
        vm.expectRevert(backingShortfall);
        position.keepRedeem(positionId, 0.1 ether, keeper);
        vm.expectRevert(backingShortfall);
        position.previewKeepRedeem(positionId, 0.1 ether);

        // The view surface propagates the halt too: quoting a stake or a wrap stake reads the same
        // rate, and the wrap-redeem quote passes its debt guard (the healthy 1 ether wrap stake
        // above funds the pool debt) before reaching the same read.
        vm.expectRevert(backingShortfall);
        position.previewStake(AMOUNT);
        vm.expectRevert(backingShortfall);
        position.previewWrapStake(AMOUNT);
        vm.expectRevert(backingShortfall);
        position.previewWrapRedeem(0.1 ether);

        // The blocked mints left the uAsset supply untouched.
        assertEq(uAsset.totalSupply(), uAssetSupplyBefore);

        // Exit-channel contrast: redeem never reads the exchange rate (documented intent — staked
        // SY leaves at face), so the matured position still exits while the quote fails closed.
        // repay burns the caller's uAsset through the position, so the user must approve it first.
        vm.startPrank(user);
        uAsset.approve(address(position), mintedUAsset);
        (uint256 uAssetBurned, uint256 syOut) = position.redeem(positionId, shares, user, sy, 0);
        vm.stopPrank();
        assertEq(uAssetBurned, mintedUAsset);
        assertEq(syOut, shares);
        assertEq(_asSY(sy).balanceOf(user), shares);

        // The adapter's preview surface stays usable in the same shortfall state: previews quote
        // the PSM3 leg directly and never run the backing reconciliation.
        assertEq(_asSY(sy).previewDeposit(address(usds), AMOUNT), AMOUNT);
        assertEq(_asSY(sy).previewRedeem(address(usds), shares), shares);
    }

    function testL2WrappableWstEthExchangeRateRevertsWhenBackingBelowShares() external {
        (address sy, MockToken wstETH,) = _deployL2WrappableWstEthSY(1e18);

        wstETH.mint(user, AMOUNT);
        vm.startPrank(user);
        wstETH.approve(sy, AMOUNT);
        uint256 shares = _asSY(sy).deposit(user, address(wstETH), AMOUNT, 0);
        vm.stopPrank();

        uint256 outstanding = _asSY(sy).totalSupply();
        assertEq(shares, outstanding);
        // Healthy path: the deposited wstETH fully backs the outstanding supply, so the quote succeeds.
        assertEq(_asSY(sy).exchangeRate(), 1e18);

        // Simulate backing leaving the adapter outside deposit/redeem: the self-held wstETH falls
        // below the outstanding supply, so the quote must fail closed instead of pricing unbacked
        // shares at par.
        uint256 resident = outstanding - 1;
        deal(address(wstETH), sy, resident);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutrunL2WrappableWstETHSYUpgradeable.InsufficientBacking.selector, resident, outstanding
            )
        );
        _asSY(sy).exchangeRate();

        // Snapshot semantics: the assertion reads only the current balance, so restoring it (here to
        // strictly more than the supply) releases the quote without any other state change.
        deal(address(wstETH), sy, outstanding + 1 ether);
        assertEq(_asSY(sy).exchangeRate(), 1e18);
    }

    function testL2WrappableWstEthExchangeRateAllowsBackingEqualToOutstandingShares() external {
        (address sy, MockToken wstETH,) = _deployL2WrappableWstEthSY(1e18);

        wstETH.mint(user, AMOUNT);
        vm.startPrank(user);
        wstETH.approve(sy, AMOUNT);
        _asSY(sy).deposit(user, address(wstETH), AMOUNT, 0);
        vm.stopPrank();

        uint256 outstanding = _asSY(sy).totalSupply();
        // Boundary: deal the resident wstETH to exactly the outstanding supply — equality is not a
        // shortfall (the guard is strict <), so the quote must succeed.
        deal(address(wstETH), sy, outstanding);
        assertEq(_asSY(sy).exchangeRate(), 1e18);
    }

    function testFuzz_WstETHNativePreviewBoundsActualWithinOneQuantum(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 4, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        MockStETH stETH = new MockStETH();
        MockWstETH wstETH = new MockWstETH(address(stETH));
        stETH.setPooledEthPerShare(rate);
        wstETH.setStEthPerToken(rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );

        vm.deal(user, amount);
        vm.startPrank(user);
        uint256 preview = _asSY(sy).previewDeposit(NATIVE, amount);
        uint256 actual = _asSY(sy).deposit{value: amount}(user, NATIVE, amount, 0);
        vm.stopPrank();

        // After the 9950/10000 conservative headroom, the native preview is `raw *9950/10000`
        // where `raw == actual` at the same block (single floor via WstETH.receive). The executed
        // output is therefore ~0.5% above the preview, not within 1 wei. Check the discount
        // identity and that verbatim preview as minSharesOut never reverts.
        assertGe(actual, preview, "native wstETH actual falls below conservative preview");
        assertEq(preview, actual * 9950 / 10000, "native wstETH preview not discounted by 9950/10000");
        assertLe(actual, preview * 10000 / 9950 + 1, "native wstETH actual exceeds discounted preview bound");
    }

    function testFuzz_WeETHNativePreviewBoundsActualWithinOneQuantum(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 4, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        MockWeETH weETH = new MockWeETH(address(eETH));
        MockLiquidityPool pool = new MockLiquidityPool();
        MockDepositAdapter depositAdapter = new MockDepositAdapter();
        weETH.setShareRate(rate);
        pool.setShareRate(rate);
        depositAdapter.setShareRate(rate);
        depositAdapter.setWeETHToken(weETH);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(depositAdapter), address(pool))
            )
        );

        vm.deal(user, amount);
        vm.startPrank(user);
        uint256 preview = _asSY(sy).previewDeposit(NATIVE, amount);
        uint256 actual = _asSY(sy).deposit{value: amount}(user, NATIVE, amount, 0);
        vm.stopPrank();

        // After the 9950/10000 conservative headroom, the native preview is `raw *9950/10000`
        // where `raw` is the double-floor quote. Execution via DepositAdapter is the single-floor
        // raw, so actual is ~0.5% above preview. Double-floor vs single-floor can diverge by 1 wei
        // before the 9950 discount, so allow 1 wei tolerance.
        assertGe(actual, preview, "native weETH actual falls below conservative preview");
        // preview should equal raw*9950/10000 and actual should equal raw (within 1 wei of raw)
        // so preview == actual*9950/10000 within 1 wei rounding. Double-floor can add 1 extra wei at dust.
        assertApproxEqAbs(preview, actual * 9950 / 10000, 1, "native weETH preview not discounted by 9950/10000");
        assertLe(actual, preview * 10000 / 9950 + 2, "native weETH actual exceeds discounted preview bound");
    }

    function testFuzz_L2OracleFamilyRoundtripIsExact(uint128 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1_000_000 ether);
        // Both oracle-backed variants deposit and redeem the yield-bearing token 1:1 — the
        // quoted oracle rate never enters the exchange track, so the roundtrip is exact.
        address[] memory instances = new address[](2);
        instances[0] = _deployL2Staked();
        instances[1] = _deployL2WstETH();
        for (uint256 i; i < instances.length; ++i) {
            address sy = instances[i];
            token.mint(user, amount);
            vm.startPrank(user);
            token.approve(sy, amount);
            uint256 shares = _asSY(sy).deposit(user, address(token), amount, 0);
            uint256 out = _asSY(sy).redeem(user, shares, address(token), 0, false);
            vm.stopPrank();

            assertEq(shares, amount, "L2 oracle family shares must be 1:1");
            assertEq(out, amount, "L2 oracle family roundtrip must be exact");
        }
    }

    function _assertYieldTokenRoundtrip(address sy, MockToken ybt, uint256 amount) internal {
        uint256 balanceBefore = ybt.balanceOf(user);
        ybt.mint(user, amount);
        vm.startPrank(user);
        ybt.approve(sy, amount);
        uint256 previewShares = _asSY(sy).previewDeposit(address(ybt), amount);
        uint256 sharesOut = _asSY(sy).deposit(user, address(ybt), amount, 0);
        uint256 previewOut = _asSY(sy).previewRedeem(address(ybt), sharesOut);
        uint256 redeemed = _asSY(sy).redeem(user, sharesOut, address(ybt), 0, false);
        vm.stopPrank();

        assertEq(sharesOut, previewShares);
        assertEq(redeemed, previewOut);
        assertEq(redeemed, amount);
        assertEq(ybt.balanceOf(user), balanceBefore + amount);
        assertEq(_asSY(sy).balanceOf(user), 0);
    }

    // Dust tail shared by the family tests above: a deposit below the exchange-rate quantum floors
    // to zero shares, so the SYBase zero-output guard reverts SYZeroSharesOut even at minSharesOut=0.
    function _assertDustDepositReverts(address sy, MockToken asset, uint256 amount) internal {
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(sy, amount);
        vm.expectRevert(IStandardizedYield.SYZeroSharesOut.selector);
        _asSY(sy).deposit(user, address(asset), amount, 0);
        vm.stopPrank();
    }

    function _assertAdapterMatrix(address sy, address[] memory expectedTokensIn, address[] memory expectedTokensOut)
        internal
    {
        address[] memory tokensIn = _asSY(sy).getTokensIn();
        assertEq(tokensIn.length, expectedTokensIn.length);
        for (uint256 i; i < expectedTokensIn.length; ++i) {
            assertTrue(_contains(tokensIn, expectedTokensIn[i]));
            assertTrue(_asSY(sy).isValidTokenIn(expectedTokensIn[i]));
            assertGt(_asSY(sy).previewDeposit(expectedTokensIn[i], AMOUNT), 0);
        }
        for (uint256 i; i < tokensIn.length; ++i) {
            assertTrue(_contains(expectedTokensIn, tokensIn[i]));
            assertTrue(_asSY(sy).isValidTokenIn(tokensIn[i]));
        }

        address[] memory tokensOut = _asSY(sy).getTokensOut();
        assertEq(tokensOut.length, expectedTokensOut.length);
        for (uint256 i; i < expectedTokensOut.length; ++i) {
            assertTrue(_contains(tokensOut, expectedTokensOut[i]));
            assertTrue(_asSY(sy).isValidTokenOut(expectedTokensOut[i]));
            assertGt(_asSY(sy).previewRedeem(expectedTokensOut[i], AMOUNT), 0);
        }
        for (uint256 i; i < tokensOut.length; ++i) {
            assertTrue(_contains(expectedTokensOut, tokensOut[i]));
            assertTrue(_asSY(sy).isValidTokenOut(tokensOut[i]));
        }

        assertGt(_asSY(sy).exchangeRate(), 0);

        address invalid = address(new MockToken("Invalid", "BAD", 18));
        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInvalidTokenIn.selector, invalid));
        _asSY(sy).deposit(user, invalid, AMOUNT, 0);

        vm.expectRevert(abi.encodeWithSelector(IStandardizedYield.SYInvalidTokenOut.selector, invalid));
        _asSY(sy).redeem(user, AMOUNT, invalid, 0, false);
    }

    function _contains(address[] memory tokens, address token_) internal pure returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token_) return true;
        }
        return false;
    }

    function _tokens(address token0) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token0;
    }

    function _tokens(address token0, address token1) internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
    }

    function _tokens(address token0, address token1, address token2) internal pure returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = token0;
        tokens[1] = token1;
        tokens[2] = token2;
    }

    function _assertSY(address sy, string memory name_, string memory symbol_, address ybt) internal {
        assertEq(_asSY(sy).name(), name_);
        assertEq(_asSY(sy).symbol(), symbol_);
        assertEq(_asSY(sy).yieldBearingToken(), ybt);
        assertEq(_asSY(sy).owner(), owner);
    }

    function _asSY(address sy) internal pure returns (OutrunL2StakedTokenSYUpgradeable) {
        return OutrunL2StakedTokenSYUpgradeable(payable(sy));
    }

    function _storedAddress(address target, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    // Variation point across call sites: `liquidityIndex` (ray) is the pool reserve index that
    // drives Aave's rounding math. Rounding-focused callers pass 2e27 or 3e27; identity callers pass 1e27.
    function _deployAave(uint256 liquidityIndex)
        internal
        returns (address sy, MockToken underlying, MockAToken aToken)
    {
        underlying = new MockToken("Underlying", "UND", 18);
        aToken = new MockAToken(address(underlying));
        MockAavePool aavePool = new MockAavePool();
        aavePool.setReserve(address(underlying), aToken, liquidityIndex);
        sy = ProxyTestHelper.deploy(
            address(new OutrunAaveV3SYUpgradeable()),
            abi.encodeCall(
                OutrunAaveV3SYUpgradeable.initialize, ("SY Aave", "SYA", address(aToken), address(aavePool), owner)
            )
        );
    }

    // Variation point across call sites: `psmRate` is the PSM3 share rate that drives both swap
    // execution and the SSR-synced exchange-rate quote. Identity callers pass 1e18.
    function _deploySkyL2UsdsPsm(uint256 psmRate)
        internal
        returns (address sy, MockToken usds, MockToken sUSDS, MockPSM3 psm3)
    {
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        usds = new MockToken("USDS", "USDS", 18);
        sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        psm3 = new MockPSM3();
        psm3.setRate(address(sUSDS), psmRate);
        sy = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usdc), address(usds), address(sUSDS), address(psm3))
            )
        );
    }

    // Variation point across call sites: `tokensPerShare` is the L2 stETH share-to-token ratio that
    // backs both the wrap math and the exchange-rate quote. Identity callers pass 1e18.
    function _deployL2WrappableWstEthSY(uint256 tokensPerShare)
        internal
        returns (address sy, MockToken wstETH, MockL2StETH l2StETH)
    {
        wstETH = new MockToken("wstETH", "wstETH", 18);
        l2StETH = new MockL2StETH(address(wstETH), tokensPerShare);
        sy = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeCall(
                OutrunL2WrappableWstETHSYUpgradeable.initialize,
                (owner, address(l2StETH), address(wstETH), address(l2StETH), 18)
            )
        );
    }

    function _deployL2Staked() internal returns (address) {
        OutrunL2StakedTokenSYUpgradeable impl = new OutrunL2StakedTokenSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunL2StakedTokenSYUpgradeable.initialize,
                ("SY Generic", "SYG", owner, address(token), address(oracle), address(token), 18)
            )
        );
    }

    function _deployWeETH() internal returns (address) {
        return _deployWeETHWith(new MockToken("eETH", "eETH", 18));
    }

    function _deployWeETHWith(MockToken eETH) internal returns (address) {
        OutrunWeETHSYUpgradeable impl = new OutrunWeETHSYUpgradeable();
        MockLiquidityPool pool = new MockLiquidityPool();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(token), address(new MockDepositAdapter()), address(pool))
            )
        );
    }

    function _deployWstETH() internal returns (address) {
        OutrunWstETHSYUpgradeable impl = new OutrunWstETHSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunWstETHSYUpgradeable.initialize,
                (owner, address(new MockToken("stETH", "stETH", 18)), address(token))
            )
        );
    }

    function _deployL2WstETH() internal returns (address) {
        OutrunL2WstETHSYUpgradeable impl = new OutrunL2WstETHSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunL2WstETHSYUpgradeable.initialize, (owner, address(token), address(oracle), address(token), 18)
            )
        );
    }

    function _deployL2WrappableWstETH() internal returns (address) {
        OutrunL2WrappableWstETHSYUpgradeable impl = new OutrunL2WrappableWstETHSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeWithSelector(
                OutrunL2WrappableWstETHSYUpgradeable.initialize.selector,
                owner,
                address(new MockToken("stETH", "stETH", 18)),
                address(token),
                address(token),
                18
            )
        );
    }

    function _deployEthena() internal returns (address) {
        OutrunStakedUSDeSYUpgradeable impl = new OutrunStakedUSDeSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunStakedUSDeSYUpgradeable.initialize,
                (owner, address(new MockToken("USDe", "USDe", 18)), address(token))
            )
        );
    }

    function _deploySky() internal returns (address) {
        OutrunStakedUsdsSYUpgradeable impl = new OutrunStakedUsdsSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunStakedUsdsSYUpgradeable.initialize,
                (owner, address(new MockToken("USDS", "USDS", 18)), address(token))
            )
        );
    }

    function _deploySkyL2() internal returns (address) {
        OutrunL2StakedUsdsSYUpgradeable impl = new OutrunL2StakedUsdsSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (
                    owner,
                    address(new MockToken("USDC", "USDC", 6)),
                    address(new MockToken("USDS", "USDS", 18)),
                    address(token),
                    address(new MockPSM3())
                )
            )
        );
    }

    function _deployLista() internal returns (address) {
        OutrunSlisBNBSYUpgradeable impl = new OutrunSlisBNBSYUpgradeable();
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunSlisBNBSYUpgradeable.initialize, (owner, address(token), address(new MockListaStakeManager()))
            )
        );
    }

    function _deployAster() internal returns (address) {
        OutrunAsBNBSYUpgradeable impl = new OutrunAsBNBSYUpgradeable();
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockToken slis = new MockToken("slisBNB", "slisBNB", 18);
        MockAsBnbMinter minter = new MockAsBnbMinter(address(token), address(slis), address(yieldProxy));
        return ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(OutrunAsBNBSYUpgradeable.initialize, (owner, address(token), address(slis), address(minter)))
        );
    }
}
