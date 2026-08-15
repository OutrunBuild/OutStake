// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IAaveV3Pool} from "../../src/integrations/aave/interfaces/IAaveV3Pool.sol";
import {IAToken} from "../../src/integrations/aave/interfaces/IAToken.sol";
import {IAsBnbMinter} from "../../src/integrations/aster/interfaces/IAsBnbMinter.sol";
import {IYieldProxy} from "../../src/integrations/aster/interfaces/IYieldProxy.sol";
import {ILiquidityPool} from "../../src/integrations/etherfi/interfaces/ILiquidityPool.sol";
import {IL2StETH} from "../../src/integrations/lido/interfaces/IL2StETH.sol";
import {IListaStakeManager} from "../../src/integrations/lista/interfaces/IListaStakeManager.sol";
import {IWstETH} from "../../src/integrations/lido/interfaces/IWstETH.sol";
import {IPSM3} from "../../src/integrations/sky/interfaces/IPSM3.sol";
import {IWETH} from "../../src/libraries/IWETH.sol";
import {OutrunAaveV3SYUpgradeable} from "../../src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol";
import {OutrunAsBNBSYUpgradeable} from "../../src/yield/adapters/aster/OutrunAsBNBSYUpgradeable.sol";
import {OutrunStakedUSDeSYUpgradeable} from "../../src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol";
import {OutrunWeETHSYUpgradeable} from "../../src/yield/adapters/etherfi/OutrunWeETHSYUpgradeable.sol";
import {
    OutrunL2WrappableWstETHSYUpgradeable
} from "../../src/yield/adapters/lido/OutrunL2WrappableWstETHSYUpgradeable.sol";
import {OutrunSlisBNBSYUpgradeable} from "../../src/yield/adapters/lista/OutrunSlisBNBSYUpgradeable.sol";
import {OutrunWstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol";
import {OutrunL2StakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol";
import {OutrunStakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunStakedUsdsSYUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";

contract SYAdaptersForkTest is Test {
    address internal constant OWNER = address(0xA11CE);
    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;
    uint256 internal constant BSC_MAINNET_FORK_BLOCK = 98_653_065;

    // Current live Lista stake manager on BSC mainnet.
    address internal constant STAKE_MANAGER_PROXY = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address internal constant EXPECTED_SLIS_BNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

    // Current live Aster asBNB minter wiring on BSC mainnet.
    address internal constant AS_BNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant AS_BNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;

    OutrunSlisBNBSYUpgradeable internal slisSy;
    OutrunAsBNBSYUpgradeable internal asBnbSy;
    address internal slisBnb;
    address internal asBnbYieldProxy;
    address internal asBnbStakeManager;

    function setUp() external {
        string memory bscRpc;
        try vm.envString("BSC_MAINNET_RPC") returns (string memory rpc) {
            bscRpc = rpc;
        } catch {
            vm.skip(true);
            return;
        }

        try vm.createSelectFork(bscRpc, BSC_MAINNET_FORK_BLOCK) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, BSC_MAINNET_CHAIN_ID);
        assertEq(block.number, BSC_MAINNET_FORK_BLOCK);

        assertGt(STAKE_MANAGER_PROXY.code.length, 0);
        assertGt(AS_BNB.code.length, 0);
        assertGt(AS_BNB_MINTER.code.length, 0);

        slisSy = _deploySlisSy();
        slisBnb = slisSy.yieldBearingToken();
        asBnbYieldProxy = IAsBnbMinter(AS_BNB_MINTER).yieldProxy();
        asBnbStakeManager = IYieldProxy(asBnbYieldProxy).stakeManager();
        asBnbSy = _deployAsBnbSy();
    }

    function testFork_SlisBnbLiveWiringMatchesMainnetAddress() external {
        assertEq(slisBnb, EXPECTED_SLIS_BNB);
        assertEq(IAsBnbMinter(AS_BNB_MINTER).token(), EXPECTED_SLIS_BNB);
    }

    function testFork_SlisBnbExchangeRateMatchesOnchainQuote() external {
        uint256 expected = IListaStakeManager(STAKE_MANAGER_PROXY).convertSnBnbToBnb(1 ether);
        assertEq(slisSy.exchangeRate(), expected);
    }

    function testFork_SlisBnbPreviewDepositNativeMatchesOnchainQuote() external {
        uint256 amount = 1 ether;
        uint256 expected = IListaStakeManager(STAKE_MANAGER_PROXY).convertBnbToSnBnb(amount);
        assertEq(slisSy.previewDeposit(address(0), amount), expected);
    }

    function testFork_SlisBnbPreviewDepositMatchesActualDeposit() external {
        uint256 amount = 1 ether;
        uint256 previewShares = slisSy.previewDeposit(address(0), amount);

        vm.deal(address(this), amount);
        uint256 actualShares = slisSy.deposit{value: amount}(address(this), address(0), amount, 0);

        assertEq(previewShares, actualShares);
        assertEq(slisSy.balanceOf(address(this)), actualShares);
    }

    function testFork_AsBnbLiveWiringMatchesMainnetAddress() external {
        assertEq(IAsBnbMinter(AS_BNB_MINTER).asBnb(), AS_BNB);
        assertEq(IAsBnbMinter(AS_BNB_MINTER).token(), EXPECTED_SLIS_BNB);
        assertEq(asBnbYieldProxy, asBnbSy.YIELD_PROXY());
        assertEq(asBnbStakeManager, STAKE_MANAGER_PROXY);
        assertEq(asBnbSy.STAKE_MANAGER(), STAKE_MANAGER_PROXY);
    }

    function testFork_AsBnbExchangeRateMatchesTwoHopQuote() external {
        uint256 slisBnbPerShare = IAsBnbMinter(AS_BNB_MINTER).convertToTokens(1 ether);
        uint256 expectedRate = IListaStakeManager(asBnbStakeManager).convertSnBnbToBnb(slisBnbPerShare);
        assertEq(asBnbSy.exchangeRate(), expectedRate);
    }

    function testFork_AsBnbPreviewDepositNativeMatchesTwoHopQuote() external {
        uint256 amount = 1 ether;
        uint256 slisQuote = IListaStakeManager(asBnbStakeManager).convertBnbToSnBnb(amount);
        uint256 expectedShares = IAsBnbMinter(AS_BNB_MINTER).convertToAsBnb(slisQuote);
        assertEq(asBnbSy.previewDeposit(address(0), amount), expectedShares);
    }

    function testFork_AsBnbPreviewDepositMatchesActualDeposit() external {
        assertFalse(IYieldProxy(asBnbSy.YIELD_PROXY()).activitiesOnGoing());

        uint256 amount = 1 ether;
        uint256 previewShares = asBnbSy.previewDeposit(address(0), amount);

        vm.deal(address(this), amount);
        uint256 actualShares = asBnbSy.deposit{value: amount}(address(this), address(0), amount, 0);

        assertEq(actualShares, previewShares);
        assertEq(asBnbSy.balanceOf(address(this)), actualShares);
    }

    function _deploySlisSy() internal returns (OutrunSlisBNBSYUpgradeable) {
        OutrunSlisBNBSYUpgradeable impl = new OutrunSlisBNBSYUpgradeable();
        return OutrunSlisBNBSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl),
                    abi.encodeCall(
                        OutrunSlisBNBSYUpgradeable.initialize, (OWNER, EXPECTED_SLIS_BNB, STAKE_MANAGER_PROXY)
                    )
                ))
        );
    }

    function _deployAsBnbSy() internal returns (OutrunAsBNBSYUpgradeable) {
        OutrunAsBNBSYUpgradeable impl = new OutrunAsBNBSYUpgradeable();
        // Read the live slisBNB token from the minter before deploying (fork state, not a constant).
        address slis = IAsBnbMinter(AS_BNB_MINTER).token();
        return OutrunAsBNBSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl),
                    abi.encodeCall(OutrunAsBNBSYUpgradeable.initialize, (OWNER, AS_BNB, slis, AS_BNB_MINTER))
                ))
        );
    }
}

