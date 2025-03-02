// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;
 
interface IYieldManager {
	struct RecentAccumulatedInfo {
		uint192 accumulatedYields;
		uint64 latestAccumulateTime;
	}
	
	function totalRedeemableYields() external view returns (uint256);

	function totalAccumulatedYields() external view returns (uint256);

	function previewWithdrawYields(uint256 amountInBurnedYT) external view returns (uint256 amountYieldsOut);

	function accumulateYields() external returns (uint256 increasedYield);

	function withdrawYields(uint256 amountInBurnedYT) external returns (uint256 amountYieldsOut);

	function setRevenuePool(address revenuePool) external;

    function setProtocolFeeRate(uint256 protocolFeeRate) external;

	event SetRevenuePool(address revenuePool);
	
    event SetProtocolFeeRate(uint256 protocolFeeRate);

	event WithdrawYields(address indexed account, uint256 amountYieldsOut);

	event AccumulateYields(uint256 amountInYields, uint256 protocolFee);

	error FeeRateOverflow();

	error InvalidInput();
}