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
    // Ray-only domain (1e27): Aave liquidity-index conversions via AaveAdapterLib only;
    // never use RAY for SY/Position exchangeRate — those are wad (1e18) via SYUtils.ONE.
    uint256 internal constant RAY = 1e27;

    /**
     * @notice Divides two ray, rounding half up to the nearest ray
     * @dev assembly optimized for improved gas savings, see https://twitter.com/transmissions11/status/1451131036377571328
     * @dev Revert data is intentionally empty `revert(0,0)` mirroring Aave's gas-optimized assembly; this is a
     * documented exception to the repository's custom-error observability convention (see
     * `docs/spec/common-foundations.md` ray-domain section). Callers needing a decoded selector may add a
     * caller-side guard such as `if (b == 0) revert ZeroIndex()` before calling.
     * @param a Ray
     * @param b Ray
     * @return c = a raydiv b
     */
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= (type(uint256).max - halfB) / RAY
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Empty revert `revert(0,0)` intentionally mirrors Aave's gas-optimized assembly; documented
            // exception to custom-error convention (see NatSpec and docs/spec/common-foundations.md).
            if or(iszero(b), iszero(iszero(gt(a, div(sub(not(0), div(b, 2)), RAY))))) {
                revert(0, 0)
            }

            c := div(add(mul(a, RAY), div(b, 2)), b)
        }
    }
}