// Shared Ethereum mainnet fork pin for the two mainnet fork contracts below. Declared once at file
// level so the contracts cannot drift apart: each setUp asserts its fork block against this value.
uint256 constant ETHEREUM_MAINNET_CHAIN_ID = 1;
uint256 constant ETHEREUM_MAINNET_FORK_BLOCK = 25_108_887;

contract SYAdaptersMainnetForkTest is Test {
    address internal constant OWNER = address(0xA11CE);

    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    OutrunAaveV3SYUpgradeable internal aaveSy;
    OutrunWstETHSYUpgradeable internal lidoSy;
    OutrunStakedUSDeSYUpgradeable internal ethenaSy;
    OutrunStakedUsdsSYUpgradeable internal skySy;

    function setUp() external {
        string memory mainnetRpc;
        try vm.envString("ETHEREUM_MAINNET_RPC") returns (string memory rpc) {
            mainnetRpc = rpc;
        } catch {
            vm.skip(true);
            return;
        }

        try vm.createSelectFork(mainnetRpc, ETHEREUM_MAINNET_FORK_BLOCK) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, ETHEREUM_MAINNET_CHAIN_ID);
        assertEq(block.number, ETHEREUM_MAINNET_FORK_BLOCK);

        assertGt(AAVE_POOL.code.length, 0);
        assertGt(A_WETH.code.length, 0);
        assertGt(WETH.code.length, 0);
        assertGt(STETH.code.length, 0);
        assertGt(WSTETH.code.length, 0);
        assertGt(USDE.code.length, 0);
        assertGt(SUSDE.code.length, 0);
        assertGt(USDS.code.length, 0);
        assertGt(SUSDS.code.length, 0);

        aaveSy = _deployAaveSy();
        lidoSy = _deployLidoSy();
        ethenaSy = _deployEthenaSy();
        skySy = _deploySkySy();
    }

    function testMainnetFork_AaveWethDepositMatchesLiveAave() external {
        uint256 amount = 0.1 ether;
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        vm.deal(address(this), amount);
        IWETH(WETH).deposit{value: amount}();
        IERC20(WETH).approve(address(aaveSy), amount);

        assertEq(aaveSy.yieldBearingToken(), A_WETH);
        assertEq(aaveSy.underlying(), WETH);
        assertEq(aaveSy.aavePool(), AAVE_POOL);
        assertEq(IAToken(A_WETH).UNDERLYING_ASSET_ADDRESS(), WETH);
        assertEq(aaveSy.exchangeRate(), IAaveV3Pool(AAVE_POOL).getReserveNormalizedIncome(WETH) / 1e9);

        uint256 scaledBefore = IAToken(A_WETH).scaledBalanceOf(address(aaveSy));
        uint256 previewShares = aaveSy.previewDeposit(WETH, amount);
        uint256 shares = aaveSy.deposit(address(this), WETH, amount, 0);
        uint256 scaledAfter = IAToken(A_WETH).scaledBalanceOf(address(aaveSy));
        assertApproxEqAbs(shares, previewShares, 1);
        assertEq(shares, scaledAfter - scaledBefore);
        assertEq(aaveSy.balanceOf(address(this)), shares);
        assertApproxEqAbs(IERC20(A_WETH).balanceOf(address(aaveSy)), amount, 2);

        uint256 previewRedeem = aaveSy.previewRedeem(WETH, shares);
        uint256 redeemed = aaveSy.redeem(address(this), shares, WETH, 0, false);
        assertEq(redeemed, previewRedeem);
        assertEq(aaveSy.balanceOf(address(this)), 0);
        assertEq(IAToken(A_WETH).scaledBalanceOf(address(aaveSy)), scaledBefore);
        assertEq(IERC20(WETH).balanceOf(address(this)) - wethBefore, redeemed);
    }

    function testMainnetFork_LidoNativeDepositAndRedeemToStEthMatchesLiveLido() external {
        uint256 amount = 0.1 ether;
        vm.deal(address(this), amount);

        assertEq(lidoSy.yieldBearingToken(), WSTETH);
        assertEq(lidoSy.STETH(), STETH);
        assertEq(lidoSy.exchangeRate(), IWstETH(WSTETH).stEthPerToken());

        uint256 previewShares = lidoSy.previewDeposit(address(0), amount);
        uint256 shares = lidoSy.deposit{value: amount}(address(this), address(0), amount, 0);
        assertApproxEqAbs(shares, previewShares, 1);
        assertEq(lidoSy.balanceOf(address(this)), shares);

        uint256 previewStEth = lidoSy.previewRedeem(STETH, shares);
        uint256 redeemed = lidoSy.redeem(address(this), shares, STETH, 0, false);
        assertApproxEqAbs(redeemed, previewStEth, 1);
        assertEq(lidoSy.balanceOf(address(this)), 0);
        assertApproxEqAbs(IERC20(STETH).balanceOf(address(this)), redeemed, 1);
    }

    function testMainnetFork_EthenaUSDeDepositMatchesLiveVault() external {
        uint256 amount = 100 ether;
        deal(USDE, address(this), amount);
        IERC20(USDE).approve(address(ethenaSy), amount);

        assertEq(ethenaSy.yieldBearingToken(), SUSDE);
        assertEq(ethenaSy.USDE(), USDE);
        assertEq(IERC4626(SUSDE).asset(), USDE);
        assertEq(ethenaSy.exchangeRate(), IERC4626(SUSDE).convertToAssets(1 ether));

        uint256 previewShares = ethenaSy.previewDeposit(USDE, amount);
        uint256 shares = ethenaSy.deposit(address(this), USDE, amount, 0);
        assertEq(shares, previewShares);
        assertEq(ethenaSy.balanceOf(address(this)), shares);
        assertEq(IERC20(SUSDE).balanceOf(address(ethenaSy)), shares);
    }

    function testMainnetFork_SkyUSDSDepositAndRedeemMatchesLiveVault() external {
        uint256 amount = 100 ether;
        deal(USDS, address(this), amount);
        IERC20(USDS).approve(address(skySy), amount);

        assertEq(skySy.yieldBearingToken(), SUSDS);
        assertEq(skySy.USDS(), USDS);
        assertEq(IERC4626(SUSDS).asset(), USDS);
        assertEq(skySy.exchangeRate(), IERC4626(SUSDS).convertToAssets(1 ether));

        uint256 previewShares = skySy.previewDeposit(USDS, amount);
        uint256 shares = skySy.deposit(address(this), USDS, amount, 0);
        assertEq(shares, previewShares);
        assertEq(skySy.balanceOf(address(this)), shares);
        assertEq(IERC20(SUSDS).balanceOf(address(skySy)), shares);

        uint256 previewAssets = skySy.previewRedeem(USDS, shares);
        uint256 redeemed = skySy.redeem(address(this), shares, USDS, 0, false);
        assertEq(redeemed, previewAssets);
        assertEq(skySy.balanceOf(address(this)), 0);
        assertEq(IERC20(USDS).balanceOf(address(this)), redeemed);
    }

    function _deployAaveSy() internal returns (OutrunAaveV3SYUpgradeable) {
        OutrunAaveV3SYUpgradeable impl = new OutrunAaveV3SYUpgradeable();
        return OutrunAaveV3SYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl),
                    abi.encodeCall(
                        OutrunAaveV3SYUpgradeable.initialize, ("SY Aave WETH", "SY aWETH", A_WETH, AAVE_POOL, OWNER)
                    )
                ))
        );
    }

    function _deployLidoSy() internal returns (OutrunWstETHSYUpgradeable) {
        OutrunWstETHSYUpgradeable impl = new OutrunWstETHSYUpgradeable();
        return OutrunWstETHSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl), abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (OWNER, STETH, WSTETH))
                ))
        );
    }

    function _deployEthenaSy() internal returns (OutrunStakedUSDeSYUpgradeable) {
        OutrunStakedUSDeSYUpgradeable impl = new OutrunStakedUSDeSYUpgradeable();
        return OutrunStakedUSDeSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl), abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (OWNER, USDE, SUSDE))
                ))
        );
    }

    function _deploySkySy() internal returns (OutrunStakedUsdsSYUpgradeable) {
        OutrunStakedUsdsSYUpgradeable impl = new OutrunStakedUsdsSYUpgradeable();
        return OutrunStakedUsdsSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl), abi.encodeCall(OutrunStakedUsdsSYUpgradeable.initialize, (OWNER, USDS, SUSDS))
                ))
        );
    }
}

