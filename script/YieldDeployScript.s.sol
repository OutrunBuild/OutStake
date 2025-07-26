// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./BaseScript.s.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { IYieldToken } from "../src/core/YieldContracts/interfaces/IYieldToken.sol";
import { IOutrunDeployer, OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { IOutrunStakeManager, OutrunStakingPosition } from "../src/core/Position/OutrunStakingPosition.sol";
import { OutrunERC4626YieldToken } from "../src/core/YieldContracts/OutrunERC4626YieldToken.sol";
import { IPrincipalToken, OutrunPrincipalToken } from "../src/core/YieldContracts/OutrunPrincipalToken.sol";
import { OutrunUniversalPrincipalToken, IUniversalPrincipalToken } from "../src/core/YieldContracts/OutrunUniversalPrincipalToken.sol";
import { IOutrunPointsYieldToken, OutrunPointsYieldToken } from "../src/core/YieldContracts/OutrunPointsYieldToken.sol";

import { ISlisBNBProvider } from "../src/external/lista/ISlisBNBProvider.sol";
import { IListaBNBStakeManager } from "../src/external/lista/IListaBNBStakeManager.sol";

import { OutrunWstETHSY } from "../src/core/StandardizedYield/implementations/Lido/OutrunWstETHSY.sol";
import { OutrunStakedUSDeSY } from "../src/core/StandardizedYield/implementations/Ethena/OutrunStakedUSDeSY.sol";
import { OutrunAaveV3SY } from "../src/core/StandardizedYield/implementations/Aave/OutrunAaveV3SY.sol";
import { OutrunSlisBNBSY } from "../src/core/StandardizedYield/implementations/Lista/OutrunSlisBNBSY.sol";

contract YieldDeployScript is BaseScript {
    address internal UETH;
    address internal UUSD;
    address internal UBNB;

    address internal owner;
    address internal revenuePool;
    address internal liquidator;
    address internal outrunDeployer;

    uint256 internal protocolFeeRate;

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        UUSD = vm.envAddress("UUSD");
        UBNB = vm.envAddress("UBNB");
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        liquidator = vm.envAddress("LIQUIDATOR");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        protocolFeeRate = vm.envUint("PROTOCOL_FEE_RATE");

        // _supportWstETHOnSepolia();
        // _supportSUSDeOnSepolia();
        // _supportAUSDC();
        _supportSlisBNB();
    }

    /**
     * Support wstETH (Sepolia)
     */
    function _supportWstETHOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) return;

        address stETH = vm.envAddress("SEPOLIA_STETH");
        address wstETH = vm.envAddress("SEPOLIA_WSTETH");

        // SY
        OutrunWstETHSY SY_wstETH = new OutrunWstETHSY(
            owner,
            stETH,
            wstETH
        );
        address wstETHSYAddress = address(SY_wstETH);

        // PT
        OutrunPrincipalToken PT_wstETH = new OutrunPrincipalToken(
            "Outrun wstETH Principal Token",
            "PT wstETH",
            18,
            owner
        );
        address wstETHPTAddress = address(PT_wstETH);
        
        // YT
        OutrunERC4626YieldToken YT_wstETH = new OutrunERC4626YieldToken(
            "Outrun wstETH Yield Token",
            "YT wstETH",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address wstETHYTAddress = address(YT_wstETH);

        // PYT
        OutrunPointsYieldToken PYT_wstETH = new OutrunPointsYieldToken(
            "Outrun wstETH Points Yield Token",
            "PYT wstETH",
            18,
            owner
        );
        address wstETHPYTAddress = address(PYT_wstETH);

        // SP
        OutrunStakingPosition SP_wstETH = new OutrunStakingPosition(
            owner,
            "Outrun wstETH Staking Position",
            "SP wstETH",
            18,
            0,
            protocolFeeRate,
            liquidator,
            revenuePool,
            wstETHSYAddress,
            wstETHPTAddress,
            wstETHYTAddress,
            wstETHPYTAddress,
            UETH
        );
        SP_wstETH.setLockupDuration(1, 365);
        address wstETHSPAddress = address(SP_wstETH);

        PT_wstETH.initialize(wstETHSPAddress);
        YT_wstETH.initialize(wstETHSYAddress, wstETHSPAddress);
        PYT_wstETH.initialize(wstETHSPAddress);

        console.log("SY_wstETH deployed on %s", wstETHSYAddress);
        console.log("SP_wstETH deployed on %s", wstETHSPAddress);
        console.log("PT_wstETH deployed on %s", wstETHPTAddress);
        console.log("YT_wstETH deployed on %s", wstETHYTAddress);
        console.log("PYT_wstETH deployed on %s", wstETHPYTAddress);
    }

    /**
     * Support sUSDe (Sepolia)
     */
    function _supportSUSDeOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) return;

        address USDe = vm.envAddress("SEPOLIA_USDE");
        address sUSDe = vm.envAddress("SEPOLIA_SUSDE");

        // SY
        OutrunStakedUSDeSY SY_sUSDe = new OutrunStakedUSDeSY(
            owner,
            USDe,
            sUSDe
        );
        address sUSDeSYAddress = address(SY_sUSDe);

        // PT
        OutrunPrincipalToken PT_sUSDe = new OutrunPrincipalToken(
            "Outrun sUSDe Principal Token",
            "PT sUSDe",
            18,
            owner
        );
        address sUSDePTAddress = address(PT_sUSDe);
        
        // YT
        OutrunERC4626YieldToken YT_sUSDe = new OutrunERC4626YieldToken(
            "Outrun sUSDe Yield Token",
            "YT sUSDe",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address sUSDeYTAddress = address(YT_sUSDe);

        // PYT
        OutrunPointsYieldToken PYT_sUSDe = new OutrunPointsYieldToken(
            "Outrun sUSDe Points Yield Token",
            "PYT sUSDe",
            18,
            owner
        );
        address sUSDePYTAddress = address(PYT_sUSDe);

        // SP
        OutrunStakingPosition SP_sUSDe = new OutrunStakingPosition(
            owner,
            "Outrun sUSDe Staking Position",
            "SP sUSDe",
            18,
            0,
            protocolFeeRate,
            liquidator,
            revenuePool,
            sUSDeSYAddress,
            sUSDePTAddress,
            sUSDeYTAddress,
            sUSDePYTAddress,
            UUSD
        );
        SP_sUSDe.setLockupDuration(1, 365);
        address sUSDeSPAddress = address(SP_sUSDe);

        PT_sUSDe.initialize(sUSDeSPAddress);
        YT_sUSDe.initialize(sUSDeSYAddress, sUSDeSPAddress);
        PYT_sUSDe.initialize(sUSDeSPAddress);

        console.log("SY_sUSDe deployed on %s", sUSDeSYAddress);
        console.log("SP_sUSDe deployed on %s", sUSDeSPAddress);
        console.log("PT_sUSDe deployed on %s", sUSDePTAddress);
        console.log("YT_sUSDe deployed on %s", sUSDeYTAddress);
        console.log("PYT_sUSDe deployed on %s", sUSDePYTAddress);
    }

    /**
     * Support aUSDC (Arbitrum Sepolia, Base Sepolia)
     */
    function _supportAUSDC() internal {
        address aUSDC;
        address aavePool;
        if (block.chainid == vm.envUint("ARBITRUM_SEPOLIA_CHAINID")) {
            aUSDC = vm.envAddress("ARBITRUM_SEPOLIA_AUSDC");
            aavePool = vm.envAddress("ARBITRUM_SEPOLIA_POOL");
        } else if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            aUSDC = vm.envAddress("BASE_SEPOLIA_AUSDC");
            aavePool = vm.envAddress("BASE_SEPOLIA_POOL");
        } else {
            return;
        }

        // SY
        OutrunAaveV3SY SY_aUSDC = new OutrunAaveV3SY(
            "SY AaveE aUSDC",
            "SY aUSDC",
            aUSDC,
            aavePool,
            owner
        );
        address aUSDCSYAddress = address(SY_aUSDC);

        // PT
        OutrunPrincipalToken PT_aUSDC = new OutrunPrincipalToken(
            "Outrun aUSDC Principal Token",
            "PT aUSDC",
            18,
            owner
        );
        address aUSDCPTAddress = address(PT_aUSDC);
        
        // YT
        OutrunERC4626YieldToken YT_aUSDC = new OutrunERC4626YieldToken(
            "Outrun aUSDC Yield Token",
            "YT aUSDC",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address aUSDCYTAddress = address(YT_aUSDC);

        // PYT
        OutrunPointsYieldToken PYT_aUSDC = new OutrunPointsYieldToken(
            "Outrun aUSDC Points Yield Token",
            "PYT aUSDC",
            18,
            owner
        );
        address aUSDCPYTAddress = address(PYT_aUSDC);

        // SP
        OutrunStakingPosition SP_aUSDC = new OutrunStakingPosition(
            owner,
            "Outrun aUSDC Staking Position",
            "SP aUSDC",
            18,
            0,
            protocolFeeRate,
            liquidator,
            revenuePool,
            aUSDCSYAddress,
            aUSDCPTAddress,
            aUSDCYTAddress,
            aUSDCPYTAddress,
            UUSD
        );
        SP_aUSDC.setLockupDuration(1, 365);
        address aUSDCSPAddress = address(SP_aUSDC);

        PT_aUSDC.initialize(aUSDCSPAddress);
        YT_aUSDC.initialize(aUSDCSYAddress, aUSDCSPAddress);
        PYT_aUSDC.initialize(aUSDCSPAddress);

        console.log("SY_aUSDC deployed on %s", aUSDCSYAddress);
        console.log("SP_aUSDC deployed on %s", aUSDCSPAddress);
        console.log("PT_aUSDC deployed on %s", aUSDCPTAddress);
        console.log("YT_aUSDC deployed on %s", aUSDCYTAddress);
        console.log("PYT_aUSDC deployed on %s", aUSDCPYTAddress);
    }

    /**
     * Support slisBNB (BSC Testnet)
     */
    function _supportSlisBNB() internal {
        if (block.chainid != vm.envUint("BSC_TESTNET_CHAINID")) return;

        address slisBNB = vm.envAddress("BSC_TESTNET_SLISBNB");

        // SY
        OutrunSlisBNBSY SY_slisBNB = new OutrunSlisBNBSY(
            owner,
            slisBNB,
            vm.envAddress("DELEGATE_TO"),
            IListaBNBStakeManager(vm.envAddress("BSC_TESTNET_LISTA_BNB_STAKE_MANAGER")),
            ISlisBNBProvider(vm.envAddress("BSC_TESTNET_SLISBNB_PROVIDER"))
        );
        address slisBNBSYAddress = address(SY_slisBNB);

        // PT
        OutrunPrincipalToken PT_slisBNB = new OutrunPrincipalToken(
            "Outrun slisBNB Principal Token",
            "PT slisBNB",
            18,
            owner
        );
        address slisBNBPTAddress = address(PT_slisBNB);
        
        // YT
        OutrunERC4626YieldToken YT_slisBNB = new OutrunERC4626YieldToken(
            "Outrun slisBNB Yield Token",
            "YT slisBNB",
            18,
            owner, 
            revenuePool, 
            protocolFeeRate
        );
        address slisBNBYTAddress = address(YT_slisBNB);

        // PYT
        OutrunPointsYieldToken PYT_slisBNB = new OutrunPointsYieldToken(
            "Outrun slisBNB Points Yield Token",
            "PYT slisBNB",
            18,
            owner
        );
        address slisBNBPYTAddress = address(PYT_slisBNB);

        // SP
        OutrunStakingPosition SP_slisBNB = new OutrunStakingPosition(
            owner,
            "Outrun slisBNB Staking Position",
            "SP slisBNB",
            18,
            0,
            protocolFeeRate,
            liquidator,
            revenuePool,
            slisBNBSYAddress,
            slisBNBPTAddress,
            slisBNBYTAddress,
            slisBNBPYTAddress,
            UUSD
        );
        SP_slisBNB.setLockupDuration(1, 365);
        address slisBNBSPAddress = address(SP_slisBNB);

        PT_slisBNB.initialize(slisBNBSPAddress);
        YT_slisBNB.initialize(slisBNBSYAddress, slisBNBSPAddress);
        PYT_slisBNB.initialize(slisBNBSPAddress);

        console.log("SY_slisBNB deployed on %s", slisBNBSYAddress);
        console.log("SP_slisBNB deployed on %s", slisBNBSPAddress);
        console.log("PT_slisBNB deployed on %s", slisBNBPTAddress);
        console.log("YT_slisBNB deployed on %s", slisBNBYTAddress);
        console.log("PYT_slisBNB deployed on %s", slisBNBPYTAddress);
    }
}