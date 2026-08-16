// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMintable {
    function mint(address account, uint256 amount) external;
}

error OnlyFaucet();

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockUSDC is IMintable, ERC20 {
    uint8 private immutable _mockDecimals;

    address public faucet;

    constructor(string memory _name, string memory _symbol, uint8 decimals_, address _faucet) ERC20(_name, _symbol) {
        _mockDecimals = decimals_;
        faucet = _faucet;
    }

    function decimals() public view override returns (uint8) {
        return _mockDecimals;
    }

    function mint(address account, uint256 amount) external override {
        if (msg.sender != faucet) revert OnlyFaucet();
        _mint(account, amount);
    }
}
