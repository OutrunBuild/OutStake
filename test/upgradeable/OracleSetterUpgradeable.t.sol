// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunL2WstETHSYUpgradeable} from "../../src/yield/adapters/lido/OutrunL2WstETHSYUpgradeable.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {OracleSetterMockToken, OracleSetterMockOracle, RevertingOracle} from "./mocks/OracleSetterMocks.sol";

interface IOracleBackedSYUpgradeable {
    function exchangeRateOracle() external view returns (address);
    function setExchangeRateOracle(address newOracle) external;
    function exchangeRate() external view returns (uint256);
}

contract OracleSetterUpgradeableTest is Test {
    event SetExchangeRateOracle(address indexed oldOracle, address indexed newOracle);

    address internal owner = address(0xA11CE);
    address internal nonOwner = address(0xB0B);

    OracleSetterMockToken internal token;
    OracleSetterMockOracle internal oracle;

    function setUp() external {
        token = new OracleSetterMockToken("Yield Token", "YBT");
        oracle = new OracleSetterMockOracle(1.1e18);
    }

    function testL2StakedTokenOwnerCanSetExchangeRateOracle() external {
        IOracleBackedSYUpgradeable sy = _deployL2Staked();
        OracleSetterMockOracle newOracle = new OracleSetterMockOracle(1.2e18);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit SetExchangeRateOracle(address(oracle), address(newOracle));
        sy.setExchangeRateOracle(address(newOracle));

        assertEq(sy.exchangeRateOracle(), address(newOracle));
    }

    function testL2WstEthOwnerCanSetExchangeRateOracle() external {
        IOracleBackedSYUpgradeable sy = _deployL2WstETH();
        OracleSetterMockOracle newOracle = new OracleSetterMockOracle(1.2e18);

        vm.prank(owner);
        sy.setExchangeRateOracle(address(newOracle));

        assertEq(sy.exchangeRateOracle(), address(newOracle));
    }

    function testNonOwnerCannotSetExchangeRateOracle() external {
        IOracleBackedSYUpgradeable sy = _deployL2Staked();
        OracleSetterMockOracle newOracle = new OracleSetterMockOracle(1.2e18);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        sy.setExchangeRateOracle(address(newOracle));
    }

    function testZeroExchangeRateOracleReverts() external {
        IOracleBackedSYUpgradeable sy = _deployL2Staked();
        vm.prank(owner);
        vm.expectRevert(IStandardizedYield.SYZeroAddress.selector);
        sy.setExchangeRateOracle(address(0));
    }

    function testExchangeRateReflectsUpdatedOracle() external {
        IOracleBackedSYUpgradeable sy = _deployL2Staked();
        assertEq(sy.exchangeRate(), 1.1e18);

        OracleSetterMockOracle newOracle = new OracleSetterMockOracle(1.7e18);
        vm.prank(owner);
        sy.setExchangeRateOracle(address(newOracle));

        assertEq(sy.exchangeRate(), 1.7e18);
    }

    function testSetterDoesNotCallOracleDuringUpdate() external {
        IOracleBackedSYUpgradeable sy = _deployL2Staked();
        RevertingOracle newOracle = new RevertingOracle();

        vm.prank(owner);
        sy.setExchangeRateOracle(address(newOracle));

        assertEq(sy.exchangeRateOracle(), address(newOracle));
        vm.expectRevert("ORACLE_DOWN");
        sy.exchangeRate();
    }

    function _deployL2Staked() internal returns (IOracleBackedSYUpgradeable) {
        OutrunL2StakedTokenSYUpgradeable implementation = new OutrunL2StakedTokenSYUpgradeable();
        return IOracleBackedSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(implementation),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY Generic", "SYG", owner, address(token), address(oracle), address(token), 18)
                    )
                ))
        );
    }

    function _deployL2WstETH() internal returns (IOracleBackedSYUpgradeable) {
        OutrunL2WstETHSYUpgradeable implementation = new OutrunL2WstETHSYUpgradeable();
        return IOracleBackedSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(implementation),
                    abi.encodeCall(
                        OutrunL2WstETHSYUpgradeable.initialize,
                        (owner, address(token), address(oracle), address(token), 18)
                    )
                ))
        );
    }
}

