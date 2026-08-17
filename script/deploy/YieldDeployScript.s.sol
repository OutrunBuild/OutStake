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
    // UETH/UUSD are resolved lazily by support functions (state override for tests, env fallback).
    address internal UETH;
    address internal UUSD;

    // Defaults applied to every SP deployed by this script.
    // These are deployment constants, not env-configurable; adjust post-deploy via owner setters.
    uint256 internal constant SP_DEFAULT_MINTING_CAP = 1_000_000_000 ether;
    uint256 internal constant SP_DEFAULT_MIN_STAKE = 0;

    address internal owner;
    address internal revenuePool;
    address internal keeper;

    function run() public broadcaster {
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        keeper = vm.envAddress("KEEPER");

        // Requires optimizer-runs=20000 (see docs/deployment.md)
        // _supportWstETHOnSepolia();
        // _supportSUSDeOnSepolia();
        _supportAUSDC();
    }

    // SP/SY are single-chain deployments with no cross-chain/co-location requirement,
    // so we intentionally use direct `new ERC1967Proxy` instead of the CREATE3
    // OutrunDeployer path used by OutstakeScript. Migrate to the factory if that changes.
    function _deploySP(address sy, address uAsset) internal returns (address) {
        address impl = address(new OutrunStakingPositionUpgradeable());
        address sp = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, SP_DEFAULT_MIN_STAKE, revenuePool, sy, uAsset, keeper)
                )
            )
        );
        IUniversalAssets(uAsset).setMintingCap(sp, SP_DEFAULT_MINTING_CAP);
        return sp;
    }

    /**
     * Support wstETH (Sepolia)
     */
    function _supportWstETHOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) {
            console.log("wstETH support skipped on chainid %s", block.chainid);
            return;
        }

        address stETH = vm.envAddress("SEPOLIA_STETH");
        address wstETH = vm.envAddress("SEPOLIA_WSTETH");

        // SY
        address syImpl = address(new OutrunWstETHSYUpgradeable());
        address wstETHSYAddress = address(
            new ERC1967Proxy(syImpl, abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, stETH, wstETH)))
        );

        // Position
        address ueth = UETH != address(0) ? UETH : vm.envAddress("UETH");
        address wstETHSPAddress = _deploySP(wstETHSYAddress, ueth);

        console.log("SY_wstETH deployed on %s", wstETHSYAddress);
        console.log("SP_wstETH deployed on %s", wstETHSPAddress);
    }

    /**
     * Support sUSDe (Sepolia)
     */
    function _supportSUSDeOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) {
            console.log("sUSDe support skipped on chainid %s", block.chainid);
            return;
        }

        address USDe = vm.envAddress("SEPOLIA_USDE");
        address sUSDe = vm.envAddress("SEPOLIA_SUSDE");

        // SY
        address syImpl = address(new OutrunStakedUSDeSYUpgradeable());
        address sUSDeSYAddress = address(
            new ERC1967Proxy(syImpl, abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, USDe, sUSDe)))
        );

        // Position
        address uusd = UUSD != address(0) ? UUSD : vm.envAddress("UUSD");
        address sUSDeSPAddress = _deploySP(sUSDeSYAddress, uusd);

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
            console.log("aUSDC support skipped on chainid %s", block.chainid);
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
        address uusd = UUSD != address(0) ? UUSD : vm.envAddress("UUSD");
        address aUSDCSPAddress = _deploySP(aUSDCSYAddress, uusd);

        console.log("SY_aUSDC deployed on %s", aUSDCSYAddress);
        console.log("SP_aUSDC deployed on %s", aUSDCSPAddress);
    }
}
