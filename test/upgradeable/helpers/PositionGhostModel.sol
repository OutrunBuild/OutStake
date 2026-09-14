// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PositionRefModel} from "./PositionRefModel.sol";

/**
 * @title PositionGhostModel
 * @notice Shared ghost reference for the CDP interest model.
 * @dev Independent reference for RAY-domain compounding: per-segment closed-form rate unit
 *      plus single-floor interest on the RAY delta. Both the fuzz suite
 *      and the invariant handler inherit this base so a rate-model change requires
 *      only one edit. Storage (per-position principal / snapshot /
 *      residual accrued) and the `byIds` helpers live here; timestamp tracking
 *      (`warpAt` / `currentTimestamp`) and position-specific ops stay in the
 *      subclasses via virtual getters. Pure/view math core and `byCounter`
 *      helpers are inherited from `PositionRefModel` so counter-iterating
 *      invariant suites can inherit that base alone without ghost virtuals.
 */
abstract contract PositionGhostModel is PositionRefModel {
    // Per-position ghost bookkeeping (id -> value); index 0 unused.
    mapping(uint256 => uint256) internal ghostPrincipal;
    mapping(uint256 => uint256) internal ghostLastUnit;
    // Residual booked-but-unpaid accrued interest: a partial redeem settles
    // pending interest into accruedInterest but only pays its pro-rata share.
    mapping(uint256 => uint256) internal ghostAccrued;
    uint256[] internal ghostIds; // all ids ever opened

    // Cumulative donations (SY) seen by the ghost model. Shared so the
    // conservation checks in fuzz and invariant handler use the same source.
    uint256 public donatedCum;

    /**
     * @notice Cuts a ghost rate segment at `timestamp`, mirroring a production settlement touchpoint.
     * @dev Production settles its cumulative rate in closed form at every debt-mutating touchpoint
     *      (open, redeem, duty change), so the reference must cut its own segment table at
     *      the same points: one closed form over merged spans would otherwise diverge from the
     *      production per-touchpoint floors by rounding. The cut is continuous
     *      (`unitAtStart` carries the extrapolated value), so snapshots taken at the same timestamp
     *      are unaffected. Pure ghost bookkeeping: reads only the ghost table, never contract state.
     */
    function _settleGhostSegment(uint256 timestamp) internal {
        uint256 duty_ = segments[segments.length - 1].duty;
        uint256 settled = _refUnit(timestamp);
        segments.push(Segment({startAt: timestamp, unitAtStart: settled, duty: duty_}));
    }

    /**
     * @notice Settled interest reference: booked residual plus the pending increment to `timestamp`.
     * @dev Single source for the settled combination so handler and fuzz suites never drift;
     *      callers pass their own tracker (`currentTimestamp` / `warpAt`).
     */
    function _refSettledInterest(uint256 positionId, uint256 timestamp) internal view returns (uint256) {
        return ghostAccrued[positionId]
            + _refInterest(ghostPrincipal[positionId], _refUnit(timestamp) - ghostLastUnit[positionId]);
    }

    /**
     * @notice One bounded duty random-walk step with domain filter.
     * @dev Single source for the walk rule so the fuzz suite and the invariant handler
     *      never drift; callers keep their own randomness, prank target, timestamp
     *      tracker, and segment push. A down-step that would underflow is a no-op
     *      (returns `current` with `skip` set), keeping duty in [RAY, dutyCap];
     *      the zero-fee sentinel (1e27) stays a legal rate.
     */
    function _dutyStepCandidate(uint256 current, uint256 raw, uint256 step, uint256 dutyCap)
        internal
        pure
        returns (uint256 candidate, bool skip)
    {
        candidate = raw > step ? current + (raw - step) : (current > raw ? current - raw : current);
        skip = (candidate == current || candidate < RAY || candidate > dutyCap);
    }

    // ---- ghost-active selection (unified _randomActiveId) ----

    /**
     * @notice Virtual: whether a ghost position id is still active.
     * @dev Subclasses implement via `position.positions(id).owner != address(0)`.
     */
    function _ghostIsActive(uint256 positionId) internal view virtual returns (bool);

    /**
     * @notice Picks a random active ghost id, or 0 if none.
     * @dev Unified from fuzz `keccak _pick` and handler `seed % count`; now
     *      both suites use the same distribution (`_pick`), eliminating the
     *      dual-write drift.
     */
    function _randomActiveId(uint256 seed) internal view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < ghostIds.length; ++i) {
            if (_ghostIsActive(ghostIds[i])) ++count;
        }
        if (count == 0) return 0;
        uint256 target = _pick(seed, 1, count);
        uint256 seen;
        for (uint256 i = 0; i < ghostIds.length; ++i) {
            uint256 id = ghostIds[i];
            if (!_ghostIsActive(id)) continue;
            ++seen;
            if (seen == target) return id;
        }
        return 0;
    }

    // ---- virtual getters for position-specific fields ----

    function _ghostSyStaked(uint256 positionId) internal view virtual returns (uint256);
    function _ghostPrincipalDebt(uint256 positionId) internal view virtual returns (uint256);

    // ---- shared decomposition helpers (ghostIds-iterating) ----

    function _decomposedSyByIds() internal view returns (uint256 total) {
        for (uint256 i = 0; i < ghostIds.length; ++i) {
            uint256 id = ghostIds[i];
            if (!_ghostIsActive(id)) continue;
            total += _ghostSyStaked(id);
        }
    }

    function _ghostMinterTotalByIds() internal view returns (uint256 total) {
        for (uint256 i = 0; i < ghostIds.length; ++i) {
            uint256 id = ghostIds[i];
            if (!_ghostIsActive(id)) continue;
            total += _ghostPrincipalDebt(id);
        }
    }
}
