// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

abstract contract MockExchangeRateOracle is Ownable {
    error InvalidOracleAnswer();

    int256 public latestAnswer;

    constructor(address _owner, int256 _latestAnswer) Ownable(_owner) {
        latestAnswer = _latestAnswer;
    }

    function getExchangeRate() external view returns (uint256) {
        if (latestAnswer <= 0) revert InvalidOracleAnswer();
        // latestAnswer is checked to be strictly positive before converting to uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(latestAnswer) * 10 ** _decimals()) / 10 ** _rawDecimals();
    }

    function setLatestAnswer(int256 _latestAnswer) external onlyOwner {
        latestAnswer = _latestAnswer;
    }

    function _decimals() internal pure virtual returns (uint8);

    function _rawDecimals() internal pure virtual returns (uint8);
}
