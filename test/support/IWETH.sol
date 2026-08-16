// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Canonical WETH interface
 * @notice WETH9-style wrapped native token interface. In this repository it is consumed only by fork tests
 *      (test/upgradeable/SYAdaptersFork.t.sol), which use it to mint WETH before interacting with live SY
 *      adapters; no production contract in src/ consumes it.
 */
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
