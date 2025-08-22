// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev Mock aUSDC Oracle
 */
contract MockAUSDCOracle is Ownable {
    uint8 public constant decimals = 18;
    uint8 public constant rawDecimals = 6;

    int256 public latestAnswer;

    constructor(address _owner) Ownable(_owner) {
        latestAnswer = 1000000;
    }

    function getExchangeRate() external view returns (uint256) {
        return (uint256(latestAnswer) * 10 ** decimals) / 10 ** rawDecimals;
    }

    function setLatestAnswer(int256 _latestAnswer) external onlyOwner {
        latestAnswer = _latestAnswer;
    }
}
