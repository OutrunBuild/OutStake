// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./BaseScript.s.sol";
import { OutrunERC4626YieldToken } from "../src/core/YieldContracts/OutrunERC4626YieldToken.sol";
import { OutrunStakingPosition } from "../src/core/Position/OutrunStakingPosition.sol";
import { IUniversalPrincipalToken } from "../src/core/YieldContracts/OutrunUniversalPrincipalToken.sol";

import { ISlisBNBProvider } from "../src/external/lista/ISlisBNBProvider.sol";
import { IListaBNBStakeManager } from "../src/external/lista/IListaBNBStakeManager.sol";

import { OutrunWstETHSY } from "../src/core/StandardizedYield/implementations/Lido/OutrunWstETHSY.sol";
import { OutrunAaveV3SY } from "../src/core/StandardizedYield/implementations/Aave/OutrunAaveV3SY.sol";
import { OutrunSlisBNBSY } from "../src/core/StandardizedYield/implementations/Lista/OutrunSlisBNBSY.sol";
import { OutrunStakedUSDeSY } from "../src/core/StandardizedYield/implementations/Ethena/OutrunStakedUSDeSY.sol";

contract YieldDeployScript is BaseScript {
    address internal UETH;
    address internal UUSD;
    address internal UBNB;

    address internal owner;
    address internal revenuePool;
    address internal keeper;
    address internal outrunDeployer;

    uint96 internal mtv;
    uint96 internal protocolFeeRate;

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        UUSD = vm.envAddress("UUSD");
        UBNB = vm.envAddress("UBNB");
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        keeper = vm.envAddress("KEEPER");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        mtv = uint96(vm.envUint("MTV"));
        protocolFeeRate = uint96(vm.envUint("PROTOCOL_FEE_RATE"));

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

        // SP
        OutrunStakingPosition SP_wstETH = new OutrunStakingPosition(
            owner,
            "Outrun wstETH Staking Position",
            "SP wstETH",
            18,
            0,
            mtv,
            protocolFeeRate,
            revenuePool,
            wstETHSYAddress,
            wstETHYTAddress,
            UETH
        );
        address wstETHSPAddress = address(SP_wstETH);

        SP_wstETH.setLockupDuration(1, 365);
        SP_wstETH.addKeeper(keeper);
        YT_wstETH.initialize(wstETHSYAddress, wstETHSPAddress);
        IUniversalPrincipalToken(UETH).grantMintingCap(wstETHSPAddress, 1000000000 ether);

        console.log("SY_wstETH deployed on %s", wstETHSYAddress);
        console.log("SP_wstETH deployed on %s", wstETHSPAddress);
        console.log("YT_wstETH deployed on %s", wstETHYTAddress);
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

        // SP
        OutrunStakingPosition SP_sUSDe = new OutrunStakingPosition(
            owner,
            "Outrun sUSDe Staking Position",
            "SP sUSDe",
            18,
            0,
            mtv,
            protocolFeeRate,
            revenuePool,
            sUSDeSYAddress,
            sUSDeYTAddress,
            UUSD
        );
        address sUSDeSPAddress = address(SP_sUSDe);

        SP_sUSDe.setLockupDuration(1, 365);
        SP_sUSDe.addKeeper(keeper);
        YT_sUSDe.initialize(sUSDeSYAddress, sUSDeSPAddress);
        IUniversalPrincipalToken(UUSD).grantMintingCap(sUSDeSPAddress, 1000000000 ether);

        console.log("SY_sUSDe deployed on %s", sUSDeSYAddress);
        console.log("SP_sUSDe deployed on %s", sUSDeSPAddress);
        console.log("YT_sUSDe deployed on %s", sUSDeYTAddress);
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

        // SP
        OutrunStakingPosition SP_aUSDC = new OutrunStakingPosition(
            owner,
            "Outrun aUSDC Staking Position",
            "SP aUSDC",
            18,
            0,
            mtv,
            protocolFeeRate,
            revenuePool,
            aUSDCSYAddress,
            aUSDCYTAddress,
            UUSD
        );
        address aUSDCSPAddress = address(SP_aUSDC);

        SP_aUSDC.setLockupDuration(1, 365);
        SP_aUSDC.addKeeper(keeper);
        YT_aUSDC.initialize(aUSDCSYAddress, aUSDCSPAddress);
        IUniversalPrincipalToken(UUSD).grantMintingCap(aUSDCSPAddress, 1000000000 ether);

        console.log("SY_aUSDC deployed on %s", aUSDCSYAddress);
        console.log("SP_aUSDC deployed on %s", aUSDCSPAddress);
        console.log("YT_aUSDC deployed on %s", aUSDCYTAddress);
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

        // SP
        OutrunStakingPosition SP_slisBNB = new OutrunStakingPosition(
            owner,
            "Outrun slisBNB Staking Position",
            "SP slisBNB",
            18,
            0,
            mtv,
            protocolFeeRate,
            revenuePool,
            slisBNBSYAddress,
            slisBNBYTAddress,
            UBNB
        );
        address slisBNBSPAddress = address(SP_slisBNB);

        SP_slisBNB.setLockupDuration(1, 365);
        SP_slisBNB.addKeeper(keeper);
        YT_slisBNB.initialize(slisBNBSYAddress, slisBNBSPAddress);
        IUniversalPrincipalToken(UBNB).grantMintingCap(slisBNBSPAddress, 1000000000 ether);

        console.log("SY_slisBNB deployed on %s", slisBNBSYAddress);
        console.log("SP_slisBNB deployed on %s", slisBNBSPAddress);
        console.log("YT_slisBNB deployed on %s", slisBNBYTAddress);
    }
}