contract SYAdaptersEtherfiMainnetForkTest is Test {
    address internal constant OWNER = address(0xA11CE);

    address internal constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant ETHERFI_DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address internal constant ETHERFI_LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;

    OutrunWeETHSYUpgradeable internal etherfiSy;

    function setUp() external {
        string memory mainnetRpc;
        try vm.envString("ETHEREUM_MAINNET_RPC") returns (string memory rpc) {
            mainnetRpc = rpc;
        } catch {
            vm.skip(true);
            return;
        }

        try vm.createSelectFork(mainnetRpc, ETHEREUM_MAINNET_FORK_BLOCK) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, ETHEREUM_MAINNET_CHAIN_ID);
        assertEq(block.number, ETHEREUM_MAINNET_FORK_BLOCK);

        assertGt(EETH.code.length, 0);
        assertGt(WEETH.code.length, 0);
        assertGt(ETHERFI_DEPOSIT_ADAPTER.code.length, 0);
        assertGt(ETHERFI_LIQUIDITY_POOL.code.length, 0);

        etherfiSy = _deployEtherfiSy();
    }

    function testMainnetFork_EtherfiWeEthDepositAndRedeemMatchesLiveQuote() external {
        uint256 amount = 0.1 ether;
        vm.deal(address(this), amount);

        assertEq(etherfiSy.yieldBearingToken(), WEETH);
        assertEq(etherfiSy.EETH(), EETH);
        assertEq(etherfiSy.DEPOSIT_ADAPTER(), ETHERFI_DEPOSIT_ADAPTER);
        assertEq(etherfiSy.LIQUIDITY_POOL(), ETHERFI_LIQUIDITY_POOL);
        assertEq(etherfiSy.exchangeRate(), ILiquidityPool(ETHERFI_LIQUIDITY_POOL).amountForShare(1 ether));

        uint256 eEthQuote = ILiquidityPool(ETHERFI_LIQUIDITY_POOL)
            .amountForShare(ILiquidityPool(ETHERFI_LIQUIDITY_POOL).sharesForAmount(amount));
        uint256 expectedShares = ILiquidityPool(ETHERFI_LIQUIDITY_POOL).sharesForAmount(eEthQuote);
        uint256 previewShares = etherfiSy.previewDeposit(address(0), amount);
        uint256 shares = etherfiSy.deposit{value: amount}(address(this), address(0), amount, 0);
        assertEq(previewShares, expectedShares);
        assertApproxEqAbs(shares, previewShares, 1);
        assertEq(etherfiSy.balanceOf(address(this)), shares);
        assertEq(IERC20(WEETH).balanceOf(address(etherfiSy)), shares);

        uint256 previewEEth = etherfiSy.previewRedeem(EETH, shares);
        uint256 redeemed = etherfiSy.redeem(address(this), shares, EETH, 0, false);
        assertEq(previewEEth, ILiquidityPool(ETHERFI_LIQUIDITY_POOL).amountForShare(shares));
        assertApproxEqAbs(redeemed, previewEEth, 1);
        assertEq(etherfiSy.balanceOf(address(this)), 0);
        assertApproxEqAbs(IERC20(EETH).balanceOf(address(this)), redeemed, 1);
    }

    function _deployEtherfiSy() internal returns (OutrunWeETHSYUpgradeable) {
        OutrunWeETHSYUpgradeable impl = new OutrunWeETHSYUpgradeable();
        return OutrunWeETHSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl),
                    abi.encodeCall(
                        OutrunWeETHSYUpgradeable.initialize,
                        (OWNER, EETH, WEETH, ETHERFI_DEPOSIT_ADAPTER, ETHERFI_LIQUIDITY_POOL)
                    )
                ))
        );
    }
}

