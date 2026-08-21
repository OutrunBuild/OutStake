// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

        assertEq(previewShares, 2);
        assertEq(sharesOut, 2);
        assertEq(sharesOut, previewShares);
        assertEq(sharesOut, scaledDelta);
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

    function testAaveUnderlyingDepositThatRoundsToZeroReverts() external {
        uint256 amount = 1;
        (address sy, MockToken underlying,) = _deployAave(3e27);

        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(sy, amount);
        vm.expectRevert(ScaledAmountIsZero.selector);
        _asSY(sy).deposit(user, address(underlying), amount, 0);
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
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        // The wrap step leaves the SY holding the wstETH backing for the minted shares.
        assertEq(wstETH.balanceOf(sy), sharesOut);
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
        assertEq(_asSY(lista).previewDeposit(NATIVE, AMOUNT), AMOUNT);
        assertEq(_asSY(lista).exchangeRate(), 1e18);

        address aster = _deployAster();
        _assertYieldTokenRoundtrip(aster, token, AMOUNT);
        assertEq(_asSY(aster).previewDeposit(NATIVE, AMOUNT), AMOUNT);
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
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedShares);
        assertEq(sharesOut, expectedShares);
        assertEq(sharesOut, previewShares);
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
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedShares);
        assertEq(sharesOut, expectedShares);
        assertEq(sharesOut, previewShares);
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
        slis.mint(user, AMOUNT);
        vm.startPrank(user);
        slis.approve(sy, AMOUNT);
        uint256 previewShares = _asSY(sy).previewDeposit(address(slis), AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit(user, address(slis), AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedShares);
        assertEq(sharesOut, expectedShares);
        assertEq(sharesOut, previewShares);
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
        // through the deposit adapter, which mints the quoted weETH amount to the SY, so preview ==
        // actual is non-tautological and the SY ends up holding real weETH backing.
        uint256 expectedShares = AMOUNT * 1e18 / rate;
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 previewShares = _asSY(sy).previewDeposit(NATIVE, AMOUNT);
        uint256 sharesOut = _asSY(sy).deposit{value: AMOUNT}(user, NATIVE, AMOUNT, 0);
        vm.stopPrank();

        assertEq(previewShares, expectedShares);
        assertEq(sharesOut, expectedShares);
        assertEq(sharesOut, previewShares);
        // The adapter-minted weETH backing sits on the SY, matching the fork-observed behaviour.
        assertEq(weETH.balanceOf(sy), sharesOut);
        assertEq(_asSY(sy).exchangeRate(), rate);
    }

    // ---------------------------------------------------------------------------
    // Rounding-direction property tests (docs/audits/2026-08-19/04a-guidelines-yield-libraries.md §4)
    //
    // P1 roundtrip bounded loss: deposit then immediately redeem the same token and assert the
    // output stays within the adapter's rounding quanta of the input. P2 preview bounds actual:
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
        MockToken wstETH = new MockToken("wstETH", "wstETH", 18);
        MockL2StETH l2StETH = new MockL2StETH(address(wstETH), tokensPerShare);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2WrappableWstETHSYUpgradeable()),
            abi.encodeCall(
                OutrunL2WrappableWstETHSYUpgradeable.initialize,
                (owner, address(l2StETH), address(wstETH), address(l2StETH), 18)
            )
        );

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
    }

    function testFuzz_SkyL2PsmUsdsRoundtripLosesAtMostTwoQuanta(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 2, 1_000_000 ether);
        uint256 rate = bound(rateSeed, 1e18, 2e18);
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockToken l2sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        MockPSM3 psm3 = new MockPSM3();
        psm3.setRate(address(l2sUSDS), rate);
        address sy = ProxyTestHelper.deploy(
            address(new OutrunL2StakedUsdsSYUpgradeable()),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usdc), address(usds), address(l2sUSDS), address(psm3))
            )
        );

        usds.mint(user, amount);
        vm.startPrank(user);
        usds.approve(sy, amount);
        uint256 shares = _asSY(sy).deposit(user, address(usds), amount, 0);
        uint256 out = _asSY(sy).redeem(user, shares, address(usds), 0, false);
        vm.stopPrank();

        // Both PSM3 legs are floors (into the share divides by rate, out of the share multiplies
        // by rate), so the swap roundtrip loses at most ceil(rate / 1e18) quanta — <= 2 at 2x.
        assertGe(out, amount - 2, "PSM3 USDS roundtrip loss exceeds two quanta");
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

        // The native path chains three floors (submit -> getPooledEthByShares -> wrap) against
        // the preview's single floor, so the executed output never exceeds the preview and stays
        // within one quantum below it while the rate stays >= 1x. The one-quantum bound is
        // proven on the mock's unified-rate model (pooledEthPerShare == stEthPerTokenRate); the
        // real-chain composite deviation keeps the adapter NatSpec guidance — callers leave
        // slippage headroom rather than passing the preview verbatim.
        assertLe(actual, preview, "native wstETH actual exceeds preview");
        assertGe(actual, preview - 1, "native wstETH preview overquotes actual by more than one quantum");
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

        // The native preview chains two extra floors (sharesForAmount -> amountForShare ->
        // sharesForAmount) against the deposit adapter's single floor, so the executed output
        // never falls below the preview and stays within one quantum above it.
        assertGe(actual, preview, "native weETH actual falls below preview");
        assertLe(actual, preview + 1, "native weETH preview underquotes actual by more than one quantum");
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

