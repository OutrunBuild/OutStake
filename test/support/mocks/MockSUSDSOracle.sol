// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockExchangeRateOracle} from "./MockExchangeRateOracle.sol";

/**
 * @dev Mock sUSDS Oracle
 */
contract MockSUSDSOracle is MockExchangeRateOracle {
    // DECIMALS is the normalized output scale (the fixed 1e18 convention SY accounting requires),
    // RAW_DECIMALS the native precision of the simulated feed — both 18 here.
    uint8 public constant DECIMALS = 18;
    uint8 public constant RAW_DECIMALS = 18;

    // Seed is 1.0 raw unit: 1e18 * 1e18 / 1e18 == 1e18, so getExchangeRate() stays constant 1e18.
    constructor(address _owner) MockExchangeRateOracle(_owner, 1e18) {}

    function _decimals() internal pure override returns (uint8) {
        return DECIMALS;
    }

    function _rawDecimals() internal pure override returns (uint8) {
        return RAW_DECIMALS;
    }
}
