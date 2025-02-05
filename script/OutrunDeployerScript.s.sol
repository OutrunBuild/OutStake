// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BaseScript.s.sol";
import { OutrunDeployer } from "../src/external/deployer/OutrunDeployer.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

contract OutrunDeployerScript is BaseScript {
    address internal owner;
    function run() public broadcaster {
        owner = vm.envAddress("OWNER");

        deployOutrunDeployer(0);
    }

    function deployOutrunDeployer(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked(owner, "OutrunDeployer", nonce));
        address outrunDeployerAddr = Create2.deploy(0, salt, abi.encodePacked(type(OutrunDeployer).creationCode, abi.encode(owner)));

        console.log("OutrunDeployer deployed on %s", outrunDeployerAddr);
    }
}