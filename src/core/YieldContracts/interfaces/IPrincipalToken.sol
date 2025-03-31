// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IBurnable } from "../../libraries/IBurnable.sol";

 /**
  * @title Outrun principal token interface
  */
interface IPrincipalToken is IBurnable {
	error ZeroInput();

	error PermissionDenied();

	function SP() external view returns (address);

	function initialize(address SP) external;

	function mint(address account, uint256 amount) external;
}