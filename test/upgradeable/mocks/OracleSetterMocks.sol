// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract OracleSetterMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract OracleSetterMockOracle {
    uint256 internal rate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function getExchangeRate() external view returns (uint256) {
        return rate;
    }
}

contract RevertingOracle {
    function getExchangeRate() external pure returns (uint256) {
        revert("ORACLE_DOWN");
    }
}
