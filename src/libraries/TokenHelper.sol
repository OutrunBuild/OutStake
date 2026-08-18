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
    /// @dev Approval refresh threshold.
    /// Some ERC20 tokens store allowances in 96 bits. When the remaining allowance drops below
    /// half of uint96 max, we refresh it back to max.
    uint256 internal constant LOWER_BOUND_APPROVAL = type(uint96).max / 2; // some tokens use 96 bits for approval

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
    /// @dev Skips the ERC20 call for zero amount transfers.
    function _transferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (amount != 0) token.safeTransferFrom(from, to, amount);
    }

    /// @notice Transfers token out; native via low-level call or ERC20 transfer.
    /// @param token Address of the token to transfer (NATIVE sentinel for ETH/BNB).
    /// @param to Address to receive the tokens.
    /// @param amount Amount of token to transfer.
    /// @dev Skips zero amounts; native transfers revert with `NativeTransferFailed` when the call fails.
    // Shared by SY adapters and the staking position; a single-inheritor Slither run cannot see those callers.
    // slither-disable-next-line dead-code
    function _transferOut(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE) {
            // Native transfers require a low-level call for contract recipients; production callers guard reentrancy.
            // slither-disable-next-line low-level-calls
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Returns this contract's native balance for NATIVE, ERC20 balance otherwise.
    /// @param token Address of the token to query (NATIVE sentinel for ETH/BNB).
    /// @return The token balance held by this contract.
    /// @dev Returns this contract's native balance for the sentinel, otherwise the ERC20 balance.
    // Shared by SY adapters and the staking position; a single-inheritor Slither run cannot see those callers.
    // slither-disable-next-line dead-code
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

    /// @notice Refreshes allowance to max when it falls below the refresh threshold; resets to 0 first
    /// because some tokens reject non-zero-to-non-zero.
    /// @param token Address of the ERC20 token.
    /// @param to Address to approve as spender.
    /// @dev On each invocation, refreshes an ERC20 allowance to max when it is below `LOWER_BOUND_APPROVAL`;
    ///      does not maintain a persistent max-allowance invariant. Native sentinel is ignored.
    // Shared by SY adapters and the staking position; a single-inheritor Slither run cannot see those callers.
    // slither-disable-next-line dead-code
    function _safeApproveInf(address token, address to) internal {
        if (token == NATIVE) return;
        uint256 currentAllowance = IERC20(token).allowance(address(this), to);
        if (currentAllowance < LOWER_BOUND_APPROVAL) {
            // Explicit two-step: resetting to 0 first makes each approve succeed on the first try for
            // tokens that reject non-zero-to-non-zero changes. forceApprove's fallback would also recover,
            // but only after one wasted failed call. Then set to max. When the allowance is already 0 the
            // zero step is skipped — such tokens accept 0-to-max directly.
            if (currentAllowance != 0) {
                _safeApprove(token, to, 0);
            }
            _safeApprove(token, to, type(uint256).max);
        }
    }
}
