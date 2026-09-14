// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {UAssetHelper} from "./UAssetHelper.sol";
import {OutrunStakingPositionUpgradeable} from "../../../src/position/OutrunStakingPositionUpgradeable.sol";

/**
 * @title PositionRefModel
 * @notice Stateless reference for the CDP interest model and counter-iterating decomposition.
 * @dev Holds the pure/view math core (`_refUnit`/`_refInterest`/`_pick`, RAY-domain compounding
 *      rate-segment table) and the `idCounter`-iterating helpers that read the
 *      position contract directly. Counter-iterating invariant suites inherit only this
 *      base, so they never depend on ghost bookkeeping (`ghostPrincipal` etc.) or the
 *      `byIds` virtual getters and need no `revert("unused")` stubs. Ghost-dependent
 *      suites (`PositionGhostModel`) layer ghost storage, `byIds` helpers and virtuals on top.
 */
abstract contract PositionRefModel is UAssetHelper {
    /// @dev RAY fixed-point base (1e27) for `duty` and the cumulative rate unit; mirrors production.
    uint256 internal constant RAY = 1e27;

    // Rate-segment table: cumulative rate settled at each segment start.
    struct Segment {
        uint256 startAt;
        uint256 unitAtStart; // RAY cumulative rate at the segment start; the genesis segment starts at RAY.
        uint256 duty; // RAY per-second rate active for the segment.
    }

    Segment[] internal segments;

    /**
     * @notice Seeds the genesis rate segment.
     * @dev The cumulative rate starts at RAY at `startAt`. Every suite seeds the same
     *      shape with its own timestamp and duty, so the construction lives here once.
     */
    function _seedGenesisSegment(uint256 startAt, uint256 duty) internal {
        segments.push(Segment({startAt: startAt, unitAtStart: RAY, duty: duty}));
    }

    /**
     * @notice Cumulative rate at `timestamp` per the segmented compounding model.
     * @dev `segments` last entry holds the current segment; the open segment compounds in
     *      closed form: rmul(rpow(duty, t - startAt), unitAtStart). Same closed form as
     *      production settlement, so a single-span extrapolation agrees wei for wei.
     */
    function _refUnit(uint256 timestamp) internal view returns (uint256) {
        Segment storage current = segments[segments.length - 1];
        return _refRmul(_refRpow(current.duty, timestamp - current.startAt), current.unitAtStart);
    }

    /**
     * @notice Staged-floor interest increment on a RAY rate delta.
     * @dev Full-precision product of principal and the RAY-domain delta, floored once by RAY
     *      (compounding increment domain). Interest accrues on principal only; settled interest
     *      never compounds. Mirrors the production `_interestDelta`.
     */
    function _refInterest(uint256 principal, uint256 deltaUnit) internal pure returns (uint256) {
        return (principal * deltaUnit / RAY);
    }

    /**
     * @notice RAY multiplication with a single truncation.
     * @dev Verbatim production `rmul` semantics: `x * y / RAY` floored once.
     */
    function _refRmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / RAY;
    }

    /**
     * @notice Compounding factor `x^n` in RAY.
     * @dev Verbatim port of the production MakerDAO `rpow` assembly routine:
     *      exponentiation-by-squaring where every intermediate multiply divides by RAY with
     *      round-half-up (`add(half)` with `half = RAY / 2` before `div`), while the outer
     *      multiply applies a single truncation. Overflow and addition-carry checks revert.
     *      Self-implemented in this helper rather than exposed from production: production keeps
     *      its routine private, and widening production visibility for tests is forbidden, so no
     *      area mocks harness can wrap it. Any production change to the routine must be mirrored here.
     */
    function _refRpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := 1000000000000000000000000000 }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := 1000000000000000000000000000 }
                default { z := x }
                let half := div(1000000000000000000000000000, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, 1000000000000000000000000000)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if iszero(eq(div(zx, z), x)) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, 1000000000000000000000000000)
                    }
                }
            }
        }
    }

    // ---- deterministic random helper (same distribution as fuzz suite) ----

    function _pick(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (uint256(keccak256(abi.encode(seed))) % (hi - lo + 1));
    }

    // ---- counter-iterating helpers for invariant suites (idCounter) ----

    function _decomposedSyByCounter(OutrunStakingPositionUpgradeable pos) internal view returns (uint256 total) {
        uint256 last = pos.idCounter();
        for (uint256 id = 1; id <= last; ++id) {
            (address owner, uint256 syStaked,,,) = pos.positions(id);
            if (owner != address(0)) total += syStaked;
        }
    }

    function _ghostMinterTotalByCounter(OutrunStakingPositionUpgradeable pos) internal view returns (uint256 total) {
        uint256 last = pos.idCounter();
        for (uint256 id = 1; id <= last; ++id) {
            (address owner,, uint256 principal,,) = pos.positions(id);
            if (owner != address(0)) total += principal;
        }
    }
}
