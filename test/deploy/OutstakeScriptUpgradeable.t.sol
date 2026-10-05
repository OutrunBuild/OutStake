// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {SPDefaults} from "../../script/lib/SPDefaults.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunOFTUpgradeable} from "../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {OutrunUSRVaultUpgradeable} from "../../src/usr/OutrunUSRVaultUpgradeable.sol";
import {MockLzEndpoint} from "../upgradeable/mocks/OFTMocks.sol";
import {EmptyMockLauncher} from "../upgradeable/mocks/EmptyMockLauncher.sol";
import {MockUSDC} from "../support/mocks/MockUSDC.sol";
import {DeterministicCreate2FactoryMock} from "./mocks/DeterministicCreate2FactoryMock.sol";
import {RouterConfigInjectionHarness} from "./mocks/RouterConfigInjectionHarness.sol";

contract OutstakeDeploymentScriptHarness is OutstakeScript {
    uint256 internal rawLimit = 1_000_000 ether;
    uint256 internal rawWindow = 1 hours;

    function configure(address owner_, address deployer_, address outrunDeployer_) external {
        owner = owner_;
        deployer = deployer_;
        outrunDeployer = outrunDeployer_;
    }

    function setEndpoint(uint32 chainId, address endpoint) external {
        endpoints[chainId] = endpoint;
    }

    function setEndpointId(uint32 chainId, uint32 endpointId) external {
        endpointIds[chainId] = endpointId;
    }

    function setRawRateLimit(uint256 limit, uint256 window) external {
        rawLimit = limit;
        rawWindow = window;
    }

    function setRouterConfig(address outrunRouter_, address memeverseLauncher_) external {
        outrunRouter = outrunRouter_;
        memeverseLauncher = memeverseLauncher_;
    }

    function exposedDeployUETH(uint256 nonce) external {
        _deployUETH(nonce);
    }

    function exposedDeployUUSD(uint256 nonce) external {
        _deployUUSD(nonce);
    }

    function exposedDeployUBNB(uint256 nonce) external {
        _deployUBNB(nonce);
    }

    function exposedDeployUETHPSM(uint256 nonce) external {
        _deployUETHPSM(nonce);
    }

    function exposedDeployUUSDPSM(uint256 nonce) external {
        _deployUUSDPSM(nonce);
    }

    function exposedDeployUBNBPSM(uint256 nonce) external {
        _deployUBNBPSM(nonce);
    }

    function exposedDeploySuETH(uint256 nonce) external {
        _deploySuETH(nonce);
    }

    function exposedDeploySuUSD(uint256 nonce) external {
        _deploySuUSD(nonce);
    }

    function exposedDeploySuBNB(uint256 nonce) external {
        _deploySuBNB(nonce);
    }

    function exposedRegisterPOLendMinter(string memory symbol, bool isUBNB) external {
        _registerPOLendMinter(symbol, isUBNB);
    }

    function exposedValidatedMintingCap(uint256 cap) external pure returns (uint256) {
        return SPDefaults.validatedMintingCap(cap);
    }

    function exposedPolendMintingCap(string memory symbol, bool isUBNB) external view returns (uint256) {
        return _polendMintingCap(symbol, isUBNB);
    }

    function exposedDeployOutrunRouter(uint256 nonce) external {
        _deployOutrunRouter(nonce);
    }

    function exposedUpdateRouterLauncher() external {
        _updateRouterLauncher();
    }

    function exposedAssertOutrunDeployer(uint256 nonce) external {
        _assertOutrunDeployer(nonce);
    }

    function exposedAssertUAssetOmnichainConfig(
        address uAsset,
        uint32 endpointId,
        bytes32 peer,
        uint192 outboundRateLimit,
        uint64 outboundRateWindow
    ) external view {
        _assertUAssetOmnichainConfig(uAsset, endpointId, peer, outboundRateLimit, outboundRateWindow);
    }

    function exposedDeployOutrunDeployer(uint256 nonce) external returns (address) {
        return _deployOutrunDeployer(nonce);
    }

    function exposedCanonicalCreate2Factory() external pure returns (address) {
        return CANONICAL_CREATE2_FACTORY;
    }

    function _rawOutboundRateLimitConfig(string memory, string memory)
        internal
        view
        override
        returns (uint256 limit, uint256 window)
    {
        return (rawLimit, rawWindow);
    }

    // --- wiring-config injection (overrides the script's env-read seams so tests never mutate
    // --- process env: forge runs tests concurrently and vm.setEnv writes race across tests) ---

    address internal injectedFamilyUAsset;
    uint256 internal injectedStockCap;
    bool internal psmFeesSet;
    uint256 internal injectedTin;
    uint256 internal injectedTout;
    address internal injectedUsdc;
    address internal injectedUsdt;
    address internal injectedFeeRecipient;
    address internal injectedPolendMinter;
    bool internal polendCapSet;
    uint256 internal injectedPolendCap;

    function setFamilyUAsset(address uAsset) external {
        injectedFamilyUAsset = uAsset;
    }

    function setPSMCaps(uint256 stockCap) external {
        injectedStockCap = stockCap;
    }

    function setPSMFees(uint256 tin, uint256 tout) external {
        psmFeesSet = true;
        injectedTin = tin;
        injectedTout = tout;
    }

    function setPSMFeeRecipient(address feeRecipient) external {
        injectedFeeRecipient = feeRecipient;
    }

    function setUusdReserves(address usdc, address usdt) external {
        injectedUsdc = usdc;
        injectedUsdt = usdt;
    }

    function setPolendMinter(address minter) external {
        injectedPolendMinter = minter;
    }

    function setPolendMintingCap(uint256 mintingCap) external {
        polendCapSet = true;
        injectedPolendCap = mintingCap;
    }

    function _familyUAssetAddress(string memory) internal view override returns (address) {
        return injectedFamilyUAsset;
    }

    function _psmCapsConfig(string memory) internal view override returns (uint256) {
        return injectedStockCap;
    }

    /// @dev Unset fees fall through to the script's envOr path so the 0.1% launch default stays
    ///      covered (no test ever writes PSM_TIN / PSM_TOUT, so the read is race-free).
    function _psmFeesConfig() internal view override returns (uint256, uint256) {
        return psmFeesSet ? (injectedTin, injectedTout) : super._psmFeesConfig();
    }

    function _psmFeeRecipientConfig() internal view override returns (address) {
        return injectedFeeRecipient;
    }

    function _uusdReserveTokens() internal view override returns (address, address) {
        return (injectedUsdc, injectedUsdt);
    }

    function _polendMinterAddress() internal view override returns (address) {
        return injectedPolendMinter;
    }

    /// @dev An unset injected cap falls through to the script's envOr path so the per-family
    ///      defaults (including the small UBNB launch cap) stay covered without env.
    function _polendMintingCap(string memory symbol, bool isUBNB) internal view override returns (uint256) {
        return polendCapSet ? injectedPolendCap : super._polendMintingCap(symbol, isUBNB);
    }

    // Neutralize the chain endpoint/EID env reads: uAsset deploy tests populate the endpoints /
    // endpointIds maps via setEndpoint / setEndpointId and must not hit real env reads now that
    // `_deployUAsset` loads them via `_chainsInit`.
    function _chainsInit() internal override {}
}

