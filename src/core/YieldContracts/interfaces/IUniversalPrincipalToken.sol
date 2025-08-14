// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IBurnable } from "../../libraries/IBurnable.sol";

 /**
  * @title Outrun omnichain universal principal token interface
  */
interface IUniversalPrincipalToken is IBurnable {
	struct MintingStatus {
		uint256 mintingCap;
		uint256 amountInMinted;
	}

	function checkMintableAmount(address minter) external view returns (uint256 amountInMintable);

	function grantMintingCap(address minter, uint256 mintingCap) external;

	function mint(address receiver, uint256 amount) external;
	

	event MintUPT(address indexed SP, address receiver, uint256 amount);

	error PermissionDenied();
}