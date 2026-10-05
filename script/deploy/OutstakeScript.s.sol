// SPDX-License-Identifier: UNLICENSED
// solhint-disable no-console,check-send-result
pragma solidity ^0.8.35;

import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {BaseScript} from "../lib/BaseScript.s.sol";
import {SPDefaults} from "../lib/SPDefaults.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {IOutrunDeployer} from "./deployment/interfaces/IOutrunDeployer.sol";
import {OutrunDeployer} from "./deployment/OutrunDeployer.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OutrunOFTUpgradeable} from "../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "../../src/assets/omnichain/OutrunRateLimiterUpgradeable.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {OutrunUSRVaultUpgradeable} from "../../src/usr/OutrunUSRVaultUpgradeable.sol";

import {Faucet, IFaucet} from "../../test/support/Faucet.sol";
import {MockUSDC} from "../../test/support/mocks/MockUSDC.sol";
import {MockAUSDC} from "../../test/support/mocks/MockAUSDC.sol";
import {MockSUSDS} from "../../test/support/mocks/MockSUSDS.sol";
import {MockAUSDCOracle} from "../../test/support/mocks/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "../../test/support/mocks/MockSUSDSOracle.sol";
import {MockOutrunAUSDCSYUpgradeable} from "../../test/upgradeable/mocks/MockOutrunAUSDCSYUpgradeable.sol";
import {MockOutrunSUSDSSYUpgradeable} from "../../test/upgradeable/mocks/MockOutrunSUSDSSYUpgradeable.sol";