/// @dev Run-path harness that deliberately does NOT override `_chainsInit`, so the Router-only
/// `run()` regression test exercises the real chain endpoint/EID env reads. This keeps the
/// `_chainsInit` no-op override above scoped to the uAsset deploy tests that populate the
/// endpoints/endpointIds maps via test setters.
contract OutstakeScriptRunHarness is RouterConfigInjectionHarness {
    function configureRun(uint256 nonce) external returns (address) {
        owner = address(this);
        deployer = address(this);
        return _deployOutrunDeployer(nonce);
    }

    function exposedCanonicalCreate2Factory() external pure returns (address) {
        return CANONICAL_CREATE2_FACTORY;
    }
}

contract OutstakeScriptUpgradeableTest is Test {
    uint32 internal constant LOCAL_CHAIN_ID = 97;
    uint32 internal constant LOCAL_EID = 40_102;

    // First-principles address of the canonical deterministic-deployment proxy (Arachnid): it was
    // deployed by key 0x3fab...5362 as that account's nonce-0 transaction, so its address is
    // keccak256(RLP([deployer, nonce]))[12:]. RLP bytes: 0xd6 = list of 22 payload bytes, 0x94 =
    // 20-byte address, 0x80 = integer 0 encoded as an empty string.
    address internal constant DERIVED_CANONICAL_CREATE2_FACTORY =
        address(uint160(uint256(keccak256(hex"d6943fab184622dc19b6109349b94811493bf2a4536280"))));

    address internal owner;

    OutstakeDeploymentScriptHarness internal script;
    OutrunDeployer internal outrunDeployer;
    MockLzEndpoint internal endpoint;
    // UUSD-family ERC20 reserve stand-ins registered by the PSM wiring tests.
    MockUSDC internal wiringUSDC;
    MockUSDC internal wiringUSDT;
    // Fee-sweep recipient injected into every PSM instance the wiring tests deploy.
    address internal wiringFeeRecipient;

    uint32[] internal chainIds;
    uint32[] internal endpointIds;

    function setUp() external {
        // The POLend family-cap defaults test leaves UETH/UBNB on the env fall-through path
        // (`_polendMintingCap` reads <SYMBOL>_POLEND_MINTING_CAP), so an ambient export of
        // either ops key would break the family-default asserts below. Fail here with the
        // culprit named instead of an unrelated-looking red.
        assertFalse(
            vm.envExists("UETH_POLEND_MINTING_CAP"), "ambient UETH_POLEND_MINTING_CAP export breaks family-cap asserts"
        );
        assertFalse(
            vm.envExists("UBNB_POLEND_MINTING_CAP"), "ambient UBNB_POLEND_MINTING_CAP export breaks family-cap asserts"
        );
        // The PSM deploy tests leave fees on the env fall-through path (`_psmFeesConfig` reads
        // PSM_TIN / PSM_TOUT with the 0.1% launch default), so an ambient export of either
        // ops key would break the default-fee asserts below. Fail here with the culprit named.
        assertFalse(vm.envExists("PSM_TIN"), "ambient PSM_TIN export breaks default-fee asserts");
        assertFalse(vm.envExists("PSM_TOUT"), "ambient PSM_TOUT export breaks default-fee asserts");

        vm.chainId(LOCAL_CHAIN_ID);

        script = new OutstakeDeploymentScriptHarness();
        owner = address(script);
        outrunDeployer = new OutrunDeployer(address(script));
        endpoint = new MockLzEndpoint();
        endpoint.setEid(LOCAL_EID);

        script.configure(owner, owner, address(outrunDeployer));

        _pushChain(97, LOCAL_EID);
        _pushChain(84532, 40_245);
        _pushChain(11155111, 40_161);
    }

    function testDeployUETHUUSDAndUBNBCreateInitializedProxiesAndConfigureRemoteOmnichainState() external {
        _deployAndAssertUAsset("ETH", "Omnichain Universal Assets ETH", "UETH", 1);
        _deployAndAssertUAsset("USD", "Omnichain Universal Assets USD", "UUSD", 1);
        _deployAndAssertUAsset("BNB", "Omnichain Universal Assets BNB", "UBNB", 1);
    }

    /// @dev The post-deploy omnichain assertion must catch an owner-drifted remote peer: a peer
    ///      that no longer matches the shared uAsset identity is a wiring break, not a config choice.
    function testAssertUAssetOmnichainConfigRevertsWhenPeerDriftsAfterDeploy() external {
        _deployAndAssertUAsset("ETH", "Omnichain Universal Assets ETH", "UETH", 1);
        OutrunUniversalAssetsUpgradeable uAsset = OutrunUniversalAssetsUpgradeable(
            outrunDeployer.getDeployed(
                address(script), keccak256(abi.encodePacked("OmnichainUniversalAssetsETH", uint256(1)))
            )
        );
        bytes32 expectedPeer = bytes32(uint256(uint160(address(uAsset))));

        vm.prank(owner);
        OutrunOFTUpgradeable(address(uAsset)).setPeer(40_245, bytes32(uint256(uint160(address(0xB0B)))));

        vm.expectRevert(OutstakeScript.InvalidOmnichainConfig.selector);
        script.exposedAssertUAssetOmnichainConfig(address(uAsset), 40_245, expectedPeer, 1_000_000 ether, 1 hours);
    }

    /// @dev Removing a remote outbound rate limit after deployment must also fail the assertion:
    ///      the mesh was deployed with a per-eid limit, so its absence is a regression.
    function testAssertUAssetOmnichainConfigRevertsWhenRateLimitIsRemovedAfterDeploy() external {
        _deployAndAssertUAsset("ETH", "Omnichain Universal Assets ETH", "UETH", 1);
        OutrunUniversalAssetsUpgradeable uAsset = OutrunUniversalAssetsUpgradeable(
            outrunDeployer.getDeployed(
                address(script), keccak256(abi.encodePacked("OmnichainUniversalAssetsETH", uint256(1)))
            )
        );
        bytes32 expectedPeer = bytes32(uint256(uint160(address(uAsset))));

        vm.prank(owner);
        OutrunOFTUpgradeable(address(uAsset)).removeOutboundRateLimit(40_245);

        vm.expectRevert(OutstakeScript.InvalidOmnichainConfig.selector);
        script.exposedAssertUAssetOmnichainConfig(address(uAsset), 40_245, expectedPeer, 1_000_000 ether, 1 hours);
    }

    function testDeployUAssetRevertsWhenOwnerDoesNotMatchDeployer() external {
        _configureEndpoints();
        script.configure(address(0xA11CE), address(0xB0B), address(outrunDeployer));

        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenOutboundRateLimitIsZero() external {
        _configureEndpoints();
        script.setRawRateLimit(0, 1 hours);

        vm.expectRevert(OutstakeScript.InvalidOutboundRateLimit.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenOutboundRateWindowIsZero() external {
        _configureEndpoints();
        script.setRawRateLimit(1_000_000 ether, 0);

        vm.expectRevert(OutstakeScript.InvalidOutboundRateWindow.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenLocalEndpointIsInvalid() external {
        _configureEndpointIds();

        vm.expectRevert(OutstakeScript.InvalidEndpoint.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenLocalEndpointHasNoCode() external {
        script.setEndpoint(LOCAL_CHAIN_ID, address(0x1234));
        _configureEndpointIds();

        // No code check remains: the eid() liveness probe is what fails closed. An EOA/no-code
        // target escapes the try/catch as a bare dataless revert, so this pins any revert
        // rather than the selector; the path still fails closed either way.
        vm.expectRevert();
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenLocalEndpointIdDoesNotMatchEndpoint() external {
        _configureEndpoints();
        script.setEndpointId(LOCAL_CHAIN_ID, LOCAL_EID + 1);

        vm.expectRevert(OutstakeScript.InvalidEndpoint.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenRemoteEndpointIdIsMissing() external {
        script.setEndpoint(LOCAL_CHAIN_ID, address(endpoint));
        script.setEndpointId(LOCAL_CHAIN_ID, LOCAL_EID);
        script.setEndpointId(84532, 40_245);

        vm.expectRevert(OutstakeScript.InvalidOmnichainId.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployUAssetRevertsWhenLocalChainNotInOmnichainSet() external {
        // A chain id outside the 3-chain mesh: fully wired locally but never a member of
        // _sharedOmnichainIds, so validation must fail closed before any peer/rate-limit config.
        uint32 nonMemberChainId = 10143;
        vm.chainId(nonMemberChainId);
        script.setEndpoint(nonMemberChainId, address(endpoint));
        script.setEndpointId(nonMemberChainId, LOCAL_EID);
        _configureEndpointIds();

        vm.expectRevert(OutstakeScript.InvalidOmnichainId.selector);
        script.exposedDeployUETH(1);
    }

    function testDeployOutrunRouterRevertsWhenLauncherIsZero() external {
        script.setRouterConfig(address(0), address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedDeployOutrunRouter(1);
    }

    function testDeployOutrunRouterAcceptsCodelessLauncher() external {
        script.setRouterConfig(address(0), address(0x1234));

        script.exposedDeployOutrunRouter(1);

        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", uint256(1)));
        OutrunRouter deployedRouter = OutrunRouter(outrunDeployer.getDeployed(address(script), salt));

        assertEq(deployedRouter.owner(), owner);
        assertEq(deployedRouter.memeverseLauncher(), address(0x1234));
    }

    function testDeployOutrunRouterAcceptsLauncherContract() external {
        EmptyMockLauncher launcher = new EmptyMockLauncher();
        script.setRouterConfig(address(0), address(launcher));

        script.exposedDeployOutrunRouter(1);

        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", uint256(1)));
        OutrunRouter deployedRouter = OutrunRouter(outrunDeployer.getDeployed(address(script), salt));

        assertEq(deployedRouter.owner(), owner);
        assertEq(deployedRouter.memeverseLauncher(), address(launcher));
    }

    function testRunRouterOnlyDoesNotRequireChainEndpointEnv() external {
        // Poison the 6 chain endpoint/EID envs that `_chainsInit` reads, overriding whatever the
        // runner environment pre-sets (repo `.env`/CI/dev shells may already provide them). Each key
        // is overwritten with a deliberately-invalid value: the 3 *_ENDPOINT keys get "0xdeadbeef"
        // (not a valid 20-byte address → `vm.envAddress` reverts) and the 3 *_EID keys get
        // "not-a-number" (not numeric → `vm.envUint` reverts). A fixed Router-only run() never reads
        // them, so the test passes; a regression that re-reads any key reverts immediately. This is
        // an explicit poison-pin rather than an "env must be absent" precondition, so the test is
        // discriminating regardless of what the environment pre-sets.
        string[3] memory endpointKeys = ["BSC_TESTNET_ENDPOINT", "BASE_SEPOLIA_ENDPOINT", "ETHEREUM_SEPOLIA_ENDPOINT"];
        for (uint256 i = 0; i < endpointKeys.length; i++) {
            vm.setEnv(endpointKeys[i], "0xdeadbeef");
        }

        string[3] memory eidKeys = ["BSC_TESTNET_EID", "BASE_SEPOLIA_EID", "ETHEREUM_SEPOLIA_EID"];
        for (uint256 i = 0; i < eidKeys.length; i++) {
            vm.setEnv(eidKeys[i], "not-a-number");
        }

        // Router-only owner/deployer/launcher: this harness uses the real `_chainsInit`, so it would
        // revert on any chain endpoint/EID env read still reachable from `run()`.
        OutstakeScriptRunHarness runScript = new OutstakeScriptRunHarness();

        // Etch the CREATE2 stand-in at the canonical address so the real OutrunDeployer deploys at
        // the CREATE2-expected address (mirrors testDeployOutrunDeployerMatchesAssertOutrunDeployer).
        vm.etch(runScript.exposedCanonicalCreate2Factory(), type(DeterministicCreate2FactoryMock).runtimeCode);

        address canonicalDeployer = runScript.configureRun(1);
        EmptyMockLauncher launcher = new EmptyMockLauncher();

        vm.setEnv("OWNER", vm.toString(address(runScript)));
        vm.setEnv("OUTRUN_DEPLOYER", vm.toString(canonicalDeployer));
        vm.setEnv("MEMEVERSE_LAUNCHER", vm.toString(address(launcher)));

        // Inject the deterministic CREATE3 address this run() is about to deploy via the
        // `_routerConfigEnv` seam instead of process env: `_applyRouterConfig` switches on the
        // seam's existence flag and `_deployOutrunRouter` reverts on mismatch, so the test stays
        // independent of the runner's shell/.env, positively covers the enforcement-pass path,
        // and cannot pollute concurrent tests sharing process env.
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", uint256(7)));
        address expectedRouter = OutrunDeployer(canonicalDeployer).getDeployed(address(runScript), salt);
        runScript.setRouterConfigOverride(expectedRouter);

        // A Router-only run() must never read the (now-poisoned) chain endpoint/EID envs: if `run()`
        // still loaded them, the first read reverts `vm.envAddress`/`vm.envUint` and fails this test —
        // the revert-if-read-on-regression behavior is the pin.
        runScript.run();

        // The router deploys with nonce 7 (`_deployOutrunRouter(7)`); assert it was created and
        // owned by the run harness — proving run() reached the router deploy.
        OutrunRouter deployedRouter =
            OutrunRouter(OutrunDeployer(canonicalDeployer).getDeployed(address(runScript), salt));
        assertGt(address(deployedRouter).code.length, 0);
        assertEq(deployedRouter.owner(), address(runScript));
        assertEq(deployedRouter.memeverseLauncher(), address(launcher));
    }

    function testUpdateRouterLauncherRevertsWhenLauncherIsZero() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        script.setRouterConfig(address(router), address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedUpdateRouterLauncher();
    }

    function testUpdateRouterLauncherAcceptsCodelessLauncher() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        script.setRouterConfig(address(router), address(0x1234));

        script.exposedUpdateRouterLauncher();

        assertEq(router.memeverseLauncher(), address(0x1234));
    }

    function testUpdateRouterLauncherAcceptsLauncherContract() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        EmptyMockLauncher launcher = new EmptyMockLauncher();
        script.setRouterConfig(address(router), address(launcher));

        script.exposedUpdateRouterLauncher();

        assertEq(router.memeverseLauncher(), address(launcher));
    }

    // --- PSM deployment wiring ---

    function testDeployFamilyPSMsWireSingleReserveInstancesAndPairRegistry() external {
        _deployPSMWiringStack();

        // UETH native leg.
        script.setFamilyUAsset(_familyUAsset("ETH"));
        script.setPSMCaps(800_000 ether);
        vm.expectEmit(true, true, false, true);
        emit IUniversalAssets.SetReserveMinter(_psmByStem("OutrunPSMETH"), true);
        script.exposedDeployUETHPSM(1);
        _assertPSMInstance("OutrunPSMETH", "ETH", address(0), 800_000 ether);

        // UUSD stablecoin legs: one call deploys both single-reserve instances.
        script.setFamilyUAsset(_familyUAsset("USD"));
        script.setPSMCaps(600_000 ether);
        vm.expectEmit(true, true, false, true);
        emit IUniversalAssets.SetReserveMinter(_psmByStem("OutrunPSMUSDUSDC"), true);
        vm.expectEmit(true, true, false, true);
        emit IUniversalAssets.SetReserveMinter(_psmByStem("OutrunPSMUSDUSDT"), true);
        script.exposedDeployUUSDPSM(1);
        _assertPSMInstance("OutrunPSMUSDUSDC", "USD", address(wiringUSDC), 600_000 ether);
        _assertPSMInstance("OutrunPSMUSDUSDT", "USD", address(wiringUSDT), 600_000 ether);

        // UBNB native leg.
        script.setFamilyUAsset(_familyUAsset("BNB"));
        script.setPSMCaps(400_000 ether);
        vm.expectEmit(true, true, false, true);
        emit IUniversalAssets.SetReserveMinter(_psmByStem("OutrunPSMBNB"), true);
        script.exposedDeployUBNBPSM(1);
        _assertPSMInstance("OutrunPSMBNB", "BNB", address(0), 400_000 ether);
    }

    /// @dev A zero ERC20 reserve address must fail closed BEFORE the CREATE3 deploy: with the
    ///      pre-deploy resolution a spent salt (half-deployed PSM) can never result from an invalid
    ///      reserve env.
    function test_RevertWhen_PSMStablecoinReserveAddressIsZero() external {
        _deployPSMWiringStack();
        script.setFamilyUAsset(_familyUAsset("USD"));
        script.setPSMCaps(600_000 ether);
        script.setUusdReserves(address(0), address(wiringUSDT));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedDeployUUSDPSM(1);

        // Nothing was deployed: both leg salts are unspent.
        assertEq(_psmByStem("OutrunPSMUSDUSDC").code.length, 0);
        assertEq(_psmByStem("OutrunPSMUSDUSDT").code.length, 0);
    }

    /// @dev Family-identity re-check: a cross-filled family env (the UETH entry pointed at the
    ///      UUSD token) must fail closed before any deployment — the PSM/uAsset binding has no
    ///      setter, so a native-leg PSM bound to the stablecoin family would be unfixable.
    function test_RevertWhen_PSMUAssetFamilySymbolMismatches() external {
        _deployPSMWiringStack();
        // Every other check passes (UUSD is a deployed, script-owned uAsset); only the symbol
        // re-check can catch the cross-fill.
        script.setFamilyUAsset(_familyUAsset("USD"));
        script.setPSMCaps(800_000 ether);

        vm.expectRevert(SPDefaults.InvalidFamilyUAsset.selector);
        script.exposedDeployUETHPSM(1);

        assertEq(_psmByStem("OutrunPSMETH").code.length, 0);
    }

    function testDeployPSMAppliesConfiguredFees() external {
        _deployPSMWiringStack();
        script.setFamilyUAsset(_familyUAsset("ETH"));
        script.setPSMCaps(800_000 ether);
        script.setPSMFees(5e14, 0);

        script.exposedDeployUETHPSM(1);

        OutrunPSMUpgradeable psm = OutrunPSMUpgradeable(_psmByStem("OutrunPSMETH"));
        assertEq(psm.tin(), 5e14);
        assertEq(psm.tout(), 0);
    }

    // --- USR savings vault deployment wiring ---

    function testDeploySuVaultsInitializeInactive() external {
        _deployFamilyUAssets();

        script.setFamilyUAsset(_familyUAsset("ETH"));
        script.exposedDeploySuETH(1);
        script.setFamilyUAsset(_familyUAsset("USD"));
        script.exposedDeploySuUSD(1);
        script.setFamilyUAsset(_familyUAsset("BNB"));
        script.exposedDeploySuBNB(1);

        _assertUSRVault("ETH", "Universal Savings ETH", "suETH");
        _assertUSRVault("USD", "Universal Savings USD", "suUSD");
        _assertUSRVault("BNB", "Universal Savings BNB", "suBNB");
    }

    // --- POLend minter initial mintingCap wiring ---

    function testRegisterPOLendMinterAppliesFamilyInitialCaps() external {
        _deployFamilyUAssets();
        // The engine minter is an operator-supplied address.
        address polendMinter = address(new EmptyMockLauncher());
        script.setPolendMinter(polendMinter);

        // No injected cap: the family placeholder defaults apply.
        script.setFamilyUAsset(_familyUAsset("ETH"));
        script.exposedRegisterPOLendMinter("UETH", false);
        assertEq(_familyUAssetMintingCap("ETH", polendMinter), 1_000_000_000 ether);

        script.setFamilyUAsset(_familyUAsset("BNB"));
        script.exposedRegisterPOLendMinter("UBNB", true);
        // UBNB launches with a deliberately small cap; early ReachMintCap is intended, not an incident.
        assertEq(_familyUAssetMintingCap("BNB", polendMinter), 100_000 ether);
        assertLt(_familyUAssetMintingCap("BNB", polendMinter), _familyUAssetMintingCap("ETH", polendMinter));

        // An injected per-family cap wins over the default.
        script.setFamilyUAsset(_familyUAsset("USD"));
        script.setPolendMintingCap(7_777 ether);
        script.exposedRegisterPOLendMinter("UUSD", false);
        assertEq(_familyUAssetMintingCap("USD", polendMinter), 7_777 ether);
    }

    /// @dev An explicitly configured zero SP minting cap must fail fast instead of deploying
    ///      an SP that cannot mint. The zero rejection is a pure input check
    ///      (`SPDefaults.validatedMintingCap`), so it is asserted through an external
    ///      harness call with no process-env write: SP_MINTING_CAP via vm.setEnv would race
    ///      concurrent suites that read the key on their default paths. The env plumbing
    ///      (unset key falls back to the placeholder default) stays covered by the
    ///      support-suite default-value asserts.
    function test_RevertWhen_ExplicitZeroMintingCap() external {
        vm.expectRevert(SPDefaults.ExplicitZeroMintingCap.selector);
        script.exposedValidatedMintingCap(0);
    }

    /// @dev Explicit <SYMBOL>_POLEND_MINTING_CAP=0 must fail fast. Uses a ZZZ symbol so the
    /// key collides with no family key used by the defaults test (UETH/UBNB fall through to
    /// env, UUSD is injected and never reads env); fresh harness leaves polendCapSet false
    /// so the call exercises the super env path.
    function test_RevertWhen_ExplicitZeroPOLendMintingCapEnv() external {
        vm.setEnv("ZZZ_POLEND_MINTING_CAP", "0");

        vm.expectRevert(SPDefaults.ExplicitZeroMintingCap.selector);
        script.exposedPolendMintingCap("ZZZ", false);
    }

    /// @dev A cap above type(uint128).max would revert at the on-chain setMintingCap wiring
    ///      call after the SP is already deployed; the pure guard (`SPDefaults.validatedMintingCap`)
    ///      rejects it fail-fast pre-deploy instead, asserted through the same explicit-value
    ///      harness seam as the zero rejection (no process-env write).
    function test_RevertWhen_MintingCapAboveUint128Width() external {
        vm.expectRevert(SPDefaults.MintingCapTooLarge.selector);
        script.exposedValidatedMintingCap(uint256(type(uint128).max) + 1);
    }

    /// @dev Same over-width rejection on the per-family POLend env path, following the zero
    ///      precedent's ZZZ symbol so the key collides with no family key (UETH/UBNB fall
    ///      through to env, UUSD is injected and never reads env).
    function test_RevertWhen_POLendMintingCapAboveUint128WidthEnv() external {
        vm.setEnv("ZZZ_POLEND_MINTING_CAP", vm.toString(uint256(type(uint128).max) + 1));

        vm.expectRevert(SPDefaults.MintingCapTooLarge.selector);
        script.exposedPolendMintingCap("ZZZ", false);
    }

    function testDeployOutrunDeployerMatchesAssertOutrunDeployer() external {
        uint256 nonce = 1;

        // Etch the factory stand-in at the canonical address: CREATE2 results depend on the
        // factory's address, not its code identity, so the deployed address matches production.
        vm.etch(script.exposedCanonicalCreate2Factory(), type(DeterministicCreate2FactoryMock).runtimeCode);

        address deployed = script.exposedDeployOutrunDeployer(nonce);

        assertEq(deployed, _expectedOutrunDeployerAddress(nonce));
        assertEq(OutrunDeployer(deployed).owner(), owner);

        script.configure(owner, owner, deployed);
        script.exposedAssertOutrunDeployer(nonce);
    }

    function testCanonicalCreate2FactoryMatchesFirstPrinciplesAddress() external view {
        // Pins the factory constant independently of the script: without this, a typo'd
        // CANONICAL_CREATE2_FACTORY would pass every etch/expected-creator check above because
        // both read the same script constant (circular evidence). Derived = first principles,
        // literal = the externally known canonical address; all three must agree.
        assertEq(DERIVED_CANONICAL_CREATE2_FACTORY, 0x4e59b44847b379578588920cA78FbF26c0B4956C);
        assertEq(script.exposedCanonicalCreate2Factory(), DERIVED_CANONICAL_CREATE2_FACTORY);
    }

    function testDeployOutrunDeployerRevertsWhenFactoryIsAbsent() external {
        // Model a chain where the canonical factory was never deployed. Foundry predeploys its own
        // create2 helper at this address, so clear that code first to reach the codeless state.
        vm.etch(script.exposedCanonicalCreate2Factory(), "");
        // The raw call to a codeless address succeeds with empty returndata, so only the 20-byte
        // return-length check can fail closed.
        vm.expectRevert(OutstakeScript.FactoryDeployFailed.selector);
        script.exposedDeployOutrunDeployer(1);
    }

    function testAssertOutrunDeployerRevertsWhenOutrunDeployerDoesNotMatchExpectedAddress() external {
        script.configure(owner, owner, address(0xDEAD));

        vm.expectRevert(OutstakeScript.InvalidDeployer.selector);
        script.exposedAssertOutrunDeployer(1);
    }

    function testAssertOutrunDeployerRevertsWhenOwnerDoesNotMatchDeployer() external {
        script.configure(address(0xA11CE), address(0xB0B), address(0xDEAD));

        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedAssertOutrunDeployer(1);
    }

    function _deployAndAssertUAsset(
        string memory saltSuffix,
        string memory expectedName,
        string memory expectedSymbol,
        uint256 nonce
    ) internal {
        _configureEndpoints();

        if (keccak256(bytes(expectedSymbol)) == keccak256("UETH")) {
            script.exposedDeployUETH(nonce);
        } else if (keccak256(bytes(expectedSymbol)) == keccak256("UUSD")) {
            script.exposedDeployUUSD(nonce);
        } else {
            script.exposedDeployUBNB(nonce);
        }

        bytes32 salt = keccak256(abi.encodePacked(string.concat("OmnichainUniversalAssets", saltSuffix), nonce));
        OutrunUniversalAssetsUpgradeable uAsset =
            OutrunUniversalAssetsUpgradeable(outrunDeployer.getDeployed(address(script), salt));

        assertGt(address(uAsset).code.length, 0);
        assertEq(uAsset.name(), expectedName);
        assertEq(uAsset.symbol(), expectedSymbol);
        assertEq(uAsset.decimals(), 18);
        assertEq(uAsset.owner(), owner);
        assertEq(address(uAsset.endpoint()), address(endpoint));
        assertEq(uAsset.localDecimals(), 18);

        bytes32 expectedPeer = bytes32(uint256(uint160(address(uAsset))));
        for (uint256 i; i < chainIds.length; ++i) {
            uint32 chainId = chainIds[i];
            uint32 endpointId = endpointIds[i];
            if (chainId == block.chainid) {
                assertEq(IOAppCore(address(uAsset)).peers(endpointId), bytes32(0));
                continue;
            }

            assertEq(IOAppCore(address(uAsset)).peers(endpointId), expectedPeer);
            OutrunRateLimiterUpgradeable.RateLimit memory rl =
                OutrunOFTUpgradeable(address(uAsset)).rateLimits(endpointId);
            assertEq(rl.limit, 1_000_000 ether);
            assertEq(rl.window, 1 hours);
        }
    }

    /// @dev Single expected-address definition shared by the assert-path and deploy-path tests:
    /// CREATE2(factory, salt, keccak256(initcode)). Salt/initcode are re-derived from literals as
    /// an independent oracle — any drift in the script's recipe must fail these tests. Only the
    /// factory constant still comes from the script (`exposedCanonicalCreate2Factory`), and it is
    /// independently pinned by testCanonicalCreate2FactoryMatchesFirstPrinciplesAddress.
    function _expectedOutrunDeployerAddress(uint256 nonce) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        bytes memory initcode = abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner));
        return Create2.computeAddress(salt, keccak256(initcode), script.exposedCanonicalCreate2Factory());
    }

    /// @dev Full stack the PSM wiring consumes: the three family uAssets (deployed through the
    ///      script's own uAsset path), the router (state-injected via setRouterConfig), and the
    ///      UUSD-family ERC20 reserve stand-ins. Per-family stock caps are set per deploy below and
    ///      are distinct so a cross-family wiring mistake cannot pass.
    function _deployPSMWiringStack() internal {
        _deployFamilyUAssets();
        script.setRouterConfig(address(0), address(new EmptyMockLauncher()));
        script.exposedDeployOutrunRouter(7);
        // Point the script's router state at the deployed router for the setPsmForUAsset wiring.
        script.setRouterConfig(_wiringRouter(), address(new EmptyMockLauncher()));

        wiringUSDC = new MockUSDC("Mock USDC", "USDC", 6, address(this));
        wiringUSDT = new MockUSDC("Mock USDT", "USDT", 6, address(this));
        script.setUusdReserves(address(wiringUSDC), address(wiringUSDT));

        wiringFeeRecipient = makeAddr("psmFeeRecipient");
        script.setPSMFeeRecipient(wiringFeeRecipient);
    }

    /// @dev The three family uAssets through the script's own deploy path (real symbols: the
    ///      family-identity re-check in the wiring helpers reads them).
    function _deployFamilyUAssets() internal {
        _configureEndpoints();
        script.exposedDeployUETH(1);
        script.exposedDeployUUSD(1);
        script.exposedDeployUBNB(1);
    }

    /// @dev Asserts one deployed single-reserve instance: initialized parameters (the stock cap
    ///      config-injected; fees fall through to the 0.1% launch default), the init-bound reserve,
    ///      and the router path-A pair registry entry. The uAsset-side reserve-minter registration
    ///      has no view getter, so it is pinned by event at the deploy call site — with the indexed
    ///      minter topic checked against the pre-computed PSM address, so a registration for any
    ///      other minter cannot satisfy the assert.
    function _assertPSMInstance(string memory saltStem, string memory assetWord, address reserve, uint256 stockCap)
        internal
        view
    {
        address uAsset = _familyUAsset(assetWord);
        address psm = _psmByStem(saltStem);
        OutrunPSMUpgradeable psmContract = OutrunPSMUpgradeable(psm);
        assertGt(psm.code.length, 0);
        assertEq(psmContract.uAsset(), uAsset);
        assertEq(psmContract.reserveToken(), reserve);
        assertEq(psmContract.owner(), owner);
        assertEq(psmContract.feeRecipient(), wiringFeeRecipient);
        assertEq(psmContract.stockCap(), stockCap);
        // Launch fee default: 0.1% on each direction when no fee config is injected.
        assertEq(psmContract.tin(), 1e15);
        assertEq(psmContract.tout(), 1e15);
        assertEq(OutrunRouter(_wiringRouter()).psmForUAsset(uAsset, reserve), psm);
    }

    function _assertUSRVault(string memory assetWord, string memory expectedName, string memory expectedSymbol)
        internal
        view
    {
        OutrunUSRVaultUpgradeable vault = OutrunUSRVaultUpgradeable(_familyUSRVault(assetWord));
        assertGt(address(vault).code.length, 0);
        assertEq(vault.asset(), _familyUAsset(assetWord));
        assertEq(vault.name(), expectedName);
        assertEq(vault.symbol(), expectedSymbol);
        // Pre-activation state: accrual off and the index at par — the family rate is a post-deploy
        // owner decision via setUsrRate.
        assertEq(vault.usrRate(), 0);
        assertEq(vault.accrualIndex(), 1e18);
        assertEq(vault.lastSettledAt(), block.timestamp);
        assertEq(vault.owner(), owner);
    }

    function _familyUAssetMintingCap(string memory assetWord, address minter) internal view returns (uint256) {
        return OutrunUniversalAssetsUpgradeable(_familyUAsset(assetWord)).mintingStatusTable(minter).mintingCap;
    }

    function _familyUAsset(string memory assetWord) internal view returns (address) {
        return outrunDeployer.getDeployed(
            address(script),
            keccak256(abi.encodePacked(string.concat("OmnichainUniversalAssets", assetWord), uint256(1)))
        );
    }

    function _psmByStem(string memory saltStem) internal view returns (address) {
        return outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked(saltStem, uint256(1))));
    }

    function _familyUSRVault(string memory assetWord) internal view returns (address) {
        return outrunDeployer.getDeployed(
            address(script), keccak256(abi.encodePacked(string.concat("OutrunUSRVault", assetWord), uint256(1)))
        );
    }

    function _wiringRouter() internal view returns (address) {
        return outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("OutrunRouter", uint256(7))));
    }

    function _configureEndpoints() internal {
        script.setEndpoint(LOCAL_CHAIN_ID, address(endpoint));
        _configureEndpointIds();
    }

    function _configureEndpointIds() internal {
        for (uint256 i; i < chainIds.length; ++i) {
            script.setEndpointId(chainIds[i], endpointIds[i]);
        }
    }

    function _pushChain(uint32 chainId, uint32 endpointId) internal {
        chainIds.push(chainId);
        endpointIds.push(endpointId);
    }
}
