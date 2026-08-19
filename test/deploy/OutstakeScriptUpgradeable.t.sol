// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunOFTUpgradeable} from "../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {MockLzEndpoint} from "../upgradeable/mocks/OFTMocks.sol";
import {EmptyMockLauncher} from "../upgradeable/mocks/EmptyMockLauncher.sol";
import {DeterministicCreate2FactoryMock} from "./mocks/DeterministicCreate2FactoryMock.sol";

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

    function exposedDeployOutrunRouter(uint256 nonce) external {
        _deployOutrunRouter(nonce);
    }

    function exposedUpdateRouterLauncher() external {
        _updateRouterLauncher();
    }

    function exposedAssertOutrunDeployer(uint256 nonce) external {
        _assertOutrunDeployer(nonce);
    }

    function exposedDeployOutrunDeployer(uint256 nonce) external returns (address) {
        return _deployOutrunDeployer(nonce);
    }

    function exposedOutrunDeployerRecipe(uint256 nonce) external view returns (bytes32 salt, bytes memory initcode) {
        return _outrunDeployerRecipe(nonce);
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

    // Neutralize the chain endpoint/EID env reads: uAsset deploy tests populate the endpoints /
    // endpointIds maps via setEndpoint / setEndpointId and must not hit real env reads now that
    // `_deployUAsset` loads them via `_chainsInit`.
    function _chainsInit() internal override {}
}

