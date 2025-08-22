// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunERC20 } from "./OutrunERC20.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/**
 * @dev Implementation of the ERC-3156 Flash loans extension, as defined in
 *      https://eips.ethereum.org/EIPS/eip-3156.
 */
abstract contract OutrunERC20FlashMint is OutrunERC20, IERC3156FlashLender {
    bytes32 private constant RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public constant FLASHLOAN_FEE_RATE = 25;   // 0.25 %.

    /**
     * @dev The loan token is not valid.
     */
    error ERC3156UnsupportedToken(address token);

    /**
     * @dev The requested loan exceeds the max loan value for `token`.
     */
    error ERC3156ExceededMaxLoan(uint256 maxLoan);

    /**
     * @dev The receiver of a flashloan is not a valid {IERC3156FlashBorrower-onFlashLoan} implementer.
     */
    error ERC3156InvalidReceiver(address receiver);

    /**
     * @dev Returns the maximum amount of tokens available for loan.
     * @param token The address of the token that is requested.
     * @return The amount of token that can be loaned.
     */
    function maxFlashLoan(address token) public view virtual returns (uint256) {
        return token == address(this) ? type(uint256).max - totalSupply : 0;
    }

    /**
     * @dev Returns the fee applied when doing flash loans.
     * @param token The token to be flash loaned.
     * @param value The amount of tokens to be loaned.
     * @return The fees applied to the corresponding flash loan.
     */
    function flashFee(address token, uint256 value) public view virtual returns (uint256) {
        if (token != address(this)) {
            revert ERC3156UnsupportedToken(token);
        }
        return value * FLASHLOAN_FEE_RATE / 10000;
    }

    /**
     * @dev Performs a flash loan. New tokens are minted and sent to the `receiver`, who is required to 
     * implement the {IERC3156FlashBorrower} interface. By the end of the flash loan, the receiver is 
     * expected to own value + fee tokens so they can be burned.
     * @param receiver The receiver of the flash loan. Should implement the {IERC3156FlashBorrower-onFlashLoan} interface.
     * @param token The token to be flash loaned. Only `address(this)` is supported.
     * @param value The amount of tokens to be loaned.
     * @param data An arbitrary datafield that is passed to the receiver.
     * @return `true` if the flash loan was successful.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 value,
        bytes calldata data
    ) public virtual returns (bool) {
        uint256 maxLoan = maxFlashLoan(token);
        require(value <= maxLoan, ERC3156ExceededMaxLoan(maxLoan));

        uint256 fee = flashFee(token, value);
        _mint(address(receiver), value);
        require(
            receiver.onFlashLoan(msg.sender, token, value, fee, data) == RETURN_VALUE, 
            ERC3156InvalidReceiver(address(receiver))
        );
        
        _burn(address(receiver), value + fee);
        return true;
    }
}
