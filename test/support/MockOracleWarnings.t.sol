// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {MockAUSDCOracle} from "./mocks/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "./mocks/MockSUSDSOracle.sol";
import {OutrunExchangeOracleAdapter} from "../../src/libraries/oracle/OutrunExchangeOracleAdapter.sol";
import {MockAggregator} from "./mocks/MockOracleWarningsMocks.sol";

contract MockOracleWarningsTest is Test {
    bytes4 internal constant INVALID_ORACLE_ANSWER_SELECTOR = bytes4(keccak256("InvalidOracleAnswer()"));
    bytes4 internal constant STALE_ORACLE_ANSWER_SELECTOR = bytes4(keccak256("StaleOracleAnswer()"));
    bytes4 internal constant SEQUENCER_DOWN_SELECTOR = bytes4(keccak256("SequencerDown()"));
    bytes4 internal constant SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR =
        bytes4(keccak256("SequencerGracePeriodNotOver()"));
    bytes4 internal constant ZERO_NORMALIZED_RATE_SELECTOR = bytes4(keccak256("ZeroNormalizedRate()"));
    bytes4 internal constant INVALID_STALENESS_SELECTOR = bytes4(keccak256("InvalidStaleness()"));

    address internal owner = address(0xA11CE);

    MockSUSDSOracle internal susdsOracle;
    MockAUSDCOracle internal ausdcOracle;
    MockAggregator internal aggregator;
    MockAggregator internal sequencerUptimeFeed;
    OutrunExchangeOracleAdapter internal adapter;

    function setUp() external {
        susdsOracle = new MockSUSDSOracle(owner);
        ausdcOracle = new MockAUSDCOracle(owner);
        aggregator = new MockAggregator(18);
        sequencerUptimeFeed = new MockAggregator(18);
        adapter = new OutrunExchangeOracleAdapter(address(aggregator), 2 days, address(0), 0);
    }

    function testMockSUSDSOracleRevertsWhenAnswerIsZeroOrNegative() external {
        vm.startPrank(owner);

        susdsOracle.setLatestAnswer(0);
        vm.expectRevert(INVALID_ORACLE_ANSWER_SELECTOR);
        susdsOracle.getExchangeRate();

        susdsOracle.setLatestAnswer(-1);
        vm.expectRevert(INVALID_ORACLE_ANSWER_SELECTOR);
        susdsOracle.getExchangeRate();

        vm.stopPrank();
    }

    function testMockAUSDCOracleRevertsWhenAnswerIsZeroOrNegative() external {
        vm.startPrank(owner);

        ausdcOracle.setLatestAnswer(0);
        vm.expectRevert(INVALID_ORACLE_ANSWER_SELECTOR);
        ausdcOracle.getExchangeRate();

        ausdcOracle.setLatestAnswer(-1);
        vm.expectRevert(INVALID_ORACLE_ANSWER_SELECTOR);
        ausdcOracle.getExchangeRate();

        vm.stopPrank();
    }

    function testExchangeOracleAdapterRevertsWhenAnswerIsZeroOrNegative() external {
        aggregator.setLatestAnswer(0);
        vm.expectRevert(INVALID_ORACLE_ANSWER_SELECTOR);
        adapter.getExchangeRate();

        aggregator.setLatestAnswer(-1);
        vm.expectRevert(INVALID_ORACLE_ANSWER_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterRevertsWhenLatestRoundDataIsStale() external {
        vm.warp(10 days);
        aggregator.setLatestRoundData(1.1 ether, block.timestamp - 2 days - 1);

        vm.expectRevert(STALE_ORACLE_ANSWER_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterRevertsWhenSequencerIsDown() external {
        adapter = new OutrunExchangeOracleAdapter(address(aggregator), 2 days, address(sequencerUptimeFeed), 1 hours);
        aggregator.setLatestAnswer(1.1 ether);
        sequencerUptimeFeed.setLatestAnswer(1);

        vm.expectRevert(SEQUENCER_DOWN_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterRevertsDuringSequencerGracePeriod() external {
        adapter = new OutrunExchangeOracleAdapter(address(aggregator), 2 days, address(sequencerUptimeFeed), 1 hours);
        vm.warp(10 days);
        aggregator.setLatestAnswer(1.1 ether);
        sequencerUptimeFeed.setLatestRoundData(0, block.timestamp - 30 minutes, block.timestamp - 30 minutes);

        vm.expectRevert(SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterRevertsWhenSequencerStartedAtIsZero() external {
        adapter = new OutrunExchangeOracleAdapter(address(aggregator), 2 days, address(sequencerUptimeFeed), 1 hours);
        vm.warp(10 days);
        aggregator.setLatestAnswer(1.1 ether);
        sequencerUptimeFeed.setLatestRoundData(0, 0, block.timestamp);

        vm.expectRevert(SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterRevertsWhenUpdatedAtInFuture() external {
        // Feed clock ahead of chain time (e.g. L1-relayed feed on a lagging L2) must surface as the
        // documented StaleOracleAnswer, not a Panic(0x11) from the underflowing age subtraction.
        aggregator.setLatestRoundData(1e18, block.timestamp + 1 hours);
        vm.expectRevert(STALE_ORACLE_ANSWER_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterRevertsWhenSequencerStartedAtInFuture() external {
        adapter = new OutrunExchangeOracleAdapter(address(aggregator), 2 days, address(sequencerUptimeFeed), 1 hours);
        vm.warp(10 days);
        aggregator.setLatestAnswer(1.1 ether);
        // Feed clock ahead of chain time must surface as SequencerGracePeriodNotOver: the
        // startedAt > block.timestamp guard reverts before the age subtraction, so the unchecked
        // block.timestamp - startedAt can never underflow into a huge age that skips the grace
        // window and returns an untrusted price.
        sequencerUptimeFeed.setLatestRoundData(0, block.timestamp + 1 hours, block.timestamp);

        vm.expectRevert(SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR);
        adapter.getExchangeRate();
    }

    function testExchangeOracleAdapterNormalizes8DecimalAnswerTo18Scale() external {
        MockAggregator aggregator8 = new MockAggregator(8);
        aggregator8.setLatestAnswer(1.05e8);
        OutrunExchangeOracleAdapter adapter8 =
            new OutrunExchangeOracleAdapter(address(aggregator8), 2 days, address(0), 0);

        // (1.05e8 * 1e18) / 1e8 == 1.05e18 — raw 8-decimal feed scaled to the fixed 1e18 output scale.
        assertEq(adapter8.getExchangeRate(), 1.05e18);
    }

    function testExchangeOracleAdapterNormalizes18DecimalAnswerTo18Scale() external {
        MockAggregator aggregator18 = new MockAggregator(18);
        aggregator18.setLatestAnswer(1.1e18);
        OutrunExchangeOracleAdapter adapter18 =
            new OutrunExchangeOracleAdapter(address(aggregator18), 2 days, address(0), 0);

        // Same-scale feed passes through unchanged.
        assertEq(adapter18.getExchangeRate(), 1.1e18);
    }

    function testExchangeOracleAdapterRevertsWhenNormalizedRateIsZero() external {
        // rawDecimals=19 passes the construction overflow guard (it only fails at >= 78), but answer=1
        // truncates to zero after normalization: 1 * 1e18 / 1e19 == 0.
        MockAggregator aggregator19 = new MockAggregator(19);
        aggregator19.setLatestAnswer(1);
        OutrunExchangeOracleAdapter adapter19 =
            new OutrunExchangeOracleAdapter(address(aggregator19), 2 days, address(0), 0);

        vm.expectRevert(ZERO_NORMALIZED_RATE_SELECTOR);
        adapter19.getExchangeRate();
    }

    function testExchangeOracleAdapterNormalizes19DecimalAnswerWhenLargeEnough() external {
        // A 19-decimal feed with an answer large enough to survive normalization still works: the new
        // zero check must not reject non-zero rates.
        MockAggregator aggregator19 = new MockAggregator(19);
        aggregator19.setLatestAnswer(10 ether); // 1e19: 1e19 * 1e18 / 1e19 == 1e18
        OutrunExchangeOracleAdapter adapter19 =
            new OutrunExchangeOracleAdapter(address(aggregator19), 2 days, address(0), 0);

        assertEq(adapter19.getExchangeRate(), 1e18);
    }

    function testExchangeOracleAdapterNormalizes19DecimalAnswerAtThreshold() external {
        // Threshold: answer == 10^(rawDecimals-18) keeps the normalized rate non-zero (10 * 1e18 / 1e19 == 1).
        MockAggregator aggregator19 = new MockAggregator(19);
        aggregator19.setLatestAnswer(10);
        OutrunExchangeOracleAdapter adapter19 =
            new OutrunExchangeOracleAdapter(address(aggregator19), 2 days, address(0), 0);

        assertEq(adapter19.getExchangeRate(), 1);
    }

    function testExchangeOracleAdapterConstructorRevertsWhenRawDecimalsPowerOverflows() external {
        // rawDecimals >= 78 makes 10 ** rawDecimals overflow uint256. Precomputing the power at
        // construction moves this arithmetic error from every rate read to deployment (fail fast on
        // misconfigured feeds).
        MockAggregator aggregator78 = new MockAggregator(78);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        new OutrunExchangeOracleAdapter(address(aggregator78), 2 days, address(0), 0);

        MockAggregator aggregator255 = new MockAggregator(255);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        new OutrunExchangeOracleAdapter(address(aggregator255), 2 days, address(0), 0);
    }

    function testExchangeOracleAdapterRevertsWhenMaxStalenessIsZero() external {
        vm.expectRevert(INVALID_STALENESS_SELECTOR);
        new OutrunExchangeOracleAdapter(address(aggregator), 0, address(0), 0);
    }

    function testExchangeOracleAdapterRevertsWhenOracleIsZero() external {
        bytes4 invalidOracleSelector = bytes4(keccak256("InvalidOracle()"));
        vm.expectRevert(invalidOracleSelector);
        new OutrunExchangeOracleAdapter(address(0), 2 days, address(0), 0);
    }
}

/// @title Property tests for OutrunExchangeOracleAdapter validation and normalization
/// @notice Stateless fuzz properties pinning the adapter's documented behavior: the staleness
///     boundary from both sides (OR-1), the cross-decimals normalization identity (SY-4a),
///     two-instance agreement on the same physical price (OR-3a), the sequencer guard running
///     before every main-feed check (OR-3d), and the revert-or-valid dichotomy under which no bad
///     value ever escapes (OR-4). Property numbering follows the oracle invariants design
///     (docs/audits/2026-08-19/05-invariants.md §4).
contract OracleAdapterPropertyTest is Test {
    bytes4 internal constant STALE_ORACLE_ANSWER_SELECTOR = bytes4(keccak256("StaleOracleAnswer()"));
    bytes4 internal constant SEQUENCER_DOWN_SELECTOR = bytes4(keccak256("SequencerDown()"));
    bytes4 internal constant SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR =
        bytes4(keccak256("SequencerGracePeriodNotOver()"));
    bytes4 internal constant ZERO_NORMALIZED_RATE_SELECTOR = bytes4(keccak256("ZeroNormalizedRate()"));
    // Solidity Panic selector: a fail-closed surface must fail with named errors, never with an
    // arithmetic Panic that downstream callers cannot distinguish from a bug.
    bytes4 internal constant PANIC_SELECTOR = bytes4(0x4e487b71);

    /// @notice [OR-1] The staleness window is a two-sided boundary: an answer aged exactly
    ///     `maxStaleness` is still accepted (the source uses a strict `>`), while one second older
    ///     reverts with StaleOracleAnswer.
    function testFuzz_StalenessBoundaryTwoSided(uint48 maxStaleness, uint256 caseSeed) external {
        uint256 staleness = bound(maxStaleness, 1, 30 days);
        // delta ∈ {−1, 0, +1} probes below, exactly on, and above the boundary.
        int256 delta = int256(caseSeed % 3) - 1;
        uint256 age = uint256(int256(staleness) + delta);

        // Warp past the largest possible age (30 days + 1): the feed timestamp is written as
        // block.timestamp - age, so a warp point inside the staleness domain would underflow the
        // test's own arithmetic before the adapter is even called.
        vm.warp(60 days);
        MockAggregator feed = new MockAggregator(18);
        OutrunExchangeOracleAdapter adapter = new OutrunExchangeOracleAdapter(address(feed), staleness, address(0), 0);
        feed.setLatestRoundData(1.1e18, block.timestamp - age);

        if (age > staleness) {
            vm.expectRevert(STALE_ORACLE_ANSWER_SELECTOR);
            adapter.getExchangeRate();
        } else {
            // Includes the age == maxStaleness boundary itself: the strict `>` lets it through.
            assertEq(adapter.getExchangeRate(), 1.1e18);
        }
    }

    /// @notice [SY-4a] Normalization is an identity: for every decimal count the returned rate is
    ///     exactly mulDiv(raw, 1e18, 10**decimals), and the floor-truncation gap stays below one
    ///     raw quantum (10**decimals). ZeroNormalizedRate fires only when decimals > 18 and the
    ///     raw answer is below 10**(decimals − 18) — the truncation-then-reject path.
    function testFuzz_OracleNormalizationIdentity(uint8 decimals, uint256 raw) external {
        // ≤ 30 keeps 10**decimals and every product in this test far from overflow.
        uint8 d = uint8(bound(decimals, 0, 30));
        uint256 r = bound(raw, 1, 1e12);

        MockAggregator feed = new MockAggregator(d);
        OutrunExchangeOracleAdapter adapter = new OutrunExchangeOracleAdapter(address(feed), 2 days, address(0), 0);
        vm.warp(10 days);
        feed.setLatestRoundData(int256(r), block.timestamp);

        // raw ≤ 1e12 keeps every intermediate product below 1e30, so a plain mul/div equals
        // full-precision mulDiv on this domain.
        uint256 expected = (r * 1e18) / 10 ** d;
        if (expected == 0) {
            // Only reachable when d > 18: raw < 10**(d − 18) truncates to zero.
            vm.expectRevert(ZERO_NORMALIZED_RATE_SELECTOR);
            adapter.getExchangeRate();
        } else {
            assertEq(adapter.getExchangeRate(), expected);
            // Floor guarantee: expected·10^d ≤ raw·1e18 < (expected + 1)·10^d, so the gap is
            // strictly below one quantum of the raw scale.
            assertLt(r * 1e18 - expected * 10 ** d, 10 ** d);
        }
    }

    /// @notice [OR-3a] Two adapters over feeds with different decimals agree exactly when the
    ///     physical price is integrally representable in both domains: rawA = price·10^dA and
    ///     rawB = price·10^dB both normalize back to price·1e18 with zero floor loss.
    function testFuzz_TwoAdaptersAgreeOnSamePhysicalPrice(uint8 dA, uint8 dB, uint256 price) external {
        uint8 a = uint8(bound(dA, 0, 18));
        uint8 b = uint8(bound(dB, 0, 18));
        uint256 p = bound(price, 1, 1e12);

        MockAggregator feedA = new MockAggregator(a);
        MockAggregator feedB = new MockAggregator(b);
        OutrunExchangeOracleAdapter adapterA = new OutrunExchangeOracleAdapter(address(feedA), 2 days, address(0), 0);
        OutrunExchangeOracleAdapter adapterB = new OutrunExchangeOracleAdapter(address(feedB), 2 days, address(0), 0);

        vm.warp(10 days);
        // Integer physical price, exactly representable in both decimal domains, fresh timestamps.
        feedA.setLatestAnswer(int256(p * 10 ** a));
        feedB.setLatestAnswer(int256(p * 10 ** b));

        uint256 rateA = adapterA.getExchangeRate();
        uint256 rateB = adapterB.getExchangeRate();
        assertEq(rateA, rateB);
        assertEq(rateA, p * 1e18);
    }

    /// @notice [OR-3d] The sequencer guard runs before every main-feed check: with the sequencer
    ///     unhealthy (down, still in grace, recovery never recorded, or startedAt in the future),
    ///     getExchangeRate reverts with the sequencer's own named error even when the main feed is
    ///     simultaneously stale or zero — a main-feed error surfacing instead would mean the two
    ///     checks run out of order.
    function testFuzz_SequencerCheckPrecedesPriceChecks(uint256 mainCase, uint256 seqCase) external {
        MockAggregator feed = new MockAggregator(18);
        MockAggregator seqFeed = new MockAggregator(18);
        OutrunExchangeOracleAdapter adapter =
            new OutrunExchangeOracleAdapter(address(feed), 2 days, address(seqFeed), 1 hours);
        vm.warp(10 days);

        // Main-feed state: fresh / stale (3 days > the 2-day window) / zero answer but fresh.
        uint256 main = mainCase % 3;
        if (main == 0) {
            feed.setLatestAnswer(1.1e18);
        } else if (main == 1) {
            feed.setLatestRoundData(1.1e18, block.timestamp - 3 days);
        } else {
            feed.setLatestRoundData(0, block.timestamp);
        }

        // Sequencer state: down / within grace / recovery never recorded / startedAt in the future.
        uint256 seq = seqCase % 4;
        if (seq == 0) {
            seqFeed.setLatestAnswer(1);
        } else if (seq == 1) {
            seqFeed.setLatestRoundData(0, block.timestamp - 30 minutes, block.timestamp - 30 minutes);
        } else if (seq == 2) {
            seqFeed.setLatestRoundData(0, 0, block.timestamp);
        } else {
            seqFeed.setLatestRoundData(0, block.timestamp + 1 hours, block.timestamp);
        }

        // The expected error depends on the sequencer case, so vm.expectRevert cannot be used —
        // classify the outcome with try/catch and a bytes4 comparison instead.
        try adapter.getExchangeRate() returns (uint256) {
            revert("sequencer-unhealthy state returned a rate");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            bytes4 expectedSelector = seq == 0 ? SEQUENCER_DOWN_SELECTOR : SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR;
            assertTrue(selector == expectedSelector, "main-feed state leaked past the sequencer guard");
        }
    }

    /// @notice [OR-4] Over the full input-combination space the adapter is revert-or-valid: it
    ///     either reverts with a named error (never a Panic) or returns exactly
    ///     mulDiv(rawAnswer, 1e18, 10**decimals) — never zero, never an unnormalized value, never
    ///     a silent success on a bad input.
    function testFuzz_RevertOrValidNeverBadValue(int216 rawAnswer, uint256 ageSeed, uint256 seqSeed, uint8 decimals)
        external
    {
        uint8 d = uint8(bound(decimals, 0, 18));
        // The int216 fuzz parameter natively bounds the magnitude; restricting to ±2^90 keeps the
        // value far from the checked-multiply overflow region — extreme magnitudes are pinned by
        // the dedicated example below.
        int216 bounded = int216(bound(int256(rawAnswer), -(2 ** 90), 2 ** 90));
        uint256 age = bound(ageSeed, 0, 5 days);

        MockAggregator feed = new MockAggregator(d);
        MockAggregator seqFeed = new MockAggregator(18);
        OutrunExchangeOracleAdapter adapter =
            new OutrunExchangeOracleAdapter(address(feed), 2 days, address(seqFeed), 1 hours);
        vm.warp(10 days);

        // Sequencer state: cases 0–3 unhealthy as in the priority test above; case 4 recovered
        // long ago (startedAt 2 hours ago > the 1-hour grace), letting the main-feed checks run.
        uint256 seq = seqSeed % 5;
        if (seq == 0) {
            seqFeed.setLatestAnswer(1);
        } else if (seq == 1) {
            seqFeed.setLatestRoundData(0, block.timestamp - 30 minutes, block.timestamp - 30 minutes);
        } else if (seq == 2) {
            seqFeed.setLatestRoundData(0, 0, block.timestamp);
        } else if (seq == 3) {
            seqFeed.setLatestRoundData(0, block.timestamp + 1 hours, block.timestamp);
        } else {
            seqFeed.setLatestRoundData(0, block.timestamp - 2 hours, block.timestamp - 2 hours);
        }

        feed.setLatestRoundData(int256(bounded), block.timestamp - age);

        try adapter.getExchangeRate() returns (uint256 rate) {
            assertGt(rate, 0);
            // On this domain (|raw| ≤ 2^90, d ≤ 18) the plain product cannot overflow, so the
            // only legal return value is the exact normalized form.
            assertEq(rate, (uint256(int256(bounded)) * 1e18) / 10 ** d);
        } catch (bytes memory reason) {
            // Fail-closed means named errors only: an arithmetic Panic escaping this surface
            // would be indistinguishable from a bug for downstream callers.
            assertNotEq(bytes32(bytes4(reason)), bytes32(PANIC_SELECTOR), "Panic escaped the fail-closed surface");
        }
    }

    /// @notice [OR-4 extreme magnitude] An answer of int256.max overflows the checked
    ///     normalization multiply: the adapter must revert — here with the arithmetic Panic —
    ///     rather than silently return a wrapped-around rate. Realistic feed domains (≤ 18
    ///     decimals, values < 2^90) are covered by the fuzz property above; this example pins
    ///     only the extreme magnitude.
    function test_ExtremeAnswerRevertsFailClosed() external {
        MockAggregator feed = new MockAggregator(18);
        OutrunExchangeOracleAdapter adapter = new OutrunExchangeOracleAdapter(address(feed), 2 days, address(0), 0);
        vm.warp(10 days);
        feed.setLatestAnswer(type(int256).max);

        try adapter.getExchangeRate() returns (uint256) {
            revert("extreme answer silently returned a rate");
        } catch {} // any revert — including the checked-multiply Panic — is the fail-closed outcome
    }
}
