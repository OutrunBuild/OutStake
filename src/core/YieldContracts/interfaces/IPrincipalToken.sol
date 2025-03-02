// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

 /**
  * @title Outrun principal token interface
  */
interface IPrincipalToken {
	error ZeroInput();

	error PermissionDenied();

	function UPT() external view returns (address);

	function UPTConvertiblestatus() external view returns (bool);

	function initialize(address _POT) external;

	function updateConvertibleStatus(address UPT, bool status) external;

	function mint(address account, uint256 amount) external;
	
	function burn(address account, uint256 amount) external;

	event UpdateConvertibleStatus(address indexed UPT, bool status);
}