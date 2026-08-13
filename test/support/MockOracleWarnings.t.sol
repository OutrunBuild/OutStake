// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {MockAUSDCOracle} from "./MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "./MockSUSDSOracle.sol";
import {OutrunExchangeOracleAdapter} from "../../src/libraries/oracle/OutrunExchangeOracleAdapter.sol";
import {MockAggregator} from "./MockOracleWarningsMocks.sol";

contract MockOracleWarningsTest is Test {
    bytes4 internal constant INVALID_ORACLE_ANSWER_SELECTOR = bytes4(keccak256("InvalidOracleAnswer()"));
    bytes4 internal constant STALE_ORACLE_ANSWER_SELECTOR = bytes4(keccak256("StaleOracleAnswer()"));
    bytes4 internal constant SEQUENCER_DOWN_SELECTOR = bytes4(keccak256("SequencerDown()"));
    bytes4 internal constant SEQUENCER_GRACE_PERIOD_NOT_OVER_SELECTOR =
        bytes4(keccak256("SequencerGracePeriodNotOver()"));

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
}