/// @dev Run-path harness that deliberately does NOT override `_chainsInit`, so the Router-only
/// `run()` regression test exercises the real chain endpoint/EID env reads. This keeps the
/// `_chainsInit` no-op override above scoped to the uAsset deploy tests that populate the
/// endpoints/endpointIds maps via test setters.
contract OutstakeScriptRunHarness is OutstakeScript {
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

    uint32[] internal chainIds;
    uint32[] internal endpointIds;

    function setUp() external {
        vm.chainId(LOCAL_CHAIN_ID);

        script = new OutstakeDeploymentScriptHarness();
        owner = address(script);
        outrunDeployer = new OutrunDeployer(address(script));
        endpoint = new MockLzEndpoint();
        endpoint.setEid(LOCAL_EID);

        script.configure(owner, owner, address(outrunDeployer));

        _pushChain(97, LOCAL_EID);
        _pushChain(84532, 40_245);
        _pushChain(421614, 40_231);
        _pushChain(43113, 40_106);
        _pushChain(80002, 40_209);
        _pushChain(57054, 40_367);
        _pushChain(168587773, 40_243);
        _pushChain(534351, 40_214);
        _pushChain(11155111, 40_161);
    }

    function testDeployUETHUUSDAndUBNBCreateInitializedProxiesAndConfigureRemoteOmnichainState() external {
        _deployAndAssertUAsset("ETH", "Omnichain Universal Assets ETH", "UETH", 1);
        _deployAndAssertUAsset("USD", "Omnichain Universal Assets USD", "UUSD", 1);
        _deployAndAssertUAsset("BNB", "Omnichain Universal Assets BNB", "UBNB", 1);
    }

    function testDeployUAssetRevertsWhenOwnerDoesNotMatchDeployer() external {
        _configureEndpoints();
        script.configure(address(0xA11CE), address(0xB0B), address(outrunDeployer));

        vm.expectRevert(OutstakeScript.InvalidOwner.selector);
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

        vm.expectRevert(OutstakeScript.InvalidEndpoint.selector);
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
        // Monad Testnet (10143) is fully configured in _chainsInit but excluded from
        // _sharedOmnichainIds: validation must fail closed before any peer/rate-limit config.
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

    function testDeployOutrunRouterRevertsWhenLauncherHasNoCode() external {
        script.setRouterConfig(address(0), address(0x1234));

        vm.expectRevert(bytes("INITIALIZATION_FAILED"));
        script.exposedDeployOutrunRouter(1);
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
        // Poison the 28 chain endpoint/EID envs that `_chainsInit` reads, overriding whatever the
        // runner environment pre-sets (repo `.env`/CI/dev shells may already provide them). Each key
        // is overwritten with a deliberately-invalid value: the 14 *_ENDPOINT keys get "0xdeadbeef"
        // (not a valid 20-byte address → `vm.envAddress` reverts) and the 14 *_EID keys get
        // "not-a-number" (not numeric → `vm.envUint` reverts). A fixed Router-only run() never reads
        // them, so the test passes; a regression that re-reads any key reverts immediately. This is
        // an explicit poison-pin rather than an "env must be absent" precondition, so the test is
        // discriminating regardless of what the environment pre-sets.
        string[14] memory endpointKeys = [
            "BSC_TESTNET_ENDPOINT",
            "BASE_SEPOLIA_ENDPOINT",
            "ARBITRUM_SEPOLIA_ENDPOINT",
            "AVALANCHE_FUJI_ENDPOINT",
            "POLYGON_AMOY_ENDPOINT",
            "SONIC_TESTNET_ENDPOINT",
            "OPTIMISTIC_SEPOLIA_ENDPOINT",
            "ZKSYNC_SEPOLIA_ENDPOINT",
            "LINEA_SEPOLIA_ENDPOINT",
            "BLAST_SEPOLIA_ENDPOINT",
            "SCROLL_SEPOLIA_ENDPOINT",
            "MONAD_TESTNET_ENDPOINT",
            "BERA_SEPOLIA_ENDPOINT",
            "ETHEREUM_SEPOLIA_ENDPOINT"
        ];
        for (uint256 i = 0; i < endpointKeys.length; i++) {
            vm.setEnv(endpointKeys[i], "0xdeadbeef");
        }

        string[14] memory eidKeys = [
            "BSC_TESTNET_EID",
            "BASE_SEPOLIA_EID",
            "ARBITRUM_SEPOLIA_EID",
            "AVALANCHE_FUJI_EID",
            "POLYGON_AMOY_EID",
            "SONIC_TESTNET_EID",
            "OPTIMISTIC_SEPOLIA_EID",
            "ZKSYNC_SEPOLIA_EID",
            "LINEA_SEPOLIA_EID",
            "BLAST_SEPOLIA_EID",
            "SCROLL_SEPOLIA_EID",
            "MONAD_TESTNET_EID",
            "BERA_SEPOLIA_EID",
            "ETHEREUM_SEPOLIA_EID"
        ];
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

        // Override any environment-preset OUTRUN_ROUTER with the deterministic CREATE3 address this
        // run() is about to deploy: `_applyRouterConfig` switches on `vm.envExists("OUTRUN_ROUTER")`
        // and `_deployOutrunRouter` reverts on mismatch, so the test must be independent of the
        // runner's shell/.env and also positively covers the enforcement-pass path.
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", uint256(7)));
        address expectedRouter = OutrunDeployer(canonicalDeployer).getDeployed(address(runScript), salt);
        vm.setEnv("OUTRUN_ROUTER", vm.toString(expectedRouter));

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

    function testUpdateRouterLauncherRevertsWhenLauncherHasNoCode() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        script.setRouterConfig(address(router), address(0x1234));

        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.InvalidMemeverseLauncher.selector, address(0x1234)));
        script.exposedUpdateRouterLauncher();
    }

    function testUpdateRouterLauncherAcceptsLauncherContract() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        EmptyMockLauncher launcher = new EmptyMockLauncher();
        script.setRouterConfig(address(router), address(launcher));

        script.exposedUpdateRouterLauncher();

        assertEq(router.memeverseLauncher(), address(launcher));
    }

    function testAssertOutrunDeployerPassesWhenOutrunDeployerMatchesExpectedAddress() external {
        uint256 nonce = 1;

        script.configure(owner, owner, _expectedOutrunDeployerAddress(nonce));

        script.exposedAssertOutrunDeployer(nonce);
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

        vm.expectRevert(OutstakeScript.InvalidOwner.selector);
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