contract SYAdaptersOptimismForkTest is Test {
    address internal constant OWNER = address(0xA11CE);
    uint256 internal constant OPTIMISM_MAINNET_CHAIN_ID = 10;
    uint256 internal constant OPTIMISM_MAINNET_FORK_BLOCK = 151_675_883;

    address internal constant L1_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant OP_WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address internal constant OP_STETH = 0x76A50b8c7349cCDDb7578c6627e79b5d99D24138;

    OutrunL2WrappableWstETHSYUpgradeable internal lidoL2Sy;

    function setUp() external {
        string memory optimismRpc;
        try vm.envString("OPTIMISM_MAINNET_RPC") returns (string memory rpc) {
            optimismRpc = rpc;
        } catch {
            vm.skip(true);
            return;
        }

        try vm.createSelectFork(optimismRpc, OPTIMISM_MAINNET_FORK_BLOCK) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, OPTIMISM_MAINNET_CHAIN_ID);
        assertEq(block.number, OPTIMISM_MAINNET_FORK_BLOCK);

        assertGt(OP_WSTETH.code.length, 0);
        assertGt(OP_STETH.code.length, 0);

        lidoL2Sy = _deployLidoL2Sy();
        // L1_STETH is an Ethereum mainnet address with no code on this L2 fork, so its wiring is
        // asserted through the adapter's stored assetInfo() rather than a code-length check.
        (, address l1Underlying,) = lidoL2Sy.assetInfo();
        assertEq(l1Underlying, L1_STETH);
    }

    function testOptimismFork_LidoL2WrappableWstEthMatchesLiveQuote() external {
        uint256 amount = 0.1 ether;
        deal(OP_WSTETH, address(this), amount);
        IERC20(OP_WSTETH).approve(address(lidoL2Sy), amount);

        assertEq(lidoL2Sy.yieldBearingToken(), OP_WSTETH);
        assertEq(lidoL2Sy.STETH(), OP_STETH);
        assertEq(lidoL2Sy.exchangeRate(), IL2StETH(OP_STETH).getTokensByShares(1 ether));

        uint256 previewShares = lidoL2Sy.previewDeposit(OP_WSTETH, amount);
        uint256 shares = lidoL2Sy.deposit(address(this), OP_WSTETH, amount, 0);
        assertEq(shares, previewShares);
        assertEq(lidoL2Sy.balanceOf(address(this)), shares);
        assertEq(IERC20(OP_WSTETH).balanceOf(address(lidoL2Sy)), shares);

        uint256 previewWstEth = lidoL2Sy.previewRedeem(OP_WSTETH, shares);
        uint256 redeemed = lidoL2Sy.redeem(address(this), shares, OP_WSTETH, 0, false);
        assertEq(redeemed, previewWstEth);
        assertEq(lidoL2Sy.balanceOf(address(this)), 0);
        assertEq(IERC20(OP_WSTETH).balanceOf(address(this)), redeemed);

        IERC20(OP_WSTETH).approve(address(lidoL2Sy), amount);
        uint256 sharesForStEthRedeem = lidoL2Sy.deposit(address(this), OP_WSTETH, amount, 0);
        uint256 stEthAmount = lidoL2Sy.redeem(address(this), sharesForStEthRedeem, OP_STETH, 0, false);
        uint256 previewSharesFromStEth = lidoL2Sy.previewDeposit(OP_STETH, stEthAmount);
        IERC20(OP_STETH).approve(address(lidoL2Sy), stEthAmount);
        uint256 sharesFromStEth = lidoL2Sy.deposit(address(this), OP_STETH, stEthAmount, 0);
        assertEq(previewSharesFromStEth, IL2StETH(OP_STETH).getSharesByTokens(stEthAmount));
        assertEq(sharesFromStEth, previewSharesFromStEth);
        assertEq(lidoL2Sy.balanceOf(address(this)), sharesFromStEth);

        uint256 previewStEth = lidoL2Sy.previewRedeem(OP_STETH, sharesFromStEth);
        uint256 redeemedStEth = lidoL2Sy.redeem(address(this), sharesFromStEth, OP_STETH, 0, false);
        assertEq(previewStEth, IL2StETH(OP_STETH).getTokensByShares(sharesFromStEth));
        assertEq(redeemedStEth, previewStEth);
        assertEq(lidoL2Sy.balanceOf(address(this)), 0);
        assertApproxEqAbs(IERC20(OP_STETH).balanceOf(address(this)), redeemedStEth, 1);
    }

    function _deployLidoL2Sy() internal returns (OutrunL2WrappableWstETHSYUpgradeable) {
        OutrunL2WrappableWstETHSYUpgradeable impl = new OutrunL2WrappableWstETHSYUpgradeable();
        return OutrunL2WrappableWstETHSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl),
                    abi.encodeCall(
                        OutrunL2WrappableWstETHSYUpgradeable.initialize, (OWNER, OP_STETH, OP_WSTETH, L1_STETH, 18)
                    )
                ))
        );
    }
}

