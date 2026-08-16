// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenHelper} from "../../../src/libraries/TokenHelper.sol";
import {IMintable, OnlyFaucet} from "./MockUSDC.sol";

interface IMockSUSDS is IMintable {
    function wrap(uint256 amount) external returns (uint256);

    function unwrap(uint256 amount) external returns (uint256);
}

/**
 * @dev Just For Memeverse Genesis Test
 */
contract MockSUSDS is IMockSUSDS, ERC20, TokenHelper {
    uint8 private immutable _mockDecimals;

    address public immutable MOCK_USDC;

    address public faucet;

    constructor(string memory _name, string memory _symbol, uint8 decimals_, address _mockUSDC, address _faucet)
        ERC20(_name, _symbol)
    {
        _mockDecimals = decimals_;
        MOCK_USDC = _mockUSDC;
        faucet = _faucet;
    }

    function decimals() public view override returns (uint8) {
        return _mockDecimals;
    }

    function mint(address account, uint256 amount) external override {
        if (msg.sender != faucet) revert OnlyFaucet();
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
