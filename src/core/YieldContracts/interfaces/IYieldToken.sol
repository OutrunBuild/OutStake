// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

 /**
  * @title Outrun yield token interface
  */
interface IYieldToken {
	error ZeroInput();

	error InvalidInput();

	error FeeRateOverflow();

	error PermissionDenied();


	function initialize(address SY, address POT) external;

	function totalRedeemableYields() external view returns (uint256);

	function previewWithdrawYields(uint256 amountInBurnedYT) external view returns (uint256 amountYieldsOut);

	function accumulateYields() external returns (uint256 realTimeYield, int256 increasedYield);

	function withdrawYields(uint256 amountInBurnedYT) external returns (uint256 amountYieldsOut);
	
	function mint(address account, uint256 amount, bool transferable) external;

	function setRevenuePool(address revenuePool) external;

    function setProtocolFeeRate(uint256 protocolFeeRate) external;


	event SetRevenuePool(address revenuePool);
	
    event SetProtocolFeeRate(uint256 protocolFeeRate);

	event AccumulateYields(uint256 totalYields, int256 increasedYields, uint256 protocolFee);

	event WithdrawYields(address indexed account, uint256 amountYieldsOut);
}