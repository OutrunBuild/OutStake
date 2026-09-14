// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutstakeScript} from "../../../script/deploy/OutstakeScript.s.sol";

/// @title Shared base for deploy-script test harnesses that pin the router config
/// @dev OUTRUN_ROUTER is process-global and `vm.setEnv` writes race across concurrently
///      running forge tests, so harnesses inject the router address through the
///      `_routerConfigEnv` seam instead of mutating process env. Without an injection the
///      override falls through to the script's real env read.
abstract contract RouterConfigInjectionHarness is OutstakeScript {
    address internal routerConfigOverride;
    bool internal useRouterConfigOverride;

    /// @dev Injects the router config without touching process env (see `_routerConfigEnv`).
    function setRouterConfigOverride(address router_) external {
        routerConfigOverride = router_;
        useRouterConfigOverride = true;
    }

    function _routerConfigEnv() internal view override returns (bool exists, address router) {
        if (useRouterConfigOverride) return (true, routerConfigOverride);
        return super._routerConfigEnv();
    }
}
