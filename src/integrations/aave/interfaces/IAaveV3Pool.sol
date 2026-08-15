// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title Aave V3 Pool interface
 * @notice Aave's lending pool for supplying and withdrawing reserves; OutrunAaveV3SY deposits and redeems the
 *      underlying through it and reads `getReserveNormalizedIncome` as its exchange-rate source.
 */
interface IAaveV3Pool {
    /**
     * @notice Supplies an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
     * - E.g. User supplies 100 USDC and gets in return 100 aUSDC
     * @dev OutrunAaveV3SY approves and calls this when depositing underlying. This interface records the call
     * boundary only; reserve accounting remains external to this repository.
     * @param asset The address of the underlying asset to supply
     * @param amount The amount to be supplied
     * @param onBehalfOf The address that will receive the aTokens, same as msg.sender if the user
     *   wants to receive them on his own wallet, or a different address if the beneficiary of aTokens
     *   is a different wallet
     * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
     *   0 if the action is executed directly by the user, without any middle-man
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /**
     * @notice Withdraws an `amount` of underlying asset from the reserve, burning the equivalent aTokens owned
     * E.g. User has 100 aUSDC, calls withdraw() and receives 100 USDC, burning the 100 aUSDC
     * @dev OutrunAaveV3SY consumes the returned amount as redemption output. Passing `type(uint256).max` requests
     * a full balance withdrawal for the chosen reserve asset.
     * @param asset The address of the underlying asset to withdraw
     * @param amount The underlying amount to be withdrawn
     *   - Send the value type(uint256).max in order to withdraw the whole aToken balance
     * @param to The address that will receive the underlying, same as msg.sender if the user
     *   wants to receive it on his own wallet, or a different address if the beneficiary is a
     *   different wallet
     * @return The final amount withdrawn
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /**
     * @notice Returns the normalized income of the reserve
     * @dev OutrunAaveV3SY consumes this as its local `exchangeRate()` source for the reserve.
     * @param asset The address of the underlying asset of the reserve
     * @return The reserve's normalized income
     */
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}
