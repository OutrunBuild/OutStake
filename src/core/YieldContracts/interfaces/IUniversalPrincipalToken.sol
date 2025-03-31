// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IBurnable } from "../../libraries/IBurnable.sol";

 /**
  * @title Outrun omnichain universal principal token interface
  */
interface IUniversalPrincipalToken is IBurnable {
	function setAuthorized(address SP, bool authorized) external;

	function mint(address receiver, uint256 amount) external;
	

	event MintUPT(address indexed SP, address receiver, uint256 amount);

	error PermissionDenied();
}