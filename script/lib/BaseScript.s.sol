// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import "forge-std/Script.sol";

abstract contract BaseScript is Script {
    uint256 internal privateKey;
    address internal deployer;

    function setUp() public virtual {
        privateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.rememberKey(privateKey);
    }

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