// ---------------------------------------------------------------------------
// SY adapter property suite (docs/audits/2026-08-19/05-invariants.md §2)
//
// Property tests promoted from the audit's SY-layer design: preview==actual on
// token paths (SY-3), absolute roundtrip loss at large amounts (SY-1b), Aave
// exchange-rate decimals independence (SY-4b), SY↔YBT decimals identity (SY-4c),
// and exchange-rate monotonicity via a handler invariant (SY-2).
// ---------------------------------------------------------------------------

/// @title SY adapter property tests (SY-3 / SY-1b / SY-4b / SY-4c)
/// @notice Stateless property tests for the SY adapter layer. Inherits the example suite above so
///     the `_deploy*` wiring helpers are reused directly instead of being duplicated.
contract SYAdapterPropertyTest is SYAdaptersUpgradeableTest {
    /// @notice [SY-3] previewDeposit/previewRedeem equal the executed deposit/redeem output on the
    ///     token paths: preview and execution quote through the same conversion source (k = 0).
    /// @dev Rates and the derived Aave ray index stay in the realistic [1x, 2x) appreciation band;
    ///      amounts sit at or above each path's dust threshold so the zero-share guard never fires.
    function testFuzz_PreviewMatchesActualOnTokenPaths(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 2, 1e24);
        uint256 rate = bound(rateSeed, 1e18, 2e18 - 1);
        // Ray index for the Aave scenarios. rate * 1e9 stays inside [1e27, 2e27), matching the
        // strictly-below-2x cap the aToken mock's ERC20/scaled accounting needs.
        uint256 index = rate * 1e9;

        // Aave underlying path: the preview runs calcSharesFromAssetHalfUp while execution measures
        // the pool supply's scaled-balance delta — the same half-up ray division, hence the equality.
        {
            (address sy, MockToken underlying,) = _deployAave(index);
            underlying.mint(user, amount);
            vm.startPrank(user);
            underlying.approve(sy, amount);
            uint256 previewShares = IStandardizedYield(sy).previewDeposit(address(underlying), amount);
            uint256 sharesOut = IStandardizedYield(sy).deposit(user, address(underlying), amount, 0);
            uint256 previewOut = IStandardizedYield(sy).previewRedeem(address(underlying), sharesOut);
            uint256 out = IStandardizedYield(sy).redeem(user, sharesOut, address(underlying), 0, false);
            vm.stopPrank();

            assertEq(sharesOut, previewShares, "Aave underlying previewDeposit != actual shares");
            assertEq(out, previewOut, "Aave underlying previewRedeem != actual out");
        }

        // Aave aToken path: preview and execution both run the half-up conversion locally.
        {
            (address sy,, MockAToken aToken) = _deployAave(index);
            aToken.mintScaled(user, amount);
            vm.startPrank(user);
            aToken.approve(sy, amount);
            uint256 previewShares = IStandardizedYield(sy).previewDeposit(address(aToken), amount);
            uint256 sharesOut = IStandardizedYield(sy).deposit(user, address(aToken), amount, 0);
            uint256 previewOut = IStandardizedYield(sy).previewRedeem(address(aToken), sharesOut);
            uint256 out = IStandardizedYield(sy).redeem(user, sharesOut, address(aToken), 0, false);
            vm.stopPrank();

            assertEq(sharesOut, previewShares, "Aave aToken previewDeposit != actual shares");
            assertEq(out, previewOut, "Aave aToken previewRedeem != actual out");
        }

        // wstETH stETH path: preview (getSharesByPooledEth / getPooledEthByShares) and execution
        // (wrap / unwrap) run the identical floor divisions on the mock's shared rate.
        {
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
            uint256 previewShares = IStandardizedYield(sy).previewDeposit(address(stETH), amount);
            uint256 sharesOut = IStandardizedYield(sy).deposit(user, address(stETH), amount, 0);
            uint256 previewOut = IStandardizedYield(sy).previewRedeem(address(stETH), sharesOut);
            uint256 out = IStandardizedYield(sy).redeem(user, sharesOut, address(stETH), 0, false);
            vm.stopPrank();

            assertEq(sharesOut, previewShares, "wstETH stETH previewDeposit != actual shares");
            assertEq(out, previewOut, "wstETH stETH previewRedeem != actual out");
        }

        // 4626 vault path (Sky form): preview delegates to vault previewDeposit/previewRedeem while
        // execution delegates to vault deposit/redeem — the same convertToShares/convertToAssets floors.
        {
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
            uint256 previewShares = IStandardizedYield(sy).previewDeposit(address(usds), amount);
            uint256 sharesOut = IStandardizedYield(sy).deposit(user, address(usds), amount, 0);
            uint256 previewOut = IStandardizedYield(sy).previewRedeem(address(usds), sharesOut);
            uint256 out = IStandardizedYield(sy).redeem(user, sharesOut, address(usds), 0, false);
            vm.stopPrank();

            assertEq(sharesOut, previewShares, "sUSDS vault previewDeposit != actual shares");
            assertEq(out, previewOut, "sUSDS vault previewRedeem != actual out");
        }
    }

    /// @notice [SY-1b] The deposit-then-redeem roundtrip loss stays an absolute quantum count at
    ///     large amounts — the bound must not scale with the amount (dust-scale property, not a fee).
    /// @dev 04a §1.1 conclusion (docs/audits/2026-08-19/04a-guidelines-yield-libraries.md): no
    ///      bidirectional rounding leak exists, so the double floor (convertToShares then
    ///      convertToAssets, wrap then unwrap) loses at most ceil(rate / 1e18) quanta — an absolute
    ///      bound of 2 quanta while the rate stays within 2x, independent of the amount.
    function testFuzz_LargeAmountRoundtripLossStaysAbsolute(uint128 amountSeed, uint96 rateSeed) external {
        uint256 amount = bound(amountSeed, 1e24, 1e30);
        uint256 rate = bound(rateSeed, 1e18, 2e18);

        // 4626 vault family (Sky form): usds -> deposit -> redeem usds.
        {
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
            uint256 shares = IStandardizedYield(sy).deposit(user, address(usds), amount, 0);
            uint256 out = IStandardizedYield(sy).redeem(user, shares, address(usds), 0, false);
            vm.stopPrank();

            assertGe(out, amount - 2, "sUSDS roundtrip loss scales with amount");
        }

        // wstETH family: stETH -> deposit(stETH) -> redeem(stETH) through wrap + unwrap.
        {
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
            uint256 shares = IStandardizedYield(sy).deposit(user, address(stETH), amount, 0);
            uint256 out = IStandardizedYield(sy).redeem(user, shares, address(stETH), 0, false);
            vm.stopPrank();

            assertGe(out, amount - 2, "wstETH stETH roundtrip loss scales with amount");
        }
    }

    /// @notice [SY-4b] Aave's exchangeRate() is the ray liquidity index divided by 1e9 — independent
    ///     of the underlying's decimals — and assetInfo() reports each deployment's own underlying.
    /// @dev Mock fidelity note: MockAToken hardcodes 18 decimals while real Aave aTokens share the
    ///      underlying's decimals; the adapter's scaled accounting never touches token decimals,
    ///      which is exactly the independence this property pins (the F-INFO-8 executable form).
    function testFuzz_AaveExchangeRateIsUnderlyingDecimalsIndependent(uint96 indexSeed) external {
        uint256 index = bound(indexSeed, 1e27, 2e27 - 1);

        (address sy18, MockToken underlying18,) = _deployAave(index);

        MockToken usdc = new MockToken("USDC", "USDC", 6);
        // MockToken discards its decimals constructor argument (OZ ERC20 hardcodes decimals() to 18),
        // so the 6-decimals shape is completed with a decimals() stub — the sanctioned way to obtain
        // a real 6-decimals underlying without editing the shared mocks file.
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
        MockAToken aToken6 = new MockAToken(address(usdc));
        MockAavePool pool6 = new MockAavePool();
        pool6.setReserve(address(usdc), aToken6, index);
        address sy6 = ProxyTestHelper.deploy(
            address(new OutrunAaveV3SYUpgradeable()),
            abi.encodeCall(
                OutrunAaveV3SYUpgradeable.initialize, ("SY Aave", "SYA", address(aToken6), address(pool6), owner)
            )
        );

        uint256 rate18 = IStandardizedYield(sy18).exchangeRate();
        uint256 rate6 = IStandardizedYield(sy6).exchangeRate();
        assertEq(rate18, index / 1e9, "18-decimals Aave exchangeRate != index / 1e9");
        assertEq(rate6, index / 1e9, "6-decimals Aave exchangeRate != index / 1e9");
        assertEq(rate18, rate6, "Aave exchangeRate depends on underlying decimals");

        (, address asset18, uint8 decimals18) = IStandardizedYield(sy18).assetInfo();
        (, address asset6, uint8 decimals6) = IStandardizedYield(sy6).assetInfo();
        assertEq(asset18, address(underlying18), "18-decimals assetInfo reports wrong underlying");
        assertEq(decimals18, 18, "18-decimals assetInfo reports wrong decimals");
        assertEq(asset6, address(usdc), "6-decimals assetInfo reports wrong underlying");
        assertEq(decimals6, 6, "6-decimals assetInfo reports wrong decimals");

        // 6-decimals underlying roundtrip: supply/withdraw operate on raw amounts, so the composed
        // half-up -> floor conversion loses at most one quantum regardless of the token's decimals.
        uint256 amount = 1_000_000e6;
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(sy6, amount);
        uint256 shares = IStandardizedYield(sy6).deposit(user, address(usdc), amount, 0);
        uint256 out = IStandardizedYield(sy6).redeem(user, shares, address(usdc), 0, false);
        vm.stopPrank();

        assertGe(out, amount - 1, "6-decimals Aave roundtrip loses more than one quantum");
    }

    /// @notice [SY-4c] SY decimals equal the yield-bearing token's decimals for every adapter — the
    ///     1:1 mint identity premise wired in SYBaseUpgradeable.__SYBase_init (deposit mints the
    ///     yield-bearing-token-domain amount verbatim as SY units).
    function test_SYDecimalsMatchYieldBearingTokenAcrossAdapters() external {
        (address aave,,) = _deployAave(1e27);
        address[] memory instances = new address[](11);
        instances[0] = _deployL2Staked();
        instances[1] = aave;
        instances[2] = _deployWeETH();
        instances[3] = _deployWstETH();
        instances[4] = _deployL2WstETH();
        instances[5] = _deployL2WrappableWstETH();
        instances[6] = _deployEthena();
        instances[7] = _deploySky();
        instances[8] = _deploySkyL2();
        instances[9] = _deployLista();
        instances[10] = _deployAster();

        for (uint256 i; i < instances.length; ++i) {
            assertEq(
                IERC20Metadata(instances[i]).decimals(),
                IERC20Metadata(IStandardizedYield(instances[i]).yieldBearingToken()).decimals(),
                "SY decimals must match yield-bearing token decimals"
            );
        }
    }
}

