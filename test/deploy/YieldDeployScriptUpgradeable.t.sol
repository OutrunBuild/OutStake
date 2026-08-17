// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {YieldDeployScript} from "../../script/deploy/YieldDeployScript.s.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {OutrunAaveV3SYUpgradeable} from "../../src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol";
import {OutrunWstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol";
import {OutrunStakedUSDeSYUpgradeable} from "../../src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol";
import {
    YieldDeployMockToken,
    YieldDeployMockAToken,
    YieldDeployMockAavePool,
    YieldDeployMockUniversalAsset
} from "./mocks/YieldDeployMocks.sol";

contract YieldDeployScriptHarness is YieldDeployScript {
    function configure(address ueth, address uusd, address ubnb, address owner_, address revenuePool_, address keeper_)
        external
    {
        UETH = ueth;
        UUSD = uusd;
        UBNB = ubnb;
        owner = owner_;
        revenuePool = revenuePool_;
        keeper = keeper_;
    }

    function exposedSupportWstETHOnSepolia() external {
        _supportWstETHOnSepolia();
    }

    function exposedSupportSUSDeOnSepolia() external {
        _supportSUSDeOnSepolia();
    }

    function exposedSupportAUSDC() external {
        _supportAUSDC();
    }
}

contract YieldDeployScriptUpgradeableTest is Test {
    uint256 internal constant ETHEREUM_SEPOLIA_CHAINID = 11_155_111;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAINID = 421_614;
    uint256 internal constant BASE_SEPOLIA_CHAINID = 84_532;

    address internal owner = address(0xA11CE);
    address internal revenuePool = address(0xBEEF);
    address internal keeper = address(0xC0FFEE);

    YieldDeployScriptHarness internal script;
    YieldDeployMockUniversalAsset internal ueth;
    YieldDeployMockUniversalAsset internal uusd;
    YieldDeployMockUniversalAsset internal ubnb;

    function setUp() external {
        script = new YieldDeployScriptHarness();
        ueth = new YieldDeployMockUniversalAsset(address(script));
        uusd = new YieldDeployMockUniversalAsset(address(script));
        ubnb = new YieldDeployMockUniversalAsset(address(script));
        script.configure(address(ueth), address(uusd), address(ubnb), owner, revenuePool, keeper);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ETHEREUM_SEPOLIA_CHAINID", vm.toString(ETHEREUM_SEPOLIA_CHAINID));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ARBITRUM_SEPOLIA_CHAINID", vm.toString(ARBITRUM_SEPOLIA_CHAINID));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("BASE_SEPOLIA_CHAINID", vm.toString(BASE_SEPOLIA_CHAINID));
    }

    function testSupportWstETHOnSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(ETHEREUM_SEPOLIA_CHAINID);
        YieldDeployMockToken stETH = new YieldDeployMockToken("stETH", "stETH", 18);
        YieldDeployMockToken wstETH = new YieldDeployMockToken("wstETH", "wstETH", 18);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("SEPOLIA_STETH", vm.toString(address(stETH)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("SEPOLIA_WSTETH", vm.toString(address(wstETH)));

        (address sy, address sp) = _supportWstETHOnSepolia();

        OutrunWstETHSYUpgradeable wstETHSY = OutrunWstETHSYUpgradeable(payable(sy));
        assertEq(wstETHSY.owner(), owner);
        assertEq(wstETHSY.name(), "SY Lido wstETH");
        assertEq(wstETHSY.symbol(), "SY wstETH");
        assertEq(wstETHSY.stETH(), address(stETH));
        assertEq(wstETHSY.yieldBearingToken(), address(wstETH));
        _assertPosition(sp, sy, address(ueth));
        assertEq(ueth.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportSUSDeOnSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(ETHEREUM_SEPOLIA_CHAINID);
        YieldDeployMockToken usde = new YieldDeployMockToken("USDe", "USDe", 18);
        YieldDeployMockToken susde = new YieldDeployMockToken("sUSDe", "sUSDe", 18);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("SEPOLIA_USDE", vm.toString(address(usde)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("SEPOLIA_SUSDE", vm.toString(address(susde)));

        (address sy, address sp) = _supportSUSDeOnSepolia();

        OutrunStakedUSDeSYUpgradeable sUSDeSY = OutrunStakedUSDeSYUpgradeable(payable(sy));
        assertEq(sUSDeSY.owner(), owner);
        assertEq(sUSDeSY.name(), "SY Ethena sUSDe");
        assertEq(sUSDeSY.symbol(), "SY sUSDe");
        assertEq(sUSDeSY.usde(), address(usde));
        assertEq(sUSDeSY.yieldBearingToken(), address(susde));
        _assertPosition(sp, sy, address(uusd));
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportAUSDCOnBaseSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(BASE_SEPOLIA_CHAINID);
        (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool) = _setBaseAUSDCEnv();

        (address sy, address sp) = _supportAUSDC();

        _assertAUSDCSY(sy, address(usdc), address(aUSDC), address(pool));
        _assertPosition(sp, sy, address(uusd));
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportAUSDCOnArbitrumSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(ARBITRUM_SEPOLIA_CHAINID);
        (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool) = _setArbitrumAUSDCEnv();

        (address sy, address sp) = _supportAUSDC();

        _assertAUSDCSY(sy, address(usdc), address(aUSDC), address(pool));
        _assertPosition(sp, sy, address(uusd));
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportAUSDCOnUnsupportedChainNoOps() external {
        vm.chainId(1);
        NoOpState memory beforeState = _snapshotNoOpState();

        script.exposedSupportAUSDC();

        _assertNoOpStateUnchanged(beforeState);
    }

    function testSupportWstETHOnUnsupportedChainNoOps() external {
        vm.chainId(1);
        NoOpState memory beforeState = _snapshotNoOpState();

        script.exposedSupportWstETHOnSepolia();

        _assertNoOpStateUnchanged(beforeState);
    }

    function testSupportSUSDeOnUnsupportedChainNoOps() external {
        vm.chainId(1);
        NoOpState memory beforeState = _snapshotNoOpState();

        script.exposedSupportSUSDeOnSepolia();

        _assertNoOpStateUnchanged(beforeState);
    }

    function _supportWstETHOnSepolia() internal returns (address sy, address sp) {
        script.exposedSupportWstETHOnSepolia();
        sp = ueth.lastMinter();
        sy = OutrunStakingPositionUpgradeable(sp).SY();
    }

    function _supportSUSDeOnSepolia() internal returns (address sy, address sp) {
        script.exposedSupportSUSDeOnSepolia();
        sp = uusd.lastMinter();
        sy = OutrunStakingPositionUpgradeable(sp).SY();
    }

    function _supportAUSDC() internal returns (address sy, address sp) {
        script.exposedSupportAUSDC();
        sp = uusd.lastMinter();
        sy = OutrunStakingPositionUpgradeable(sp).SY();
    }

    function _assertAUSDCSY(address sy, address usdc, address aUSDC, address pool) internal {
        OutrunAaveV3SYUpgradeable aUSDCSY = OutrunAaveV3SYUpgradeable(payable(sy));
        assertEq(aUSDCSY.owner(), owner);
        assertEq(aUSDCSY.name(), "SY Aave aUSDC");
        assertEq(aUSDCSY.symbol(), "SY aUSDC");
        assertEq(aUSDCSY.underlying(), usdc);
        assertEq(aUSDCSY.yieldBearingToken(), aUSDC);
        assertEq(aUSDCSY.aavePool(), pool);
    }

    function _assertPosition(address sp, address sy, address uAsset) internal {
        OutrunStakingPositionUpgradeable position = OutrunStakingPositionUpgradeable(sp);
        assertEq(position.owner(), owner);
        assertEq(position.minStake(), 0);
        assertEq(position.revenuePool(), revenuePool);
        assertEq(position.SY(), sy);
        assertEq(position.uAsset(), uAsset);
        assertEq(position.keeper(), keeper);
    }

    function _setBaseAUSDCEnv()
        internal
        returns (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool)
    {
        (usdc, aUSDC, pool) = _newAaveMocks();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("BASE_SEPOLIA_AUSDC", vm.toString(address(aUSDC)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("BASE_SEPOLIA_POOL", vm.toString(address(pool)));
    }

    function _setArbitrumAUSDCEnv()
        internal
        returns (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool)
    {
        (usdc, aUSDC, pool) = _newAaveMocks();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ARBITRUM_SEPOLIA_AUSDC", vm.toString(address(aUSDC)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ARBITRUM_SEPOLIA_POOL", vm.toString(address(pool)));
    }

    function _newAaveMocks()
        internal
        returns (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool)
    {
        usdc = new YieldDeployMockToken("USDC", "USDC", 18);
        aUSDC = new YieldDeployMockAToken(address(usdc));
        pool = new YieldDeployMockAavePool();
    }

    struct AssetNoOpState {
        address lastMinter;
        uint256 lastMintingCap;
        uint256 capUpdateCount;
    }

    struct NoOpState {
        uint64 scriptNonce;
        AssetNoOpState ueth;
        AssetNoOpState uusd;
        AssetNoOpState ubnb;
    }

    function _snapshotNoOpState() internal view returns (NoOpState memory state) {
        state.scriptNonce = vm.getNonce(address(script));
        state.ueth = _snapshotAssetNoOpState(ueth);
        state.uusd = _snapshotAssetNoOpState(uusd);
        state.ubnb = _snapshotAssetNoOpState(ubnb);
    }

    function _snapshotAssetNoOpState(YieldDeployMockUniversalAsset asset)
        internal
        view
        returns (AssetNoOpState memory state)
    {
        state.lastMinter = asset.lastMinter();
        state.lastMintingCap = asset.lastMintingCap();
        state.capUpdateCount = asset.capUpdateCount();
    }

    function _assertNoOpStateUnchanged(NoOpState memory beforeState) internal {
        assertEq(vm.getNonce(address(script)), beforeState.scriptNonce);
        _assertAssetNoOpStateUnchanged(ueth, beforeState.ueth);
        _assertAssetNoOpStateUnchanged(uusd, beforeState.uusd);
        _assertAssetNoOpStateUnchanged(ubnb, beforeState.ubnb);
    }

    function _assertAssetNoOpStateUnchanged(YieldDeployMockUniversalAsset asset, AssetNoOpState memory beforeState)
        internal
    {
        assertEq(asset.lastMinter(), beforeState.lastMinter);
        assertEq(asset.lastMintingCap(), beforeState.lastMintingCap);
        assertEq(asset.capUpdateCount(), beforeState.capUpdateCount);
    }
}
