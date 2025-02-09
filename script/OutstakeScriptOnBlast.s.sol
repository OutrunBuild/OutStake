// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BaseScript.s.sol";
import { OutStakeRouter } from "../src/router/OutStakeRouter.sol";
import { IPrincipalToken } from "../src/core/YieldContracts/interfaces/IPrincipalToken.sol";
import { IOutrunDeployer, OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { IBlastGovernorable, BlastModeEnum } from "../src/external/blast/BlastGovernorable.sol";
import { OutrunBlastETHSY } from "../src/core/StandardizedYield/implementations/Blast/OutrunBlastETHSY.sol";
import { OutrunBlastUSDSY } from "../src/core/StandardizedYield/implementations/Blast/OutrunBlastUSDSY.sol";
import { OutrunPositionOptionToken } from "../src/core/Position/OutrunPositionOptionToken.sol";
import { OutrunERC4626YieldToken } from "../src/core/YieldContracts/OutrunERC4626YieldToken.sol";
import { OutrunPrincipalToken } from "../src/core/YieldContracts/OutrunPrincipalToken.sol";

contract OutstakeScriptOnBlast is BaseScript {
    address internal owner;
    address internal blastGovernor;
    address internal blastPoints;
    address internal pointsOperator;
    address internal revenuePool;
    address internal outrunDeployer;
    uint256 internal protocolFeeRate;

    function run() public broadcaster {
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        protocolFeeRate = vm.envUint("PROTOCOL_FEE_RATE");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");

        blastGovernor = vm.envAddress("BLAST_GOVERNOR");
        blastPoints = vm.envAddress("BLAST_POINTS");
        pointsOperator = vm.envAddress("POINTS_OPERATOR");

        supportBlastETH();
        supportBlastUSD();
    }

    /**
     * Support Blast ETH 
     */
    function supportBlastETH() internal {
        address WETH = vm.envAddress("TESTNET_WETH");
 
        // SY
        OutrunBlastETHSY SY_BETH = new OutrunBlastETHSY(
            WETH,
            owner,
            blastGovernor,
            blastPoints,
            pointsOperator
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
        OutrunPositionOptionToken POT_BETH = new OutrunPositionOptionToken(
            owner,
            "Blast ETH Position Option Token",
            "POT-BETH",
            18,
            0,
            protocolFeeRate,
            revenuePool,
            BETHSYAddress,
            BETHPTAddress,
            BETHYTAddress
        );
        POT_BETH.setLockupDuration(1, 365);
        address BETHPOTAddress = address(POT_BETH);

        IPrincipalToken(PT_BETH).initialize(BETHPOTAddress);
        YT_BETH.initialize(BETHSYAddress, BETHPOTAddress);

        // IBlastGovernorable(SY_BETH).configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE);

        console.log("SY_BETH deployed on %s", BETHSYAddress);
        console.log("PT_BETH deployed on %s", BETHPTAddress);
        console.log("YT_BETH deployed on %s", BETHYTAddress);
        console.log("POT_BETH deployed on %s", BETHPOTAddress);
    }

    /**
     * Support USDB 
     */
    function supportBlastUSD() internal {
        address USDB = vm.envAddress("TESTNET_USDB");

        // SY
        OutrunBlastUSDSY SY_USDB = new OutrunBlastUSDSY(
            USDB,
            owner,
            blastGovernor,
            blastPoints,
            pointsOperator
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
        OutrunPositionOptionToken POT_USDB = new OutrunPositionOptionToken(
            owner,
            "Blast USD Position Option Token",
            "POT-BETH",
            18,
            0,
            protocolFeeRate,
            revenuePool,
            USDBSYAddress,
            USDBPTAddress,
            USDBYTAddress
        );
        POT_USDB.setLockupDuration(1, 365);
        address USDBPOTAddress = address(POT_USDB);

        IPrincipalToken(PT_USDB).initialize(USDBPOTAddress);
        YT_USDB.initialize(USDBSYAddress, USDBPOTAddress);

        // IBlastGovernorable(SY_USDB).configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE);

        console.log("SY_USDB deployed on %s", USDBSYAddress);
        console.log("PT_USDB deployed on %s", USDBPTAddress);
        console.log("YT_USDB deployed on %s", USDBYTAddress);
        console.log("POT_USDB deployed on %s", USDBPOTAddress);
    }
}