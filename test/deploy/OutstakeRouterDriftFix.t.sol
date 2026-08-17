// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {EmptyMockLauncher} from "../upgradeable/mocks/EmptyMockLauncher.sol";

contract OutstakeRouterDriftFixHarness is OutstakeScript {
    function configure(address owner_, address deployer_, address outrunDeployer_) external {
        owner = owner_;
        deployer = deployer_;
        outrunDeployer = outrunDeployer_;
    }

    function setRouterConfig(address outrunRouter_, bool enforceOutrunRouter_, address memeverseLauncher_) external {
        outrunRouter = outrunRouter_;
        enforceOutrunRouter = enforceOutrunRouter_;
        memeverseLauncher = memeverseLauncher_;
    }

    function applyRouterConfig() external {
        _applyRouterConfig();
    }

    function getOutrunRouter() external view returns (address) {
        return outrunRouter;
    }

    function getEnforceOutrunRouter() external view returns (bool) {
        return enforceOutrunRouter;
    }

    function exposedDeployOutrunRouter(uint256 nonce) external {
        _deployOutrunRouter(nonce);
    }
}

contract OutstakeRouterDriftFixTest is Test {
    address internal owner;

    OutstakeRouterDriftFixHarness internal script;
    OutrunDeployer internal outrunDeployer;

    function setUp() external {
        script = new OutstakeRouterDriftFixHarness();
        owner = address(script);
        outrunDeployer = new OutrunDeployer(address(script));
        script.configure(owner, owner, address(outrunDeployer));
    }

    function testDeployOutrunRouterMatchesEnforcedExpectedAddress() external {
        EmptyMockLauncher launcher = new EmptyMockLauncher();
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", uint256(1)));
        address expected = outrunDeployer.getDeployed(address(script), salt);
        script.setRouterConfig(expected, true, address(launcher));

        script.exposedDeployOutrunRouter(1);

        OutrunRouter deployedRouter = OutrunRouter(outrunDeployer.getDeployed(address(script), salt));
        assertEq(address(deployedRouter), expected);
        assertEq(deployedRouter.owner(), owner);
        assertEq(deployedRouter.memeverseLauncher(), address(launcher));
    }

    function testDeployOutrunRouterRevertsWhenEnforcedAddressMismatches() external {
        EmptyMockLauncher launcher = new EmptyMockLauncher();
        bytes32 salt = keccak256(abi.encodePacked("OutrunRouter", uint256(1)));
        script.setRouterConfig(address(0xDEAD), true, address(launcher));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedDeployOutrunRouter(1);

        assertEq(outrunDeployer.getDeployed(address(script), salt).code.length, 0);
    }

    function testApplyRouterConfigUsesEnvWhenPresent() external {
        vm.setEnv("OUTRUN_ROUTER", vm.toString(address(0xABCD)));

        script.applyRouterConfig();

        assertEq(script.getOutrunRouter(), address(0xABCD));
        assertTrue(script.getEnforceOutrunRouter());
    }

    function testApplyRouterConfigDefaultsWhenEnvMissing() external {
        script.applyRouterConfig();

        assertEq(script.getOutrunRouter(), address(0));
        assertFalse(script.getEnforceOutrunRouter());
    }
}