contract SYAdaptersBaseForkTest is Test {
    address internal constant OWNER = address(0xA11CE);
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 internal constant BASE_MAINNET_FORK_BLOCK = 46_080_598;

    address internal constant BASE_PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant BASE_SUSDS = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;

    OutrunL2StakedUsdsSYUpgradeable internal skyL2Sy;

    function setUp() external {
        string memory baseRpc;
        try vm.envString("BASE_MAINNET_RPC") returns (string memory rpc) {
            baseRpc = rpc;
        } catch {
            vm.skip(true);
            return;
        }

        try vm.createSelectFork(baseRpc, BASE_MAINNET_FORK_BLOCK) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, BASE_MAINNET_CHAIN_ID);
        assertEq(block.number, BASE_MAINNET_FORK_BLOCK);

        assertGt(BASE_PSM3.code.length, 0);
        assertGt(BASE_USDC.code.length, 0);
        assertGt(BASE_USDS.code.length, 0);
        assertGt(BASE_SUSDS.code.length, 0);

        skyL2Sy = _deploySkyL2Sy();
    }

    function testBaseFork_SkyL2StakedUsdsMatchesLivePsmQuote() external {
        uint256 amount = 100 ether;
        deal(BASE_USDS, address(this), amount);
        IERC20(BASE_USDS).approve(address(skyL2Sy), amount);

        assertEq(skyL2Sy.yieldBearingToken(), BASE_SUSDS);
        assertEq(skyL2Sy.USDC(), BASE_USDC);
        assertEq(skyL2Sy.USDS(), BASE_USDS);
        assertEq(skyL2Sy.PSM3(), BASE_PSM3);
        assertEq(skyL2Sy.exchangeRate(), IPSM3(BASE_PSM3).previewSwapExactIn(BASE_SUSDS, BASE_USDS, 1 ether));

        uint256 previewShares = skyL2Sy.previewDeposit(BASE_USDS, amount);
        uint256 shares = skyL2Sy.deposit(address(this), BASE_USDS, amount, 0);
        assertEq(previewShares, IPSM3(BASE_PSM3).previewSwapExactIn(BASE_USDS, BASE_SUSDS, amount));
        assertEq(shares, previewShares);
        assertEq(skyL2Sy.balanceOf(address(this)), shares);
        assertEq(IERC20(BASE_SUSDS).balanceOf(address(skyL2Sy)), shares);

        uint256 previewUsds = skyL2Sy.previewRedeem(BASE_USDS, shares);
        uint256 redeemed = skyL2Sy.redeem(address(this), shares, BASE_USDS, 0, false);
        assertEq(previewUsds, IPSM3(BASE_PSM3).previewSwapExactIn(BASE_SUSDS, BASE_USDS, shares));
        assertEq(redeemed, previewUsds);
        assertEq(skyL2Sy.balanceOf(address(this)), 0);
        assertEq(IERC20(BASE_USDS).balanceOf(address(this)), redeemed);

        uint256 usdcAmount = 100e6;
        uint256 usdcBefore = IERC20(BASE_USDC).balanceOf(address(this));
        vm.prank(BASE_PSM3);
        IERC20(BASE_USDC).transfer(address(this), usdcAmount);
        IERC20(BASE_USDC).approve(address(skyL2Sy), usdcAmount);
        uint256 previewSharesFromUsdc = skyL2Sy.previewDeposit(BASE_USDC, usdcAmount);
        uint256 sharesFromUsdc = skyL2Sy.deposit(address(this), BASE_USDC, usdcAmount, 0);
        assertEq(previewSharesFromUsdc, IPSM3(BASE_PSM3).previewSwapExactIn(BASE_USDC, BASE_SUSDS, usdcAmount));
        assertEq(sharesFromUsdc, previewSharesFromUsdc);
        assertEq(skyL2Sy.balanceOf(address(this)), sharesFromUsdc);

        uint256 previewUsdc = skyL2Sy.previewRedeem(BASE_USDC, sharesFromUsdc);
        uint256 redeemedUsdc = skyL2Sy.redeem(address(this), sharesFromUsdc, BASE_USDC, 0, false);
        assertEq(previewUsdc, IPSM3(BASE_PSM3).previewSwapExactIn(BASE_SUSDS, BASE_USDC, sharesFromUsdc));
        assertEq(redeemedUsdc, previewUsdc);
        assertEq(skyL2Sy.balanceOf(address(this)), 0);
        assertEq(IERC20(BASE_USDC).balanceOf(address(this)) - usdcBefore, redeemedUsdc);
    }

    function _deploySkyL2Sy() internal returns (OutrunL2StakedUsdsSYUpgradeable) {
        OutrunL2StakedUsdsSYUpgradeable impl = new OutrunL2StakedUsdsSYUpgradeable();
        return OutrunL2StakedUsdsSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(impl),
                    abi.encodeCall(
                        OutrunL2StakedUsdsSYUpgradeable.initialize, (OWNER, BASE_USDC, BASE_USDS, BASE_SUSDS, BASE_PSM3)
                    )
                ))
        );
    }
}
