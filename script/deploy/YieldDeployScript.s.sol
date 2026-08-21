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
import {L2AssetValidation} from "../lib/L2AssetValidation.sol";
import {OutrunL2WstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunL2WstETHSYUpgradeable.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {
    OutrunL2WrappableWstETHSYUpgradeable
} from "../../src/yield/adapters/lido/OutrunL2WrappableWstETHSYUpgradeable.sol";

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

    // -----------------------------------------------------------------------
    // L2 oracle-backed SY deployment helpers (G-4 hardening)
    // -----------------------------------------------------------------------

    /// @notice Deploys an L2 oracle-backed wstETH SY with deployment-time validation (G-1 + G-4).
    /// @dev Validates `underlyingAssetOnEthDecimals_` against the known L1 stETH family (18) and
    /// enforces oracle adapter `maxStaleness = 2 days` + sequencer uptime feed + grace period (G-1).
    /// before broadcasting. Generic range 1..18 is enforced for unknown assets. See
    /// script/lib/L2AssetValidation.sol and docs/deployment.md L2 checklist.
    function _deployL2WstETHSY(
        address owner_,
        address wstETH_,
        address exchangeRateOracle_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) internal returns (address) {
        L2AssetValidation.validateL2OracleBackedParams(
            underlyingAssetOnEthAddr_, underlyingAssetOnEthDecimals_, exchangeRateOracle_
        );
        L2AssetValidation.validateL2OracleAdapter(exchangeRateOracle_, underlyingAssetOnEthAddr_);
        address impl = address(new OutrunL2WstETHSYUpgradeable());
        return address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    OutrunL2WstETHSYUpgradeable.initialize,
                    (owner_, wstETH_, exchangeRateOracle_, underlyingAssetOnEthAddr_, underlyingAssetOnEthDecimals_)
                )
            )
        );
    }

    /// @notice Deploys a generic L2 staked-token SY with deployment-time validation (G-1 + G-4).
    function _deployL2StakedTokenSY(
        string memory name_,
        string memory symbol_,
        address owner_,
        address token_,
        address exchangeRateOracle_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) internal returns (address) {
        L2AssetValidation.validateL2OracleBackedParams(
            underlyingAssetOnEthAddr_, underlyingAssetOnEthDecimals_, exchangeRateOracle_
        );
        L2AssetValidation.validateL2OracleAdapter(exchangeRateOracle_, underlyingAssetOnEthAddr_);
        address impl = address(new OutrunL2StakedTokenSYUpgradeable());
        return address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    OutrunL2StakedTokenSYUpgradeable.initialize,
                    (
                        name_,
                        symbol_,
                        owner_,
                        token_,
                        exchangeRateOracle_,
                        underlyingAssetOnEthAddr_,
                        underlyingAssetOnEthDecimals_
                    )
                )
            )
        );
    }

    /// @notice Deploys the Optimism wrappable wstETH SY with deployment-time validation.
    function _deployL2WrappableWstETHSY(
        address owner_,
        address stETH_,
        address wstETH_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) internal returns (address) {
        L2AssetValidation.validateL2WrappableParams(underlyingAssetOnEthAddr_, underlyingAssetOnEthDecimals_, stETH_);
        address impl = address(new OutrunL2WrappableWstETHSYUpgradeable());
        return address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    OutrunL2WrappableWstETHSYUpgradeable.initialize,
                    (owner_, stETH_, wstETH_, underlyingAssetOnEthAddr_, underlyingAssetOnEthDecimals_)
                )
            )
        );
    }
}
