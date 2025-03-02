// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

 /**
  * @title Outrun yield token interface
  */
interface IYieldToken {
	error ZeroInput();

	error PermissionDenied();

	function initialize(address _SY, address _POT) external;
	
	function mint(address _account, uint256 _amount) external;
}