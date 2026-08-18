// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunUniversalAssetsUpgradeable} from "../../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunStakingPositionUpgradeable} from "../../../src/position/OutrunStakingPositionUpgradeable.sol";
import {MockLzEndpoint} from "../mocks/OFTMocks.sol";
import {ProxyTestHelper} from "./ProxyTestHelper.sol";
import {PositionMockToken, PositionMockOracle} from "../mocks/PositionMocks.sol";

/**
 * @title PositionStackTestBase
 * @notice Shared fixture that deploys the real three-module production stack behind proxies:
 *         L2 staked-token SY + universal asset + staking position, identically wired for every
 *         suite exercising the production stack (initialize params, minting-cap grant, user funding).
 * @dev Suites previously duplicated this chain in their own setUp; a parameter change missed in one
 *      copy left the suites silently asserting against diverged stacks. Inherit this base and call
 *      `_deployPositionStack()` from setUp, then append suite-local steps (router deployment, SY
 *      deposit) after it.
 */
contract PositionStackTestBase is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal revenuePool = address(0xFEE);
    address internal keeper = address(0xC0FFEE);

    PositionMockToken internal token;
    OutrunL2StakedTokenSYUpgradeable internal sy;
    OutrunUniversalAssetsUpgradeable internal uAsset;
    OutrunStakingPositionUpgradeable internal position;

    /// @notice Deploys the production stack behind ERC1967 proxies and wires it for staking tests:
    ///         mock token + oracle, SY, uAsset (with a mock LZ endpoint), and the staking position.
    ///         Ends by granting the position an unlimited uAsset minting cap (as `owner`) and
    ///         funding `user` with 100e18 mock tokens.
    function _deployPositionStack() internal {
        token = new PositionMockToken();
        PositionMockOracle oracle = new PositionMockOracle();

        sy = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY Token", "SYT", owner, address(token), address(oracle), address(token), 18)
                    )
                ))
        );

        MockLzEndpoint endpoint = new MockLzEndpoint();
        uAsset = OutrunUniversalAssetsUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunUniversalAssetsUpgradeable(18, address(endpoint))),
                abi.encodeCall(OutrunUniversalAssetsUpgradeable.initialize, ("UAsset", "UAST", owner))
            )
        );

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );

        vm.prank(owner);
        uAsset.setMintingCap(address(position), type(uint256).max);

        token.mint(user, 100e18);
    }
}
