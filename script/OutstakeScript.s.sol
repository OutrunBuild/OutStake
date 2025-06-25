// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import "./BaseScript.s.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { OutrunRouter, IOutrunRouter } from "../src/router/OutrunRouter.sol";
import { ISlisBNBProvider } from "../src/external/lista/ISlisBNBProvider.sol";
import { IYieldToken } from "../src/core/YieldContracts/interfaces/IYieldToken.sol";
import { IListaBNBStakeManager } from "../src/external/lista/IListaBNBStakeManager.sol";
import { IOutrunDeployer, OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { IOutrunStakeManager, OutrunStakingPosition } from "../src/core/Position/OutrunStakingPosition.sol";
import { OutrunERC4626YieldToken } from "../src/core/YieldContracts/OutrunERC4626YieldToken.sol";
import { IPrincipalToken, OutrunPrincipalToken } from "../src/core/YieldContracts/OutrunPrincipalToken.sol";
import { OutrunUniversalPrincipalToken, IUniversalPrincipalToken } from "../src/core/YieldContracts/OutrunUniversalPrincipalToken.sol";
import { IOutrunPointsYieldToken, OutrunPointsYieldToken } from "../src/core/YieldContracts/OutrunPointsYieldToken.sol";

import { OutrunSlisBNBSY } from "../src/core/StandardizedYield/implementations/Lista/OutrunSlisBNBSY.sol";
import { OutrunSlisUSDSY } from "../src/core/StandardizedYield/implementations/Lista/OutrunSlisUSDSY.sol";
import { OutrunBlastUSDSY } from "../src/core/StandardizedYield/implementations/Blast/OutrunBlastUSDSY.sol";
import { OutrunBlastETHSY } from "../src/core/StandardizedYield/implementations/Blast/OutrunBlastETHSY.sol";

import { Faucet, IFaucet } from "../test/Faucet.sol";
import { MockETH } from "../test/MockETH.sol";
import { MockWeETH } from "../test/MockWeETH.sol";
import { MockWstETH } from "../test/MockWstETH.sol";
import { MockOutrunWeETHSY } from "../test/MockOutrunWeETHSY.sol";
import { MockOutrunWstETHSY } from "../test/MockOutrunWstETHSY.sol";

contract OutstakeScript is BaseScript {
    using OptionsBuilder for bytes;

    address internal ueth;
    address internal uusd;
    address internal ubnb;

    address internal owner;
    address internal blastGovernor;
    address internal slisBNB;
    address internal revenuePool;
    address internal listaBNBStakeManager;
    address internal outrunDeployer;
    address internal outrunRouter;
    address internal memeverseLauncher;

    uint256 internal protocolFeeRate;

    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    function run() public broadcaster {
        ueth = vm.envAddress("UETH");
        uusd = vm.envAddress("UUSD");
        ubnb = vm.envAddress("UBNB");
        owner = vm.envAddress("OWNER");
        slisBNB = vm.envAddress("TESTNET_SLISBNB");
        revenuePool = vm.envAddress("REVENUE_POOL");
        listaBNBStakeManager = vm.envAddress("TESTNET_LISTA_BNB_STAKE_MANAGER");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        protocolFeeRate = vm.envUint("PROTOCOL_FEE_RATE");
        blastGovernor = vm.envAddress("BLAST_GOVERNOR");
        outrunRouter = vm.envAddress("OUTRUN_ROUTER");
        memeverseLauncher = vm.envAddress("MEMEVERSE_LAUNCHER");

        // _deployOutrunDeployer(0);

        _chainsInit();

        // _crossChainOFT();
        // _deployUETH(3);
        // _deployOutrunRouter(4);
        // _updateRouterLauncher();
        // _deployMockERC20(3);
        // _deployMockERC20SY(2)
        // _supportMockWeETH(6);
        _supportMockWstETH(6);

        // _supportSlisBNB();
        // _supportSlisUSD();
        // _supportBlastETH();
        // _supportBlastUSD();
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
        endpoints[57054] = vm.envAddress("SONIC_BLAZE_ENDPOINT");
        endpoints[11155420] = vm.envAddress("OPTIMISTIC_SEPOLIA_ENDPOINT");
        endpoints[300] = vm.envAddress("ZKSYNC_SEPOLIA_ENDPOINT");
        endpoints[59141] = vm.envAddress("LINEA_SEPOLIA_ENDPOINT");
        endpoints[168587773] = vm.envAddress("BLAST_SEPOLIA_ENDPOINT");
        endpoints[534351] = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
        endpoints[10143] = vm.envAddress("MONAD_TESTNET_ENDPOINT");
        endpoints[80069] = vm.envAddress("BERA_SEPOLIA_ENDPOINT");
        
        endpointIds[97] = uint32(vm.envUint("BSC_TESTNET_EID"));
        endpointIds[84532] = uint32(vm.envUint("BASE_SEPOLIA_EID"));
        endpointIds[421614] = uint32(vm.envUint("ARBITRUM_SEPOLIA_EID"));
        endpointIds[43113] = uint32(vm.envUint("AVALANCHE_FUJI_EID"));
        endpointIds[80002] = uint32(vm.envUint("POLYGON_AMOY_EID"));
        endpointIds[57054] = uint32(vm.envUint("SONIC_BLAZE_EID"));
        endpointIds[11155420] = uint32(vm.envUint("OPTIMISTIC_SEPOLIA_EID"));
        endpointIds[300] = uint32(vm.envUint("ZKSYNC_SEPOLIA_EID"));
        endpointIds[59141] = uint32(vm.envUint("LINEA_SEPOLIA_EID"));
        endpointIds[168587773] = uint32(vm.envUint("BLAST_SEPOLIA_EID"));
        endpointIds[534351] = uint32(vm.envUint("SCROLL_SEPOLIA_EID"));
        endpointIds[10143] = uint32(vm.envUint("MONAD_TESTNET_EID"));
        endpointIds[80069] = uint32(vm.envUint("BERA_SEPOLIA_EID"));
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
        bytes32 salt = keccak256(abi.encodePacked("OutrunUniversalPrincipalToken", nonce));

        address UETH = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        bytes32 peer = bytes32(uint256(uint160(UETH)));

        uint32[] memory omnichainIds = new uint32[](8);
        omnichainIds[0] = 97;           // BSC Testnet
        omnichainIds[1] = 84532;        // Base Sepolia
        omnichainIds[2] = 421614;       // Arbitrum Sepolia
        omnichainIds[3] = 43113;        // Avalanche Fuji C-Chain
        omnichainIds[4] = 80002;        // Polygon Amoy
        omnichainIds[5] = 57054;        // Sonic Blaze
        omnichainIds[6] = 168587773;    // Blast Sepolia
        omnichainIds[7] = 534351;       // Scroll Sepolia
        // omnichainIds[8] = 10143;        // Monad Testnet
        // omnichainIds[9] = 80069;        // Bera Sepolia
        // omnichainIds[10] = 59141;    // Linea Sepolia
        // omnichainIds[11] = 11155420; // Optimistic Sepolia
        // omnichainIds[12] = 300;      // ZKsync Sepolia
        

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

    function _deployMockERC20(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("Faucet", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(Faucet).creationCode,
            abi.encode(owner)
        );
        address faucetAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockETH", nonce));
        creationCode = abi.encodePacked(
            type(MockETH).creationCode,
            abi.encode(
                "Mock ETH",
                "ETH",
                18,
                faucetAddr
            )
        );
        address mockETHAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        
        salt = keccak256(abi.encodePacked("MockWeETH", nonce));
        creationCode = abi.encodePacked(
            type(MockWeETH).creationCode,
            abi.encode(
                "Mock weETH",
                "weETH",
                18,
                mockETHAddr,
                faucetAddr
            )
        );
        address mockWeETHAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockWstETH", nonce));
        creationCode = abi.encodePacked(
            type(MockWstETH).creationCode,
            abi.encode(
                "Mock wstETH",
                "wstETH",
                18,
                mockETHAddr,
                faucetAddr
            )
        );
        address mockWstETHAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        IFaucet(faucetAddr).addToken(mockETHAddr, 1000 * 1e18);
        IFaucet(faucetAddr).addToken(mockWeETHAddr, 1000 * 1e18);
        IFaucet(faucetAddr).addToken(mockWstETHAddr, 1000 * 1e18);

        console.log("Faucet deployed on %s", faucetAddr);
        console.log("MockETH deployed on %s", mockETHAddr);
        console.log("MockWeETH deployed on %s", mockWeETHAddr);
        console.log("MockWstETH deployed on %s", mockWstETHAddr);
    }

    function _deployMockERC20SY(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MockOutrunWeETHSY", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MockOutrunWeETHSY).creationCode,
            abi.encode(
                owner, 
                vm.envAddress("MOCK_ETH"), 
                vm.envAddress("MOCK_WEETH")
            )
        );
        address weETHSYAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        console.log("SY_WEETH deployed on %s", weETHSYAddress);

        salt = keccak256(abi.encodePacked("MockOutrunWstETHSY", nonce));
        creationCode = abi.encodePacked(
            type(MockOutrunWstETHSY).creationCode,
            abi.encode(
                owner, 
                vm.envAddress("MOCK_ETH"), 
                vm.envAddress("MOCK_WSTETH")
            )
        );
        address wstETHSYAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        console.log("SY_WSTETH deployed on %s", wstETHSYAddress);
    }

    // Mock Ether.Fi
    function _supportMockWeETH(uint256 nonce) internal {
        // PT
        bytes32 salt = keccak256(abi.encodePacked("Mock-PT-weETH", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(OutrunPrincipalToken).creationCode,
            abi.encode(
                "Outrun weETH Principal Token",
                "PT-weETH",
                18,
                owner
            )
        );
        address weETHPTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        
        // YT
        salt = keccak256(abi.encodePacked("Mock-YT-weETH", nonce));
        creationCode = abi.encodePacked(
            type(OutrunERC4626YieldToken).creationCode,
            abi.encode(
                "Outrun weETH Yield Token",
                "YT-weETH",
                18,
                owner, 
                revenuePool, 
                protocolFeeRate
            )
        );
        address weETHYTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        
        // PYT
        salt = keccak256(abi.encodePacked("Mock-PYT-weETH", nonce));
        creationCode = abi.encodePacked(
            type(OutrunPointsYieldToken).creationCode,
            abi.encode(
                "Outrun weETH Points Yield Token",
                "PYT-weETH",
                18,
                owner, 
                revenuePool, 
                protocolFeeRate
            )
        );
        address weETHPYTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // SP
        address weETHSYAddress = vm.envAddress("MOCK_WEETH_SY");
        salt = keccak256(abi.encodePacked("Mock-SP-weETH", nonce));
        creationCode = abi.encodePacked(
            type(OutrunStakingPosition).creationCode,
            abi.encode(
                owner,
                "Outrun weETH Staking Position",
                "SP-weETH",
                18,
                0,
                protocolFeeRate,
                revenuePool,
                weETHSYAddress,
                weETHPTAddress,
                weETHYTAddress,
                weETHPYTAddress,
                ueth
            )
        );
        address weETHSPAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);
        IUniversalPrincipalToken(ueth).setAuthorized(weETHSPAddress, true);
        IOutrunStakeManager(weETHSPAddress).setLockupDuration(0, 365);
        IPrincipalToken(weETHPTAddress).initialize(weETHSPAddress);
        IYieldToken(weETHYTAddress).initialize(weETHSYAddress, weETHSPAddress);
        IOutrunPointsYieldToken(weETHPYTAddress).initialize(weETHSPAddress);

        console.log("PT_WEETH deployed on %s", weETHPTAddress);
        console.log("YT_WEETH deployed on %s", weETHYTAddress);
        console.log("PYT_WEETH deployed on %s", weETHPYTAddress);
        console.log("SP_WEETH deployed on %s", weETHSPAddress);
    }

    // Mock Lido
    function _supportMockWstETH(uint256 nonce) internal {
        // PT
        bytes32 salt = keccak256(abi.encodePacked("Mock-PT-wstETH", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(OutrunPrincipalToken).creationCode,
            abi.encode(
                "Outrun wstETH Principal Token",
                "PT-wstETH",
                18,
                owner
            )
        );
        address wstETHPTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // YT
        salt = keccak256(abi.encodePacked("Mock-YT-wstETH", nonce));
        creationCode = abi.encodePacked(
            type(OutrunERC4626YieldToken).creationCode,
            abi.encode(
                "Outrun wstETH Yield Token",
                "YT-wstETH",
                18,
                owner, 
                revenuePool, 
                protocolFeeRate
            )
        );
        address wstETHYTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // PYT
        salt = keccak256(abi.encodePacked("Mock-PYT-wstETH", nonce));
        creationCode = abi.encodePacked(
            type(OutrunPointsYieldToken).creationCode,
            abi.encode(
                "Outrun wstETH Points Yield Token",
                "PYT-wstETH",
                18,
                owner, 
                revenuePool, 
                protocolFeeRate
            )
        );
        address wstETHPYTAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // SP
        address wstETHSYAddress = vm.envAddress("MOCK_WSTETH_SY");
        salt = keccak256(abi.encodePacked("Mock-SP-wstETH", nonce));
        creationCode = abi.encodePacked(
            type(OutrunStakingPosition).creationCode,
            abi.encode(
                owner,
                "Outrun wstETH Staking Position",
                "SP-wstETH",
                18,
                0,
                protocolFeeRate,
                revenuePool,
                wstETHSYAddress,
                wstETHPTAddress,
                wstETHYTAddress,
                wstETHPYTAddress,
                ueth
            )
        );
        address wstETHSPAddress = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        IUniversalPrincipalToken(ueth).setAuthorized(wstETHSPAddress, true);
        IOutrunStakeManager(wstETHSPAddress).setLockupDuration(0, 365);
        IPrincipalToken(wstETHPTAddress).initialize(wstETHSPAddress);
        IYieldToken(wstETHYTAddress).initialize(wstETHSYAddress, wstETHSPAddress);
        IOutrunPointsYieldToken(wstETHPYTAddress).initialize(wstETHSPAddress);

        console.log("PT_WSTETH deployed on %s", wstETHPTAddress);
        console.log("YT_WSTETH deployed on %s", wstETHYTAddress);
        console.log("PYT_WSTETH deployed on %s", wstETHPYTAddress);
        console.log("SP_WSTETH deployed on %s", wstETHSPAddress);
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

    /**
     * Support slisBNB 
     */
    function _supportSlisBNB() internal {
        if (block.chainid != vm.envUint("BSC_TESTNET_CHAINID")) return;

        // SY
        OutrunSlisBNBSY SY_SLISBNB = new OutrunSlisBNBSY(
            owner, 
            slisBNB, 
            vm.envAddress("DELEGATE_TO"), 
            IListaBNBStakeManager(listaBNBStakeManager), 
            ISlisBNBProvider(vm.envAddress("TESTNET_SLISBNB_PROVIDER"))
        );
        address slisBNBSYAddress = address(SY_SLISBNB);

        // PT
        OutrunPrincipalToken PT_SLISBNB = new OutrunPrincipalToken(
            "Outrun slisBNB Principal Token",
            "PT-slisBNB",
            18,
            owner
        );
        address slisBNBPTAddress = address(PT_SLISBNB);
        
        // YT
        OutrunERC4626YieldToken YT_SLISBNB = new OutrunERC4626YieldToken(
            "Outrun slisBNB Yield Token",
            "YT-slisBNB",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address slisBNBYTAddress = address(YT_SLISBNB);

        // PYT
        OutrunPointsYieldToken PYT_SLISBNB = new OutrunPointsYieldToken(
            "Outrun slisBNB Points Yield Token",
            "PYT-slisBNB",
            18,
            owner
        );
        address slisBNBPYTAddress = address(PYT_SLISBNB);

        // SP
        OutrunStakingPosition SP_SLISBNB = new OutrunStakingPosition(
            owner,
            "Outrun SlisBNB Staking Position",
            "SP-slisBNB",
            18,
            0,
            protocolFeeRate,
            revenuePool,
            slisBNBSYAddress,
            slisBNBPTAddress,
            slisBNBYTAddress,
            slisBNBPYTAddress,
            ubnb
        );
        SP_SLISBNB.setLockupDuration(1, 365);
        address slisBNBSPAddress = address(SP_SLISBNB);

        PT_SLISBNB.initialize(slisBNBSPAddress);
        YT_SLISBNB.initialize(slisBNBSYAddress, slisBNBSPAddress);
        PYT_SLISBNB.initialize(slisBNBSPAddress);

        console.log("SY_SLISBNB deployed on %s", slisBNBSYAddress);
        console.log("PT_SLISBNB deployed on %s", slisBNBPTAddress);
        console.log("YT_SLISBNB deployed on %s", slisBNBYTAddress);
        console.log("PYT_SLISBNB deployed on %s", slisBNBPYTAddress);
        console.log("SP_SLISBNB deployed on %s", slisBNBSPAddress);
    }

    /**
     * Support Blast ETH 
     */
    function _supportBlastETH() internal {
        if (block.chainid != vm.envUint("BLAST_SEPOLIA_CHAINID")) return;

        address WETH = vm.envAddress("TESTNET_WETH");
 
        // SY
        OutrunBlastETHSY SY_BETH = new OutrunBlastETHSY(
            WETH,
            owner,
            blastGovernor
        );
        address BETHSYAddress = address(SY_BETH);

        // PT
        OutrunPrincipalToken PT_BETH = new OutrunPrincipalToken(
            "Outrun BETH Principal Token",
            "PT-BETH",
            18,
            owner
        );
        address BETHPTAddress = address(PT_BETH);
        
        // YT
        OutrunERC4626YieldToken YT_BETH = new OutrunERC4626YieldToken(
            "Outrun Blast ETH Yield Token",
            "YT-BETH",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address BETHYTAddress = address(YT_BETH);

        // PYT
        OutrunPointsYieldToken PYT_BETH = new OutrunPointsYieldToken(
            "Outrun Blast ETH Points Yield Token",
            "PYT-BETH",
            18,
            owner
        );
        address BETHPYTAddress = address(PYT_BETH);

        // SP
        OutrunStakingPosition SP_BETH = new OutrunStakingPosition(
            owner,
            "Blast ETH Staking Position",
            "SP-BETH",
            18,
            0,
            protocolFeeRate,
            revenuePool,
            BETHSYAddress,
            BETHPTAddress,
            BETHYTAddress,
            BETHPYTAddress,
            ueth
        );
        SP_BETH.setLockupDuration(1, 365);
        address BETHSPAddress = address(SP_BETH);

        PT_BETH.initialize(BETHSPAddress);
        YT_BETH.initialize(BETHSYAddress, BETHSPAddress);
        PYT_BETH.initialize(BETHSPAddress);

        // After deploy, configure the yield and gas mode
        // IBlastGovernorable(SY_BETH).configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE);

        console.log("SY_BETH deployed on %s", BETHSYAddress);
        console.log("PT_BETH deployed on %s", BETHPTAddress);
        console.log("YT_BETH deployed on %s", BETHYTAddress);
        console.log("PYT_BETH deployed on %s", BETHPYTAddress);
        console.log("SP_BETH deployed on %s", BETHSPAddress);
    }

    /**
     * Support USDB 
     */
    function _supportBlastUSD() internal {
        if (block.chainid != vm.envUint("BLAST_SEPOLIA_CHAINID")) return;

        address USDB = vm.envAddress("TESTNET_USDB");

        // SY
        OutrunBlastUSDSY SY_USDB = new OutrunBlastUSDSY(
            USDB,
            owner,
            blastGovernor
        );
        address USDBSYAddress = address(SY_USDB);

        // PT
        OutrunPrincipalToken PT_USDB = new OutrunPrincipalToken(
            "Outrun USDB Principal Token",
            "PT-USDB",
            18,
            owner
        );
        address USDBPTAddress = address(PT_USDB);
        
        // YT
        OutrunERC4626YieldToken YT_USDB = new OutrunERC4626YieldToken(
            "Outrun Blast USD Yield Token",
            "YT-USDB",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address USDBYTAddress = address(YT_USDB);

        // PYT
        OutrunPointsYieldToken PYT_USDB = new OutrunPointsYieldToken(
            "Outrun Blast USD Points Yield Token",
            "PYT-USDB",
            18,
            owner
        );
        address USDBPYTAddress = address(PYT_USDB);

        // SP
        OutrunStakingPosition SP_USDB = new OutrunStakingPosition(
            owner,
            "Blast USD Staking Position",
            "SP-BETH",
            18,
            0,
            protocolFeeRate,
            revenuePool,
            USDBSYAddress,
            USDBPTAddress,
            USDBYTAddress,
            USDBPYTAddress,
            uusd
        );
        SP_USDB.setLockupDuration(1, 365);
        address USDBSPAddress = address(SP_USDB);

        PT_USDB.initialize(USDBSPAddress);
        YT_USDB.initialize(USDBSYAddress, USDBSPAddress);
        PYT_USDB.initialize(USDBSPAddress);

        // After deploy, configure the yield and gas mode
        // IBlastGovernorable(SY_USDB).configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE);

        console.log("SY_USDB deployed on %s", USDBSYAddress);
        console.log("PT_USDB deployed on %s", USDBPTAddress);
        console.log("YT_USDB deployed on %s", USDBYTAddress);
        console.log("PYT_USDB deployed on %s", USDBPYTAddress);
        console.log("SP_USDB deployed on %s", USDBSPAddress);
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
        MessagingFee memory messagingFee = IOFT(ueth).quoteSend(sendUPTParam, false);
        IOFT(ueth).send{value: messagingFee.nativeFee}(sendUPTParam, messagingFee, msg.sender);
    }

    function _updateRouterLauncher() internal {
        IOutrunRouter(outrunRouter).setMemeverseLauncher(memeverseLauncher);
    }
}