contract OutstakeScript is BaseScript {
    using SafeCast for uint256;

    error InvalidEndpoint();
    error InvalidOmnichainId();
    error InvalidOmnichainConfig();
    error InvalidOutboundRateLimit();
    error InvalidOutboundRateWindow();
    error InvalidAddress();
    error InvalidDeployer();
    error NotTestnetChain();
    error FactoryDeployFailed();

    // SP defaults are centralized in `SPDefaults` so both deploy scripts share the
    // same values by construction. See `script/lib/SPDefaults.sol`.

    // PSM launch fee default: 0.1% in 18-dec point terms, applied to both swap directions when
    // PSM_TIN / PSM_TOUT are unset. Fees stay owner-adjustable within [0, 1%] post-deploy.
    uint256 internal constant PSM_DEFAULT_FEE = 1e15;
    // Placeholder initial minting cap for the POLend (Memeverse engine) minter on the UETH/UUSD
    // families; to be re-set by governance against the engine-side maxReserve before launch.
    uint256 internal constant POLEND_DEFAULT_MINTING_CAP = 1_000_000_000 ether;
    // UBNB-family launch cap: deliberately far below the other families' placeholder so early
    // supply stays small — hitting ReachMintCap inside this window is expected, not an incident.
    // Raise via setMintingCap as governance allows.
    uint256 internal constant UBNB_DEFAULT_MINTING_CAP = 100_000 ether;

    // Canonical deterministic-deployment proxy (Arachnid; same address on every chain), used as
    // the CREATE2 creator so the script never needs its own ephemeral address(this) — forge script
    // hard-reverts any address(this) use in script contracts.
    address internal constant CANONICAL_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal owner;
    address internal outrunDeployer;
    address internal outrunRouter;
    bool internal enforceOutrunRouter;
    address internal memeverseLauncher;

    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    // ---- Env vars consumed by the PSM / USR / mintingCap wiring below ------------------------
    // Family uAsset addresses (already deployed, owned by OWNER): UETH, UUSD, UBNB.
    // Router address for the PSM registry wiring: OUTRUN_ROUTER (same key as _applyRouterConfig).
    // PSM, one instance per (family, reserve) pair: UETH_PSM_STOCK_CAP (native leg),
    //   UUSD_USDC_PSM_STOCK_CAP / UUSD_USDT_PSM_STOCK_CAP (one per stablecoin leg),
    //   UBNB_PSM_STOCK_CAP (native leg) — each required, 18-dec face value, no default (a
    //   family-agnostic placeholder would break the reserve anchoring); shared fees PSM_TIN /
    //   PSM_TOUT (optional, default 0.1% each, bounded to [0, 1%]); the shared sweep recipient
    //   PSM_FEE_RECIPIENT (required, no default — the binding is immutable post-initialize, so a
    //   placeholder would permanently misroute fee payouts); and the UUSD-family ERC20
    //   reserve addresses PSM_USDC / PSM_USDT (required; the UETH/UBNB instances bind the native
    //   leg and read no reserve env).
    // mintingCap: SP_MINTING_CAP (CDP SPs, optional, placeholder default), POLEND_MINTER (engine
    //   minter address, required for the POLend wiring), and <SYMBOL>_POLEND_MINTING_CAP (optional
    //   per-family initial cap; UBNB defaults to a small launch cap).
    // Genesis gate: GENESIS_LAUNCHER (optional; the testnet mock-support SPs wire the SP-side
    //   genesis launcher via setGenesisLauncher when set — must be a contract — and the
    //   stakeForGenesis entry stays disabled when absent). The router-side launcher key is
    //   MEMEVERSE_LAUNCHER; both must resolve to the same address for the two genesis paths to
    //   target one launcher.

    function run() public broadcaster {
        // deployerNonce = 1 is the OutrunDeployer instance selector (CREATE2 path shared by
        // _deployOutrunDeployer/_assertOutrunDeployer).
        // _deployOutrunRouter(7) is an independent CREATE3 salt-namespace counter; it must stay
        // identical across chains.
        // The disabled call sites below split into deployment-creating calls (uAsset, PSM, USR
        // vault, and mock-stack deploys — their CREATE3 addresses depend on nonce/salt and
        // compile-config consistency) and non-deploy config calls (_registerPOLendMinter,
        // _updateRouterLauncher — they only touch already-deployed addresses). YieldDeployScript
        // has 4 support functions/call sites (_supportWstETHOnSepolia, _supportSUSDeOnSepolia,
        // _supportSlisBNBOnBscTestnet, _supportAUSDC), which are single-chain direct-new
        // deployments with no cross-chain same-address requirement.
        owner = vm.envAddress("OWNER");
        outrunDeployer = vm.envAddress("OUTRUN_DEPLOYER");
        memeverseLauncher = vm.envAddress("MEMEVERSE_LAUNCHER");
        _applyRouterConfig();

        uint256 deployerNonce = 1;
        // _deployOutrunDeployer(deployerNonce);

        _assertOutrunDeployer(deployerNonce);
        // _deployUETH(1);
        // _deployUUSD(1);
        // _deployUBNB(1);
        _deployOutrunRouter(7);
        // PSM wiring per (family, reserve) pair (requires the family uAsset deployed and OUTRUN_ROUTER set):
        // _deployUETHPSM(1);
        // _deployUUSDPSM(1); // deploys both the USDC and the USDT leg
        // _deployUBNBPSM(1);
        // USR savings vaults per family (no uAsset-side registration required):
        // _deploySuETH(1);
        // _deploySuUSD(1);
        // _deploySuBNB(1);
        // POLend (Memeverse engine) minter initial-cap registration per family:
        // _registerPOLendMinter("UETH", false);
        // _registerPOLendMinter("UUSD", false);
        // _registerPOLendMinter("UBNB", true);
        // _updateRouterLauncher();
        // _deployMockERC20(1);
        // _deployMockOracle(1);
        // _deployMockERC20SY(1);
        // _supportMockAUSDC(13); // Requires optimizer-runs=20000 to fit the code size limit
        // _supportMockSUSDS(13); // Requires optimizer-runs=20000 to fit the code size limit
    }

    /// @dev Single source of truth for the salt/initcode used to deploy OutrunDeployer.
    /// `_deployOutrunDeployer` and `_assertOutrunDeployer` share this recipe so the two
    /// CREATE2 expressions cannot drift apart.
    function _outrunDeployerRecipe(uint256 nonce) internal view returns (bytes32 salt, bytes memory initcode) {
        salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        initcode = abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner));
    }

    function _deployOutrunDeployer(uint256 nonce) internal returns (address outrunDeployerAddr) {
        (bytes32 salt, bytes memory initcode) = _outrunDeployerRecipe(nonce);
        // The factory is the CREATE2 creator, so the deployed address equals the three-param
        // expected address in `_assertOutrunDeployer` (same salt/initcode recipe). The canonical
        // deterministic-deployment proxy (Arachnid) is NOT ABI-encoded — it exposes no
        // `deploy(bytes,bytes32)` function: calldata is raw `salt (first 32 bytes) ++ initcode`,
        // the forwarded value endows the created contract, and on success it returns the deployed
        // address as 20 RAW bytes. Do not convert this back to an ABI call; it can never succeed
        // against the real proxy.
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = CANONICAL_CREATE2_FACTORY.call(abi.encodePacked(salt, initcode));
        // Fail closed on a failed create2 AND on chains where the factory is absent: a call to the
        // absent factory succeeds with empty returndata, which only this length check catches.
        if (!ok || ret.length != 20) revert FactoryDeployFailed();
        // The proxy returns 20 raw bytes, not a 32-byte ABI word — cast directly, never abi.decode.
        // ret.length == 20 checked above, so bytes20 cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        outrunDeployerAddr = address(uint160(bytes20(ret)));
        console.log("OutrunDeployer deployed on %s", outrunDeployerAddr);
    }

    /// @dev Fails closed unless `OUTRUN_DEPLOYER` is the address `_deployOutrunDeployer` would
    /// CREATE2-deploy: expected = CREATE2(CANONICAL_CREATE2_FACTORY, salt, keccak256(initcode)).
    /// The creator is the canonical deterministic-deployment proxy — a chain constant — because
    /// forge script hard-reverts any `address(this)` use in script contracts, so the script
    /// contract can no longer be the creator (and an EOA cannot execute CREATE2). Cross-chain
    /// same-address deployment depends on the factory address being identical on every chain, so
    /// a mismatch here would silently scatter the OutrunDeployer/peer=own-address design across
    /// divergent addresses.
    function _assertOutrunDeployer(uint256 nonce) internal view {
        // Deployer must equal owner (mirrors `_validateUAssetDeploymentConfig` / docs OWNER==broadcaster).
        _requireBroadcasterIsOwner();

        (bytes32 salt, bytes memory initcode) = _outrunDeployerRecipe(nonce);
        address expected = Create2.computeAddress(salt, keccak256(initcode), CANONICAL_CREATE2_FACTORY);

        if (outrunDeployer != expected) revert InvalidDeployer();
    }

    function _chainsInit() internal virtual {
        endpoints[97] = vm.envAddress("BSC_TESTNET_ENDPOINT");
        endpoints[84532] = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
        endpoints[11155111] = vm.envAddress("ETHEREUM_SEPOLIA_ENDPOINT");

        endpointIds[97] = vm.envUint("BSC_TESTNET_EID").toUint32();
        endpointIds[84532] = vm.envUint("BASE_SEPOLIA_EID").toUint32();
        endpointIds[11155111] = vm.envUint("ETHEREUM_SEPOLIA_EID").toUint32();
    }

    /// @dev Deploys an upgradeable contract via ERC1967Proxy using CREATE3 through
    /// `OutrunDeployer.deploy`: both the implementation and proxy addresses depend only on
    /// (OutrunDeployer, broadcaster, salt), never on the initcode or initCalldata — which is
    /// what lets the same address be reproduced on every chain. The "impl" suffix gives the
    /// implementation its own salt namespace; reusing the proxy salt would make the second
    /// CREATE3 deploy revert with DEPLOYMENT_FAILED.
    function _deployUpgradeable(bytes memory implCreationCode, bytes memory initCalldata, bytes32 salt)
        internal
        returns (address)
    {
        // Deploy implementation
        bytes32 implSalt = keccak256(abi.encodePacked(salt, "impl"));
        address impl = IOutrunDeployer(outrunDeployer).deploy(implSalt, implCreationCode);
        // Deploy proxy
        bytes memory proxyCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initCalldata));
        return IOutrunDeployer(outrunDeployer).deploy(salt, proxyCode);
    }

    /// @dev Shared chain list for the three uAsset deploys: one definition site, so the
    /// omnichain peer/rate-limit set can never drift between UETH/UUSD/UBNB.
    function _sharedOmnichainIds() internal pure returns (uint32[] memory omnichainIds) {
        omnichainIds = new uint32[](3);
        omnichainIds[0] = 97; // BSC Testnet
        omnichainIds[1] = 84532; // Base Sepolia
        omnichainIds[2] = 11155111; // Sepolia
    }

    function _deployUAsset(uint256 nonce, string memory symbol, string memory assetWord) internal {
        // Load the 3 testnets' cross-chain endpoint/EID envs only here, where the uAsset
        // cross-chain deploy actually consumes them; Router-only runs must never read these envs.
        _chainsInit();
        uint32[] memory omnichainIds = _sharedOmnichainIds();

        (uint192 outboundRateLimit, uint64 outboundRateWindow) = _outboundRateLimitConfig(
            string.concat(symbol, "_OUTBOUND_RATE_LIMIT"), string.concat(symbol, "_OUTBOUND_RATE_WINDOW_SECONDS")
        );
        _validateUAssetDeploymentConfig(omnichainIds);

        bytes32 salt = keccak256(abi.encodePacked(string.concat("OmnichainUniversalAssets", assetWord), nonce));
        address deployedUAsset = _deployUpgradeable(
            abi.encodePacked(
                type(OutrunUniversalAssetsUpgradeable).creationCode, abi.encode(18, endpoints[uint32(block.chainid)])
            ),
            abi.encodeCall(
                OutrunUniversalAssetsUpgradeable.initialize,
                (string.concat("Omnichain Universal Assets ", assetWord), symbol, owner)
            ),
            salt
        );
        bytes32 peer = bytes32(uint256(uint160(deployedUAsset)));

        _configureUAssetOmnichain(deployedUAsset, peer, omnichainIds, outboundRateLimit, outboundRateWindow);

        console.log(string.concat(symbol, " deployed on %s"), deployedUAsset);
    }

    /// @dev Thin named wrappers keep the per-asset deploy entrypoints discoverable by symbol for
    /// the test harness. `symbol` (e.g. "UETH") drives env vars and the token ticker; `assetWord`
    /// (e.g. "ETH") drives the CREATE3 salt and name stem — `assetWord` must stay byte-stable
    /// per asset, or every deployed uAsset address changes.
    function _deployUETH(uint256 nonce) internal {
        _deployUAsset(nonce, "UETH", "ETH");
    }

    function _deployUUSD(uint256 nonce) internal {
        _deployUAsset(nonce, "UUSD", "USD");
    }

    function _deployUBNB(uint256 nonce) internal {
        _deployUAsset(nonce, "UBNB", "BNB");
    }

    // -------------------------------------------------------------------------
    // PSM deployment wiring (one instance per (family, reserve) pair)
    // -------------------------------------------------------------------------

    /// @dev Thin wrappers mirroring the uAsset deploy names: `symbol` drives the uAsset env key and
    ///      the family-identity check. The remaining wiring is explicit per instance — bound reserve,
    ///      per-instance cap env key, and CREATE3 salt stem — so adding a leg cannot drift between
    ///      env-read and registration sites. Salt stems must stay byte-stable per instance, or the
    ///      deployed PSM address changes.
    function _deployUETHPSM(uint256 nonce) internal {
        _deployPSM(nonce, "UETH", address(0), "UETH_PSM_STOCK_CAP", "OutrunPSMETH");
    }

    /// @dev The UUSD family serves two stablecoin legs, so one call deploys two single-reserve
    ///      instances (USDC leg + USDT leg) at distinct salts with independent caps.
    function _deployUUSDPSM(uint256 nonce) internal {
        (address usdc, address usdt) = _uusdReserveTokens();
        if (usdc == address(0) || usdt == address(0) || usdc == usdt) {
            revert InvalidAddress();
        }
        _deployPSM(nonce, "UUSD", usdc, "UUSD_USDC_PSM_STOCK_CAP", "OutrunPSMUSDUSDC");
        _deployPSM(nonce, "UUSD", usdt, "UUSD_USDT_PSM_STOCK_CAP", "OutrunPSMUSDUSDT");
    }

    function _deployUBNBPSM(uint256 nonce) internal {
        _deployPSM(nonce, "UBNB", address(0), "UBNB_PSM_STOCK_CAP", "OutrunPSMBNB");
    }

    /// @dev Deploys one single-reserve PSM instance (implementation + proxy, CREATE3 cross-chain-stable
    ///      addresses) and completes the two-sided wiring: uAsset reserve-minter registration and the
    ///      router (uAsset, reserveToken) pair registry (path-A addressing). The reserve binding itself
    ///      travels in `initialize` — there is no post-deploy reserve registration. Both swap
    ///      directions stay unusable until the uAsset-side registration is in place. Env reads and
    ///      address-level checks (uAsset/router code and ownership, family identity, reserve
    ///      zero/equality checks) run BEFORE the CREATE3 deploy, so a missing env key or invalid
    ///      address fails closed with nothing deployed. Value bounds the pre-deploy path does not
    ///      re-check — a zero stockCap or fees outside [0, 1%] — are enforced by `initialize` inside
    ///      the proxy deployment transaction: only that proxy transaction rolls back atomically (the
    ///      proxy salt stays unconsumed), while the implementation deployed by the earlier broadcast
    ///      transaction stays on-chain with its impl salt namespace consumed — retrying at the same
    ///      nonce reverts DEPLOYMENT_FAILED at the implementation step, so a retry needs a fresh nonce
    ///      with the half-wired instance abandoned.
    ///      Recovery from a run that fails AFTER the deploy is not "re-run this entry": the salt is
    ///      spent (CREATE3 is one-shot per salt, a second run reverts DEPLOYMENT_FAILED). Complete
    ///      the missing wiring with manual owner calls (setReserveMinter / setPsmForUAsset) or redeploy
    ///      at a fresh nonce and abandon the half-wired instance.
    function _deployPSM(
        uint256 nonce,
        string memory symbol,
        address reserve,
        string memory capEnvKey,
        string memory saltStem
    ) internal {
        address uAsset = _familyUAssetAddress(symbol);
        // Router resolution mirrors `_updateRouterLauncher`: the `outrunRouter` state (populated by
        // `_applyRouterConfig` when OUTRUN_ROUTER is set) wins; otherwise the env read fails fast.
        address router = outrunRouter != address(0) ? outrunRouter : vm.envAddress("OUTRUN_ROUTER");
        _validatePSMDeploymentConfig(uAsset, router, symbol);
        // A nonzero reserve must differ from the family uAsset so a copy-pasted env cannot bind the
        // instance to its own uAsset; the native leg (address(0)) reads no env and needs no check.
        if (reserve != address(0) && reserve == uAsset) {
            revert InvalidAddress();
        }
        // Mirror of the PSM `initialize` reserve-leg guard: fail closed before the CREATE3 deploy
        // on an EOA/non-ERC20 reserve (no code, unreadable decimals) or a >18-dec reserve (would
        // underflow the PSM face-value scale) — the binding is immutable with no post-deploy fix.
        if (reserve != address(0)) {
            if (reserve.code.length == 0) revert InvalidAddress();
            (bool decimalsOk, bytes memory decimalsRet) =
                reserve.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
            if (!decimalsOk || decimalsRet.length != 32) revert InvalidAddress();
            if (abi.decode(decimalsRet, (uint8)) > 18) revert InvalidAddress();
        }

        uint256 stockCap = _psmCapsConfig(capEnvKey);
        (uint256 tin, uint256 tout) = _psmFeesConfig();
        address feeRecipient = _psmFeeRecipientConfig();
        // Mirror of the PSM `initialize` fee-recipient guard: the binding is immutable with no
        // setter, so a zero recipient must fail closed before the CREATE3 deploy rather than
        // inside the proxy deployment transaction.
        if (feeRecipient == address(0)) revert InvalidAddress();

        bytes32 salt = keccak256(abi.encodePacked(saltStem, nonce));
        address psm = _deployUpgradeable(
            type(OutrunPSMUpgradeable).creationCode,
            abi.encodeCall(
                OutrunPSMUpgradeable.initialize, (uAsset, reserve, owner, feeRecipient, stockCap, tin, tout)
            ),
            salt
        );

        // uAsset-side registration is also the swap kill switch surface: revoking it later halts
        // both directions of this PSM without touching any other instance.
        IUniversalAssets(uAsset).setReserveMinter(psm, true);
        IOutrunRouter(router).setPsmForUAsset(uAsset, reserve, psm);

        console.log(string.concat(saltStem, " deployed on %s"), psm);
    }

    /// @dev Env-read seam for the family uAsset address (UETH/UUSD/UBNB env keys), shared by the
    ///      PSM, USR-vault, and POLend wiring. Mirrors `_rawOutboundRateLimitConfig`: the deploy
    ///      test harness overrides this to inject addresses without mutating process env (forge
    ///      runs tests concurrently and `vm.setEnv` writes race across tests).
    function _familyUAssetAddress(string memory symbol) internal view virtual returns (address) {
        return vm.envAddress(symbol);
    }

    /// @dev The initial PSM stock cap comes from a per-instance env key with no default:
    ///      `stockCap` anchors to the instance's planned reserve injection (net minted face value must
    ///      not meaningfully exceed injectable reserves, keeping PSM supply reserve-backed); the
    ///      per-swap size is bounded only by the cap headroom and the reserve balance actually held.
    ///      A missing key reverts the env read before anything is deployed (fail-fast). Env-read seam:
    ///      harness overrides inject the cap without env.
    function _psmCapsConfig(string memory capEnvKey) internal view virtual returns (uint256 stockCap) {
        stockCap = vm.envUint(capEnvKey);
    }

    /// @dev Launch fees default to 0.1% / 0.1% unless PSM_TIN / PSM_TOUT override them; both stay
    ///      bounded to [0, 1%] by the PSM initializer. Env-read seam: harness overrides inject the
    ///      fees without env; the unset-seam path exercises the 0.1% default.
    function _psmFeesConfig() internal view virtual returns (uint256 tin, uint256 tout) {
        tin = vm.envOr("PSM_TIN", PSM_DEFAULT_FEE);
        tout = vm.envOr("PSM_TOUT", PSM_DEFAULT_FEE);
    }

    /// @dev The fee-sweep recipient is required with no default: the PSM binding is immutable
    ///      post-initialize (no setter), so a placeholder address would permanently misroute fee
    ///      payouts. A missing key reverts the env read before anything is deployed (fail-fast).
    ///      Env-read seam: harness overrides inject the recipient without env.
    function _psmFeeRecipientConfig() internal view virtual returns (address feeRecipient) {
        feeRecipient = vm.envAddress("PSM_FEE_RECIPIENT");
    }

    /// @dev Env-read seam for the UUSD-family stablecoin reserve addresses (PSM_USDC / PSM_USDT);
    ///      harness overrides inject them without env.
    function _uusdReserveTokens() internal view virtual returns (address usdc, address usdt) {
        usdc = vm.envAddress("PSM_USDC");
        usdt = vm.envAddress("PSM_USDT");
    }

    /// @dev Fail-closed pre-checks before any PSM wiring state changes: the two owner-only calls
    ///      below (uAsset setReserveMinter, router setPsmForUAsset) all execute as the broadcaster, so the broadcaster must be the current
    ///      owner of the uAsset and the router — re-read ownership instead of assuming deploy-day
    ///      state. The family-identity re-check pins the env-injected address to the family symbol
    ///      so a cross-filled env (e.g. UETH pointing at the UUSD token) cannot silently bind a
    ///      native-leg PSM to the stablecoin family — the binding has no setter and no later fix.
    function _validatePSMDeploymentConfig(address uAsset, address router, string memory symbol) internal view {
        _requireBroadcasterIsOwner();
        if (outrunDeployer == address(0) || uAsset == address(0) || router == address(0)) {
            revert InvalidAddress();
        }

        _requireSelfOwned(uAsset);
        _requireSelfOwned(router);

        SPDefaults.assertFamilyUAsset(uAsset, symbol);
    }

    /// @dev Deployment-time guards shared with YieldDeployScript; semantics live in SPDefaults.
    function _requireBroadcasterIsOwner() internal view {
        SPDefaults.requireBroadcasterIsOwner(owner, deployer);
    }

    function _requireSelfOwned(address target) internal view {
        SPDefaults.requireSelfOwned(owner, target);
    }

    // -------------------------------------------------------------------------
    // USR savings vault deployment (one suToken per family)
    // -------------------------------------------------------------------------

    /// @dev Thin wrappers mirroring the uAsset deploy names; `assetWord` drives the CREATE3 salt
    /// stem and the suToken name/symbol stems, so it must stay byte-stable per family.
    function _deploySuETH(uint256 nonce) internal {
        _deployUSRVault(nonce, "UETH", "ETH");
    }

    function _deploySuUSD(uint256 nonce) internal {
        _deployUSRVault(nonce, "UUSD", "USD");
    }

    function _deploySuBNB(uint256 nonce) internal {
        _deployUSRVault(nonce, "UBNB", "BNB");
    }

    /// @dev Deploys one family USR savings vault (suETH / suUSD / suBNB shares). The vault holds
    ///      no uAsset minting role — it is neither a minter nor a reserve minter and needs no
    ///      uAsset-side registration — so the proxy initialize is the entire wiring. Interest
    ///      accrues per second off block.timestamp (contract-internal SECONDS_PER_YEAR constant), so
    ///      initialize carries no cadence parameter. `usrRate` starts at zero (accrual off);
    ///      activating the family rate is a post-deploy owner decision via setUsrRate.
    function _deployUSRVault(uint256 nonce, string memory symbol, string memory assetWord) internal {
        address uAsset = _familyUAssetAddress(symbol);
        _validateUSRVaultDeploymentConfig(uAsset, symbol);

        bytes32 salt = keccak256(abi.encodePacked(string.concat("OutrunUSRVault", assetWord), nonce));
        address vault = _deployUpgradeable(
            type(OutrunUSRVaultUpgradeable).creationCode,
            abi.encodeCall(
                OutrunUSRVaultUpgradeable.initialize,
                (uAsset, string.concat("Universal Savings ", assetWord), string.concat("su", assetWord), owner)
            ),
            salt
        );

        console.log(string.concat("su", assetWord, " vault deployed on %s"), vault);
    }

    /// @dev Pre-checks for the vault deploy: registration performs no code check on the uAsset.
    ///      The asset binding is init-only, so the family-identity re-check runs here too — a
    ///      cross-filled env would otherwise bind suETH shares to the UUSD token with no later fix.
    function _validateUSRVaultDeploymentConfig(address uAsset, string memory symbol) internal view {
        _requireBroadcasterIsOwner();
        if (outrunDeployer == address(0) || uAsset == address(0)) revert InvalidAddress();

        _requireSelfOwned(uAsset);

        SPDefaults.assertFamilyUAsset(uAsset, symbol);
    }

    /// @dev Reads the limit env value and passes it through as the outbound rate limit.
    ///      The env value is interpreted in LOCAL decimals (LD) — the same unit as `amountSentLD`
    ///      recorded by `OutrunOFTUpgradeable.sol::_debit` (18-dec tokens: 1e18 = 1 token). It is
    ///      NOT shared decimals (SD): for an 18-dec OFT with DCR = 1e12, entering `1e12` means 1
    ///      dust unit (1e-6 token), not 1M tokens. Use full-LD integers, e.g. 1000000e18.
    function _outboundRateLimitConfig(string memory limitEnv, string memory windowEnv)
        internal
        view
        returns (uint192 limit, uint64 window)
    {
        (uint256 rawLimit, uint256 rawWindow) = _rawOutboundRateLimitConfig(limitEnv, windowEnv);
        if (rawLimit == 0) revert InvalidOutboundRateLimit();
        if (rawWindow == 0) revert InvalidOutboundRateWindow();

        limit = rawLimit.toUint192();
        window = rawWindow.toUint64();
    }

    function _rawOutboundRateLimitConfig(string memory limitEnv, string memory windowEnv)
        internal
        view
        virtual
        returns (uint256 limit, uint256 window)
    {
        limit = vm.envUint(limitEnv);
        window = vm.envUint(windowEnv);
    }

    function _validateUAssetDeploymentConfig(uint32[] memory omnichainIds) internal view {
        _requireBroadcasterIsOwner();
        address localEndpoint = endpoints[uint32(block.chainid)];
        uint32 localEndpointId = endpointIds[uint32(block.chainid)];
        // The env-supplied endpoint may be missing or carry a zero local EID;
        // both must fail closed before any deployment proceeds.
        if (localEndpoint == address(0) || localEndpointId == 0) {
            revert InvalidEndpoint();
        }

        // Fail closed on a coded-but-not-an-endpoint contract: fold a reverting or mismatched
        // eid() view call into the named InvalidEndpoint error instead of an opaque revert.
        try ILayerZeroEndpointV2(localEndpoint).eid() returns (uint32 eid) {
            if (eid != localEndpointId) revert InvalidEndpoint();
        } catch {
            revert InvalidEndpoint();
        }

        // Guard against `_chainsInit` missing a chain that `_sharedOmnichainIds` lists: a zero
        // remote EID would otherwise configure rate limits and peers against endpoint id 0.
        uint256 omnichainIdsLength = omnichainIds.length;
        bool localChainIsMember;
        for (uint256 i; i < omnichainIdsLength; ++i) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) {
                localChainIsMember = true;
                continue;
            }
            if (endpointIds[omnichainId] == 0) revert InvalidOmnichainId();
        }
        // The local chain must be a member of the omnichain set. Otherwise the uAsset would be
        // deployed here with one-way peers while the remote chains never peer back, so a cross-chain
        // send would burn locally and never credit the remote.
        if (!localChainIsMember) revert InvalidOmnichainId();
    }

    function _configureUAssetOmnichain(
        address uAsset,
        bytes32 peer,
        uint32[] memory omnichainIds,
        uint192 outboundRateLimit,
        uint64 outboundRateWindow
    ) internal {
        uint256 omnichainIdsLength = omnichainIds.length;
        for (uint256 i; i < omnichainIdsLength; ++i) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            OutrunOFTUpgradeable(uAsset).setOutboundRateLimit(endpointId, outboundRateLimit, outboundRateWindow);
            IOAppCore(uAsset).setPeer(endpointId, peer);
            _assertUAssetOmnichainConfig(uAsset, endpointId, peer, outboundRateLimit, outboundRateWindow);
        }
    }

    function _assertUAssetOmnichainConfig(
        address uAsset,
        uint32 endpointId,
        bytes32 peer,
        uint192 outboundRateLimit,
        uint64 outboundRateWindow
    ) internal view {
        if (IOAppCore(uAsset).peers(endpointId) != peer) revert InvalidOmnichainConfig();

        OutrunRateLimiterUpgradeable.RateLimit memory rl = OutrunOFTUpgradeable(uAsset).rateLimits(endpointId);
        if (rl.limit != outboundRateLimit || rl.window != outboundRateWindow) revert InvalidOmnichainConfig();
    }

    /// @dev Hardcoded allowlist of chain ids where the mock stack may run: anvil (31337) plus the
    /// 3 testnets wired in `_chainsInit`. Single source of truth alongside `_chainsInit`: adding a
    /// testnet requires updating both, or the mock helpers below fail closed on the new chain.
    function _testnetChainIds() internal pure returns (uint32[] memory testnetChainIds) {
        testnetChainIds = new uint32[](4);
        testnetChainIds[0] = 31337; // Anvil local chain
        testnetChainIds[1] = 97; // BSC Testnet
        testnetChainIds[2] = 84532; // Base Sepolia
        testnetChainIds[3] = 11155111; // Sepolia
    }

    /// @dev Fail closed outside the testnet allowlist: the mock stack is testnet/local-only, and
    /// a mock SP wrongly activated on another chain would get a 1_000_000_000 ether minting cap
    /// (`_supportMockSY` -> `SPDefaults.SP_DEFAULT_MINTING_CAP`) on the env-supplied uAsset, so unbacked
    /// minting up to that face value is exactly what this gate must prevent.
    function _assertTestnetChain() internal view {
        uint32[] memory testnetChainIds = _testnetChainIds();
        uint256 testnetChainIdsLength = testnetChainIds.length;
        for (uint256 i; i < testnetChainIdsLength; ++i) {
            if (uint256(testnetChainIds[i]) == block.chainid) return;
        }
        revert NotTestnetChain();
    }

    function _deployMockERC20(uint256 nonce) internal {
        _assertTestnetChain();
        _requireBroadcasterIsOwner();

        bytes32 salt = keccak256(abi.encodePacked("Faucet", nonce));
        bytes memory creationCode = abi.encodePacked(type(Faucet).creationCode, abi.encode(owner));
        address faucetAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockUSDC", nonce));
        creationCode = abi.encodePacked(type(MockUSDC).creationCode, abi.encode("Mock USDC", "USDC", 18, faucetAddr));
        address mockUSDCAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockAUSDC", nonce));
        creationCode = abi.encodePacked(
            type(MockAUSDC).creationCode, abi.encode("Mock aUSDC", "aUSDC", 18, mockUSDCAddr, faucetAddr)
        );
        address mockAUSDCAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockSUSDS", nonce));
        creationCode = abi.encodePacked(
            type(MockSUSDS).creationCode, abi.encode("Mock sUSDS", "sUSDS", 18, mockUSDCAddr, faucetAddr)
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
        _assertTestnetChain();
        bytes32 salt = keccak256(abi.encodePacked("MockAUSDCOracle", nonce));
        bytes memory creationCode = abi.encodePacked(type(MockAUSDCOracle).creationCode, abi.encode(owner));
        address mockAUSDCOracle = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        salt = keccak256(abi.encodePacked("MockSUSDSOracle", nonce));
        creationCode = abi.encodePacked(type(MockSUSDSOracle).creationCode, abi.encode(owner));
        address mockSUSDSOracle = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        console.log("MockAUSDCOracle deployed on %s", mockAUSDCOracle);
        console.log("MockSUSDSOracle deployed on %s", mockSUSDSOracle);
    }

    function _deployMockERC20SY(uint256 nonce) internal {
        _assertTestnetChain();
        (address mockUSDC, address mockAUSDC, address mockSUSDS, address mockAUSDCOracle, address mockSUSDSOracle) =
            _mockStackConfig();

        bytes32 salt = keccak256(abi.encodePacked("MockAUSDCSY", nonce));
        address mockAUSDCSY = _deployUpgradeable(
            type(MockOutrunAUSDCSYUpgradeable).creationCode,
            abi.encodeCall(MockOutrunAUSDCSYUpgradeable.initialize, (owner, mockUSDC, mockAUSDC, mockAUSDCOracle)),
            salt
        );

        salt = keccak256(abi.encodePacked("MockSUSDSSY", nonce));
        address mockSUSDSSY = _deployUpgradeable(
            type(MockOutrunSUSDSSYUpgradeable).creationCode,
            abi.encodeCall(MockOutrunSUSDSSYUpgradeable.initialize, (owner, mockUSDC, mockSUSDS, mockSUSDSOracle)),
            salt
        );

        console.log("MockAUSDCSY deployed on %s", mockAUSDCSY);
        console.log("MockSUSDSSY deployed on %s", mockSUSDSSY);
    }

    /// @dev Env-read seam for the mock-stack token/oracle addresses (MOCK_USDC / MOCK_AUSDC /
    ///      MOCK_SUSDS / MOCK_AUSDC_ORACLE / MOCK_SUSDS_ORACLE); harness overrides inject them
    ///      without env (mock-stack tests create fresh instances per test, so per-test env writes
    ///      would race under concurrent test execution).
    function _mockStackConfig()
        internal
        view
        virtual
        returns (
            address mockUSDC,
            address mockAUSDC,
            address mockSUSDS,
            address mockAUSDCOracle,
            address mockSUSDSOracle
        )
    {
        mockUSDC = vm.envAddress("MOCK_USDC");
        mockAUSDC = vm.envAddress("MOCK_AUSDC");
        mockSUSDS = vm.envAddress("MOCK_SUSDS");
        mockAUSDCOracle = vm.envAddress("MOCK_AUSDC_ORACLE");
        mockSUSDSOracle = vm.envAddress("MOCK_SUSDS_ORACLE");
    }

    function _supportMockSY(
        uint256 nonce,
        string memory syEnv,
        string memory saltWord,
        string memory logLabel,
        uint8 family
    ) internal {
        _assertTestnetChain();
        (address syAddress, address uusd, address protocolTreasury) = _mockSupportConfig(syEnv);
        _validateMockSupportConfig(syAddress, uusd, protocolTreasury);
        SPDefaults.assertFamilyUAsset(uusd, family);
        SPDefaults.assertFamilySY(syAddress, family);
        // Resolve the minting cap before the CREATE3 deploy so an explicit-zero cap
        // reverts with the salt unconsumed instead of after the proxy is deployed.
        uint256 mintingCap_ = _spMintingCap();
        // Resolve and validate the optional genesis launcher before the CREATE3 deploy for the
        // same reason: a missing/misconfigured GENESIS_LAUNCHER must revert with the salt
        // unconsumed instead of after the proxy is deployed. Only the final setter call needs
        // spAddress, so it stays after the deploy.
        (bool wireGenesisLauncher, address genesisLauncherAddr) = _genesisLauncherConfig();
        if (wireGenesisLauncher) {
            if (genesisLauncherAddr == address(0)) {
                revert InvalidAddress();
            }
            if (genesisLauncherAddr != memeverseLauncher) revert InvalidAddress();
        }
        bytes32 salt = keccak256(abi.encodePacked(saltWord, nonce));
        address spAddress = _deployUpgradeable(
            type(OutrunStakingPositionUpgradeable).creationCode,
            abi.encodeCall(
                OutrunStakingPositionUpgradeable.initialize,
                (owner, syAddress, uusd, protocolTreasury, SPDefaults.SP_DEFAULT_MIN_STAKE, SPDefaults.SP_DEFAULT_DUTY)
            ),
            salt
        );

        IUniversalAssets(uusd).setMintingCap(spAddress, mintingCap_);

        // Optional genesis-gate wiring: absent key leaves the SP at the zero default
        // (stakeForGenesis disabled); a present key was validated above and is wired here.
        if (wireGenesisLauncher) {
            OutrunStakingPositionUpgradeable(spAddress).setGenesisLauncher(genesisLauncherAddr);
        }

        console.log(string.concat(logLabel, " deployed on %s"), spAddress);
    }

    /// @dev Env-read seam for the optional genesis launcher wiring (GENESIS_LAUNCHER): returns
    ///      whether the key exists and its address. Mirrors `_mockSupportConfig`: harness
    ///      overrides inject the value without env (forge runs tests concurrently and env writes
    ///      race across tests).
    function _genesisLauncherConfig() internal view virtual returns (bool set, address genesisLauncherAddr) {
        if (vm.envExists("GENESIS_LAUNCHER")) {
            return (true, vm.envAddress("GENESIS_LAUNCHER"));
        }
        return (false, address(0));
    }

    /// @dev Env-read seam for the mock-support addresses (the per-family SY env key, UUSD, and
    ///      PROTOCOL_TREASURY); harness overrides inject them without env.
    function _mockSupportConfig(string memory syEnv)
        internal
        view
        virtual
        returns (address sy, address uusd, address protocolTreasury)
    {
        sy = vm.envAddress(syEnv);
        uusd = vm.envAddress("UUSD");
        protocolTreasury = vm.envAddress("PROTOCOL_TREASURY");
    }

    /// @dev Thin named wrappers keep the per-asset support entrypoints explicit; env name,
    /// salt word and log label are passed through verbatim, and `saltWord` is the CREATE3 salt
    /// input — it must stay byte-identical to the historical deployment strings.
    function _supportMockAUSDC(uint256 nonce) internal {
        _supportMockSY(nonce, "MOCK_AUSDC_SY", "Mock SP aUSDC", "SP_AUSDC", SPDefaults.FAMILY_AUSDC);
    }

    function _supportMockSUSDS(uint256 nonce) internal {
        _supportMockSY(nonce, "MOCK_SUSDS_SY", "Mock SP sUSDS", "SP_SUSDS", SPDefaults.FAMILY_SUSDS);
    }

    function _validateMockSupportConfig(address sy, address uusd, address protocolTreasury) internal view {
        _requireBroadcasterIsOwner();
        if (outrunDeployer == address(0) || protocolTreasury == address(0) || sy == address(0) || uusd == address(0)) {
            revert InvalidAddress();
        }

        _requireSelfOwned(uusd);

        try IStandardizedYield(sy).exchangeRate() returns (uint256 exchangeRate) {
            if (exchangeRate == 0) revert InvalidAddress();
        } catch {
            revert InvalidAddress();
        }
    }

    // -------------------------------------------------------------------------
    // mintingCap initial-value wiring (CDP SPs + the POLend engine minter)
    // -------------------------------------------------------------------------

    /// @dev Initial CDP SP minting cap: env-overridable via SP_MINTING_CAP. The placeholder default
    ///      is a deployment-time stand-in only — before launch each family's cap must be re-set by
    ///      governance anchored to that family's PSM reserve scale. Env-read seam: harness
    ///      overrides inject the cap without env; the unset-seam path exercises the default.
    function _spMintingCap() internal view virtual returns (uint256) {
        return SPDefaults.spMintingCap(vm);
    }

    /// @dev Registers the POLend (Memeverse engine, cross-repo) minter on one family uAsset with
    ///      its initial minting cap. The minter address comes from POLEND_MINTER (engine-side, not
    ///      deployed here); the cap comes from <SYMBOL>_POLEND_MINTING_CAP when set, else the
    ///      family default. Call once per family with the family's symbol and explicit cap-family flag.
    ///      Cap-family form is an explicit boolean (isUBNB) rather than a string keccak branch, so the
    ///      UBNB small-cap special case is declared once by the caller and cannot drift between sites.
    function _registerPOLendMinter(string memory symbol, bool isUBNB) internal {
        address uAsset = _familyUAssetAddress(symbol);
        address minter = _polendMinterAddress();
        _validateMintingCapConfig(uAsset, minter, symbol);

        IUniversalAssets(uAsset).setMintingCap(minter, _polendMintingCap(symbol, isUBNB));

        console.log(string.concat(symbol, " POLend minter registered on %s"), minter);
    }

    /// @dev Env-read seam for the engine minter address (POLEND_MINTER); harness overrides inject
    ///      it without env.
    function _polendMinterAddress() internal view virtual returns (address) {
        return vm.envAddress("POLEND_MINTER");
    }

    /// @dev Env-read seam for the per-family initial POLend cap (<SYMBOL>_POLEND_MINTING_CAP,
    ///      else the family default); harness overrides inject it without env. An explicitly
    ///      set zero env value reverts fail-fast: a zero cap would register a minter that
    ///      cannot mint (on-chain zero stays legal for post-deploy wind-down). A cap above
    ///      type(uint128).max reverts fail-fast too, mirroring the on-chain packed uint128
    ///      cap field the wiring call would reject after deployment.
    ///      Cap-family form is an explicit boolean (isUBNB) rather than a string keccak branch.
    function _polendMintingCap(string memory symbol, bool isUBNB) internal view virtual returns (uint256) {
        string memory key = string.concat(symbol, "_POLEND_MINTING_CAP");
        if (!vm.envExists(key)) return _polendMintingCapDefault(isUBNB);
        uint256 cap = vm.envUint(key);
        if (cap == 0) revert SPDefaults.ExplicitZeroMintingCap();
        if (cap > type(uint128).max) revert SPDefaults.MintingCapTooLarge();
        return cap;
    }

    /// @dev Placeholder initial POLend caps by family: UBNB launches with a deliberately small cap
    ///      (early-window ReachMintCap is governance-intended, not an incident); the other families
    ///      share the generic placeholder. Every value is env-overridable here and post-deploy
    ///      adjustable via setMintingCap.
    ///      UBNB check is an explicit boolean, not a string keccak, so adding a new family cannot drift.
    function _polendMintingCapDefault(bool isUBNB) internal pure returns (uint256) {
        return isUBNB ? UBNB_DEFAULT_MINTING_CAP : POLEND_DEFAULT_MINTING_CAP;
    }

    /// @dev Fail-closed pre-checks for a setMintingCap wiring call: the call is owner-only on the
    ///      uAsset, so the broadcaster must be its current owner, and the family-identity re-check
    ///      pins the address env to the family symbol. The minter value itself is operator
    ///      responsibility; the on-chain call rejects a zero minter.
    function _validateMintingCapConfig(address uAsset, address minter, string memory symbol) internal view {
        _requireBroadcasterIsOwner();
        if (uAsset == address(0) || minter == address(0)) revert InvalidAddress();

        _requireSelfOwned(uAsset);

        SPDefaults.assertFamilyUAsset(uAsset, symbol);
    }

    /// @dev Env-read seam for the router config (OUTRUN_ROUTER key). The default reads process
    ///      env; the deploy test harness overrides it to inject the address without mutating
    ///      process env (forge runs tests concurrently and `vm.setEnv` writes race across tests).
    function _routerConfigEnv() internal view virtual returns (bool exists, address router) {
        exists = vm.envExists("OUTRUN_ROUTER");
        router = exists ? vm.envAddress("OUTRUN_ROUTER") : address(0);
    }

    function _applyRouterConfig() internal {
        (bool exists, address router) = _routerConfigEnv();
        if (exists) {
            outrunRouter = router;
            enforceOutrunRouter = true;
        } else {
            outrunRouter = address(0);
            enforceOutrunRouter = false;
        }
    }

    function _deployOutrunRouter(uint256 nonce) internal {
        _validateMemeverseLauncher();
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", nonce));
        bytes memory creationCode =
            abi.encodePacked(type(OutrunRouter).creationCode, abi.encode(owner, memeverseLauncher));
        address outrunRouterAddr = IOutrunDeployer(outrunDeployer).deploy(salt, creationCode);

        // The router address is CREATE3(creator, salt) and must match OUTRUN_ROUTER across chains when set.
        if (enforceOutrunRouter && outrunRouterAddr != outrunRouter) revert InvalidAddress();

        console.log("OutrunRouter deployed on %s", outrunRouterAddr);
    }

    function _updateRouterLauncher() internal {
        _validateMemeverseLauncher();
        address router = outrunRouter != address(0) ? outrunRouter : vm.envAddress("OUTRUN_ROUTER");
        IOutrunRouter(router).setMemeverseLauncher(memeverseLauncher);
    }

    function _validateMemeverseLauncher() internal view {
        if (memeverseLauncher == address(0)) revert InvalidAddress();
    }
}
