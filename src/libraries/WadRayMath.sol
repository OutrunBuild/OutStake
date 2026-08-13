// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title WadRayMath library
 * @author Aave
 * @notice Provides ray-scaled (27-decimal) division with half-up rounding and the RAY constant.
 * @dev Trimmed to the subset this repo consumes.
 * @dev rayDiv rounds half up: a quotient fractional part >= 0.5 rounds up (remainder + b / 2 >= b).
 */
library WadRayMath {
    // RAY is a decimal literal because inline assembly cannot reference constants whose values are defined with operations (expressions).
    uint256 internal constant RAY = 1e27;

    /**
     * @notice Divides two ray, rounding half up to the nearest ray
     * @dev assembly optimized for improved gas savings, see https://twitter.com/transmissions11/status/1451131036377571328
     * @param a Ray
     * @param b Ray
     * @return c = a raydiv b
     */
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= (type(uint256).max - halfB) / RAY
        // solhint-disable-next-line no-inline-assembly
        assembly {
            if or(iszero(b), iszero(iszero(gt(a, div(sub(not(0), div(b, 2)), RAY))))) {
                revert(0, 0)
            }

            c := div(add(mul(a, RAY), div(b, 2)), b)
        }
    }
}
