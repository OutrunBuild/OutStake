// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

 /**
  * @title Outrun yield token interface
  */
interface IYieldToken {
	error ZeroInput();

	error InvalidInput();

	error NonApprovable();

	error NonTransferable();

	error FeeRateOverflow();

	error PermissionDenied();

	error InsufficientYields();


	function initialize(address SY, address POT) external;

	function totalRedeemableYields() external view returns (int256);

	function previewWithdrawYields(address tokenOut, uint256 amountInBurnedYT) external view returns (uint256 amountYieldsOut);

	function accumulateYields() external returns (int256 realTimeYield, int256 increasedYield);

	function withdrawYields(address tokenOut, uint256 amountInBurnedYT) external returns (uint256 amountYieldsOut);
	
	function mint(address account, uint256 amount) external;

	function setRevenuePool(address revenuePool) external;

    function setProtocolFeeRate(uint96 protocolFeeRate) external;


	event SetRevenuePool(address revenuePool);
	
    event SetProtocolFeeRate(uint96 protocolFeeRate);

	event AccumulateYields(int256 totalYields, int256 increasedYields, uint256 protocolFee);

	event WithdrawYields(address indexed account, address indexed tokenOut, uint256 amountYieldsOut);
}