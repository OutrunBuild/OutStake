// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "./BaseScript.s.sol";

import { OutStakeRouter } from "../src/router/OutStakeRouter.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { ISlisBNBProvider } from "../src/external/lista/ISlisBNBProvider.sol";
import { IYieldToken } from "../src/core/YieldContracts/interfaces/IYieldToken.sol";
import { IListaBNBStakeManager } from "../src/external/lista/IListaBNBStakeManager.sol";
import { IOutrunDeployer, OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { OutrunStakingPosition } from "../src/core/Position/OutrunStakingPosition.sol";
import { OutrunERC4626YieldToken } from "../src/core/YieldContracts/OutrunERC4626YieldToken.sol";
import { IPrincipalToken, OutrunPrincipalToken } from "../src/core/YieldContracts/OutrunPrincipalToken.sol";
import { OutrunUniversalPrincipalToken } from "../src/core/YieldContracts/OutrunUniversalPrincipalToken.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { OutrunSlisBNBSY } from "../src/core/StandardizedYield/implementations/Lista/OutrunSlisBNBSY.sol";
import { OutrunSlisUSDSY } from "../src/core/StandardizedYield/implementations/Lista/OutrunSlisUSDSY.sol";
import { OutrunBlastUSDSY } from "../src/core/StandardizedYield/implementations/Blast/OutrunBlastUSDSY.sol";
import { OutrunBlastETHSY } from "../src/core/StandardizedYield/implementations/Blast/OutrunBlastETHSY.sol";

contract OutstakeScript is BaseScript {
    using OptionsBuilder for bytes;

    address internal owner;
    address internal blastGovernor;
    address internal slisBNB;
    address internal revenuePool;
    address internal listaBNBStakeManager;
    address internal outrunDeployer;
    uint256 internal protocolFeeRate;

    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    function run() public broadcaster {
        owner = vm.envAddress("OWNER");
        slisBNB = vm.envAddress("TESTNET_SLISBNB");
        revenuePool = vm.envAddress("REVENUE_POOL");
        listaBNBStakeManager = vm.envAddress("TESTNET_LISTA_BNB_STAKE_MANAGER");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        protocolFeeRate = vm.envUint("PROTOCOL_FEE_RATE");
        blastGovernor = vm.envAddress("BLAST_GOVERNOR");

        // _deployOutrunDeployer(0);

        _chainsInit();

        _deployTPT();
        // _crossChainOFT();
        // _deployUETH(1);
        // _deployOutStakeRouter(4);

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

        uint32[] memory omnichainIds = new uint32[](10);
        omnichainIds[0] = 97;           // BSC Testnet
        omnichainIds[1] = 84532;        // Base Sepolia
        omnichainIds[2] = 421614;       // Arbitrum Sepolia
        omnichainIds[3] = 43113;        // Avalanche Fuji C-Chain
        omnichainIds[4] = 80002;        // Polygon Amoy
        omnichainIds[5] = 57054;        // Sonic Blaze
        omnichainIds[6] = 168587773;    // Blast Sepolia
        omnichainIds[7] = 534351;       // Scroll Sepolia
        omnichainIds[8] = 10143;        // Monad Testnet
        omnichainIds[9] = 59141;        // Linea Sepolia
        // omnichainIds[10] = 11155420; // Optimistic Sepolia
        // omnichainIds[11] = 300;      // ZKsync Sepolia
        

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

    function _deployOutStakeRouter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("OutStakeRouter", nonce));
        bytes memory creationCode = abi.encodePacked(type(OutStakeRouter).creationCode);
        address outStakeRouterAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        console.log("OutStakeRouter deployed on %s", outStakeRouterAddr);
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

        // POT
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
            slisBNBYTAddress
        );
        SP_SLISBNB.setLockupDuration(1, 365);
        address slisBNBSPAddress = address(SP_SLISBNB);

        IPrincipalToken(slisBNBPTAddress).initialize(slisBNBSPAddress);
        IYieldToken(slisBNBYTAddress).initialize(slisBNBSYAddress, slisBNBSPAddress);

        console.log("SY_SLISBNB deployed on %s", slisBNBSYAddress);
        console.log("PT_SLISBNB deployed on %s", slisBNBPTAddress);
        console.log("YT_SLISBNB deployed on %s", slisBNBYTAddress);
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

        // POT
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
            BETHYTAddress
        );
        SP_BETH.setLockupDuration(1, 365);
        address BETHSPAddress = address(SP_BETH);

        IPrincipalToken(PT_BETH).initialize(BETHSPAddress);
        YT_BETH.initialize(BETHSYAddress, BETHSPAddress);

        // After deploy, configure the yield and gas mode
        // IBlastGovernorable(SY_BETH).configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE);

        console.log("SY_BETH deployed on %s", BETHSYAddress);
        console.log("PT_BETH deployed on %s", BETHPTAddress);
        console.log("YT_BETH deployed on %s", BETHYTAddress);
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

        // POT
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
            USDBYTAddress
        );
        SP_USDB.setLockupDuration(1, 365);
        address USDBSPAddress = address(SP_USDB);

        IPrincipalToken(PT_USDB).initialize(USDBSPAddress);
        YT_USDB.initialize(USDBSYAddress, USDBSPAddress);

        // After deploy, configure the yield and gas mode
        // IBlastGovernorable(SY_USDB).configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE);

        console.log("SY_USDB deployed on %s", USDBSYAddress);
        console.log("PT_USDB deployed on %s", USDBPTAddress);
        console.log("YT_USDB deployed on %s", USDBYTAddress);
        console.log("SP_USDB deployed on %s", USDBSPAddress);
    }


    // Test
    function _deployTPT() internal {
        OutrunPrincipalToken TPT = new OutrunPrincipalToken(
            "Outrun Test Principal Token",
            "TPT",
            18,
            owner
        );
        address TPTAddress = address(TPT);

        console.log("TPT deployed on %s", TPTAddress);
    }

    function _crossChainOFT() internal {
        address UETH = vm.envAddress("UETH");
        bytes memory receiveOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(85000, 0);
        SendParam memory sendUPTParam = SendParam({
                dstEid: uint32(vm.envUint("ARBITRUM_SEPOLIA_EID")),
                to: bytes32(uint256(uint160(owner))),
                amountLD: 2000 * 1e18,
                minAmountLD: 0,
                extraOptions: receiveOptions,
                composeMsg: abi.encode(),
                oftCmd: abi.encode()
            });
        MessagingFee memory messagingFee = IOFT(UETH).quoteSend(sendUPTParam, false);
        IOFT(UETH).send{value: messagingFee.nativeFee}(sendUPTParam, messagingFee, msg.sender);
    }
}