// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IOutrunDeployer } from "./IOutrunDeployer.sol";

/**
 * @title Factory for deploying contracts to deterministic addresses via CREATE3
 * @notice Enables deploying contracts using CREATE3. Each deployer (msg.sender) has its own namespace for deployed addresses.
 */
contract OutrunDeployer is IOutrunDeployer, Ownable {
    constructor(address _owner) Ownable(_owner) {
    }

    /// @inheritdoc	IOutrunDeployer
    function deploy(
        bytes32 salt, 
        bytes memory creationCode
    ) external payable override onlyOwner returns (address deployed) {
        // hash salt with the deployer address to give each deployer its own namespace
        salt = keccak256(abi.encodePacked(msg.sender, salt));
        return CREATE3.deploy(salt, creationCode, msg.value);
    }

    /// @inheritdoc	IOutrunDeployer
    function getDeployed(
        address deployer, 
        bytes32 salt
    ) external view override returns (address deployed) {
        // hash salt with the deployer address to give each deployer its own namespace
        salt = keccak256(abi.encodePacked(deployer, salt));
        return CREATE3.getDeployed(salt);
    }
}