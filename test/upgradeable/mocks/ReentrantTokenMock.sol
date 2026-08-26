// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ReentrantTokenMock
 * @notice Malicious ERC20 mock that reenters a caller-controlled hook from `transferFrom`.
 * @dev Models the transferFrom callback window: after the ERC20 bookkeeping of a successful
 *      `transferFrom` completes, the token calls `hook` exactly once (armed flag is cleared
 *      before the callback so the reentrant call itself cannot recurse into the hook again).
 *      Accounting is honest — balances and allowances follow ERC20 exactly; the only attack
 *      surface is the callback. `arm` selects the address called during the callback window.
 * @dev Partial mock: models only the `transferFrom` post-success callback seam. `transfer`
 *      and `approve` have no callback; fee-on-transfer, rebasing, and boolean-return quirks
 *      are not modeled.
 */
contract ReentrantTokenMock is ERC20 {
    /// @notice Address called (with empty calldata) inside the armed `transferFrom` callback window.
    address public hook;
    /// @notice Whether the next `transferFrom` fires the callback. Cleared before the callback runs.
    bool public armed;

    constructor() ERC20("Reentrant Mock Token", "rMT") {}

    /**
     * @notice Arms the one-shot callback for the next `transferFrom`.
     * @param hook_ Contract called during the callback window; its fallback executes the reentry attempt.
     */
    function arm(address hook_) external {
        hook = hook_;
        armed = true;
    }

    /// @notice Test helper to mint mock tokens to `receiver`.
    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    /**
     * @notice Standard ERC20 transferFrom that fires the armed callback after a successful transfer.
     * @dev Disarms before calling out so the callback cannot chain further hook invocations.
     */
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, value);
        if (armed) {
            armed = false;
            // Low-level call: the hook's own revert must not break the outer flow unless it chooses to.
            // forge-lint: disable-next-line(unchecked-call)
            hook.call("");
        }
        return transferred;
    }
}
