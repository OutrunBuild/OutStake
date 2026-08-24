// SPDX-License-Identifier: GPL-3.0
// @notice Ported from docs/audits/2026-08-24/05-invariants/OracleInvariants.t.sol — non-redundant oracle fuzz invariants (stale/sequencer/band/deviation) not covered by test/upgradeable/OracleSetterUpgradeable.t.sol
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

/// @notice Mock Chainlink Aggregator — controllable roundId/answer/timestamps.
contract MockAggregator {
    uint80 public roundId = 1;
    int256 public answer = 1e8;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    uint8 public decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function setRoundData(
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) external {
        roundId = _roundId;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice Mock L2 sequencer uptime feed — same tuple, answer 0 = up.
contract MockSequencer is MockAggregator {
    constructor() MockAggregator(0) {}
}

/// @notice Mock SSR RateProvider (1e27 scale).
contract MockRateProvider {
    uint256 public rate = 1e27;

    function setRate(uint256 r) external {
        rate = r;
    }

    function getConversionRate() external view returns (uint256) {
        return rate;
    }
}

/// @notice Mock PSM3 — only previewSwapExactIn needed for deviation check.
contract MockPSM {
    uint256 public previewRate = 1e18; // 1:1, 1e18 scaled

    function setPreviewRate(uint256 r) external {
        previewRate = r;
    }

    function previewSwapExactIn(address, address, uint256 amount) external view returns (uint256) {
        return (amount * previewRate) / 1e18;
    }

    function rateProvider() external pure returns (address) {
        return address(0);
    }
}

// ---------------------------------------------------------------------------
// Harness — models OutrunExchangeOracleAdapter + band + PSM deviation checks.
// ---------------------------------------------------------------------------

contract OracleHarness {
    MockAggregator public aggregator;
    MockSequencer public sequencer;
    uint256 public maxStaleness;
    uint256 public sequencerGracePeriod;
    uint256 public rawScale;
    int256 public bandMin;
    int256 public bandMax;
    bool public bandEnabled;

    MockRateProvider public rateProvider;
    MockPSM public psm;
    uint16 public maxDeviationBps;

    error InvalidStaleness();
    error InvalidOracle();
    error InvalidOracleAnswer();
    error ZeroNormalizedRate();
    error StaleOracleAnswer();
    error SequencerDown();
    error SequencerGracePeriodNotOver();
    error BandViolation(int256 answer, int256 minAns, int256 maxAns);
    error RateProviderCallFailed();
    error RateDeviationExceeded(uint256 psmRate, uint256 ssrRate, uint256 maxBps);

    uint256 public constant ONE = 1e18;

    constructor(
        MockAggregator _aggregator,
        MockSequencer _sequencer,
        uint256 _maxStaleness,
        uint256 _gracePeriod,
        MockRateProvider _rateProvider,
        MockPSM _psm,
        uint16 _maxDeviationBps
    ) {
        if (_maxStaleness == 0) revert InvalidStaleness();
        if (address(_aggregator) == address(0)) revert InvalidOracle();
        aggregator = _aggregator;
        sequencer = _sequencer;
        maxStaleness = _maxStaleness;
        sequencerGracePeriod = _gracePeriod;
        rawScale = 10 ** _aggregator.decimals();
        rateProvider = _rateProvider;
        psm = _psm;
        maxDeviationBps = _maxDeviationBps == 0 ? 100 : _maxDeviationBps;
    }

    function setBand(int256 _min, int256 _max) external {
        bandMin = _min;
        bandMax = _max;
        bandEnabled = true;
    }

    function disableBand() external {
        bandEnabled = false;
    }

    function setMaxDeviationBps(uint16 bps) external {
        maxDeviationBps = bps;
    }

    // -- Chainlink path (staleness, sequencer, answer>0, zero rate, band) --

    function getExchangeRate() external view returns (uint256) {
        _validateSequencer();
        (, int256 answer,, uint256 updatedAt,) = aggregator.latestRoundData();
        if (answer <= 0) revert InvalidOracleAnswer();
        if (bandEnabled) {
            if (answer < bandMin || answer > bandMax) revert BandViolation(answer, bandMin, bandMax);
        }
        if (updatedAt == 0 || updatedAt > block.timestamp) revert StaleOracleAnswer();
        unchecked {
            if (block.timestamp - updatedAt > maxStaleness) revert StaleOracleAnswer();
        }
        uint256 rate = (uint256(answer) * ONE) / rawScale;
        if (rate == 0) revert ZeroNormalizedRate();
        return rate;
    }

    function _validateSequencer() internal view {
        if (address(sequencer) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = sequencer.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || startedAt > block.timestamp) revert SequencerGracePeriodNotOver();
        unchecked {
            if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriodNotOver();
        }
    }

    // -- PSM/SSR path (zero rate, deviation) --

    function getSSRWithDeviationGuard() external view returns (uint256) {
        uint256 rate;
        // solhint-disable-next-line no-empty-blocks
        try rateProvider.getConversionRate() returns (uint256 r) {
            rate = r;
        } catch {
            revert RateProviderCallFailed();
        }
        if (rate == 0) revert RateProviderCallFailed();
        uint256 ssrRate = (1 ether * rate) / 1e27;
        if (ssrRate == 0) revert RateProviderCallFailed();
        uint256 psmRate = psm.previewSwapExactIn(address(0), address(0), 1 ether);
        uint256 maxBps = maxDeviationBps;
        if (psmRate != ssrRate && ssrRate != 0) {
            uint256 diff = psmRate > ssrRate ? psmRate - ssrRate : ssrRate - psmRate;
            uint256 bps = (diff * 10000) / ssrRate;
            if (bps > maxBps) revert RateDeviationExceeded(psmRate, ssrRate, maxBps);
        }
        return ssrRate;
    }
}

// ---------------------------------------------------------------------------
// Handler for invariant fuzzing
// ---------------------------------------------------------------------------

contract OracleHandler is Test {
    MockAggregator public aggregator;
    MockSequencer public sequencer;
    MockRateProvider public rateProvider;
    MockPSM public psm;
    OracleHarness public harness;

    uint256 public ghostStaleReverts;
    uint256 public ghostSequencerReverts;
    uint256 public ghostBandReverts;
    uint256 public ghostDeviationReverts;
    uint256 public ghostCalls;

    constructor() {
        aggregator = new MockAggregator(8);
        sequencer = new MockSequencer();
        rateProvider = new MockRateProvider();
        psm = new MockPSM();
        // heartbeat 1 hour, grace 1 hour, 100 bps guard
        harness = new OracleHarness(aggregator, sequencer, 3600, 3600, rateProvider, psm, 100);
        harness.setBand(5e7, 2e8); // [0.5, 2.0] at 8 decimals
        // sequencer is UP by default, started 2h ago
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
    }

    // -- Chainlink feed -------------------------------------------------------

    function handler_setAggregator(int256 answer, uint256 ageSeed) external {
        ageSeed = bound(ageSeed, 0, 7200);
        uint256 updatedAt = block.timestamp - ageSeed;
        // clamp answer to keep harness reachable but allow edge cases
        // bound to [-1e8, 3e8] then caller can push extremes via other handlers
        int256 a = int256(bound(uint256(int256(answer) < 0 ? -int256(answer) : int256(answer)), 0, 300_000_000));
        if (answer < 0) a = -a;
        aggregator.setRoundData(1, a, updatedAt, updatedAt, 1);
        ghostCalls++;
    }

    function handler_setStale(uint256 ageSeed) external {
        // force staleness: age > maxStaleness
        ageSeed = bound(ageSeed, 3601, 10000);
        uint256 t = block.timestamp - ageSeed;
        int256 a = aggregator.answer();
        if (a <= 0) a = 1e8;
        aggregator.setRoundData(1, a, t, t, 1);
        ghostCalls++;
    }

    function handler_setSequencerDown(bool down, uint256 startedAgo) external {
        startedAgo = bound(startedAgo, 0, 10000);
        if (down) {
            sequencer.setRoundData(1, 1, block.timestamp - startedAgo, block.timestamp, 1);
        } else {
            sequencer.setRoundData(1, 0, block.timestamp - startedAgo, block.timestamp, 1);
        }
        ghostCalls++;
    }

    function handler_setBand(int256 minAns, int256 maxAns) external {
        // ensure min <= max, both in sane 8-dec range
        minAns = int256(bound(uint256(minAns < 0 ? -minAns : minAns), 0, 200_000_000));
        maxAns = int256(bound(uint256(maxAns < 0 ? -maxAns : maxAns), 0, 300_000_000));
        if (minAns > maxAns) (minAns, maxAns) = (maxAns, minAns);
        if (minAns == maxAns) maxAns = minAns + 1e7;
        harness.setBand(minAns, maxAns);
        ghostCalls++;
    }

    function handler_setRateProvider(uint256 r) external {
        r = bound(r, 0, 5e27);
        rateProvider.setRate(r);
        ghostCalls++;
    }

    function handler_setPSMRate(uint256 r) external {
        r = bound(r, 0, 5e18);
        psm.setPreviewRate(r);
        ghostCalls++;
    }

    function handler_setMaxDeviation(uint16 bps) external {
        bps = uint16(bound(uint256(bps), 1, 10000));
        harness.setMaxDeviationBps(bps);
        ghostCalls++;
    }

    function handler_warp(uint256 dt) external {
        dt = bound(dt, 1, 7 days);
        vm.warp(block.timestamp + dt);
        ghostCalls++;
    }
}

// ---------------------------------------------------------------------------
// Invariant + unit tests
// ---------------------------------------------------------------------------

contract OracleInvariants is StdInvariant, Test {
    OracleHandler public handler;
    OracleHarness public harness;
    MockAggregator public aggregator;
    MockSequencer public sequencer;
    MockRateProvider public rateProvider;
    MockPSM public psm;

    function setUp() public {
        handler = new OracleHandler();
        harness = handler.harness();
        aggregator = handler.aggregator();
        sequencer = handler.sequencer();
        rateProvider = handler.rateProvider();
        psm = handler.psm();

        targetContract(address(handler));
        // Keep corpus focused on oracle entry points; invariant_* excluded automatically.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.handler_setAggregator.selector;
        selectors[1] = handler.handler_setStale.selector;
        selectors[2] = handler.handler_setSequencerDown.selector;
        selectors[3] = handler.handler_setBand.selector;
        selectors[4] = handler.handler_setRateProvider.selector;
        selectors[5] = handler.handler_setPSMRate.selector;
        selectors[6] = handler.handler_warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // -----------------------------------------------------------------------
    // Invariants — required names
    // -----------------------------------------------------------------------

    /// @notice Reverts when heartbeat exceeds threshold (staleness > maxStaleness).
    function invariant_RevertIfStale() public {
        // push feed into stale region
        uint256 staleAt = block.timestamp - harness.maxStaleness() - 1;
        // keep answer positive and in-band
        aggregator.setRoundData(1, 1e8, staleAt, staleAt, 1);
        // sequencer healthy
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        vm.expectRevert(OracleHarness.StaleOracleAnswer.selector);
        harness.getExchangeRate();
    }

    /// @notice Reverts while L2 sequencer is down or in grace window.
    function invariant_RevertIfSequencerDown() public {
        // feed fresh
        aggregator.setRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
        // sequencer DOWN
        sequencer.setRoundData(1, 1, block.timestamp, block.timestamp, 1);
        vm.expectRevert(OracleHarness.SequencerDown.selector);
        harness.getExchangeRate();

        // sequencer reports UP but still in grace window
        sequencer.setRoundData(1, 0, block.timestamp, block.timestamp, 1);
        vm.expectRevert(OracleHarness.SequencerGracePeriodNotOver.selector);
        harness.getExchangeRate();
    }

    /// @notice Reverts when PSM quote deviates from SSR beyond maxDeviationBps.
    function invariant_RevertIfDeviationTooHigh() public {
        // SSR = 1e18, PSM = 1.05e18 => 500 bps, guard 100 bps => must revert
        rateProvider.setRate(1e27);
        psm.setPreviewRate(1050000000000000000); // 1.05e18
        harness.setMaxDeviationBps(100);
        vm.expectRevert(
            abi.encodeWithSelector(OracleHarness.RateDeviationExceeded.selector, 1050000000000000000, 1e18, 100)
        );
        harness.getSSRWithDeviationGuard();

        // Within guard must not revert
        harness.setMaxDeviationBps(600);
        uint256 ssr = harness.getSSRWithDeviationGuard();
        assertEq(ssr, 1e18);
    }

    /// @notice Reverts when answer outside configured [min,max] band.
    function invariant_RevertIfBandViolation() public {
        harness.setBand(8e7, 12e7); // [0.8, 1.2]
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);

        // below band
        aggregator.setRoundData(1, 5e7, block.timestamp, block.timestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleHarness.BandViolation.selector, int256(5e7), int256(8e7), int256(12e7))
        );
        harness.getExchangeRate();

        // above band
        aggregator.setRoundData(1, 2e8, block.timestamp, block.timestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleHarness.BandViolation.selector, int256(2e8), int256(8e7), int256(12e7))
        );
        harness.getExchangeRate();

        // inside band succeeds
        aggregator.setRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
        uint256 rate = harness.getExchangeRate();
        assertEq(rate, 1e18);
    }

    // -----------------------------------------------------------------------
    // Additional coverage: answer <=0, zero normalized rate, zero RateProvider
    // -----------------------------------------------------------------------

    function test_RevertWhen_AnswerZeroOrNegative() public {
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        harness.disableBand(); // isolate answer check
        aggregator.setRoundData(1, 0, block.timestamp, block.timestamp, 1);
        vm.expectRevert(OracleHarness.InvalidOracleAnswer.selector);
        harness.getExchangeRate();

        aggregator.setRoundData(1, -1, block.timestamp, block.timestamp, 1);
        vm.expectRevert(OracleHarness.InvalidOracleAnswer.selector);
        harness.getExchangeRate();
    }

    function test_RevertWhen_ZeroNormalizedRate() public {
        // feed with 20 decimals but tiny answer truncates to zero after /1e20
        MockAggregator highDec = new MockAggregator(20);
        MockRateProvider rp2 = new MockRateProvider();
        MockPSM psm2 = new MockPSM();
        OracleHarness h2 = new OracleHarness(highDec, sequencer, 3600, 3600, rp2, psm2, 100);
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        highDec.setRoundData(1, 1, block.timestamp, block.timestamp, 1); // 1 wei at 20 dec -> 0 after norm
        vm.expectRevert(OracleHarness.ZeroNormalizedRate.selector);
        h2.getExchangeRate();
    }

    function test_RevertWhen_RateProviderZero() public {
        rateProvider.setRate(0);
        vm.expectRevert(OracleHarness.RateProviderCallFailed.selector);
        harness.getSSRWithDeviationGuard();
    }

    function test_RevertWhen_StaleFutureTimestamp() public {
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        harness.disableBand();
        aggregator.setRoundData(1, 1e8, block.timestamp + 1, block.timestamp + 1, 1);
        vm.expectRevert(OracleHarness.StaleOracleAnswer.selector);
        harness.getExchangeRate();
    }

    function test_RevertWhen_UpdatedAtZero() public {
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        harness.disableBand();
        aggregator.setRoundData(1, 1e8, block.timestamp, 0, 1);
        vm.expectRevert(OracleHarness.StaleOracleAnswer.selector);
        harness.getExchangeRate();
    }

    function test_SuccessWhen_FreshAndInBand() public {
        sequencer.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        harness.setBand(5e7, 2e8);
        aggregator.setRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
        uint256 rate = harness.getExchangeRate();
        assertEq(rate, 1e18);
        // SSR path within deviation
        rateProvider.setRate(1e27);
        psm.setPreviewRate(1e18);
        uint256 ssr = harness.getSSRWithDeviationGuard();
        assertEq(ssr, 1e18);
    }
}
