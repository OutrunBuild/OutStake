// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import "./BaseScript.s.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { OutrunRouter, IOutrunRouter } from "../src/router/OutrunRouter.sol";
import { IYieldToken } from "../src/core/YieldContracts/interfaces/IYieldToken.sol";
import { IOutrunDeployer, OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { OutrunERC4626YieldToken } from "../src/core/YieldContracts/OutrunERC4626YieldToken.sol";
import { IOutrunStakeManager, OutrunStakingPosition } from "../src/core/Position/OutrunStakingPosition.sol";
import { OutrunUniversalPrincipalToken, IUniversalPrincipalToken } from "../src/core/YieldContracts/OutrunUniversalPrincipalToken.sol";

import { Faucet, IFaucet } from "../test/Faucet.sol";
import { MockUSDC } from "../test/MockUSDC.sol";
import { MockAUSDC } from "../test/MockAUSDC.sol";
import { MockSUSDS } from "../test/MockSUSDS.sol";
import { MockAUSDCOracle } from "../test/MockAUSDCOracle.sol";
import { MockSUSDSOracle } from "../test/MockSUSDSOracle.sol";
import { MockOutrunAUSDCSY } from "../test/MockOutrunAUSDCSY.sol";
import { MockOutrunSUSDSSY } from "../test/MockOutrunSUSDSSY.sol";

contract OutstakeScript is BaseScript {
    using OptionsBuilder for bytes;

    address internal ueth;
    address internal uusd;
    address internal ubnb;

    address internal owner;
    address internal keeper;
    address internal blastGovernor;
    address internal slisBNB;
    address internal revenuePool;
    address internal outrunDeployer;
    address internal outrunRouter;
    address internal memeverseLauncher;

    uint256 internal mtv;
    uint256 internal mintFeeRate;
    uint256 internal keeperFeeRate;
    uint256 internal protocolFeeRate;

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
        mtv = vm.envUint("MTV");

        mintFeeRate = vm.envUint("MINT_FEE_RATE");
        keeperFeeRate = vm.envUint("KEEPER_FEE_RATE");
        protocolFeeRate = vm.envUint("PROTOCOL_FEE_RATE");
        blastGovernor = vm.envAddress("BLAST_GOVERNOR");
        outrunRouter = vm.envAddress("OUTRUN_ROUTER");
        memeverseLauncher = vm.envAddress("MEMEVERSE_LAUNCHER");

        // _deployOutrunDeployer(1);

        _chainsInit();
        // _crossChainOFT();
        // _deployUETH(1);
        // _deployUUSD(1);
        // _deployUBNB(1);
        // _deployOutrunRouter(3);
        // _updateRouterLauncher();
        // _deployMockERC20(1);
        // _deployMockOracle(1);
        // _deployMockERC20SY(1);
        _supportMockAUSDC(11);   // 20000 runs
        _supportMockSUSDS(11);   // 20000 runs
    }

    function _deployOutrunDeployer(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        address outrunDeployerAddr = Create2.deploy(0, salt, abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner)));

        console.log("OutrunDeployer deployed on %s", outrunDeployerAddr);
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
        
        endpointIds[97] = uint32(vm.envUint("BSC_TESTNET_EID"));
        endpointIds[84532] = uint32(vm.envUint("BASE_SEPOLIA_EID"));
        endpointIds[421614] = uint32(vm.envUint("ARBITRUM_SEPOLIA_EID"));
        endpointIds[43113] = uint32(vm.envUint("AVALANCHE_FUJI_EID"));
        endpointIds[80002] = uint32(vm.envUint("POLYGON_AMOY_EID"));
        endpointIds[57054] = uint32(vm.envUint("SONIC_TESTNET_EID"));
        endpointIds[11155420] = uint32(vm.envUint("OPTIMISTIC_SEPOLIA_EID"));
        endpointIds[300] = uint32(vm.envUint("ZKSYNC_SEPOLIA_EID"));
        endpointIds[59141] = uint32(vm.envUint("LINEA_SEPOLIA_EID"));
        endpointIds[168587773] = uint32(vm.envUint("BLAST_SEPOLIA_EID"));
        endpointIds[534351] = uint32(vm.envUint("SCROLL_SEPOLIA_EID"));
        endpointIds[10143] = uint32(vm.envUint("MONAD_TESTNET_EID"));
        endpointIds[80069] = uint32(vm.envUint("BERA_SEPOLIA_EID"));
        endpointIds[11155111] = uint32(vm.envUint("ETHEREUM_SEPOLIA_EID"));
    }

    function _deployUETH(uint256 nonce) internal {
        bytes memory encodedArgs = abi.encode(
            "Omnichain Universal Principal ETH",
            "UETH",
            18,
            endpoints[uint32(block.chainid)],
            owner
        );
        bytes memory creationCode = abi.encodePacked(
            type(OutrunUniversalPrincipalToken).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("OmnichainUniversalPrincipalETH", nonce));

        address UETH = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        bytes32 peer = bytes32(uint256(uint160(UETH)));

        uint32[] memory omnichainIds = new uint32[](9);
        omnichainIds[0] = 97;           // BSC Testnet
        omnichainIds[1] = 84532;        // Base Sepolia
        omnichainIds[2] = 421614;       // Arbitrum Sepolia
        omnichainIds[3] = 43113;        // Avalanche Fuji C-Chain
        omnichainIds[4] = 80002;        // Polygon Amoy
        omnichainIds[5] = 57054;        // Sonic Blaze
        omnichainIds[6] = 168587773;    // Blast Sepolia
        omnichainIds[7] = 534351;       // Scroll Sepolia
        omnichainIds[8] = 11155111;     // Sepolia
        // omnichainIds[9] = 10143;     // Monad Testnet
        // omnichainIds[10] = 80069;    // Bera Sepolia
        // omnichainIds[11] = 59141;    // Linea Sepolia
        // omnichainIds[12] = 11155420; // Optimistic Sepolia
        // omnichainIds[13] = 300;      // ZKsync Sepolia
        

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, "InvalidOmnichainId");

            IOAppCore(UETH).setPeer(endpointId, peer);
        }

        console.log("UETH deployed on %s", UETH);
    }

    function _deployUUSD(uint256 nonce) internal {
        bytes memory encodedArgs = abi.encode(
            "Omnichain Universal Principal USD",
            "UUSD",
            18,
            endpoints[uint32(block.chainid)],
            owner
        );
        bytes memory creationCode = abi.encodePacked(
            type(OutrunUniversalPrincipalToken).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("OmnichainUniversalPrincipalUSD", nonce));

        address UUSD = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        bytes32 peer = bytes32(uint256(uint160(UUSD)));

        uint32[] memory omnichainIds = new uint32[](9);
        omnichainIds[0] = 97;           // BSC Testnet
        omnichainIds[1] = 84532;        // Base Sepolia
        omnichainIds[2] = 421614;       // Arbitrum Sepolia
        omnichainIds[3] = 43113;        // Avalanche Fuji C-Chain
        omnichainIds[4] = 80002;        // Polygon Amoy
        omnichainIds[5] = 57054;        // Sonic Blaze
        omnichainIds[6] = 168587773;    // Blast Sepolia
        omnichainIds[7] = 534351;       // Scroll Sepolia
        omnichainIds[8] = 11155111;    // Sepolia
        // omnichainIds[9] = 10143;     // Monad Testnet
        // omnichainIds[10] = 80069;    // Bera Sepolia
        // omnichainIds[11] = 59141;    // Linea Sepolia
        // omnichainIds[12] = 11155420; // Optimistic Sepolia
        // omnichainIds[13] = 300;      // ZKsync Sepolia
        

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, "InvalidOmnichainId");

            IOAppCore(UUSD).setPeer(endpointId, peer);
        }

        console.log("UUSD deployed on %s", UUSD);
    }

    function _deployUBNB(uint256 nonce) internal {
        bytes memory encodedArgs = abi.encode(
            "Omnichain Universal Principal BNB",
            "UBNB",
            18,
            endpoints[uint32(block.chainid)],
            owner
        );
        bytes memory creationCode = abi.encodePacked(
            type(OutrunUniversalPrincipalToken).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("OmnichainUniversalPrincipalBNB", nonce));

        address UBNB = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        bytes32 peer = bytes32(uint256(uint160(UBNB)));

        uint32[] memory omnichainIds = new uint32[](9);
        omnichainIds[0] = 97;           // BSC Testnet
        omnichainIds[1] = 84532;        // Base Sepolia
        omnichainIds[2] = 421614;       // Arbitrum Sepolia
        omnichainIds[3] = 43113;        // Avalanche Fuji C-Chain
        omnichainIds[4] = 80002;        // Polygon Amoy
        omnichainIds[5] = 57054;        // Sonic Blaze
        omnichainIds[6] = 168587773;    // Blast Sepolia
        omnichainIds[7] = 534351;       // Scroll Sepolia
        omnichainIds[8] = 11155111;     // Sepolia
        // omnichainIds[9] = 10143;     // Monad Testnet
        // omnichainIds[10] = 80069;    // Bera Sepolia
        // omnichainIds[11] = 59141;    // Linea Sepolia
        // omnichainIds[12] = 11155420; // Optimistic Sepolia
        // omnichainIds[13] = 300;      // ZKsync Sepolia
        

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, "InvalidOmnichainId");

            IOAppCore(UBNB).setPeer(endpointId, peer);
        }

        console.log("UBNB deployed on %s", UBNB);
    }

    function _deployMockERC20(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("Faucet", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(Faucet).creationCode,
            abi.encode(owner)
        );
        address faucetAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockUSDC", nonce));
        creationCode = abi.encodePacked(
            type(MockUSDC).creationCode,
            abi.encode(
                "Mock USDC",
                "USDC",
                18,
                faucetAddr
            )
        );
        address mockUSDCAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        
        salt = keccak256(abi.encodePacked("MockAUSDC", nonce));
        creationCode = abi.encodePacked(
            type(MockAUSDC).creationCode,
            abi.encode(
                "Mock aUSDC",
                "aUSDC",
                18,
                mockUSDCAddr,
                faucetAddr
            )
        );
        address mockAUSDCAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockSUSDS", nonce));
        creationCode = abi.encodePacked(
            type(MockSUSDS).creationCode,
            abi.encode(
                "Mock sUSDS",
                "sUSDS",
                18,
                mockUSDCAddr,
                faucetAddr
            )
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
        bytes memory creationCode = abi.encodePacked(
            type(MockAUSDCOracle).creationCode,
            abi.encode(owner)
        );
        address mockAUSDCOracle = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockSUSDSOracle", nonce));
        creationCode = abi.encodePacked(
            type(MockSUSDSOracle).creationCode,
            abi.encode(owner)
        );
        address mockSUSDSOracle = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        console.log("MockAUSDCOracle deployed on %s", mockAUSDCOracle);
        console.log("MockSUSDSOracle deployed on %s", mockSUSDSOracle);
    }

    function _deployMockERC20SY(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MockOutrunAUSDCSY", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MockOutrunAUSDCSY).creationCode,
            abi.encode(
                owner, 
                vm.envAddress("MOCK_USDC"), 
                vm.envAddress("MOCK_AUSDC"),
                vm.envAddress("MOCK_AUSDC_ORACLE")
            )
        );
        address aUSDCSYAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        console.log("SY_AUSDC deployed on %s", aUSDCSYAddress);

        salt = keccak256(abi.encodePacked("MockOutrunSUSDSSY", nonce));
        creationCode = abi.encodePacked(
            type(MockOutrunSUSDSSY).creationCode,
            abi.encode(
                owner, 
                vm.envAddress("MOCK_USDC"), 
                vm.envAddress("MOCK_SUSDS"),
                vm.envAddress("MOCK_SUSDS_ORACLE")
            )
        );
        address sUSDSSYAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        console.log("SY_SUSDS deployed on %s", sUSDSSYAddress);
    }

    // Mock aUSDC
    function _supportMockAUSDC(uint256 nonce) internal {
        // YT
        bytes32 salt = keccak256(abi.encodePacked("Mock YT aUSDC", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(OutrunERC4626YieldToken).creationCode,
            abi.encode(
                "Outrun aUSDC Yield Token",
                "YT aUSDC",
                18,
                owner, 
                revenuePool, 
                protocolFeeRate
            )
        );
        address aUSDCYTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // SP
        address aUSDCSYAddress = vm.envAddress("MOCK_AUSDC_SY");
        salt = keccak256(abi.encodePacked("Mock SP aUSDC", nonce));
        creationCode = abi.encodePacked(
            type(OutrunStakingPosition).creationCode,
            abi.encode(
                owner,
                "Outrun aUSDC Staking Position",
                "SP aUSDC",
                18,
                0,
                mtv,
                mintFeeRate,
                keeperFeeRate,
                protocolFeeRate,
                revenuePool,
                aUSDCSYAddress,
                aUSDCYTAddress,
                uusd
            )
        );
        address aUSDCSPAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        IUniversalPrincipalToken(uusd).grantMintingCap(aUSDCSPAddress, 1000000000 ether);
        IOutrunStakeManager(aUSDCSPAddress).setLockupDuration(1, 365);
        IOutrunStakeManager(aUSDCSPAddress).addKeeper(keeper);
        IYieldToken(aUSDCYTAddress).initialize(aUSDCSYAddress, aUSDCSPAddress);

        console.log("SP_AUSDC deployed on %s", aUSDCSPAddress);
        console.log("YT_AUSDC deployed on %s", aUSDCYTAddress);
    }

    // Mock sUSDS
    function _supportMockSUSDS(uint256 nonce) internal {
        // YT
        bytes32 salt = keccak256(abi.encodePacked("Mock YT sUSDS", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(OutrunERC4626YieldToken).creationCode,
            abi.encode(
                "Outrun sUSDS Yield Token",
                "YT sUSDS",
                18,
                owner, 
                revenuePool, 
                protocolFeeRate
            )
        );
        address sUSDSYTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // SP
        address sUSDSSYAddress = vm.envAddress("MOCK_SUSDS_SY");
        salt = keccak256(abi.encodePacked("Mock SP sUSDS", nonce));
        creationCode = abi.encodePacked(
            type(OutrunStakingPosition).creationCode,
            abi.encode(
                owner,
                "Outrun sUSDS Staking Position",
                "SP sUSDS",
                18,
                0,
                mtv,
                mintFeeRate,
                protocolFeeRate,
                revenuePool,
                sUSDSSYAddress,
                sUSDSYTAddress,
                uusd
            )
        );
        address sUSDSSPAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        IUniversalPrincipalToken(uusd).grantMintingCap(sUSDSSPAddress, 1000000000 ether);
        IOutrunStakeManager(sUSDSSPAddress).setLockupDuration(1, 365);
        IOutrunStakeManager(sUSDSSPAddress).addKeeper(keeper);
        IYieldToken(sUSDSYTAddress).initialize(sUSDSSYAddress, sUSDSSPAddress);

        console.log("SP_SUSDS deployed on %s", sUSDSSPAddress);
        console.log("YT_SUSDS deployed on %s", sUSDSYTAddress);
    }

    function _deployOutrunRouter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(OutrunRouter).creationCode,
            abi.encode(owner, memeverseLauncher)
        );
        address outrunRouterAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        console.log("OutrunRouter deployed on %s", outrunRouterAddr);
    }

    function _crossChainOFT() internal {
        bytes memory receiveOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(85000, 0);
        SendParam memory sendUPTParam = SendParam({
                dstEid: uint32(vm.envUint("SCROLL_SEPOLIA_EID")),
                to: bytes32(uint256(uint160(owner))),
                amountLD: 500000 * 1e18,
                minAmountLD: 0,
                extraOptions: receiveOptions,
                composeMsg: abi.encode(),
                oftCmd: abi.encode()
            });
        MessagingFee memory messagingFee = IOFT(uusd).quoteSend(sendUPTParam, false);
        IOFT(uusd).send{value: messagingFee.nativeFee}(sendUPTParam, messagingFee, msg.sender);
    }

    function _updateRouterLauncher() internal {
        IOutrunRouter(outrunRouter).setMemeverseLauncher(memeverseLauncher);
    }
}