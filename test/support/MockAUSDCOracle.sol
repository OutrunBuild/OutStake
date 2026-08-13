// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockExchangeRateOracle} from "./MockExchangeRateOracle.sol";

/**
 * @dev Mock aUSDC Oracle
 */
contract MockAUSDCOracle is MockExchangeRateOracle {
    // DECIMALS is the normalized output scale (the fixed 1e18 convention SY accounting requires),
    // NOT aUSDC's real on-chain 6 decimals. RAW_DECIMALS is the native precision of the simulated feed.
    uint8 public constant DECIMALS = 18;
    uint8 public constant RAW_DECIMALS = 6;

    // Seed is 1.0 raw unit: 1000000 * 1e18 / 1e6 == 1e18, so getExchangeRate() stays constant 1e18.
    constructor(address _owner) MockExchangeRateOracle(_owner, 1000000) {}

    function _decimals() internal pure override returns (uint8) {
        return DECIMALS;
    }

    function _rawDecimals() internal pure override returns (uint8) {
        return RAW_DECIMALS;
    }
}
