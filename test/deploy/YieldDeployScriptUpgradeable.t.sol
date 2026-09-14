// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {YieldDeployScript} from "../../script/deploy/YieldDeployScript.s.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {OutrunAaveV3SYUpgradeable} from "../../src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol";
import {OutrunWstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol";
import {OutrunStakedUSDeSYUpgradeable} from "../../src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol";
import {OutrunSlisBNBSYUpgradeable} from "../../src/yield/adapters/lista/OutrunSlisBNBSYUpgradeable.sol";
import {
    YieldDeployMockToken,
    YieldDeployMockAToken,
    YieldDeployMockAavePool,
    YieldDeployMockUniversalAsset
} from "./mocks/YieldDeployMocks.sol";
import {SPDefaults} from "../../script/lib/SPDefaults.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {IListaStakeManager} from "../../src/integrations/lista/interfaces/IListaStakeManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract YieldDeployScriptHarness is YieldDeployScript {
    // --- injected config (overrides the script's env-read seams so tests never mutate process
    // --- env: forge runs tests concurrently and vm.setEnv writes race across tests) ---

    bool internal spCapSet;
    uint256 internal injectedSpCap;
    address internal injectedEnvUAsset;
    address internal injectedStETH;
    address internal injectedWstETH;
    address internal injectedUsde;
    address internal injectedSusde;
    address internal injectedSlisBNB;
    address internal injectedListaStakeManager;
    address internal injectedAUSDC;
    address internal injectedAavePool;
    address internal injectedRouter;

    function setSpMintingCap(uint256 mintingCap) external {
        spCapSet = true;
        injectedSpCap = mintingCap;
    }

    function setRouter(address router_) external {
        injectedRouter = router_;
    }

    function setDeployer(address deployer_) external {
        deployer = deployer_;
    }

    function setEnvUAsset(address uAsset) external {
        injectedEnvUAsset = uAsset;
    }

    function setUBNB(address ubnb_) external {
        UBNB = ubnb_;
    }

    function setWstETHOnSepoliaTokens(address stETH, address wstETH) external {
        injectedStETH = stETH;
        injectedWstETH = wstETH;
    }

    function setSusdeOnSepoliaTokens(address usde, address susde) external {
        injectedUsde = usde;
        injectedSusde = susde;
    }

    function setSlisBNBOnBscTestnetConfig(address slisBNB, address listaStakeManager) external {
        injectedSlisBNB = slisBNB;
        injectedListaStakeManager = listaStakeManager;
    }

    function setAusdcConfig(address aUSDC, address aavePool) external {
        injectedAUSDC = aUSDC;
        injectedAavePool = aavePool;
    }

    function exposedSpMintingCap() external view returns (uint256) {
        return _spMintingCap();
    }

    function _spMintingCap() internal view override returns (uint256) {
        return spCapSet ? injectedSpCap : super._spMintingCap();
    }

    function _uAssetFromEnv(string memory) internal view override returns (address) {
        return injectedEnvUAsset;
    }

    function _wstETHOnSepoliaTokens() internal view override returns (address, address) {
        return (injectedStETH, injectedWstETH);
    }

    function _susdeOnSepoliaTokens() internal view override returns (address, address) {
        return (injectedUsde, injectedSusde);
    }

    function _ausdcConfig() internal view override returns (address, address) {
        return (injectedAUSDC, injectedAavePool);
    }

    function _slisBNBOnBscTestnetConfig() internal view override returns (address, address) {
        return (injectedSlisBNB, injectedListaStakeManager);
    }

    function _routerAddress() internal view override returns (address) {
        return injectedRouter;
    }

    function configure(address ueth, address uusd, address owner_, address protocolTreasury_) external {
        UETH = ueth;
        UUSD = uusd;
        owner = owner_;
        protocolTreasury = protocolTreasury_;
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

    function exposedSupportSlisBNBOnBscTestnet() external {
        _supportSlisBNBOnBscTestnet();
    }

    function exposedDeploySP(address sy, address uAsset, uint8 family) external returns (address) {
        return _deploySP(sy, uAsset, family);
    }
}

contract YieldDeployScriptUpgradeableTest is Test {
    uint256 internal constant ETHEREUM_SEPOLIA_CHAINID = 11_155_111;
    uint256 internal constant BASE_SEPOLIA_CHAINID = 84_532;
    uint256 internal constant BSC_TESTNET_CHAINID = 97;

    /// @dev Lista StakeManager stand-in for the slisBNB entry: initialize only reads
    ///      convertSnBnbToBnb(1 ether) to enforce its at-or-above-parity guard, so a mocked
    ///      staticcall on a codeless address models every seam the tested path depends on.
    address internal constant LISTA_STAKE_MANAGER = address(0x51A5);

    address internal owner = address(0xA11CE);
    address internal protocolTreasury = address(0xBEEF);
    address internal router = address(0xCAFE);

    YieldDeployScriptHarness internal script;
    YieldDeployMockUniversalAsset internal ueth;
    YieldDeployMockUniversalAsset internal uusd;
    YieldDeployMockUniversalAsset internal ubnb;

    function setUp() external {
        // The unset-seam cap path falls through to the real process env (the production
        // default path this suite pins), so an ambient SP_MINTING_CAP export — a legitimate
        // ops override — would break every default-value assert below. Fail here with the
        // culprit named instead of an unrelated-looking red.
        assertFalse(vm.envExists("SP_MINTING_CAP"), "ambient SP_MINTING_CAP export breaks default-cap asserts");

        script = new YieldDeployScriptHarness();
        ueth = new YieldDeployMockUniversalAsset(address(script));
        uusd = new YieldDeployMockUniversalAsset(address(script));
        ubnb = new YieldDeployMockUniversalAsset(address(script));
        ueth.setSymbol("UETH");
        uusd.setSymbol("UUSD");
        ubnb.setSymbol("UBNB");
        // The script wires SY.trustedRouter itself, so it must own the SYs it deploys and pass
        // the broadcaster check: owner and deployer both point at the script contract.
        owner = address(script);
        script.configure(address(ueth), address(uusd), owner, protocolTreasury);
        script.setUBNB(address(ubnb));
        script.setDeployer(address(script));
        script.setRouter(router);

        // The only env writes left in this suite: identical constant values in every setUp, so
        // concurrent setUps cannot produce a divergent read (the skip gates consume these keys).
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ETHEREUM_SEPOLIA_CHAINID", vm.toString(ETHEREUM_SEPOLIA_CHAINID));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("BASE_SEPOLIA_CHAINID", vm.toString(BASE_SEPOLIA_CHAINID));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("BSC_TESTNET_CHAINID", vm.toString(BSC_TESTNET_CHAINID));
    }

    function testSupportWstETHOnSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(ETHEREUM_SEPOLIA_CHAINID);
        YieldDeployMockToken stETH = new YieldDeployMockToken("stETH", "stETH", 18);
        YieldDeployMockToken wstETH = new YieldDeployMockToken("wstETH", "wstETH", 18);
        script.setWstETHOnSepoliaTokens(address(stETH), address(wstETH));

        (address sy, address sp) = _supportWstETHOnSepolia();

        OutrunWstETHSYUpgradeable wstETHSY = OutrunWstETHSYUpgradeable(payable(sy));
        assertEq(wstETHSY.owner(), owner);
        assertEq(wstETHSY.name(), "SY Lido wstETH");
        assertEq(wstETHSY.symbol(), "SY wstETH");
        assertEq(wstETHSY.stETH(), address(stETH));
        assertEq(wstETHSY.yieldBearingToken(), address(wstETH));
        assertEq(wstETHSY.trustedRouter(), router);
        _assertPosition(sp, sy, address(ueth));
        assertEq(ueth.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportSUSDeOnSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(ETHEREUM_SEPOLIA_CHAINID);
        YieldDeployMockToken usde = new YieldDeployMockToken("USDe", "USDe", 18);
        YieldDeployMockToken susde = new YieldDeployMockToken("sUSDe", "sUSDe", 18);
        script.setSusdeOnSepoliaTokens(address(usde), address(susde));

        (address sy, address sp) = _supportSUSDeOnSepolia();

        OutrunStakedUSDeSYUpgradeable sUSDeSY = OutrunStakedUSDeSYUpgradeable(payable(sy));
        assertEq(sUSDeSY.owner(), owner);
        assertEq(sUSDeSY.name(), "SY Ethena sUSDe");
        assertEq(sUSDeSY.symbol(), "SY sUSDe");
        assertEq(sUSDeSY.usde(), address(usde));
        assertEq(sUSDeSY.yieldBearingToken(), address(susde));
        assertEq(sUSDeSY.trustedRouter(), router);
        _assertPosition(sp, sy, address(uusd));
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportAUSDCOnBaseSepoliaDeploysInitializedSYAndPosition() external {
        vm.chainId(BASE_SEPOLIA_CHAINID);
        (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool) = _setBaseAUSDCConfig();

        (address sy, address sp) = _supportAUSDC();

        _assertAUSDCSY(sy, address(usdc), address(aUSDC), address(pool));
        _assertPosition(sp, sy, address(uusd));
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportSlisBNBOnBscTestnetDeploysInitializedSYAndPosition() external {
        vm.chainId(BSC_TESTNET_CHAINID);
        YieldDeployMockToken slisBNB = new YieldDeployMockToken("slisBNB", "slisBNB", 18);
        script.setSlisBNBOnBscTestnetConfig(address(slisBNB), LISTA_STAKE_MANAGER);
        // initialize enforces the Lista at-or-above-parity guard via convertSnBnbToBnb(1 ether);
        // the mocked staticcall returns exact parity (the legal boundary) so initialization proceeds.
        vm.mockCall(
            LISTA_STAKE_MANAGER,
            abi.encodeWithSelector(IListaStakeManager.convertSnBnbToBnb.selector, 1 ether),
            abi.encode(1 ether)
        );

        (address sy, address sp) = _supportSlisBNBOnBscTestnet();

        OutrunSlisBNBSYUpgradeable slisBNBSY = OutrunSlisBNBSYUpgradeable(payable(sy));
        assertEq(slisBNBSY.owner(), owner);
        assertEq(slisBNBSY.name(), "SY Lista slisBNB");
        assertEq(slisBNBSY.symbol(), "SY slisBNB");
        assertEq(slisBNBSY.yieldBearingToken(), address(slisBNB));
        assertEq(slisBNBSY.stakeManager(), LISTA_STAKE_MANAGER);
        assertEq(slisBNBSY.trustedRouter(), router);
        _assertPosition(sp, sy, address(ubnb));
        assertEq(ubnb.mintingCaps(sp), 1_000_000_000 ether);
    }

    /// @dev A missing router must fail the support entry instead of shipping an SY whose router
    ///      redeem path is dead: a zero router reverts before the SP is deployed.
    function test_RevertWhen_SupportAUSDCWithZeroRouter() external {
        vm.chainId(BASE_SEPOLIA_CHAINID);
        _setBaseAUSDCConfig();
        script.setRouter(address(0));

        vm.expectRevert(YieldDeployScript.InvalidAddress.selector);
        script.exposedSupportAUSDC();
    }

    /// @dev The wiring is owner-only on the SY: a broadcast sender that is not the configured
    ///      owner fails closed instead of leaving the SY unwired.
    function test_RevertWhen_SupportAUSDCWithForeignBroadcaster() external {
        vm.chainId(BASE_SEPOLIA_CHAINID);
        _setBaseAUSDCConfig();
        script.setDeployer(address(0xB0B));

        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedSupportAUSDC();
    }

    /// @dev Race-free seam test for the SP minting-cap config: the injected cap wins when set and
    ///      the 1_000_000_000 ether placeholder default applies when unset (no env is touched —
    ///      forge runs tests concurrently and vm.setEnv writes race across tests). The call site
    ///      (`_deploySP` -> setMintingCap) is pinned by the default-value asserts above.
    function testSpMintingCapFollowsInjectionOverDefault() external {
        assertEq(script.exposedSpMintingCap(), 1_000_000_000 ether);

        script.setSpMintingCap(5_000_000 ether);

        assertEq(script.exposedSpMintingCap(), 5_000_000 ether);
    }

    /// @dev An unrecognized family id must fail closed before the SP is deployed: with no
    /// per-family duty dispatch, the first family check in `_deploySP` is `assertFamilyUAsset`,
    /// whose `familySymbol` reverts `InvalidFamilyUAsset` for an unknown id — no shared fallback
    /// may silently apply to an unsupported asset.
    function test_RevertWhen_DeploySPWithUnknownFamily() external {
        YieldDeployMockToken unknownSY = new YieldDeployMockToken("SY Unknown", "SYU", 18);

        vm.expectRevert(SPDefaults.InvalidFamilyUAsset.selector);
        script.exposedDeploySP(address(unknownSY), address(uusd), 0);
    }

    function test_RevertWhen_DeploySPWithMismatchedFamilyUAsset() external {
        YieldDeployMockToken sy = new YieldDeployMockToken("SY", "SY", 18);
        vm.expectRevert(SPDefaults.InvalidFamilyUAsset.selector);
        script.exposedDeploySP(address(sy), address(ueth), SPDefaults.FAMILY_AUSDC);
        vm.expectRevert(SPDefaults.InvalidFamilyUAsset.selector);
        script.exposedDeploySP(address(sy), address(uusd), SPDefaults.FAMILY_UETH);
        // A wrong-symbol uAsset reaches the family assert only if it passes the ownership
        // pre-checks first, so it must report an owner (a bare ERC20 does not).
        YieldDeployMockUniversalAsset badSymbolUAsset = new YieldDeployMockUniversalAsset(address(script));
        badSymbolUAsset.setSymbol("BAD");
        vm.expectRevert(SPDefaults.InvalidFamilyUAsset.selector);
        script.exposedDeploySP(address(sy), address(badSymbolUAsset), SPDefaults.FAMILY_UETH);
        // Non-contract EOA fails closed at the ownership pre-check (the owner() call decodes empty)
        vm.expectRevert();
        script.exposedDeploySP(address(sy), address(0xBEEF), SPDefaults.FAMILY_UETH);
    }

    function test_DeploySPWithMatchedFamilyUAssetSucceeds() external {
        // One SY per family: the SY must report the canonical symbol for its family.
        address uethSY = _mockSYWithSymbol("SY wstETH");
        address ausdcSY = _mockSYWithSymbol("SY aUSDC");
        address susdeSY = _mockSYWithSymbol("SY sUSDe");
        address susdsSY = _mockSYWithSymbol("SY sUSDS");
        address sp1 = script.exposedDeploySP(uethSY, address(ueth), SPDefaults.FAMILY_UETH);
        assertGt(sp1.code.length, 0);
        assertEq(OutrunStakingPositionUpgradeable(sp1).uAsset(), address(ueth));
        address sp2 = script.exposedDeploySP(ausdcSY, address(uusd), SPDefaults.FAMILY_AUSDC);
        assertGt(sp2.code.length, 0);
        assertEq(OutrunStakingPositionUpgradeable(sp2).uAsset(), address(uusd));
        address sp3 = script.exposedDeploySP(susdeSY, address(uusd), SPDefaults.FAMILY_SUSDE);
        assertGt(sp3.code.length, 0);
        address sp4 = script.exposedDeploySP(susdsSY, address(uusd), SPDefaults.FAMILY_SUSDS);
        assertGt(sp4.code.length, 0);
    }

    function test_RevertWhen_DeploySPWithMismatchedFamilySY() external {
        // sUSDe SY paired with the aUSDC family must revert instead of deploying.
        address susdeSY = _mockSYWithSymbol("SY sUSDe");
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, susdeSY));
        script.exposedDeploySP(susdeSY, address(uusd), SPDefaults.FAMILY_AUSDC);
        // Same-group cross the other way: aUSDC SY with the sUSDe family.
        address ausdcSY = _mockSYWithSymbol("SY aUSDC");
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, ausdcSY));
        script.exposedDeploySP(ausdcSY, address(uusd), SPDefaults.FAMILY_SUSDE);
        // Cross-group: wstETH SY with the aUSDC family.
        address uethSY = _mockSYWithSymbol("SY wstETH");
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, uethSY));
        script.exposedDeploySP(uethSY, address(uusd), SPDefaults.FAMILY_AUSDC);
        // An EOA as SY fails closed too: the call itself reverts without data before the
        // symbol comparison runs (same call-level behavior as the uAsset EOA precedent below).
        address noSymbolSY = address(0xBEEF);
        vm.expectRevert();
        script.exposedDeploySP(noSymbolSY, address(uusd), SPDefaults.FAMILY_AUSDC);
    }

    /// @dev A broadcast sender that is not the configured owner fails closed before any SP
    ///      artifact is created (same guard family as the trusted-router wiring).
    function test_RevertWhen_DeploySPWithForeignBroadcaster() external {
        address susdeSY = _mockSYWithSymbol("SY sUSDe");
        script.setDeployer(address(0xB0B));

        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedDeploySP(susdeSY, address(uusd), SPDefaults.FAMILY_SUSDE);
    }

    /// @dev The uAsset cap wiring is owner-only on the uAsset: a uAsset whose current owner is
    ///      not the configured owner reverts before the SP impl/proxy are created, leaving no
    ///      initialized orphan proxy behind.
    function test_RevertWhen_DeploySPWithForeignOwnedUAsset() external {
        YieldDeployMockUniversalAsset foreignUAsset = new YieldDeployMockUniversalAsset(address(0xB0B));
        foreignUAsset.setSymbol("UUSD");
        address susdeSY = _mockSYWithSymbol("SY sUSDe");

        // The mock's own setMintingCap reverts Unauthorized, so InvalidOwner pins the pre-check.
        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedDeploySP(susdeSY, address(foreignUAsset), SPDefaults.FAMILY_SUSDE);
    }

    /// @dev A zero uAsset address reverts at the pre-check with the stable family error instead
    ///      of a dataless revert from the ownership/symbol reads on a codeless target.
    function test_RevertWhen_DeploySPWithZeroUAsset() external {
        address susdeSY = _mockSYWithSymbol("SY sUSDe");

        vm.expectRevert(YieldDeployScript.InvalidAddress.selector);
        script.exposedDeploySP(susdeSY, address(0), SPDefaults.FAMILY_SUSDE);
    }

    /// @dev Generic ERC20 stand-in for an SY: stubs assetInfo (read by initialize) and the
    /// family symbol (read by the SY-to-family binding check).
    function _mockSYWithSymbol(string memory symbol_) internal returns (address) {
        YieldDeployMockToken sy = new YieldDeployMockToken("SY", "SY", 18);
        vm.mockCall(
            address(sy),
            abi.encodeWithSelector(IStandardizedYield.assetInfo.selector),
            abi.encode(IStandardizedYield.AssetType.TOKEN, address(0x123), uint8(18))
        );
        vm.mockCall(address(sy), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode(symbol_));
        return address(sy);
    }

    function testSupportAUSDCUsesEnvUUSDWhenUUSDStateIsZero() external {
        vm.chainId(BASE_SEPOLIA_CHAINID);
        script.configure(address(0), address(0), owner, protocolTreasury);
        YieldDeployMockUniversalAsset envUUSD = new YieldDeployMockUniversalAsset(address(script));
        envUUSD.setSymbol("UUSD");
        script.setEnvUAsset(address(envUUSD));
        (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool) = _setBaseAUSDCConfig();

        script.exposedSupportAUSDC();

        address sp = envUUSD.lastMinter();
        address sy = OutrunStakingPositionUpgradeable(sp).SY();
        _assertAUSDCSY(sy, address(usdc), address(aUSDC), address(pool));
        _assertPosition(sp, sy, address(envUUSD));
        assertEq(envUUSD.mintingCaps(sp), 1_000_000_000 ether);
    }

    function testSupportWstETHOnSepoliaUsesEnvUETHWhenUETHStateIsZero() external {
        vm.chainId(ETHEREUM_SEPOLIA_CHAINID);
        script.configure(address(0), address(0), owner, protocolTreasury);
        YieldDeployMockUniversalAsset envUETH = new YieldDeployMockUniversalAsset(address(script));
        envUETH.setSymbol("UETH");
        script.setEnvUAsset(address(envUETH));
        YieldDeployMockToken stETH = new YieldDeployMockToken("stETH", "stETH", 18);
        YieldDeployMockToken wstETH = new YieldDeployMockToken("wstETH", "wstETH", 18);
        script.setWstETHOnSepoliaTokens(address(stETH), address(wstETH));

        script.exposedSupportWstETHOnSepolia();

        address sp = envUETH.lastMinter();
        address sy = OutrunStakingPositionUpgradeable(sp).SY();
        OutrunWstETHSYUpgradeable wstETHSY = OutrunWstETHSYUpgradeable(payable(sy));
        assertEq(wstETHSY.owner(), owner);
        assertEq(wstETHSY.name(), "SY Lido wstETH");
        assertEq(wstETHSY.symbol(), "SY wstETH");
        assertEq(wstETHSY.stETH(), address(stETH));
        assertEq(wstETHSY.yieldBearingToken(), address(wstETH));
        assertEq(wstETHSY.trustedRouter(), router);
        _assertPosition(sp, sy, address(envUETH));
        assertEq(envUETH.mintingCaps(sp), 1_000_000_000 ether);
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

    function testSupportSlisBNBOnUnsupportedChainNoOps() external {
        vm.chainId(1);
        uint256 scriptNonceBefore = vm.getNonce(address(script));
        AssetNoOpState memory ubnbBefore = _snapshotAssetNoOpState(ubnb);

        script.exposedSupportSlisBNBOnBscTestnet();

        assertEq(vm.getNonce(address(script)), scriptNonceBefore);
        _assertAssetNoOpStateUnchanged(ubnb, ubnbBefore);
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

    function _supportSlisBNBOnBscTestnet() internal returns (address sy, address sp) {
        script.exposedSupportSlisBNBOnBscTestnet();
        sp = ubnb.lastMinter();
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
        assertEq(aUSDCSY.trustedRouter(), router);
    }

    function _assertPosition(address sp, address sy, address uAsset) internal {
        OutrunStakingPositionUpgradeable position = OutrunStakingPositionUpgradeable(sp);
        assertEq(position.owner(), owner);
        assertEq(position.minStake(), 1);
        assertEq(position.protocolTreasury(), protocolTreasury);
        // v1 deploys every family at the zero-fee sentinel (no liquidation surface, no multipliers).
        assertEq(position.duty(), SPDefaults.SP_DEFAULT_DUTY);
        assertEq(position.genesisLauncher(), address(0), "genesis launcher unwired (entry disabled)");
        assertEq(position.SY(), sy);
        assertEq(position.uAsset(), uAsset);
    }

    function _setBaseAUSDCConfig()
        internal
        returns (YieldDeployMockToken usdc, YieldDeployMockAToken aUSDC, YieldDeployMockAavePool pool)
    {
        (usdc, aUSDC, pool) = _newAaveMocks();
        script.setAusdcConfig(address(aUSDC), address(pool));
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
    }

    function _snapshotNoOpState() internal view returns (NoOpState memory state) {
        state.scriptNonce = vm.getNonce(address(script));
        state.ueth = _snapshotAssetNoOpState(ueth);
        state.uusd = _snapshotAssetNoOpState(uusd);
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
    }

    function _assertAssetNoOpStateUnchanged(YieldDeployMockUniversalAsset asset, AssetNoOpState memory beforeState)
        internal
    {
        assertEq(asset.lastMinter(), beforeState.lastMinter);
        assertEq(asset.lastMintingCap(), beforeState.lastMintingCap);
        assertEq(asset.capUpdateCount(), beforeState.capUpdateCount);
    }
}
