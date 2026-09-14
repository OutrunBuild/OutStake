// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

error NativeAmountMismatch();
error NativeTransferFailed();

/// @title TokenHelper
/// @notice Shared helper for native-token and ERC20 transfers.
/// @dev NATIVE (address(0)) is a sentinel that routes to ETH/BNB handling instead of ERC20 calls.
abstract contract TokenHelper is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Sentinel used to route native token transfers instead of ERC20 calls.
    /// When token == NATIVE (address(0)), the helper treats the operation as a native token
    /// transfer (ETH on Ethereum, BNB on BSC) instead of calling ERC20 methods. This lets a
    /// single code path handle both native and ERC20 tokens.
    address internal constant NATIVE = address(0);

    /// @notice Transfers token from user; native via msg.value or ERC20 via transferFrom.
    /// @param token Address of the token to transfer (NATIVE sentinel for ETH/BNB).
    /// @param from Address to pull the token from.
    /// @param amount Amount of token to transfer.
    /// @dev For native token inputs, `msg.value` must equal `amount`; for ERC20 inputs, it must be zero.
    function _transferIn(address token, address from, uint256 amount) internal {
        if (token == NATIVE) {
            // For native token: msg.value must match the amount exactly — the caller sends ETH/BNB with the transaction.
            if (msg.value != amount) revert NativeAmountMismatch();
        } else {
            // For ERC20: msg.value must be 0 — funds are pulled via safeTransferFrom.
            if (msg.value != 0) revert NativeAmountMismatch();
            if (amount != 0) IERC20(token).safeTransferFrom(from, address(this), amount);
        }
    }

    /// @notice ERC20 transferFrom, skips zero amounts.
    /// @param token The ERC20 token to transfer.
    /// @param from Address to pull tokens from.
    /// @param to Address to transfer tokens to.
    /// @param amount Amount of tokens to transfer.
    function _transferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (amount != 0) token.safeTransferFrom(from, to, amount);
    }

    /// @notice Transfers token out; native via low-level call or ERC20 transfer.
    /// @param token Address of the token to transfer (NATIVE sentinel for ETH/BNB).
    /// @param to Address to receive the tokens.
    /// @param amount Amount of token to transfer.
    /// @dev Skips zero amounts; native transfers revert with `NativeTransferFailed` when the call fails.
    // Shared by SY adapters and the staking position; a single-inheritor Slither run cannot see those callers.
    function _transferOut(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE) {
            // Native transfers require a low-level call for contract recipients; production callers guard reentrancy.
            // Destination `to` is always the caller-designated recipient of its own funds, never an arbitrary sink.
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Returns this contract's native balance for NATIVE, ERC20 balance otherwise.
    /// @param token Address of the token to query (NATIVE sentinel for ETH/BNB).
    /// @return The token balance held by this contract.
    function _selfBalance(address token) internal view returns (uint256) {
        return (token == NATIVE) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice forceApprove to the given spender
    /// @param token Address of the ERC20 token.
    /// @param to Address to approve as spender.
    /// @param value Amount to approve.
    /// @dev Passthrough to SafeERC20.forceApprove. Tokens that reject non-zero-to-non-zero approval
    /// changes (e.g. USDT) are handled by its internal fallback (on failure, reset to 0 and retry),
    /// so callers do not need to pre-zero the allowance.
    function _safeApprove(address token, address to, uint256 value) internal {
        IERC20(token).forceApprove(to, value);
    }
}
