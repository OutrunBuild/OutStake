// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {OutrunL2StakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {MockToken, MockPSM3, MockRateProvider} from "./mocks/SYAdapterMocks.sol";

/**
 * @title Invariant handler for the Sky L2 sUSDS SY deviation-guard inputs
 * @notice Exposes one bounded knob per guard input: the SSR rate provider value (1e27 scale),
 *      the PSM sUSDS->USDS swap quote (1e18 scale), and the adapter's max deviation bound (bps).
 * @dev The two rate knobs must stay independent. The adapter's initializer binds the PSM's own
 *      rate provider as the SSR source, and MockPSM3.setRate auto-syncs whichever provider is
 *      currently bound to the PSM. setUp therefore rebinds the adapter to a fresh provider via
 *      the owner-only setter after initialize, so later MockPSM3.setRate calls only sync the PSM's
 *      (now unbound) internal provider and move the swap quote alone.
 */
contract SkyL2DeviationGuardHandler is Test {
    OutrunL2StakedUsdsSYUpgradeable public sy;
    MockPSM3 public psm3;
    MockRateProvider public ssr;
    MockToken public sUsds;
    MockToken public usds;

    address public owner;

    constructor(
        OutrunL2StakedUsdsSYUpgradeable _sy,
        MockPSM3 _psm3,
        MockRateProvider _ssr,
        MockToken _sUsds,
        MockToken _usds,
        address _owner
    ) {
        sy = _sy;
        psm3 = _psm3;
        ssr = _ssr;
        sUsds = _sUsds;
        usds = _usds;
        owner = _owner;
    }

    /// @notice Sets the independent SSR rate on the provider the adapter reads (1e27 scale).
    function setSsr(uint256 raw27) external {
        ssr.setRate(bound(raw27, 5e26, 5e27));
    }

    /// @notice Sets the PSM swap quote for sUSDS -> USDS (1e18 scale) without touching the
    ///      SSR source the adapter reads.
    function setPsmQuote(uint256 quote18) external {
        psm3.setRate(address(sUsds), bound(quote18, 5e17, 5e18));
    }

    /// @notice Sets the adapter's max PSM-vs-SSR deviation bound in bps (owner-only setter).
    function setMaxDeviation(uint16 bps) external {
        vm.prank(owner);
        sy.setMaxDeviationBps(uint16(bound(bps, 1, 10000)));
    }

    /// @notice Current SSR rate (1e27 scale) as read by the adapter.
    function ssrRate27() external view returns (uint256) {
        return ssr.rate();
    }

    /// @notice Current PSM quote: USDS out for exactly 1 sUSDS in (1e18 scale).
    function psmQuote() external view returns (uint256) {
        return psm3.previewSwapExactIn(address(sUsds), address(usds), 1e18);
    }
}

/**
 * @title Invariant tests for the Sky L2 sUSDS SY PSM-vs-SSR deviation guard
 * @notice Two-sided property: exchangeRate either returns exactly the SSR-derived USDS-per-sUSDS
 *      rate, or fails closed with RateDeviationExceeded when the PSM quote deviates from SSR by
 *      more than maxDeviationBps. The bound is strict — deviation of exactly maxDeviationBps
 *      still returns the SSR-derived rate.
 * @dev No deposits are ever made, so the SY totalSupply stays zero and the adapter's backing
 *      precondition (resident sUSDS >= outstanding shares) can never trip: the deviation guard
 *      is the only behavior under test.
 */