/// @dev Minimal read surface shared by every oracle source the swap sequence can select: the
/// fixed-rate mocks and the reverting mock all expose exactly this.
interface IOracleLike {
    function getExchangeRate() external view returns (uint256);
}

/// @title Invariant handler swapping the SY's exchange-rate oracle source
/// @notice Deploys an L2 staked SY with four candidate oracles (three fixed-rate mocks plus a
///     reverting one) and exposes a single swapOracle entry point, so the fuzzer drives arbitrary
///     source-swap sequences while the invariant checks that the SY always mirrors the current
///     oracle.
contract OracleSourceSwapHandler is Test {
    address internal owner = address(0xA11CE);

    IOracleBackedSYUpgradeable public sy;
    address[] public oracles;

    constructor() {
        OracleSetterMockToken token = new OracleSetterMockToken("Yield Token", "YBT");
        OracleSetterMockOracle oracleA = new OracleSetterMockOracle(1.1e18);
        OracleSetterMockOracle oracleB = new OracleSetterMockOracle(1.7e18);
        OracleSetterMockOracle oracleC = new OracleSetterMockOracle(2.3e18);
        RevertingOracle revertingOracle = new RevertingOracle();

        oracles.push(address(oracleA));
        oracles.push(address(oracleB));
        oracles.push(address(oracleC));
        oracles.push(address(revertingOracle));

        // Same deployment shape as OracleSetterUpgradeableTest._deployL2Staked, with the first
        // fixed-rate oracle as the initial source.
        OutrunL2StakedTokenSYUpgradeable implementation = new OutrunL2StakedTokenSYUpgradeable();
        sy = IOracleBackedSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(implementation),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY Generic", "SYG", owner, address(token), address(oracleA), address(token), 18)
                    )
                ))
        );
    }

    /// @notice Swaps the SY's oracle source to the candidate selected by the seed. The setter is
    ///     owner-only on the SY side, so the handler pranks the owner.
    function swapOracle(uint256 indexSeed) external {
        uint256 index = indexSeed % oracles.length;
        vm.prank(owner);
        sy.setExchangeRateOracle(oracles[index]);
    }
}

/// @title Invariant test: the SY exchange rate always mirrors the current oracle source [OR-3b]
/// @notice After any sequence of source swaps the SY must report exactly what its currently
///     configured oracle reports — no caching, no blending, no stale value from a previous
///     source. The reverting oracle participates in the sequence, so propagation (the SY
///     reverting when its current source reverts) is part of the property, not an error.
contract OracleSourceSwapSequenceTest is StdInvariant, Test {
    OracleSourceSwapHandler internal handler;

    function setUp() external {
        handler = new OracleSourceSwapHandler();
        targetContract(address(handler));
    }

    function invariant_rateAlwaysMirrorsCurrentOracle() public view {
        IOracleBackedSYUpgradeable sy = handler.sy();
        address current = sy.exchangeRateOracle();

        // vm.expectRevert is unusable inside invariants (they run as plain calls), so classify
        // outcomes with nested try/catch instead.
        try IStandardizedYield(address(sy)).exchangeRate() returns (uint256 got) {
            try IOracleLike(current).getExchangeRate() returns (uint256 expected) {
                assertEq(got, expected, "SY rate does not mirror the current oracle (cache/blending leak)");
            } catch {
                revert("SY returned a rate while its current oracle reverts");
            }
        } catch {
            try IOracleLike(current).getExchangeRate() returns (uint256) {
                revert("SY reverted while its current oracle returned a value");
            } catch {} // both revert: the SY propagates its current oracle's failure correctly
        }
    }
}
