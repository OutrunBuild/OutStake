// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunERC20 } from "./OutrunERC20.sol";

/**
 * @dev ERC-20 token with dual balance management (transferable and non-transferable balances).
 */
abstract contract OutrunERC20DualBalance is OutrunERC20 {
    mapping(address => uint256) public totalBalanceOf;

    mapping(address => uint256) public nonTransferableBalanceOf;

    function balanceOf(address account) public view override returns (uint256) {
        return totalBalanceOf[account] - nonTransferableBalanceOf[account];
    }

    function _mint(address account, uint256 amount, bool transferable) internal {
        _mint(account, amount);
        if (!transferable) nonTransferableBalanceOf[account] += amount;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        _beforeTokenTransfer(from, to, value);

        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            totalSupply += value;
        } else {
            uint256 fromBalance = balanceOf(from);
            require(fromBalance >= value, ERC20InsufficientBalance(from, fromBalance, value));
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                totalBalanceOf[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                totalBalanceOf[to] += value;
            }
        }

        _afterTokenTransfer(from, to, value);

        emit Transfer(from, to, value);
    }
}