contract SkyL2DeviationGuardInvariantUpgradeableTest is StdInvariant, Test {
    SkyL2DeviationGuardHandler public handler;
    OutrunL2StakedUsdsSYUpgradeable public sy;
    MockPSM3 public psm3;
    MockRateProvider public ssr;
    MockToken public usdc;
    MockToken public usds;
    MockToken public sUsds;

    address public owner;
    address public user;

    function setUp() external {
        owner = makeAddr("owner");
        user = makeAddr("user");

        usdc = new MockToken("USDC", "USDC", 6);
        usds = new MockToken("USDS", "USDS", 18);
        sUsds = new MockToken("sUSDS", "sUSDS", 18);

        psm3 = new MockPSM3();
        // Seed the share token and a parity quote before initialize binds the PSM's provider.
        psm3.setRate(address(sUsds), 1e18);

        sy = OutrunL2StakedUsdsSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedUsdsSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedUsdsSYUpgradeable.initialize,
                        (owner, address(usdc), address(usds), address(sUsds), address(psm3))
                    )
                ))
        );

        // Rebind the SSR source to a fresh provider so the two rate knobs are independent:
        // MockPSM3.setRate auto-syncs only the provider currently bound to the PSM, which after
        // this call is no longer the one the adapter reads for exchangeRate.
        ssr = new MockRateProvider();
        vm.prank(owner);
        sy.setRateProvider(address(ssr));

        handler = new SkyL2DeviationGuardHandler(sy, psm3, ssr, sUsds, usds, owner);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.setSsr.selector;
        selectors[1] = handler.setPsmQuote.selector;
        selectors[2] = handler.setMaxDeviation.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /**
     * @notice exchangeRate returns the SSR-derived rate exactly, or fails closed beyond the bound.
     * @dev Mirrors the adapter's guard arithmetic test-side (same floor divisions), then checks
     *      both sides: a successful quote equals the SSR-derived rate and only happens at or below
     *      the bound; a revert is exactly RateDeviationExceeded(psmRate, ssrRate, maxBps) and only
     *      happens strictly above the bound. ssrRate >= 5e17 under the knob bounds, never zero.
     */
    function invariant_ExchangeRateFailsClosedOnPsmDeviation() public view {
        uint256 ssrRate = (1e18 * handler.ssrRate27()) / 1e27;
        uint256 psmRate = handler.psmQuote();
        uint256 maxBps = sy.maxDeviationBps();
        uint256 diff = psmRate > ssrRate ? psmRate - ssrRate : ssrRate - psmRate;
        uint256 bps = (diff * 10000) / ssrRate;

        try sy.exchangeRate() returns (uint256 got) {
            assertEq(got, ssrRate, "within bound: exchangeRate must return SSR");
            assertLe(bps, maxBps, "returned a rate while deviation exceeded the bound");
        } catch (bytes memory reason) {
            assertEq(
                keccak256(reason),
                keccak256(
                    abi.encodeWithSelector(
                        OutrunL2StakedUsdsSYUpgradeable.RateDeviationExceeded.selector, psmRate, ssrRate, maxBps
                    )
                ),
                "beyond bound must fail closed with the exact deviation error"
            );
            assertGt(bps, maxBps, "reverted while deviation was within the bound");
        }
    }

    /// @notice Deviation of exactly maxDeviationBps (default 100) is inside the bound: the
    ///      strict `>` comparison must still return the SSR-derived rate.
    function test_DeviationAtExactlyMaxBpsStillReturnsSSR() external {
        ssr.setRate(1e27);
        psm3.setRate(address(sUsds), 1.01e18);

        // diff = 1e16 -> bps = 100, which equals (does not exceed) the default bound.
        assertEq(sy.exchangeRate(), 1e18);
    }

    /// @notice One bps past the bound fails closed, carrying the observed rates and the bound.
    function test_DeviationOneBpsBeyondMaxFailsClosedWithExactArgs() external {
        ssr.setRate(1e27);
        psm3.setRate(address(sUsds), 1.0101e18);

        // diff = 1.01e16 -> bps = 101 > 100: revert with the exact PSM quote, SSR rate, and bound.
        vm.expectRevert(
            abi.encodeWithSelector(OutrunL2StakedUsdsSYUpgradeable.RateDeviationExceeded.selector, 1.0101e18, 1e18, 100)
        );
        sy.exchangeRate();
    }

    /// @notice setRateProvider emits (old, new) provider addresses for governance observability.
    function test_SetRateProviderEmitsOldAndNewProvider() external {
        address newProvider = makeAddr("newProvider");
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit OutrunL2StakedUsdsSYUpgradeable.RateProviderSet(address(ssr), newProvider);
        sy.setRateProvider(newProvider);
    }

    /// @notice setMaxDeviationBps emits (old, new) bounds; old is the raw stored default 100.
    function test_SetMaxDeviationBpsEmitsOldAndNewBound() external {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit OutrunL2StakedUsdsSYUpgradeable.MaxDeviationBpsSet(100, 500);
        sy.setMaxDeviationBps(500);
    }
}
