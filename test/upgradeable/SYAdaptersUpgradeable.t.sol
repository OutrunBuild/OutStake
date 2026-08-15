// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

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

        vm.expectRevert();
        ProxyTestHelper.deploy(
            address(impl), abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, address(stETH), address(0)))
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

    function testOracleSetterIsOwnerOnlyAndAffectsExchangeRate() external {
        address sy = _deployL2Staked();
        assertEq(_asSY(sy).exchangeRate(), 1.2e18);

        MockOracle newOracle = new MockOracle(1.5e18);
        vm.prank(address(0xB0B));
        vm.expectRevert();
        _asSY(sy).setExchangeRateOracle(address(newOracle));

        vm.prank(owner);
        _asSY(sy).setExchangeRateOracle(address(newOracle));

        assertEq(_asSY(sy).exchangeRateOracle(), address(newOracle));
        assertEq(_asSY(sy).exchangeRate(), 1.5e18);

        vm.prank(owner);
        vm.expectRevert();
        _asSY(sy).setExchangeRateOracle(address(0));
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
        address sy = ProxyTestHelper.deploy(
            address(new OutrunWeETHSYUpgradeable()),
            abi.encodeCall(
                OutrunWeETHSYUpgradeable.initialize,
                (owner, address(eETH), address(weETH), address(depositAdapter), address(pool))
            )
        );

        // Native ETH preview reduces to sharesForAmount(amount) at the pool rate; the deposit adapter
        // mints the same weETH amount, so preview == actual is non-tautological.
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
