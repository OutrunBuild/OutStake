// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunOFTUpgradeable} from "../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {MockLzEndpoint} from "../upgradeable/mocks/OFTMocks.sol";
import {EmptyMockLauncher} from "../upgradeable/mocks/EmptyMockLauncher.sol";

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

    function _rawOutboundRateLimitConfig(string memory, string memory)
        internal
        view
        override
        returns (uint256 limit, uint256 window)
    {
        return (rawLimit, rawWindow);
    }
}

contract OutstakeScriptUpgradeableTest is Test {
    uint32 internal constant LOCAL_CHAIN_ID = 97;
    uint32 internal constant LOCAL_EID = 40_102;

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

    function testUpdateRouterLauncherRevertsWhenLauncherIsZero() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        script.setRouterConfig(address(router), address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedUpdateRouterLauncher();
    }

    function testUpdateRouterLauncherRevertsWhenLauncherHasNoCode() external {
        OutrunRouter router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        script.setRouterConfig(address(router), address(0x1234));

        vm.expectRevert(abi.encodeWithSelector(OutrunRouter.InvalidMemeverseLauncher.selector, address(0x1234)));
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

        bytes32 salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        bytes memory initcode = abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner));
        script.configure(owner, owner, Create2.computeAddress(salt, keccak256(initcode), address(script)));

        script.exposedAssertOutrunDeployer(nonce);
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
