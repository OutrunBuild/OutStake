// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunERC20 } from "../src/core/common/OutrunERC20.sol";

interface IMintable {
    function mint(address account, uint256 amount) external;
}

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockUSDC is IMintable, OutrunERC20 {
    address public faucet;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _faucet
    ) OutrunERC20(_name, _symbol, _decimals) {
        faucet = _faucet;
    }

    function mint(address account, uint256 amount) external override {
        require(msg.sender == faucet, "PermissionDenied");
        _mint(account, amount);
    }
}
