// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title Aave V3 aToken interface
 * @notice Aave's interest-bearing receipt for a supplied reserve; OutrunAaveV3SY holds it as the adapter's
 *      yield-bearing token and measures pool-supply deposits via scaled-balance deltas.
 */
interface IAToken {
    /**
     * @notice Returns the underlying asset tracked by this aToken.
     * @dev OutrunAaveV3SY uses this to bind the adapter's underlying token to the aToken reserve address.
     * @return The underlying ERC20 asset address.
     */
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    /**
     * @notice Returns a user's balance in scaled units.
     * @dev OutrunAaveV3SY consumes this as a before/after balance delta around a pool supply() call to
     * measure the scaled shares minted; it is never combined with pool income data at the call site.
     * This interface does not define the upstream index mechanics.
     * @param user The account to query.
     * @return The scaled balance for `user`.
     */
    function scaledBalanceOf(address user) external view returns (uint256);
}
