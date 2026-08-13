// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    /// @notice Wrap native ETH into WETH.
    /// @dev Wraps msg.value into WETH. Currently called only by fork tests
    ///      (e.g. SYAdaptersFork.t.sol) to mint WETH before interacting with live SY adapters;
    ///      no production contract in src/ calls this.
    function deposit() external payable;

    /// @notice Unwrap WETH into native ETH.
    /// @dev Unwraps WETH into native ETH. Currently has no caller in src/ or test/;
    ///      retained for future wrap/unwrap integrations.
    /// @param wad Amount of WETH to burn and withdraw.
    function withdraw(uint256 wad) external;
}
