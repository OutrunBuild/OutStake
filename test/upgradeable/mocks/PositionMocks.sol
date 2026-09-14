// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IExchangeRateOracle} from "../../../src/libraries/oracle/interfaces/IExchangeRateOracle.sol";

/// @title PositionMockToken
/// @notice Simple ERC20 with a public mint, used as the underlying yield token in position tests.
/// @dev Decimals model: fixed 18 (no decimals override; OpenZeppelin default).
contract PositionMockToken is ERC20 {
    constructor() ERC20("Yield Token", "YBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title PositionMockOracle
/// @notice Fixed 1:1 exchange rate oracle for position tests.
contract PositionMockOracle is IExchangeRateOracle {
    function getExchangeRate() external pure override returns (uint256) {
        return 1e18;
    }
}

/// @title PositionSettableOracle
/// @notice Exchange rate oracle whose answer the test controls, for scenarios that need the
///         collateral rate to move after deployment (liquidation triggers, pause matrices).
contract PositionSettableOracle is IExchangeRateOracle {
    uint256 public rate = 1e18;

    function setExchangeRate(uint256 newRate) external {
        rate = newRate;
    }

    function getExchangeRate() external view override returns (uint256) {
        return rate;
    }
}
