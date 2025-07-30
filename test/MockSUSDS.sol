// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunERC20 } from "../src/core/common/OutrunERC20.sol";
import { TokenHelper } from "../src/core/libraries/TokenHelper.sol";
import { IMintable } from "./MockUSDC.sol";

interface IMockSUSDS is IMintable {
    function wrap(uint256 amount) external returns (uint256);

    function unwrap(uint256 amount) external returns (uint256);
}

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockSUSDS is IMockSUSDS, OutrunERC20, TokenHelper {
    address immutable MOCK_USDC;

    address public faucet;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _mockUSDC,
        address _faucet
    ) OutrunERC20(_name, _symbol, _decimals) {
        MOCK_USDC = _mockUSDC;
        faucet = _faucet;
    }

    function mint(address account, uint256 amount) external override {
        require(msg.sender == faucet, "PermissionDenied");
        _mint(account, amount);
    }

    function wrap(uint256 amount) external override returns (uint256) {
        _transferIn(MOCK_USDC, msg.sender, amount);
        _mint(msg.sender, amount);
        return amount;
    }

     function unwrap(uint256 amount) external override returns (uint256) {
        _burn(msg.sender, amount);
        _transferOut(MOCK_USDC, msg.sender, amount);
        return amount;
    }
}
