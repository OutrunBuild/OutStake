// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import "forge-std/Script.sol";

abstract contract BaseScript is Script {
    uint256 internal privateKey;
    address internal deployer;

    function setUp() public virtual {
        // Dead: MNEMONIC-based key setup removed; key source is PRIVATE_KEY only.
        //mnemonic = vm.envString("MNEMONIC");
        privateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.rememberKey(privateKey);
    }

    // Dead: retired helper kept as reference (unused repo-wide). Delete when no longer needed.
    // function saveContract(string memory network, string memory name, address addr) public {
    //   string memory json1 = "key";
    //   string memory finalJson =  vm.serializeAddress(json1, "address", addr);
    //   string memory dirPath = string.concat(string.concat("output/", network), "/");
    //   vm.writeJson(finalJson, string.concat(dirPath, string.concat(name, ".json")));
    // }

    // Runs the wrapped body inside a broadcast region signed by `deployer` — the EOA
    // derived from PRIVATE_KEY via vm.rememberKey in setUp(). Note deployer is NOT the
    // script contract's own address(this): forge v1.7.1 forbids address(this) reliance in
    // scripts, so the CREATE2 creator role for OutrunDeployer lives in OutstakeScript's
    // canonical factory constant, not the script contract.
    modifier broadcaster() {
        vm.startBroadcast(deployer);
        _;
        vm.stopBroadcast();
    }
}
