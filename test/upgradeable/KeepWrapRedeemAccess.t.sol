// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";

/**
 * @title KeepWrapRedeemAccess
 * @notice F-44 closure regression. The public wrap-pool drain (`wrapRedeem`) is sealed; wrap-pool
 *         SY exits only through the keeper-only `keepWrapRedeem` at face value, which reverts
 *         `WrapPoolUndercollateralized` on an undercollateralized pool.
 * @dev The keeper does not mint its own uAsset — it acts as redemption payer, burning uAsset
 *      transferred to it by wrap depositors.
 */
contract KeepWrapRedeemAccess is Test {
    MockERC20 internal underlying;
    MockSY internal sy;
    MockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;

    address internal owner = address(0xA11CE);
    address internal keeper = address(0xC0FFEE);
    address internal revenuePool = address(0xFEE);
    address internal alice = address(0xA11CE1);
    address internal nonKeeper = address(0xBAD);

    function setUp() external {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );

        uAsset.setMintingCap(address(position), type(uint256).max);

        // Alice funds SY and approves the position to pull it on wrap stake.
        sy.mintShares(alice, 1_000e18);
        vm.prank(alice);
        sy.approve(address(position), type(uint256).max);

        // The keeper must approve the position to burn its uAsset on redemption.
        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);
    }

    /// @notice A non-keeper calling keepWrapRedeem is rejected: the public drain is sealed.
    function test_NonKeeperCallReverts() external {
        vm.prank(alice);
        position.wrapStake(100e18, alice);
        assertEq(position.wrapUAssetDebt(), 100e18);

        // Alice hands her wrap-minted uAsset to a non-keeper; they still cannot redeem.
        vm.prank(alice);
        uAsset.transfer(nonKeeper, 100e18);

        vm.prank(nonKeeper);
        uAsset.approve(address(position), 100e18);

        vm.prank(nonKeeper);
        vm.expectRevert(IOutrunStakeManager.PermissionDenied.selector);
        position.keepWrapRedeem(100e18, nonKeeper);
    }

    /// @notice The keeper redeems a healthy wrap pool at face value (rate 1e18, matching 18/18 decimals).
    function test_KeeperRedeemsAtFaceValue() external {
        vm.prank(alice);
        position.wrapStake(100e18, alice);

        // Alice transfers her wrap-minted uAsset to the keeper, who burns it as redemption payer.
        vm.prank(alice);
        uAsset.transfer(keeper, 100e18);

        vm.prank(keeper);
        uint256 out = position.keepWrapRedeem(100e18, keeper);

        // Healthy pool at rate 1e18 with matching 18/18 decimals redeems 1:1 SY for uAsset.
        assertEq(out, 100e18);
        assertEq(position.wrapUAssetDebt(), 0);
        assertEq(sy.balanceOf(keeper), 100e18);
        assertEq(uAsset.balanceOf(keeper), 0);
    }

    /// @notice An undercollateralized wrap pool reverts instead of paying a loss-making redemption.
    function test_UndercollateralizedPoolReverts() external {
        vm.prank(alice);
        uint256 minted = position.wrapStake(100e18, alice);

        // Drop the rate below 1e18: pool 100 SY (now worth 50 uAsset) < debt 100 uAsset face value.
        sy.setExchangeRate(5e17);

        vm.prank(alice);
        uAsset.transfer(keeper, minted);

        vm.prank(keeper);
        vm.expectRevert(IOutrunStakeManager.WrapPoolUndercollateralized.selector);
        position.keepWrapRedeem(minted, keeper);
    }
}
