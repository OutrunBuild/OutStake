// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;



 /**
  * @title Outrun omnichain universal principal token interface
  */
interface IOutrunPointsYieldToken {
	function initialize(address SP) external;

	function mint(address receiver, uint256 id, uint256 amount) external;

	error PermissionDenied();
}