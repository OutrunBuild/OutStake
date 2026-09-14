// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunStakingPositionUpgradeable} from "../../../src/position/OutrunStakingPositionUpgradeable.sol";
import {SPDefaults} from "../../../script/lib/SPDefaults.sol";

/// @title SPTestDefaults
/// @notice Single source of truth for SP test deployment defaults.
/// @dev Mirrors `SPDefaults` so prod and test stay in sync by construction.
/// `ZERO_FEE_DUTY` is the v1 prod default (every family deploys at the RAY zero-fee sentinel);
/// `DUTY` is a non-zero interest-test rate (3% annual) so accrual suites exercise the compounding
/// math — zero-fee semantics (frozen rate, zero interest legs) are covered by dedicated tests.
/// Test suites must consume `spInitCall` (or hand-write explicit duty tuples with
/// `ZERO_FEE_DUTY`) instead of writing `(owner, sy, uAsset, treasury, 1, ...)` literals.
/// Changing a parameter requires editing only this file (and `SPDefaults.sol` for prod).
library SPTestDefaults {
    uint256 internal constant MIN_STAKE = SPDefaults.SP_DEFAULT_MIN_STAKE;
    // Zero-fee sentinel duty (1e27): the v1 prod default for every family.
    uint256 internal constant ZERO_FEE_DUTY = SPDefaults.SP_DEFAULT_DUTY;
    // Non-zero interest-test duty: 3% annual per-second RAY value, for accrual suites.
    uint256 internal constant DUTY = 1000000000937303470807876290;
    // Absolute duty cap (15% annual per-second RAY value); mirrors the production cap.
    uint256 internal constant DUTY_CAP = 1000000004431822129783699001;

    /// @notice Returns the canonical SP `initialize` calldata (min-stake and the non-zero
    ///         interest-test duty DUTY inlined; zero-fee suites hand-write ZERO_FEE_DUTY tuples).
    /// @dev The tuple literal and the encode block live only here; `abi.encodeCall` type-checks
    ///      against `initialize`'s signature, so encoding drift fails compilation here instead of
    ///      reverting in every consumer's setUp.
    function spInitCall(address owner, address sy, address uAsset, address treasury)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodeCall(OutrunStakingPositionUpgradeable.initialize, (owner, sy, uAsset, treasury, MIN_STAKE, DUTY));
    }

    /// @notice Ceiled division shared by fuzz and position suites.
    function ceilDiv(uint256 value, uint256 denominator) internal pure returns (uint256) {
        return (value + denominator - 1) / denominator;
    }
}
