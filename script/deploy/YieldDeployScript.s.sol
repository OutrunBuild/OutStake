// SPDX-License-Identifier: UNLICENSED
// solhint-disable no-console
pragma solidity ^0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseScript} from "../lib/BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";

import {OutrunWstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol";
import {OutrunAaveV3SYUpgradeable} from "../../src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol";
import {OutrunStakedUSDeSYUpgradeable} from "../../src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol";

contract YieldDeployScript is BaseScript {
    address internal UETH;
    address internal UUSD;
    address internal UBNB;

    address internal owner;
    address internal revenuePool;
    address internal keeper;

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        UUSD = vm.envAddress("UUSD");
        UBNB = vm.envAddress("UBNB");
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        keeper = vm.envAddress("KEEPER");

        // 20000 runs
        // _supportWstETHOnSepolia();
        // _supportSUSDeOnSepolia();
        _supportAUSDC();
    }

    function _deploySP(address sy, address uAsset) internal returns (address) {
        address impl = address(new OutrunStakingPositionUpgradeable());
        address sp = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(OutrunStakingPositionUpgradeable.initialize, (owner, 0, revenuePool, sy, uAsset, keeper))
            )
        );
        IUniversalAssets(uAsset).setMintingCap(sp, 1000000000 ether);
        return sp;
    }

    /**
     * Support wstETH (Sepolia)
     */
    function _supportWstETHOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) return;

        address stETH = vm.envAddress("SEPOLIA_STETH");
        address wstETH = vm.envAddress("SEPOLIA_WSTETH");

        // SY
        address syImpl = address(new OutrunWstETHSYUpgradeable());
        address wstETHSYAddress = address(
            new ERC1967Proxy(syImpl, abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, stETH, wstETH)))
        );

        // Position
        address wstETHSPAddress = _deploySP(wstETHSYAddress, UETH);

        console.log("SY_wstETH deployed on %s", wstETHSYAddress);
        console.log("SP_wstETH deployed on %s", wstETHSPAddress);
    }

    /**
     * Support sUSDe (Sepolia)
     */
    function _supportSUSDeOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) return;

        address USDe = vm.envAddress("SEPOLIA_USDE");
        address sUSDe = vm.envAddress("SEPOLIA_SUSDE");

        // SY
        address syImpl = address(new OutrunStakedUSDeSYUpgradeable());
        address sUSDeSYAddress = address(
            new ERC1967Proxy(syImpl, abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, USDe, sUSDe)))
        );

        // Position
        address sUSDeSPAddress = _deploySP(sUSDeSYAddress, UUSD);

        console.log("SY_sUSDe deployed on %s", sUSDeSYAddress);
        console.log("SP_sUSDe deployed on %s", sUSDeSPAddress);
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
        address syImpl = address(new OutrunAaveV3SYUpgradeable());
        address aUSDCSYAddress = address(
            new ERC1967Proxy(
                syImpl,
                abi.encodeCall(
                    OutrunAaveV3SYUpgradeable.initialize, ("SY Aave aUSDC", "SY aUSDC", aUSDC, aavePool, owner)
                )
            )
        );

        // Position
        address aUSDCSPAddress = _deploySP(aUSDCSYAddress, UUSD);

        console.log("SY_aUSDC deployed on %s", aUSDCSYAddress);
        console.log("SP_aUSDC deployed on %s", aUSDCSPAddress);
    }
}