/// @title Invariant handler for SY exchange-rate monotonicity (SY-2)
/// @notice Deploys the seven deterministic-yield SY families and exposes two fuzzer entry points:
///     bumpRate (advance every family's rate knobs, never lower them) and warp (advance time). The
///     ghost arrays record the highest exchangeRate ever observed per adapter so the invariant test
///     can pin interval monotonicity (docs/audits/2026-08-19/05-invariants.md §2 SY-2).
/// @dev This is a model-level property: underlying-protocol rate monotonicity is assumption A-3 in
///      docs/audits/2026-08-19/04b-token-integration.md; what this property pins is the SY-layer
///      composition having no direction bug (e.g. one of Aster's two conversion hops wired backwards).
///      Negative space (do NOT "fix" by adding these families — they promise no monotonicity):
///      - The oracle families (OutrunL2StakedTokenSYUpgradeable / OutrunL2WstETHSYUpgradeable)
///        forward arbitrary oracle quotes verbatim (gaps G-1/G-2) — excluded.
///      - Sky L2 PSM3 embeds pool imbalance in its quoted rate (gap G-3) — excluded.
///      - MockL2StETH's TOKENS_PER_SHARE is an immutable constructor argument, so the L2 wrappable
///        wstETH family has a constant rate — excluded (no knob to fuzz).
contract SYRateMonotonicityHandler is Test {
    address internal owner = address(0xA11CE);

    // Family 1 — Aave: the knob is the pool's ray liquidity index; rate = index / 1e9.
    MockToken internal aaveUnderlying;
    MockAToken internal aaveAToken;
    MockAavePool internal aavePool;
    address internal aaveSy;

    // Family 2 — wstETH L1: two knobs move together (stETH.pooledEthPerShare must equal
    // wstETH.stEthPerToken for the mock's preview/wrap consistency); the rate reads the wstETH knob.
    MockStETH internal stETH;
    MockWstETH internal wstETH;
    address internal wstEthSy;

    // Family 3 — weETH: three knobs move together (the pool rate drives exchangeRate; weETH and
    // the deposit adapter must quote the same rate so the wrap/native paths stay consistent).
    MockWeETH internal weETH;
    MockLiquidityPool internal weEthPool;
    MockDepositAdapter internal weEthDepositAdapter;
    address internal weEthSy;

    // Family 4 — Ethena sUSDe (ERC-4626 vault): the vault's assetsPerShare is the only knob.
    MockVault internal sUSDe;
    address internal ethenaSy;

    // Family 5 — Sky sUSDS L1 (ERC-4626 vault): the vault's assetsPerShare is the only knob.
    MockVault internal sUSDS;
    address internal skySy;

    // Family 6 — Lista slisBNB: the stake-manager rate is BNB per slisBNB and must stay >= 1e18
    // (the adapter's init parity floor).
    MockListaStakeManager internal listaStakeManager;
    address internal listaSy;

    // Family 7 — Aster asBNB: the rate composes two hops (minter.convertToTokens then
    // stakeManager.convertSnBnbToBnb); each hop's knob is bumped on its own, monotonically.
    MockAsBnbMinter internal asBnbMinter;
    MockListaStakeManager internal asterStakeManager;
    address internal asterSy;

    // Ghosts: the deployed adapters and the highest exchangeRate ever observed for each.
    address[] public adapters;
    uint256[] public ghostLastRates;

    constructor() {
        // Aave.
        aaveUnderlying = new MockToken("Underlying", "UND", 18);
        aaveAToken = new MockAToken(address(aaveUnderlying));
        aavePool = new MockAavePool();
        aavePool.setReserve(address(aaveUnderlying), aaveAToken, 1e27);
        aaveSy = ProxyTestHelper.deploy(
            address(new OutrunAaveV3SYUpgradeable()),
            abi.encodeCall(
                OutrunAaveV3SYUpgradeable.initialize, ("SY Aave", "SYA", address(aaveAToken), address(aavePool), owner)
            )
        );
        adapters.push(aaveSy);

        // wstETH L1.
        stETH = new MockStETH();
        wstETH = new MockWstETH(address(stETH));
        wstEthSy = ProxyTestHelper.deploy(
            address(new OutrunWstETHSYUpgradeable()),
            abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(wstETH)))
        );
        adapters.push(wstEthSy);

        // weETH.
        MockToken eETH = new MockToken("eETH", "eETH", 18);
        weETH = new MockWeETH(address(eETH));
        weEthPool = new MockLiquidityPool();
        weEthDepositAdapter = new MockDepositAdapter();
        weEthSy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(weEthDepositAdapter), address(weEthPool))
            )
        );
        adapters.push(weEthSy);

        // Ethena sUSDe.
        MockToken usde = new MockToken("USDe", "USDe", 18);
        sUSDe = new MockVault(address(usde));
        ethenaSy = ProxyTestHelper.deploy(
            address(new OutrunStakedUSDeSYUpgradeable()),
            abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, address(usde), address(sUSDe)))
        );
        adapters.push(ethenaSy);

        // Sky sUSDS.
        MockToken usds = new MockToken("USDS", "USDS", 18);
        sUSDS = new MockVault(address(usds));
        skySy = ProxyTestHelper.deploy(
            address(new OutrunStakedUsdsSYUpgradeable()),
            abi.encodeCall(OutrunStakedUsdsSYUpgradeable.initialize, (owner, address(usds), address(sUSDS)))
        );
        adapters.push(skySy);

        // Lista slisBNB (stake manager starts at the 1e18 parity floor).
        MockToken slisBnb = new MockToken("slisBNB", "slisBNB", 18);
        listaStakeManager = new MockListaStakeManager();
        listaSy = ProxyTestHelper.deploy(
            address(new OutrunSlisBNBSYUpgradeable()),
            abi.encodeCall(OutrunSlisBNBSYUpgradeable.initialize, (owner, address(slisBnb), address(listaStakeManager)))
        );
        adapters.push(listaSy);

        // Aster asBNB.
        MockToken asBnb = new MockToken("asBNB", "asBNB", 18);
        MockToken asterSlis = new MockToken("slisBNB", "slisBNB", 18);
        asterStakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(asterStakeManager));
        asBnbMinter = new MockAsBnbMinter(address(asBnb), address(asterSlis), address(yieldProxy));
        asterSy = ProxyTestHelper.deploy(
            address(new OutrunAsBNBSYUpgradeable()),
            abi.encodeCall(
                OutrunAsBNBSYUpgradeable.initialize, (owner, address(asBnb), address(asterSlis), address(asBnbMinter))
            )
        );
        adapters.push(asterSy);

        // Ghost baseline: the first observation of every family's exchangeRate.
        for (uint256 i; i < adapters.length; ++i) {
            ghostLastRates.push(IStandardizedYield(adapters[i]).exchangeRate());
        }
    }

    /// @notice Advances every family's rate knobs upward by a fuzzed delta (bounded to [0, 1e18]),
    ///     capped at each family's domain ceiling, then records the observed exchangeRates.
    /// @dev Aave's knob is the ray index (domain [1e27, 5e27], rate = index / 1e9); every other
    ///      family turns a direct 1e18-scaled rate (domain [1e18, 5e18]). Knobs only ever rise.
    function bumpRate(uint256 deltaSeed) external {
        uint256 delta = bound(deltaSeed, 0, 1e18);

        // Aave: three-argument setReserve resets index and aToken transfer index together while
        // keeping the stored reserve references.
        aavePool.setReserve(address(aaveUnderlying), aaveAToken, _cappedNext(aavePool.index(), delta, 5e27));

        // wstETH L1: both knobs move to the same next rate.
        uint256 wstEthNext = _cappedNext(stETH.pooledEthPerShare(), delta, 5e18);
        stETH.setPooledEthPerShare(wstEthNext);
        wstETH.setStEthPerToken(wstEthNext);

        // weETH: all three knobs move to the same next rate.
        uint256 weEthNext = _cappedNext(weEthPool.shareRate(), delta, 5e18);
        weEthPool.setShareRate(weEthNext);
        weETH.setShareRate(weEthNext);
        weEthDepositAdapter.setShareRate(weEthNext);

        // ERC-4626 vaults.
        sUSDe.setAssetsPerShare(_cappedNext(sUSDe.assetsPerShare(), delta, 5e18));
        sUSDS.setAssetsPerShare(_cappedNext(sUSDS.assetsPerShare(), delta, 5e18));

        // Lista: BNB per slisBNB, kept >= 1e18 by construction (starts at parity, only rises).
        listaStakeManager.setRate(_cappedNext(listaStakeManager.rate(), delta, 5e18));

        // Aster: the two hops advance independently (each monotone) so the composition is exercised
        // asymmetrically — a lockstep pair could mask an inverted hop behind a constant rate. The
        // seed's high half drives the stake-manager hop while the full seed drives the minter hop.
        asBnbMinter.setRate(_cappedNext(asBnbMinter.rate(), delta, 5e18));
        asterStakeManager.setRate(_cappedNext(asterStakeManager.rate(), bound(deltaSeed >> 128, 0, 1e18), 5e18));

        // Record the post-bump observation into the ghosts. The ghost keeps the HIGHEST rate ever
        // observed (not merely the latest): "never decreases" must hold against every past
        // observation, and overwriting with a lower value would launder a direction bug inside
        // the very call that caused it.
        for (uint256 i; i < adapters.length; ++i) {
            uint256 observed = IStandardizedYield(adapters[i]).exchangeRate();
            if (observed > ghostLastRates[i]) ghostLastRates[i] = observed;
        }
    }

    /// @notice Advances block time; time alone must never move a deterministic-yield rate down.
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 365 days));
    }

    /// @notice Returns the deployed adapters under test.
    function getAdapters() external view returns (address[] memory) {
        return adapters;
    }

    /// @notice Returns the highest exchangeRate ever observed per adapter.
    function getGhostLastRates() external view returns (uint256[] memory) {
        return ghostLastRates;
    }

    function _cappedNext(uint256 current, uint256 delta, uint256 cap) private pure returns (uint256) {
        uint256 next = current + delta;
        return next > cap ? cap : next;
    }
}

/// @title SY exchange-rate monotonicity invariant test (SY-2)
/// @notice exchangeRate never decreases across arbitrary sequences of rate bumps and time warps
///     for the deterministic-yield families (docs/audits/2026-08-19/05-invariants.md §2 SY-2).
contract SYRateMonotonicityInvariantTest is StdInvariant, Test {
    SYRateMonotonicityHandler internal handler;

    function setUp() external {
        handler = new SYRateMonotonicityHandler();
        targetContract(address(handler));
    }

    function invariant_exchangeRateNeverDecreases() public view {
        address[] memory instances = handler.getAdapters();
        uint256[] memory lastRates = handler.getGhostLastRates();
        for (uint256 i; i < instances.length; ++i) {
            assertGe(
                IStandardizedYield(instances[i]).exchangeRate(),
                lastRates[i],
                "SY exchangeRate fell below a previously observed rate"
            );
        }
    }
}
