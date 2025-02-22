// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

 /**
  * @title Outrun omnichain universal principal token interface
  */
interface IUniversalPrincipalToken {
	function setAuthorizedPTs(address PT, bool authorized) external;

	function mintUPTFromPT(address authorizedPT, address receiver, uint256 amountInPT) external;

	function redeemPTFromUPT(address authorizedPT, address receiver, uint256 amountInUPT) external;

	function burn(uint256 amount) external;
	

	event MintUPT(address indexed fromPT, address receiver, uint256 amountInUPT);

	event RedeemPT(address indexed authorizedPT, address receiver, uint256 amountInPT);

	error PermissionDenied();
}