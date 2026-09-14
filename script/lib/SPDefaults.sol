// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Minimal ownable surface read by the deploy-time ownership guards.
interface IDeployOwnable {
    function owner() external view returns (address);
}

/// @title SPDefaults
/// @notice Single source of truth for Staking Position (SP) deployment defaults.
/// @dev Both `OutstakeScript` (mock-support SPs) and `YieldDeployScript` (production SPs)
/// deploy SPs with the same zero-fee duty: v1 mints at value parity with no liquidation surface,
/// so every SP deploys at the RAY zero-fee sentinel. Centralizing the constants here
/// makes "same name, same value" a construction guarantee instead of a docs-only convention.
/// Changing a default requires editing only this file; both scripts pick it up via import.
/// Init args and CREATE3 salt bytes stay unchanged so deployed addresses are unaffected.
library SPDefaults {
    error InvalidFamilyUAsset();
    error MismatchedFamilySY(address sy);
    error ExplicitZeroMintingCap();
    error InvalidOwner();
    // Minting cap placeholder — env-overridable via SP_MINTING_CAP, governance must re-set before launch.
    // An explicitly set zero env value reverts instead of deploying an unusable cap.
    uint256 internal constant SP_DEFAULT_MINTING_CAP = 1_000_000_000 ether;
    // Minimum stake — must stay > 0, initialize rejects zero.
    uint256 internal constant SP_DEFAULT_MIN_STAKE = 1;

    // --- Family ids and the shared zero-fee duty sentinel (RAY) ---
    // v1 deploys every family at the shared zero-fee sentinel (`SP_DEFAULT_DUTY`), so there is
    // no per-family dispatch; an unrecognized family id still fails closed via `familySymbol`
    // inside `assertFamilyUAsset`/`assertFamilySY`.
    uint8 internal constant FAMILY_SUSDS = 1;
    uint8 internal constant FAMILY_AUSDC = 2;
    uint8 internal constant FAMILY_SUSDE = 3;
    uint8 internal constant FAMILY_UETH = 4;
    uint8 internal constant FAMILY_UBNB = 5;
    // RAY (1e27) is the zero-fee sentinel: legal, settable, and the v1 default for all families.
    uint256 internal constant SP_DEFAULT_DUTY = 1e27;

    /// @notice Resolves the canonical uAsset symbol for a family id.
    /// @dev Centralized mapping so both deploy scripts share the same family→symbol table
    /// by construction. Unknown family ids revert fail-closed.
    function familySymbol(uint8 family) internal pure returns (string memory) {
        if (family == FAMILY_UETH) return "UETH";
        if (family == FAMILY_UBNB) return "UBNB";
        if (family == FAMILY_SUSDS || family == FAMILY_AUSDC || family == FAMILY_SUSDE) {
            return "UUSD";
        }
        revert InvalidFamilyUAsset();
    }

    /// @dev Shared symbol fetch-and-hash seam for the family-identity checks below.
    /// A reverting contract target reports `ok == false`, so each caller keeps its own
    /// fail-closed revert with its original error; a codeless target succeeds with empty
    /// returndata whose decode failure escapes the try/catch and propagates (still fail-closed).
    function _symbolHash(address token) internal view returns (bool ok, bytes32 hash) {
        try IERC20Metadata(token).symbol() returns (string memory actual) {
            return (true, keccak256(bytes(actual)));
        } catch {
            return (false, bytes32(0));
        }
    }

    /// @notice Family-identity re-check: the resolved uAsset must report the expected symbol.
    /// @dev A mismatch (or a reverting `symbol()` call) means the address env was cross-filled
    /// or points at a non-token; fail closed. Used by both deploy scripts.
    function assertFamilyUAsset(address uAsset, string memory expected) internal view {
        (bool ok, bytes32 actualHash) = _symbolHash(uAsset);
        if (!ok || actualHash != keccak256(bytes(expected))) revert InvalidFamilyUAsset();
    }

    /// @notice Family-identity re-check by family id (resolves symbol via `familySymbol`).
    function assertFamilyUAsset(address uAsset, uint8 family) internal view {
        assertFamilyUAsset(uAsset, familySymbol(family));
    }

    /// @notice SY-to-family binding check: the SY must report the canonical symbol for `family`.
    /// @dev A support entry that pairs a correctly deployed SY with the wrong family constant
    /// would otherwise deploy the SP with another family's duty and no revert. The uAsset
    /// check cannot catch it: all three UUSD families share the "UUSD" symbol. A missing symbol
    /// function, or a family with no registered SY yet, reverts the same way (fail closed).
    function assertFamilySY(address sy, uint8 family) internal view {
        // The UBNB family is v1's only multi-adapter family: both the Lista slisBNB
        // and Aster asBNB symbols are v1-admitted, while every other family below
        // accepts exactly one symbol.
        if (family == FAMILY_UBNB) {
            // Own names (not `ok`/`actualHash`): this block and the generic check below
            // share one function scope, so reusing those names trips shadowing.
            (bool ubnbOk, bytes32 ubnbHash) = _symbolHash(sy);
            if (!ubnbOk) revert MismatchedFamilySY(sy);
            // Both BNB-family symbols are v1-admitted: Lista slisBNB and Aster asBNB.
            if (ubnbHash != keccak256(bytes("SY slisBNB")) && ubnbHash != keccak256(bytes("SY asBNB"))) {
                revert MismatchedFamilySY(sy);
            }
            return;
        }
        string memory expected;
        if (family == FAMILY_UETH) expected = "SY wstETH";
        else if (family == FAMILY_SUSDE) expected = "SY sUSDe";
        else if (family == FAMILY_AUSDC) expected = "SY aUSDC";
        else if (family == FAMILY_SUSDS) expected = "SY sUSDS";
        else revert MismatchedFamilySY(sy);
        (bool ok, bytes32 actualHash) = _symbolHash(sy);
        if (!ok || actualHash != keccak256(bytes(expected))) revert MismatchedFamilySY(sy);
    }

    /// @notice Env-read seam for the SP minting cap, shared by both deploy scripts.
    /// @dev Harness overrides inject the cap without env (see script harnesses); the
    /// unset-seam path returns the placeholder default. An explicitly set zero env value
    /// reverts fail-fast via `validatedMintingCap`: a zero cap would deploy an SP that
    /// cannot mint, which is never an intended launch state (on-chain zero stays legal
    /// for post-deploy wind-down). Tests pin the pieces, not the join: the zero rejection
    /// on `validatedMintingCap` directly, the unset-key fallback via the support suites'
    /// default-value asserts; the one-line handoff below is guarded by review.
    function spMintingCap(Vm vm) internal view returns (uint256) {
        if (!vm.envExists("SP_MINTING_CAP")) return SP_DEFAULT_MINTING_CAP;
        return validatedMintingCap(vm.envUint("SP_MINTING_CAP"));
    }

    /// @notice Rejects an explicitly configured zero minting cap, passes nonzero through.
    /// @dev Pure guard split out of `spMintingCap` so the zero rejection is testable
    /// without process env: a vm.setEnv write for SP_MINTING_CAP races concurrent
    /// suites reading the key on their default paths, so tests assert this guard
    /// through an external harness call with an explicit value.
    function validatedMintingCap(uint256 cap) internal pure returns (uint256) {
        if (cap == 0) revert ExplicitZeroMintingCap();
        return cap;
    }

    /// @dev Deployment-time guard: the broadcast sender must be the configured owner —
    /// every owner-only wiring call reverts on-chain otherwise, so fail closed early with a
    /// stable error surface.
    function requireBroadcasterIsOwner(address owner, address deployer) internal view {
        if (owner != deployer) revert InvalidOwner();
    }

    /// @dev Self-ownership check for a target expected to be owned by `owner`: a call to a
    ///      codeless (EOA) target succeeds with empty returndata whose decode failure escapes
    ///      the try/catch and propagates as a dataless revert; a reverting contract target and
    ///      an owner mismatch both fail closed with `InvalidOwner`. Every path is fail-closed.
    function requireSelfOwned(address owner, address target) internal view {
        try IDeployOwnable(target).owner() returns (address targetOwner) {
            if (targetOwner != owner) revert InvalidOwner();
        } catch {
            revert InvalidOwner();
        }
    }
}
