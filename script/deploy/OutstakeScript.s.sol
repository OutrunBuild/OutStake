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
import {MockUSDC} from "../../test/support/MockUSDC.sol";
import {MockAUSDC} from "../../test/support/MockAUSDC.sol";
import {MockSUSDS} from "../../test/support/MockSUSDS.sol";
import {MockAUSDCOracle} from "../../test/support/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "../../test/support/MockSUSDSOracle.sol";
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

    address internal ueth;
    address internal uusd;
    address internal ubnb;

    address internal owner;
    address internal keeper;
    address internal revenuePool;
    address internal outrunDeployer;
    address internal outrunRouter;
    address internal memeverseLauncher;

    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    function run() public broadcaster {
        ueth = vm.envAddress("UETH");
        uusd = vm.envAddress("UUSD");
        ubnb = vm.envAddress("UBNB");
        owner = vm.envAddress("OWNER");
        keeper = vm.envAddress("KEEPER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        outrunRouter = vm.envAddress("OUTRUN_ROUTER");
        memeverseLauncher = vm.envAddress("MEMEVERSE_LAUNCHER");

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
        // _supportMockAUSDC(13);   // 20000 runs
        // _supportMockSUSDS(13);   // 20000 runs
    }

    function _deployOutrunDeployer(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        address outrunDeployerAddr =
            Create2.deploy(0, salt, abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner)));

        console.log("OutrunDeployer deployed on %s", outrunDeployerAddr);
    }

    /// @dev Fails closed unless `OUTRUN_DEPLOYER` is the address `_deployOutrunDeployer` would
    /// CREATE2-deploy. The creator is the script contract (`address(this)`): Foundry deploys the
    /// script contract itself deterministically (special nonce) before broadcast, and an EOA cannot
    /// execute CREATE2. Cross-chain same-address deployment depends on the script contract holding
    /// the same address on every chain, so a mismatch here would silently scatter the
    /// OutrunDeployer/peer=own-address design across divergent addresses.
    function _assertOutrunDeployer(uint256 nonce) internal view {
        // Deployer must equal owner (mirrors `_validateUAssetDeploymentConfig` / docs OWNER==broadcaster).
        if (owner != deployer) revert InvalidOwner();

        bytes32 salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        bytes memory initcode = abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner));
        address expected = Create2.computeAddress(salt, keccak256(initcode));

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

    /// @dev Deploys an upgradeable contract via ERC1967Proxy using CREATE2
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

    function _deployUETH(uint256 nonce) internal {
        uint32[] memory omnichainIds = _sharedOmnichainIds();

        (uint192 outboundRateLimit, uint64 outboundRateWindow) =
            _outboundRateLimitConfig("UETH_OUTBOUND_RATE_LIMIT", string.concat("UETH_OUTBOUND_RATE_", "WINDOW_SECONDS"));
        _validateUAssetDeploymentConfig(omnichainIds);

        bytes32 salt = keccak256(abi.encodePacked("OmnichainUniversalAssetsETH", nonce));
        address UETH = _deployUpgradeable(
            abi.encodePacked(
                type(OutrunUniversalAssetsUpgradeable).creationCode, abi.encode(18, endpoints[uint32(block.chainid)])
            ),
            abi.encodeCall(
                OutrunUniversalAssetsUpgradeable.initialize, ("Omnichain Universal Assets ETH", "UETH", 18, owner)
            ),
            salt
        );
        bytes32 peer = bytes32(uint256(uint160(UETH)));

        _configureUAssetOmnichain(UETH, peer, omnichainIds, outboundRateLimit, outboundRateWindow);

        console.log("UETH deployed on %s", UETH);
    }

    function _deployUUSD(uint256 nonce) internal {
        uint32[] memory omnichainIds = _sharedOmnichainIds();

        (uint192 outboundRateLimit, uint64 outboundRateWindow) =
            _outboundRateLimitConfig("UUSD_OUTBOUND_RATE_LIMIT", string.concat("UUSD_OUTBOUND_RATE_", "WINDOW_SECONDS"));
        _validateUAssetDeploymentConfig(omnichainIds);

        bytes32 salt = keccak256(abi.encodePacked("OmnichainUniversalAssetsUSD", nonce));
        address UUSD = _deployUpgradeable(
            abi.encodePacked(
                type(OutrunUniversalAssetsUpgradeable).creationCode, abi.encode(18, endpoints[uint32(block.chainid)])
            ),
            abi.encodeCall(
                OutrunUniversalAssetsUpgradeable.initialize, ("Omnichain Universal Assets USD", "UUSD", 18, owner)
            ),
            salt
        );
        bytes32 peer = bytes32(uint256(uint160(UUSD)));

        _configureUAssetOmnichain(UUSD, peer, omnichainIds, outboundRateLimit, outboundRateWindow);

        console.log("UUSD deployed on %s", UUSD);
    }

    function _deployUBNB(uint256 nonce) internal {
        uint32[] memory omnichainIds = _sharedOmnichainIds();

        (uint192 outboundRateLimit, uint64 outboundRateWindow) =
            _outboundRateLimitConfig("UBNB_OUTBOUND_RATE_LIMIT", string.concat("UBNB_OUTBOUND_RATE_", "WINDOW_SECONDS"));
        _validateUAssetDeploymentConfig(omnichainIds);

        bytes32 salt = keccak256(abi.encodePacked("OmnichainUniversalAssetsBNB", nonce));
        address UBNB = _deployUpgradeable(
            abi.encodePacked(
                type(OutrunUniversalAssetsUpgradeable).creationCode, abi.encode(18, endpoints[uint32(block.chainid)])
            ),
            abi.encodeCall(
                OutrunUniversalAssetsUpgradeable.initialize, ("Omnichain Universal Assets BNB", "UBNB", 18, owner)
            ),
            salt
        );
        bytes32 peer = bytes32(uint256(uint160(UBNB)));

        _configureUAssetOmnichain(UBNB, peer, omnichainIds, outboundRateLimit, outboundRateWindow);

        console.log("UBNB deployed on %s", UBNB);
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
        if (localEndpoint == address(0) || localEndpoint.code.length == 0 || localEndpointId == 0) {
            revert InvalidEndpoint();
        }

        try ILayerZeroEndpointV2(localEndpoint).eid() returns (uint32 eid) {
            if (eid != localEndpointId) revert InvalidEndpoint();
        } catch {
            revert InvalidEndpoint();
        }

        uint256 omnichainIdsLength = omnichainIds.length;
        for (uint256 i; i < omnichainIdsLength; ++i) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;
            if (endpointIds[omnichainId] == 0) revert InvalidOmnichainId();
        }
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

    function _deployMockERC20(uint256 nonce) internal {
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

    function _supportMockAUSDC(uint256 nonce) internal {
        address aUSDCSYAddress = vm.envAddress("MOCK_AUSDC_SY");
        _validateMockSupportConfig(aUSDCSYAddress);
        bytes32 salt = keccak256(abi.encodePacked("Mock SP aUSDC", nonce));
        address aUSDCSPAddress = _deployUpgradeable(
            abi.encodePacked(type(OutrunStakingPositionUpgradeable).creationCode),
            abi.encodeCall(
                OutrunStakingPositionUpgradeable.initialize, (owner, 0, revenuePool, aUSDCSYAddress, uusd, keeper)
            ),
            salt
        );

        IUniversalAssets(uusd).setMintingCap(aUSDCSPAddress, 1000000000 ether);

        console.log("SP_AUSDC deployed on %s", aUSDCSPAddress);
    }

    function _supportMockSUSDS(uint256 nonce) internal {
        address sUSDSSYAddress = vm.envAddress("MOCK_SUSDS_SY");
        _validateMockSupportConfig(sUSDSSYAddress);
        bytes32 salt = keccak256(abi.encodePacked("Mock SP sUSDS", nonce));
        address sUSDSSPAddress = _deployUpgradeable(
            abi.encodePacked(type(OutrunStakingPositionUpgradeable).creationCode),
            abi.encodeCall(
                OutrunStakingPositionUpgradeable.initialize, (owner, 0, revenuePool, sUSDSSYAddress, uusd, keeper)
            ),
            salt
        );

        IUniversalAssets(uusd).setMintingCap(sUSDSSPAddress, 1000000000 ether);

        console.log("SP_SUSDS deployed on %s", sUSDSSPAddress);
    }

    function _validateMockSupportConfig(address sy) internal view {
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

    function _deployOutrunRouter(uint256 nonce) internal {
        _validateMemeverseLauncher();
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", nonce));
        bytes memory creationCode =
            abi.encodePacked(type(OutrunRouter).creationCode, abi.encode(owner, memeverseLauncher));
        address outrunRouterAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        console.log("OutrunRouter deployed on %s", outrunRouterAddr);
    }

    function _crossChainOFT() internal {
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
        IOutrunRouter(outrunRouter).setMemeverseLauncher(memeverseLauncher);
    }

    function _validateMemeverseLauncher() internal view {
        if (memeverseLauncher == address(0)) revert InvalidAddress();
    }
}
