// SPDX-License-Identifier: UNLICENSED
// solhint-disable no-console,check-send-result
pragma solidity ^0.8.35;

import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {BaseScript} from "../lib/BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {IOutrunDeployer} from "./deployment/interfaces/IOutrunDeployer.sol";
import {OutrunDeployer} from "./deployment/OutrunDeployer.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OutrunOFTUpgradeable} from "../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";

import {Faucet, IFaucet} from "../../test/support/Faucet.sol";
import {MockUSDC} from "../../test/support/mocks/MockUSDC.sol";
import {MockAUSDC} from "../../test/support/mocks/MockAUSDC.sol";
import {MockSUSDS} from "../../test/support/mocks/MockSUSDS.sol";
import {MockAUSDCOracle} from "../../test/support/mocks/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "../../test/support/mocks/MockSUSDSOracle.sol";
import {MockOutrunAUSDCSYUpgradeable} from "../../test/upgradeable/mocks/MockOutrunAUSDCSYUpgradeable.sol";
import {MockOutrunSUSDSSYUpgradeable} from "../../test/upgradeable/mocks/MockOutrunSUSDSSYUpgradeable.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract OutstakeScript is BaseScript {
    using OptionsBuilder for bytes;
    using SafeCast for uint256;

    error InvalidEndpoint();
    error InvalidOmnichainId();
    error InvalidOmnichainConfig();
    error InvalidOutboundRateLimit();
    error InvalidOutboundRateWindow();
    error InvalidOwner();
    error InvalidKeeper();
    error InvalidAddress();
    error InvalidDeployer();
    error NotTestnetChain();
    error FactoryDeployFailed();

    // Defaults applied to every SP deployed by the mock-support helpers.
    // These are deployment constants, not env-configurable; adjust post-deploy via owner setters.
    uint256 internal constant SP_DEFAULT_MINTING_CAP = 1_000_000_000 ether;
    uint256 internal constant SP_DEFAULT_MIN_STAKE = 0;

    // Canonical deterministic-deployment proxy (Arachnid; same address on every chain), used as
    // the CREATE2 creator so the script never needs its own ephemeral address(this) — forge v1.7.1
    // hard-reverts any address(this) use in script contracts under `forge script`.
    address internal constant CANONICAL_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal owner;
    address internal outrunDeployer;
    address internal outrunRouter;
    bool internal enforceOutrunRouter;
    address internal memeverseLauncher;

    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    function run() public broadcaster {
        // deployerNonce = 1 is the OutrunDeployer instance selector (CREATE2 path shared by
        // _deployOutrunDeployer/_assertOutrunDeployer).
        // _deployOutrunRouter(7) is an independent CREATE3 salt-namespace counter; it must stay
        // identical across chains.
        // 11 disabled Outstake call sites require nonce/salt/compile-config consistency; of these,
        // the deployment-creating calls depend on nonce/salt/compile-config consistency, while
        // _crossChainOFT and _updateRouterLauncher are non-deploy calls that depend on already-deployed
        // addresses. YieldDeployScript has 3 support functions/call sites (_supportWstETHOnSepolia,
        // _supportSUSDeOnSepolia, _supportAUSDC), which are single-chain direct-new deployments with no
        // cross-chain same-address requirement.
        owner = vm.envAddress("OWNER");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        memeverseLauncher = vm.envAddress("MEMEVERSE_LAUNCHER");
        _applyRouterConfig();

        uint256 deployerNonce = 1;
        // _deployOutrunDeployer(deployerNonce);

        _assertOutrunDeployer(deployerNonce);
        _chainsInit();
        // _crossChainOFT();
        // _deployUETH(1);
        // _deployUUSD(1);
        // _deployUBNB(1);
        _deployOutrunRouter(7);
        // _updateRouterLauncher();
        // _deployMockERC20(1);
        // _deployMockOracle(1);
        // _deployMockERC20SY(1);
        // _supportMockAUSDC(13); // Requires optimizer-runs=20000 (see docs/deployment.md)
        // _supportMockSUSDS(13); // Requires optimizer-runs=20000 (see docs/deployment.md)
    }

    /// @dev Single source of truth for the salt/initcode used to deploy OutrunDeployer.
    /// `_deployOutrunDeployer` and `_assertOutrunDeployer` share this recipe so the two
    /// CREATE2 expressions cannot drift apart.
    function _outrunDeployerRecipe(uint256 nonce) internal view returns (bytes32 salt, bytes memory initcode) {
        salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        initcode = abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner));
    }

    function _deployOutrunDeployer(uint256 nonce) internal returns (address outrunDeployerAddr) {
        (bytes32 salt, bytes memory initcode) = _outrunDeployerRecipe(nonce);
        // The factory is the CREATE2 creator, so the deployed address equals the three-param
        // expected address in `_assertOutrunDeployer` (same salt/initcode recipe). The canonical
        // deterministic-deployment proxy (Arachnid) is NOT ABI-encoded — it exposes no
        // `deploy(bytes,bytes32)` function: calldata is raw `salt (first 32 bytes) ++ initcode`,
        // the forwarded value endows the created contract, and on success it returns the deployed
        // address as 20 RAW bytes. Do not convert this back to an ABI call; it can never succeed
        // against the real proxy.
        (bool ok, bytes memory ret) = CANONICAL_CREATE2_FACTORY.call(abi.encodePacked(salt, initcode));
        // Fail closed on a failed create2 AND on chains where the factory is absent: a call to a
        // codeless address succeeds with empty returndata, which only this length check catches.
        if (!ok || ret.length != 20) revert FactoryDeployFailed();
        // The proxy returns 20 raw bytes, not a 32-byte ABI word — cast directly, never abi.decode.
        // ret.length == 20 checked above, so bytes20 cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        outrunDeployerAddr = address(uint160(bytes20(ret)));
        console.log("OutrunDeployer deployed on %s", outrunDeployerAddr);
    }

    /// @dev Fails closed unless `OUTRUN_DEPLOYER` is the address `_deployOutrunDeployer` would
    /// CREATE2-deploy: expected = CREATE2(CANONICAL_CREATE2_FACTORY, salt, keccak256(initcode)).
    /// The creator is the canonical deterministic-deployment proxy — a chain constant — because
    /// forge v1.7.1 hard-reverts any `address(this)` use in script contracts, so the script
    /// contract can no longer be the creator (and an EOA cannot execute CREATE2). Cross-chain
    /// same-address deployment depends on the factory address being identical on every chain, so
    /// a mismatch here would silently scatter the OutrunDeployer/peer=own-address design across
    /// divergent addresses.
    function _assertOutrunDeployer(uint256 nonce) internal view {
        // Deployer must equal owner (mirrors `_validateUAssetDeploymentConfig` / docs OWNER==broadcaster).
        if (owner != deployer) revert InvalidOwner();

        (bytes32 salt, bytes memory initcode) = _outrunDeployerRecipe(nonce);
        address expected = Create2.computeAddress(salt, keccak256(initcode), CANONICAL_CREATE2_FACTORY);

        if (outrunDeployer != expected) revert InvalidDeployer();
    }

    function _chainsInit() internal {
        endpoints[97] = vm.envAddress("BSC_TESTNET_ENDPOINT");
        endpoints[84532] = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
        endpoints[421614] = vm.envAddress("ARBITRUM_SEPOLIA_ENDPOINT");
        endpoints[43113] = vm.envAddress("AVALANCHE_FUJI_ENDPOINT");
        endpoints[80002] = vm.envAddress("POLYGON_AMOY_ENDPOINT");
        endpoints[57054] = vm.envAddress("SONIC_TESTNET_ENDPOINT");
        endpoints[11155420] = vm.envAddress("OPTIMISTIC_SEPOLIA_ENDPOINT");
        endpoints[300] = vm.envAddress("ZKSYNC_SEPOLIA_ENDPOINT");
        endpoints[59141] = vm.envAddress("LINEA_SEPOLIA_ENDPOINT");
        endpoints[168587773] = vm.envAddress("BLAST_SEPOLIA_ENDPOINT");
        endpoints[534351] = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
        endpoints[10143] = vm.envAddress("MONAD_TESTNET_ENDPOINT");
        endpoints[80069] = vm.envAddress("BERA_SEPOLIA_ENDPOINT");
        endpoints[11155111] = vm.envAddress("ETHEREUM_SEPOLIA_ENDPOINT");

        endpointIds[97] = vm.envUint("BSC_TESTNET_EID").toUint32();
        endpointIds[84532] = vm.envUint("BASE_SEPOLIA_EID").toUint32();
        endpointIds[421614] = vm.envUint("ARBITRUM_SEPOLIA_EID").toUint32();
        endpointIds[43113] = vm.envUint("AVALANCHE_FUJI_EID").toUint32();
        endpointIds[80002] = vm.envUint("POLYGON_AMOY_EID").toUint32();
        endpointIds[57054] = vm.envUint("SONIC_TESTNET_EID").toUint32();
        endpointIds[11155420] = vm.envUint("OPTIMISTIC_SEPOLIA_EID").toUint32();
        endpointIds[300] = vm.envUint("ZKSYNC_SEPOLIA_EID").toUint32();
        endpointIds[59141] = vm.envUint("LINEA_SEPOLIA_EID").toUint32();
        endpointIds[168587773] = vm.envUint("BLAST_SEPOLIA_EID").toUint32();
        endpointIds[534351] = vm.envUint("SCROLL_SEPOLIA_EID").toUint32();
        endpointIds[10143] = vm.envUint("MONAD_TESTNET_EID").toUint32();
        endpointIds[80069] = vm.envUint("BERA_SEPOLIA_EID").toUint32();
        endpointIds[11155111] = vm.envUint("ETHEREUM_SEPOLIA_EID").toUint32();
    }

    /// @dev Deploys an upgradeable contract via ERC1967Proxy using CREATE3 through
    /// `OutrunDeployer.deploy`: both the implementation and proxy addresses depend only on
    /// (OutrunDeployer, broadcaster, salt), never on the initcode or initCalldata (see
    /// docs/deployment.md cross-chain same-address constraints). The "impl" suffix gives the
    /// implementation its own salt namespace; reusing the proxy salt would make the second
    /// CREATE3 deploy revert with DEPLOYMENT_FAILED.
    function _deployUpgradeable(bytes memory implCreationCode, bytes memory initCalldata, bytes32 salt)
        internal
        returns (address)
    {
        // Deploy implementation
        bytes32 implSalt = keccak256(abi.encodePacked(salt, "impl"));
        address impl = IOutrunDeployer(outrunDeployer).deploy(implSalt, implCreationCode);
        // Deploy proxy
        bytes memory proxyCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initCalldata));
        return IOutrunDeployer(outrunDeployer).deploy(salt, proxyCode);
    }

    /// @dev Shared chain list for the three uAsset deploys: one definition site, so the
    /// omnichain peer/rate-limit set can never drift between UETH/UUSD/UBNB.
    function _sharedOmnichainIds() internal pure returns (uint32[] memory omnichainIds) {
        omnichainIds = new uint32[](9);
        omnichainIds[0] = 97; // BSC Testnet
        omnichainIds[1] = 84532; // Base Sepolia
        omnichainIds[2] = 421614; // Arbitrum Sepolia
        omnichainIds[3] = 43113; // Avalanche Fuji C-Chain
        omnichainIds[4] = 80002; // Polygon Amoy
        omnichainIds[5] = 57054; // Sonic Blaze
        omnichainIds[6] = 168587773; // Blast Sepolia
        omnichainIds[7] = 534351; // Scroll Sepolia
        omnichainIds[8] = 11155111; // Sepolia
        // omnichainIds[9] = 10143;     // Monad Testnet
        // omnichainIds[10] = 80069;    // Bera Sepolia
        // omnichainIds[11] = 59141;    // Linea Sepolia
        // omnichainIds[12] = 11155420; // Optimistic Sepolia
        // omnichainIds[13] = 300;      // ZKsync Sepolia
    }

    function _deployUAsset(uint256 nonce, string memory symbol, string memory assetWord) internal {
        uint32[] memory omnichainIds = _sharedOmnichainIds();

        (uint192 outboundRateLimit, uint64 outboundRateWindow) = _outboundRateLimitConfig(
            string.concat(symbol, "_OUTBOUND_RATE_LIMIT"), string.concat(symbol, "_OUTBOUND_RATE_WINDOW_SECONDS")
        );
        _validateUAssetDeploymentConfig(omnichainIds);

        bytes32 salt = keccak256(abi.encodePacked(string.concat("OmnichainUniversalAssets", assetWord), nonce));
        address deployedUAsset = _deployUpgradeable(
            abi.encodePacked(
                type(OutrunUniversalAssetsUpgradeable).creationCode, abi.encode(18, endpoints[uint32(block.chainid)])
            ),
            abi.encodeCall(
                OutrunUniversalAssetsUpgradeable.initialize,
                (string.concat("Omnichain Universal Assets ", assetWord), symbol, 18, owner)
            ),
            salt
        );
        bytes32 peer = bytes32(uint256(uint160(deployedUAsset)));

        _configureUAssetOmnichain(deployedUAsset, peer, omnichainIds, outboundRateLimit, outboundRateWindow);

        console.log(string.concat(symbol, " deployed on %s"), deployedUAsset);
    }

    /// @dev Thin wrappers keep the per-asset function names anchored by docs/deployment.md and
    /// the test harness. `symbol` (e.g. "UETH") drives env vars and the token ticker; `assetWord`
    /// (e.g. "ETH") drives the CREATE3 salt and name stem — `assetWord` must stay byte-stable
    /// per asset, or every deployed uAsset address changes.
    function _deployUETH(uint256 nonce) internal {
        _deployUAsset(nonce, "UETH", "ETH");
    }

    function _deployUUSD(uint256 nonce) internal {
        _deployUAsset(nonce, "UUSD", "USD");
    }

    function _deployUBNB(uint256 nonce) internal {
        _deployUAsset(nonce, "UBNB", "BNB");
    }

    function _outboundRateLimitConfig(string memory limitEnv, string memory windowEnv)
        internal
        view
        returns (uint192 limit, uint64 window)
    {
        (uint256 rawLimit, uint256 rawWindow) = _rawOutboundRateLimitConfig(limitEnv, windowEnv);
        if (rawLimit == 0) revert InvalidOutboundRateLimit();
        if (rawWindow == 0) revert InvalidOutboundRateWindow();

        limit = rawLimit.toUint192();
        window = rawWindow.toUint64();
    }

    function _rawOutboundRateLimitConfig(string memory limitEnv, string memory windowEnv)
        internal
        view
        virtual
        returns (uint256 limit, uint256 window)
    {
        limit = vm.envUint(limitEnv);
        window = vm.envUint(windowEnv);
    }

    function _validateUAssetDeploymentConfig(uint32[] memory omnichainIds) internal view {
        if (owner != deployer) revert InvalidOwner();
        address localEndpoint = endpoints[uint32(block.chainid)];
        uint32 localEndpointId = endpointIds[uint32(block.chainid)];
        // The env-supplied endpoint may be missing, an EOA (no code), or carry a zero local EID;
        // all three must fail closed before any deployment proceeds.
        if (localEndpoint == address(0) || localEndpoint.code.length == 0 || localEndpointId == 0) {
            revert InvalidEndpoint();
        }

        // Fail closed on a coded-but-not-an-endpoint contract: fold a reverting or mismatched
        // eid() view call into the named InvalidEndpoint error instead of an opaque revert.
        try ILayerZeroEndpointV2(localEndpoint).eid() returns (uint32 eid) {
            if (eid != localEndpointId) revert InvalidEndpoint();
        } catch {
            revert InvalidEndpoint();
        }

        // Guard against `_chainsInit` missing a chain that `_sharedOmnichainIds` lists: a zero
        // remote EID would otherwise configure rate limits and peers against endpoint id 0.
        uint256 omnichainIdsLength = omnichainIds.length;
        bool localChainIsMember;
        for (uint256 i; i < omnichainIdsLength; ++i) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) {
                localChainIsMember = true;
                continue;
            }
            if (endpointIds[omnichainId] == 0) revert InvalidOmnichainId();
        }
        // The local chain must be a member of the omnichain set. Otherwise the uAsset would be
        // deployed here with one-way peers while the remote chains never peer back, so a cross-chain
        // send would burn locally and never credit the remote.
        if (!localChainIsMember) revert InvalidOmnichainId();
    }

    function _configureUAssetOmnichain(
        address uAsset,
        bytes32 peer,
        uint32[] memory omnichainIds,
        uint192 outboundRateLimit,
        uint64 outboundRateWindow
    ) internal {
        uint256 omnichainIdsLength = omnichainIds.length;
        for (uint256 i; i < omnichainIdsLength; ++i) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            OutrunOFTUpgradeable(uAsset).setOutboundRateLimit(endpointId, outboundRateLimit, outboundRateWindow);
            IOAppCore(uAsset).setPeer(endpointId, peer);
            _assertUAssetOmnichainConfig(uAsset, endpointId, peer, outboundRateLimit, outboundRateWindow);
        }
    }

    function _assertUAssetOmnichainConfig(
        address uAsset,
        uint32 endpointId,
        bytes32 peer,
        uint192 outboundRateLimit,
        uint64 outboundRateWindow
    ) internal view {
        if (IOAppCore(uAsset).peers(endpointId) != peer) revert InvalidOmnichainConfig();

        OutrunRateLimiterUpgradeable.RateLimit memory rl = OutrunOFTUpgradeable(uAsset).rateLimits(endpointId);
        if (rl.limit != outboundRateLimit || rl.window != outboundRateWindow) revert InvalidOmnichainConfig();
    }

    /// @dev Hardcoded allowlist of chain ids where the mock stack may run: anvil (31337) plus the
    /// 14 testnets wired in `_chainsInit`. Single source of truth alongside `_chainsInit`: adding
    /// a testnet requires updating both, or the mock helpers below fail closed on the new chain.
    function _testnetChainIds() internal pure returns (uint32[] memory testnetChainIds) {
        testnetChainIds = new uint32[](15);
        testnetChainIds[0] = 31337; // Anvil local chain
        testnetChainIds[1] = 97; // BSC Testnet
        testnetChainIds[2] = 84532; // Base Sepolia
        testnetChainIds[3] = 421614; // Arbitrum Sepolia
        testnetChainIds[4] = 43113; // Avalanche Fuji C-Chain
        testnetChainIds[5] = 80002; // Polygon Amoy
        testnetChainIds[6] = 57054; // Sonic Blaze
        testnetChainIds[7] = 11155420; // Optimistic Sepolia
        testnetChainIds[8] = 300; // ZKsync Sepolia
        testnetChainIds[9] = 59141; // Linea Sepolia
        testnetChainIds[10] = 168587773; // Blast Sepolia
        testnetChainIds[11] = 534351; // Scroll Sepolia
        testnetChainIds[12] = 10143; // Monad Testnet
        testnetChainIds[13] = 80069; // Bera Sepolia
        testnetChainIds[14] = 11155111; // Sepolia
    }

    /// @dev Fail closed outside the testnet allowlist: the mock stack is testnet/local-only, and
    /// a mock SP wrongly activated on another chain would get a 1_000_000_000 ether minting cap
    /// (`_supportMockSY` -> `SP_DEFAULT_MINTING_CAP`) on the env-supplied uAsset, so unbacked
    /// minting up to that face value is exactly what this gate must prevent.
    function _assertTestnetChain() internal view {
        uint32[] memory testnetChainIds = _testnetChainIds();
        uint256 testnetChainIdsLength = testnetChainIds.length;
        for (uint256 i; i < testnetChainIdsLength; ++i) {
            if (uint256(testnetChainIds[i]) == block.chainid) return;
        }
        revert NotTestnetChain();
    }

    function _deployMockERC20(uint256 nonce) internal {
        _assertTestnetChain();
        if (owner != deployer) revert InvalidOwner();

        bytes32 salt = keccak256(abi.encodePacked("Faucet", nonce));
        bytes memory creationCode = abi.encodePacked(type(Faucet).creationCode, abi.encode(owner));
        address faucetAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockUSDC", nonce));
        creationCode = abi.encodePacked(type(MockUSDC).creationCode, abi.encode("Mock USDC", "USDC", 18, faucetAddr));
        address mockUSDCAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockAUSDC", nonce));
        creationCode = abi.encodePacked(
            type(MockAUSDC).creationCode, abi.encode("Mock aUSDC", "aUSDC", 18, mockUSDCAddr, faucetAddr)
        );
        address mockAUSDCAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockSUSDS", nonce));
        creationCode = abi.encodePacked(
            type(MockSUSDS).creationCode, abi.encode("Mock sUSDS", "sUSDS", 18, mockUSDCAddr, faucetAddr)
        );
        address mockSUSDSAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        IFaucet(faucetAddr).addToken(mockUSDCAddr, 1000000 * 1e18);
        IFaucet(faucetAddr).addToken(mockAUSDCAddr, 1000000 * 1e18);
        IFaucet(faucetAddr).addToken(mockSUSDSAddr, 1000000 * 1e18);

        console.log("Faucet deployed on %s", faucetAddr);
        console.log("MockUSDC deployed on %s", mockUSDCAddr);
        console.log("MockAUSDC deployed on %s", mockAUSDCAddr);
        console.log("MockSUSDS deployed on %s", mockSUSDSAddr);
    }

    function _deployMockOracle(uint256 nonce) internal {
        _assertTestnetChain();
        bytes32 salt = keccak256(abi.encodePacked("MockAUSDCOracle", nonce));
        bytes memory creationCode = abi.encodePacked(type(MockAUSDCOracle).creationCode, abi.encode(owner));
        address mockAUSDCOracle = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockSUSDSOracle", nonce));
        creationCode = abi.encodePacked(type(MockSUSDSOracle).creationCode, abi.encode(owner));
        address mockSUSDSOracle = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        console.log("MockAUSDCOracle deployed on %s", mockAUSDCOracle);
        console.log("MockSUSDSOracle deployed on %s", mockSUSDSOracle);
    }

    function _deployMockERC20SY(uint256 nonce) internal {
        _assertTestnetChain();
        address mockUSDC = vm.envAddress("MOCK_USDC");
        address mockAUSDC = vm.envAddress("MOCK_AUSDC");
        address mockSUSDS = vm.envAddress("MOCK_SUSDS");
        address mockAUSDCOracle = vm.envAddress("MOCK_AUSDC_ORACLE");
        address mockSUSDSOracle = vm.envAddress("MOCK_SUSDS_ORACLE");

        bytes32 salt = keccak256(abi.encodePacked("MockAUSDCSY", nonce));
        address mockAUSDCSY = _deployUpgradeable(
            type(MockOutrunAUSDCSYUpgradeable).creationCode,
            abi.encodeCall(MockOutrunAUSDCSYUpgradeable.initialize, (owner, mockUSDC, mockAUSDC, mockAUSDCOracle)),
            salt
        );

        salt = keccak256(abi.encodePacked("MockSUSDSSY", nonce));
        address mockSUSDSSY = _deployUpgradeable(
            type(MockOutrunSUSDSSYUpgradeable).creationCode,
            abi.encodeCall(MockOutrunSUSDSSYUpgradeable.initialize, (owner, mockUSDC, mockSUSDS, mockSUSDSOracle)),
            salt
        );

        console.log("MockAUSDCSY deployed on %s", mockAUSDCSY);
        console.log("MockSUSDSSY deployed on %s", mockSUSDSSY);
    }

    function _supportMockSY(uint256 nonce, string memory syEnv, string memory saltWord, string memory logLabel)
        internal
    {
        _assertTestnetChain();
        address syAddress = vm.envAddress(syEnv);
        address uusd = vm.envAddress("UUSD");
        address revenuePool = vm.envAddress("REVENUE_POOL");
        address keeper = vm.envAddress("KEEPER");
        _validateMockSupportConfig(syAddress, uusd, keeper, revenuePool);
        bytes32 salt = keccak256(abi.encodePacked(saltWord, nonce));
        address spAddress = _deployUpgradeable(
            abi.encodePacked(type(OutrunStakingPositionUpgradeable).creationCode),
            abi.encodeCall(
                OutrunStakingPositionUpgradeable.initialize,
                (owner, SP_DEFAULT_MIN_STAKE, revenuePool, syAddress, uusd, keeper)
            ),
            salt
        );

        IUniversalAssets(uusd).setMintingCap(spAddress, SP_DEFAULT_MINTING_CAP);

        console.log(string.concat(logLabel, " deployed on %s"), spAddress);
    }

    /// @dev Thin wrappers keep the documented function names (docs/deployment.md); env name,
    /// salt word and log label are passed through verbatim, and `saltWord` is the CREATE3 salt
    /// input — it must stay byte-identical to the historical deployment strings.
    function _supportMockAUSDC(uint256 nonce) internal {
        _supportMockSY(nonce, "MOCK_AUSDC_SY", "Mock SP aUSDC", "SP_AUSDC");
    }

    function _supportMockSUSDS(uint256 nonce) internal {
        _supportMockSY(nonce, "MOCK_SUSDS_SY", "Mock SP sUSDS", "SP_SUSDS");
    }

    function _validateMockSupportConfig(address sy, address uusd, address keeper, address revenuePool) internal view {
        if (owner != deployer) revert InvalidOwner();
        if (keeper == address(0)) revert InvalidKeeper();
        if (outrunDeployer == address(0) || revenuePool == address(0) || sy == address(0) || uusd == address(0)) {
            revert InvalidAddress();
        }
        if (outrunDeployer.code.length == 0 || sy.code.length == 0 || uusd.code.length == 0) {
            revert InvalidAddress();
        }

        try IOwnable(uusd).owner() returns (address uusdOwner) {
            if (uusdOwner != owner) revert InvalidOwner();
        } catch {
            revert InvalidOwner();
        }

        try IStandardizedYield(sy).exchangeRate() returns (uint256 exchangeRate) {
            if (exchangeRate == 0) revert InvalidAddress();
        } catch {
            revert InvalidAddress();
        }
    }

    function _applyRouterConfig() internal {
        if (vm.envExists("OUTRUN_ROUTER")) {
            outrunRouter = vm.envAddress("OUTRUN_ROUTER");
            enforceOutrunRouter = true;
        } else {
            outrunRouter = address(0);
            enforceOutrunRouter = false;
        }
    }

    function _deployOutrunRouter(uint256 nonce) internal {
        _validateMemeverseLauncher();
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", nonce));
        bytes memory creationCode =
            abi.encodePacked(type(OutrunRouter).creationCode, abi.encode(owner, memeverseLauncher));
        address outrunRouterAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // The router address is CREATE3(creator, salt) and must match OUTRUN_ROUTER across chains when set.
        if (enforceOutrunRouter && outrunRouterAddr != outrunRouter) revert InvalidAddress();

        console.log("OutrunRouter deployed on %s", outrunRouterAddr);
    }

    function _crossChainOFT() internal {
        address uusd = vm.envAddress("UUSD");
        bytes memory receiveOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(85000, 0);
        SendParam memory sendUAssetParam = SendParam({
            dstEid: vm.envUint("SCROLL_SEPOLIA_EID").toUint32(),
            to: bytes32(uint256(uint160(owner))),
            amountLD: 500000 * 1e18,
            minAmountLD: 0,
            extraOptions: receiveOptions,
            composeMsg: abi.encode(),
            oftCmd: abi.encode()
        });
        MessagingFee memory messagingFee = IOFT(uusd).quoteSend(sendUAssetParam, false);
        IOFT(uusd).send{value: messagingFee.nativeFee}(sendUAssetParam, messagingFee, msg.sender);
    }

    function _updateRouterLauncher() internal {
        _validateMemeverseLauncher();
        address router = outrunRouter != address(0) ? outrunRouter : vm.envAddress("OUTRUN_ROUTER");
        IOutrunRouter(router).setMemeverseLauncher(memeverseLauncher);
    }

    function _validateMemeverseLauncher() internal view {
        if (memeverseLauncher == address(0)) revert InvalidAddress();
    }
}
