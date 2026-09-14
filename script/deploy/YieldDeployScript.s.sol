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
import {OutrunSlisBNBSYUpgradeable} from "../../src/yield/adapters/lista/OutrunSlisBNBSYUpgradeable.sol";
import {SPDefaults} from "../lib/SPDefaults.sol";
import {SYBaseUpgradeable} from "../../src/yield/SYBaseUpgradeable.sol";

contract YieldDeployScript is BaseScript {
    error InvalidAddress();
    // UETH/UUSD/UBNB are resolved lazily by support functions (state override for tests, env fallback).
    address internal UETH;
    address internal UUSD;
    address internal UBNB;

    // SP defaults are centralized in `SPDefaults` so both deploy scripts share the
    // same values by construction. See `script/lib/SPDefaults.sol`.

    address internal owner;
    address internal protocolTreasury;

    function run() public broadcaster {
        owner = vm.envAddress("OWNER");
        protocolTreasury = vm.envAddress("PROTOCOL_TREASURY");

        // Requires optimizer-runs=20000 to fit the code size limit
        // _supportWstETHOnSepolia();
        // _supportSUSDeOnSepolia();
        // _supportSlisBNBOnBscTestnet();
        _supportAUSDC();
    }

    // SP/SY are single-chain deployments with no cross-chain/co-location requirement,
    // so we intentionally use direct `new ERC1967Proxy` instead of the CREATE3
    // OutrunDeployer path used by OutstakeScript. Migrate to the factory if that changes.
    /// @dev The SP deploys at the shared zero-fee sentinel `SPDefaults.SP_DEFAULT_DUTY` — there
    /// is no per-family dispatch. Unknown family ids fail closed at `SPDefaults.assertFamilyUAsset`/
    /// `assertFamilySY` (`familySymbol` reverts `InvalidFamilyUAsset`). The SY must report the
    /// canonical symbol for `family` (`SPDefaults.assertFamilySY`), so a support entry that
    /// mispairs an SY with the wrong family reverts instead of deploying. The uAsset-side cap
    /// wiring below is owner-only, so the ownership pre-checks run before the family asserts:
    /// a broadcaster/uAsset-ownership mismatch reverts before any SP impl/proxy is created.
    function _deploySP(address sy, address uAsset, uint8 family) internal returns (address) {
        _requireBroadcasterIsOwner();
        if (uAsset == address(0)) revert InvalidAddress();
        _requireSelfOwned(uAsset);
        SPDefaults.assertFamilyUAsset(uAsset, family);
        SPDefaults.assertFamilySY(sy, family);
        // Resolve the minting cap before deploying so an explicit-zero cap reverts
        // before any proxy is created.
        uint256 mintingCap_ = _spMintingCap();
        address impl = address(new OutrunStakingPositionUpgradeable());
        address sp = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, sy, uAsset, protocolTreasury, SPDefaults.SP_DEFAULT_MIN_STAKE, SPDefaults.SP_DEFAULT_DUTY)
                )
            )
        );
        IUniversalAssets(uAsset).setMintingCap(sp, mintingCap_);
        return sp;
    }

    /// @dev Initial CDP SP minting cap: env-overridable via SP_MINTING_CAP. The placeholder default
    ///      is a deployment-time stand-in only — before launch each family's cap must be re-set by
    ///      governance anchored to that family's PSM reserve scale. Env-read seam: harness
    ///      overrides inject the cap without env; the unset-seam path exercises the default.
    function _spMintingCap() internal view virtual returns (uint256) {
        return SPDefaults.spMintingCap(vm);
    }

    /// @dev Env-read seam for the family uAsset fallback (UETH / UUSD / UBNB): used only when the
    ///      state override is unset. Harness overrides inject it without env.
    function _uAssetFromEnv(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    /// @dev Env-read seam for the router address (OUTRUN_ROUTER): the SY trusted-router binding
    ///      needs the router known at SY deploy time. A missing key reverts the env read before
    ///      anything is wired (fail-fast). Harness overrides inject it without env.
    function _routerAddress() internal view virtual returns (address) {
        return vm.envAddress("OUTRUN_ROUTER");
    }

    /// @dev Points a freshly deployed SY at the router so the router redeem entry can burn through
    ///      the SY internal-balance path. Runs right after the SY proxy is created so a missing
    ///      router or a drifted SY owner fails the deployment instead of shipping an SY whose
    ///      router redeem reverts on every call.
    function _wireTrustedRouter(address sy) internal {
        address router = _routerAddress();
        _validateTrustedRouterConfig(sy, router);
        SYBaseUpgradeable(payable(sy)).setTrustedRouter(router);
    }

    /// @dev Fail-closed pre-checks before the owner-only binding: the broadcast sender must be the
    ///      configured owner (otherwise the SY call reverts on-chain), neither side may be zero,
    ///      and the SY must still be owned by the configured owner.
    function _validateTrustedRouterConfig(address sy, address router) internal view {
        _requireBroadcasterIsOwner();
        if (sy == address(0) || router == address(0)) revert InvalidAddress();
        _requireSelfOwned(sy);
    }

    /// @dev Deployment-time guards shared with OutstakeScript; semantics live in SPDefaults.
    function _requireBroadcasterIsOwner() internal view {
        SPDefaults.requireBroadcasterIsOwner(owner, deployer);
    }

    function _requireSelfOwned(address target) internal view {
        SPDefaults.requireSelfOwned(owner, target);
    }

    /**
     * Support wstETH (Sepolia)
     */
    function _supportWstETHOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) {
            console.log("wstETH support skipped on chainid %s", block.chainid);
            return;
        }

        (address stETH, address wstETH) = _wstETHOnSepoliaTokens();

        // SY
        address syImpl = address(new OutrunWstETHSYUpgradeable());
        address wstETHSYAddress = address(
            new ERC1967Proxy(syImpl, abi.encodeCall(OutrunWstETHSYUpgradeable.initialize, (owner, stETH, wstETH)))
        );
        _wireTrustedRouter(wstETHSYAddress);

        // Position
        address ueth = UETH != address(0) ? UETH : _uAssetFromEnv("UETH");
        address wstETHSPAddress = _deploySP(wstETHSYAddress, ueth, SPDefaults.FAMILY_UETH);

        console.log("SY_wstETH deployed on %s", wstETHSYAddress);
        console.log("SP_wstETH deployed on %s", wstETHSPAddress);
    }

    /// @dev Env-read seam for the Sepolia wstETH pair (SEPOLIA_STETH / SEPOLIA_WSTETH); harness
    ///      overrides inject the addresses without env.
    function _wstETHOnSepoliaTokens() internal view virtual returns (address stETH, address wstETH) {
        stETH = vm.envAddress("SEPOLIA_STETH");
        wstETH = vm.envAddress("SEPOLIA_WSTETH");
    }

    /**
     * Support sUSDe (Sepolia)
     */
    function _supportSUSDeOnSepolia() internal {
        if (block.chainid != vm.envUint("ETHEREUM_SEPOLIA_CHAINID")) {
            console.log("sUSDe support skipped on chainid %s", block.chainid);
            return;
        }

        (address USDe, address sUSDe) = _susdeOnSepoliaTokens();

        // SY
        address syImpl = address(new OutrunStakedUSDeSYUpgradeable());
        address sUSDeSYAddress = address(
            new ERC1967Proxy(syImpl, abi.encodeCall(OutrunStakedUSDeSYUpgradeable.initialize, (owner, USDe, sUSDe)))
        );
        _wireTrustedRouter(sUSDeSYAddress);

        // Position
        address uusd = UUSD != address(0) ? UUSD : _uAssetFromEnv("UUSD");
        address sUSDeSPAddress = _deploySP(sUSDeSYAddress, uusd, SPDefaults.FAMILY_SUSDE);

        console.log("SY_sUSDe deployed on %s", sUSDeSYAddress);
        console.log("SP_sUSDe deployed on %s", sUSDeSPAddress);
    }

    /// @dev Env-read seam for the Sepolia sUSDe pair (SEPOLIA_USDE / SEPOLIA_SUSDE); harness
    ///      overrides inject the addresses without env.
    function _susdeOnSepoliaTokens() internal view virtual returns (address usde, address susde) {
        usde = vm.envAddress("SEPOLIA_USDE");
        susde = vm.envAddress("SEPOLIA_SUSDE");
    }

    /**
     * Support aUSDC (Base Sepolia)
     */
    function _supportAUSDC() internal {
        address aUSDC;
        address aavePool;
        if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            (aUSDC, aavePool) = _ausdcConfig();
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
        _wireTrustedRouter(aUSDCSYAddress);

        // Position
        address uusd = UUSD != address(0) ? UUSD : _uAssetFromEnv("UUSD");
        address aUSDCSPAddress = _deploySP(aUSDCSYAddress, uusd, SPDefaults.FAMILY_AUSDC);

        console.log("SY_aUSDC deployed on %s", aUSDCSYAddress);
        console.log("SP_aUSDC deployed on %s", aUSDCSPAddress);
    }

    /// @dev Env-read seam for the Base Sepolia aave pair (BASE_SEPOLIA_AUSDC / BASE_SEPOLIA_POOL);
    ///      harness overrides inject the addresses without env.
    function _ausdcConfig() internal view virtual returns (address aUSDC, address aavePool) {
        aUSDC = vm.envAddress("BASE_SEPOLIA_AUSDC");
        aavePool = vm.envAddress("BASE_SEPOLIA_POOL");
    }

    /**
     * Support slisBNB (BSC Testnet)
     */
    function _supportSlisBNBOnBscTestnet() internal {
        if (block.chainid != vm.envUint("BSC_TESTNET_CHAINID")) {
            console.log("slisBNB support skipped on chainid %s", block.chainid);
            return;
        }

        (address slisBNB, address listaStakeManager) = _slisBNBOnBscTestnetConfig();

        // SY
        address syImpl = address(new OutrunSlisBNBSYUpgradeable());
        address slisBNBSYAddress = address(
            new ERC1967Proxy(
                syImpl, abi.encodeCall(OutrunSlisBNBSYUpgradeable.initialize, (owner, slisBNB, listaStakeManager))
            )
        );
        _wireTrustedRouter(slisBNBSYAddress);

        // Position
        address ubnb = UBNB != address(0) ? UBNB : _uAssetFromEnv("UBNB");
        address slisBNBSPAddress = _deploySP(slisBNBSYAddress, ubnb, SPDefaults.FAMILY_UBNB);

        console.log("SY_slisBNB deployed on %s", slisBNBSYAddress);
        console.log("SP_slisBNB deployed on %s", slisBNBSPAddress);
    }

    /// @dev Env-read seam for the BSC Testnet slisBNB pair (BSC_TESTNET_SLISBNB /
    ///      BSC_TESTNET_LISTA_STAKE_MANAGER); harness overrides inject the addresses without env.
    function _slisBNBOnBscTestnetConfig() internal view virtual returns (address slisBNB, address listaStakeManager) {
        slisBNB = vm.envAddress("BSC_TESTNET_SLISBNB");
        listaStakeManager = vm.envAddress("BSC_TESTNET_LISTA_STAKE_MANAGER");
    }
}
