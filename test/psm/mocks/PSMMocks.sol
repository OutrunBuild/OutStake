// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPSM} from "../../../src/psm/interfaces/IPSM.sol";

/**
 * @title PSMMockReserveERC20
 * @notice Plain ERC20 reserve mock with configurable decimals, used as a PSM reserve leg.
 * @dev Models every seam the PSM reserve path depends on: standard OpenZeppelin ERC20 semantics for
 *      transfer/transferFrom/approve/balanceOf plus a decimals() accessor. No caps, fees, or deflation
 *      behavior are modeled, so it is a full mock rather than a partial one.
 *      Decimals model: configurable at construction (decimals_); faucet mint is permissionless test-only.
 */
contract PSMMockReserveERC20 is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    /// @notice Test-only faucet mint.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title NativeRejectingReceiver
 * @notice Fresh contract that rejects every native transfer: no receive function and a
 *         reverting fallback, so any `.call{value: ...}` payout to it fails.
 * @dev Partial mock: models the native-payout failure seam only — every incoming call reverts,
 *      which makes plain value transfers fail. Unmodeled: token receiving, message handling,
 *      and every seam other than rejecting the transfer.
 */
contract NativeRejectingReceiver {
    error NativeRejected();

    fallback() external payable {
        revert NativeRejected();
    }
}

/**
 * @title ReenteringReserveERC20
 * @notice Malicious reserve token whose transfer and transferFrom re-enter the PSM swap
 *         entrypoints before completing the honest transfer.
 * @dev Partial mock: models the reserve-side reentrancy surface only — when armed via `arm()`,
 *      both ERC20 move entrypoints first fire a nested attempt at PSM.mint and PSM.redeem
 *      (each expected to be blocked by the transient reentrancy guard), then perform the plain
 *      ERC20 move. Unmodeled: non-standard ERC20 behavior (feeburn, deflation), approvals with
 *      callback side effects, and any seam other than transfer/transferFrom.
 */
contract ReenteringReserveERC20 is PSMMockReserveERC20 {
    bytes4 internal constant GUARD_SELECTOR = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
    uint256 public constant NO_FAILURE = type(uint256).max;

    IPSM internal psm;

    /// @notice Index of the first nested entry not blocked by the transient guard; NO_FAILURE
    ///         when all were blocked.
    uint256 public firstFailure = NO_FAILURE;

    bool private armed;

    /// @param psm_ PSM instance targeted by the nested swap attempts.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals.
    constructor(address psm_, string memory name_, string memory symbol_, uint8 decimals_)
        PSMMockReserveERC20(name_, symbol_, decimals_)
    {
        psm = IPSM(psm_);
    }

    /// @notice Arms the reentrancy callback; all subsequent transfers attack first, move honestly after.
    function arm() external {
        armed = true;
    }

    /// @notice Test-only re-point of the attacked PSM; breaks the token/instance construction cycle
    ///         (the instance must bind the token, the token must target the instance).
    /// @param psm_ PSM instance targeted by the nested swap attempts.
    function setPsm(address psm_) external {
        psm = IPSM(psm_);
    }

    function _attemptNestedEntries() private {
        // The guard is an outermost modifier on both PSM swap entrypoints, so each nested call
        // must revert with the guard's custom error before any body logic runs; arguments only
        // need valid ABI shape, they are never evaluated.
        address self = address(this);
        bytes[] memory attempts = new bytes[](2);
        attempts[0] = abi.encodeCall(psm.mint, (self, 1e6));
        attempts[1] = abi.encodeCall(psm.redeem, (self, 1e18));
        for (uint256 i = 0; i < attempts.length; ++i) {
            // forge-lint: disable-next-line(unchecked-call)
            (bool ok, bytes memory ret) = address(psm).call(attempts[i]);
            if (ok || ret.length < 4) {
                firstFailure = i;
                return;
            }
            // Casting to bytes4 is safe after the length check: a custom error's selector is
            // exactly the first 4 revert-data bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 selector = bytes4(ret);
            if (selector != GUARD_SELECTOR) {
                firstFailure = i;
                return;
            }
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) _attemptNestedEntries();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) _attemptNestedEntries();
        return super.transferFrom(from, to, amount);
    }
}
