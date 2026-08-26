// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {RouterMockSY, RouterMockUAsset, RouterMockLauncher, RouterMockERC20} from "./mocks/RouterMocks.sol";

/**
 * @title RouterEndToEndConservationUpgradeableTest
 * @notice End-to-end token conservation loops through the full user path stack.
 * @dev Existing router tests cover steps in isolation (mint+redeem roundtrip, single stake). These
 *      tests close the full loop the invariant design (05-invariants.md §I6 gap D) calls for:
 *      token -> SY -> locked position / wrap pool -> redemption -> SY -> token, asserting the user's
 *      token balance is conserved (identity deposit rate => exact round trip), every intermediate
 *      contract keeps zero residual balances/allowances, and the uAsset mint-cap headroom is
 *      restored once the position is redeemed. A cap-revocation case pins atomicity: a blocked
 *      stake leaves all three ledgers untouched, and an already-open position stays redeemable
 *      because repay is not cap-gated.
 */
contract RouterEndToEndConservationUpgradeableTest is Test {
    RouterMockERC20 internal token;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunRouter internal router;

    address internal owner = makeAddr("owner");
    address internal revenuePool = makeAddr("revenuePool");
    address internal user = makeAddr("user");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant MINT_CAP = 1_000_000e18;

    function setUp() external {
        token = new RouterMockERC20("Mock Token", "mTKN");
        sy = new RouterMockSY(address(token));
        uAsset = new RouterMockUAsset();
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );
        router = new OutrunRouter(owner, address(new RouterMockLauncher(address(uAsset))));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));
        // The test contract deployed the mock uAsset, so it holds its owner-only admin seat.
        uAsset.setMintingCap(address(position), MINT_CAP);

        token.mint(user, 1e24);
        token.mint(keeper, 1e24);
    }

    /// @notice Full locked loop: token -> stakeFromToken -> warp -> SP.redeem(SY out) ->
    ///      redeemSyToToken -> token. The user ends exactly where they started and no contract
    ///      keeps any residual balance or allowance.
    function testFuzz_LockedStakeFullLoopConservesTokens(uint96 amount, uint16 lockupDays) external {
        amount = uint96(bound(amount, 1e18, 1e22));
        lockupDays = uint16(bound(lockupDays, 0, 365 * 5));

        vm.startPrank(user);
        token.approve(address(router), amount);
        (uint256 positionId, uint256 mintedUAsset) = router.stakeFromToken(
            address(position),
            address(token),
            amount,
            IOutrunRouter.StakeParam({
                lockupDays: lockupDays, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: user
            })
        );
        // Identity deposit rate: minted uAsset mirrors the minted SY mirrors the token amount.
        assertEq(mintedUAsset, amount, "minted uAsset does not mirror the token amount");

        vm.warp(block.timestamp + uint256(lockupDays) * 1 days + 1);
        // F-018 prerequisite: the owner must approve the position before repay burns their uAsset.
        uAsset.approve(address(position), mintedUAsset);
        uint256 amountSyOut = _syStakedOf(positionId);
        (, uint256 redeemedSy) = position.redeem(positionId, amountSyOut, user, address(sy), 0);
        assertEq(redeemedSy, amount, "position redeem did not return the staked SY");

        sy.approve(address(router), redeemedSy);
        uint256 tokensBack = router.redeemSyToToken(address(sy), user, address(token), redeemedSy, 0);
        vm.stopPrank();

        assertEq(tokensBack, amount, "SY redemption did not return the tokens 1:1");
        assertEq(token.balanceOf(user), 1e24, "user token balance changed across the loop");
        _assertNoResidualsAnywhere();
        // Mint-cap headroom is restored once the position debt was repaid.
        assertEq(uAsset.checkMintableAmount(address(position)), MINT_CAP, "mint cap headroom not restored");
    }

    /// @notice Wrap loop: token -> wrapStakeFromToken -> keeper keepWrapRedeem -> redeemSyToToken.
    /// @dev The keeper funds its own uAsset by wrap-staking first, mirroring the operational setup
    ///      where the keeper holds uAsset acquired on-chain.
    function testFuzz_WrapLoopConservesTokens(uint96 amount) external {
        amount = uint96(bound(amount, 1e18, 1e22));

        // Keeper self-funding: one wrap stake provides the uAsset the later keepWrapRedeem burns.
        vm.startPrank(keeper);
        token.approve(address(router), amount);
        router.wrapStakeFromToken(address(position), address(token), amount, 0, keeper, 0);
        vm.stopPrank();
        uint256 keeperAmount = amount;

        vm.startPrank(user);
        token.approve(address(router), amount);
        uint256 mintedUAsset = router.wrapStakeFromToken(address(position), address(token), amount, 0, user, 0);
        vm.stopPrank();

        vm.startPrank(keeper);
        uAsset.approve(address(position), mintedUAsset);
        uint256 syOut = position.keepWrapRedeem(mintedUAsset, user);
        vm.stopPrank();

        assertEq(syOut, amount, "keepWrapRedeem did not release the wrap-staked SY at face value");

        vm.startPrank(user);
        sy.approve(address(router), syOut);
        uint256 tokensBack = router.redeemSyToToken(address(sy), user, address(token), syOut, 0);
        vm.stopPrank();

        assertEq(tokensBack, amount, "SY redemption did not return the tokens 1:1");
        assertEq(token.balanceOf(user), 1e24, "user token balance changed across the wrap loop");
        // The keeper's self-funding wrap stake stays in the shared pool by design: the position's
        // only residual SY must be exactly that amount (the user's leg was fully redeemed).
        assertEq(sy.balanceOf(address(position)), keeperAmount, "unexpected residual SY in position");
        assertEq(token.balanceOf(address(router)), 0, "router kept residual tokens");
        assertEq(sy.balanceOf(address(router)), 0, "router kept residual SY");
        assertEq(uAsset.balanceOf(address(router)), 0, "router kept residual uAsset");
        assertEq(token.allowance(address(router), address(sy)), 0, "router kept token allowance to SY");
        assertEq(sy.allowance(address(router), address(position)), 0, "router kept SY allowance to SP");
    }

    /// @notice Revoking the mint cap blocks new stakes atomically: the revert leaves the position,
    ///      wrap, and uAsset minter ledgers untouched, and the already-open position stays
    ///      redeemable because repay is not cap-gated.
    function test_StakeAfterCapRevokeRevertsAndLedgersStayUntouched() external {
        vm.startPrank(user);
        token.approve(address(router), 1e18);
        (uint256 positionId,) = router.stakeFromToken(
            address(position),
            address(token),
            1e18,
            IOutrunRouter.StakeParam({lockupDays: 1, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: user})
        );
        vm.stopPrank();

        uint256 syTotalBefore = position.syTotalStaking();
        uint256 syWrapBefore = position.syWrapStaking();
        uAsset.revokeMinter(address(position));

        vm.startPrank(user);
        token.approve(address(router), 1e18);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        router.stakeFromToken(
            address(position),
            address(token),
            1e18,
            IOutrunRouter.StakeParam({lockupDays: 1, minSyOut: 0, minUAssetMinted: 0, owner: user, receiver: user})
        );
        vm.stopPrank();

        assertEq(position.syTotalStaking(), syTotalBefore, "blocked stake moved syTotalStaking");
        assertEq(position.syWrapStaking(), syWrapBefore, "blocked stake moved syWrapStaking");
        (address storedOwner,,,) = _positionTuple(positionId);
        assertEq(storedOwner, user, "existing position disturbed by the blocked stake");

        // The open position still redeems: repay reduces minter debt without needing cap headroom.
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(user);
        uAsset.approve(address(position), 1e18);
        position.redeem(positionId, _syStakedOf(positionId), user, address(sy), 0);
        vm.stopPrank();
        assertEq(sy.balanceOf(user), 1e18, "open position no longer redeemable after cap revoke");
    }

    /// @dev Reads the stored staked-SY amount for a position.
    function _syStakedOf(uint256 positionId) internal view returns (uint256 syStaked) {
        (, syStaked,,) = _positionTuple(positionId);
    }

    /// @dev Positions getter tuple: owner, syStaked, UAssetMinted, deadline.
    function _positionTuple(uint256 positionId) internal view returns (address, uint256, uint256, uint128) {
        return position.positions(positionId);
    }

    /// @dev Asserts the router, SY contract, and position hold no residual token/SY/uAsset balances
    ///      and no lingering allowances between the loop's contracts.
    function _assertNoResidualsAnywhere() internal view {
        assertEq(token.balanceOf(address(router)), 0, "router kept residual tokens");
        assertEq(sy.balanceOf(address(router)), 0, "router kept residual SY");
        assertEq(uAsset.balanceOf(address(router)), 0, "router kept residual uAsset");
        assertEq(token.allowance(address(router), address(sy)), 0, "router kept token allowance to SY");
        assertEq(sy.allowance(address(router), address(position)), 0, "router kept SY allowance to SP");
        assertEq(uAsset.allowance(address(router), address(position)), 0, "router kept uAsset allowance to SP");
        assertEq(sy.balanceOf(address(position)), 0, "position kept residual SY after full redemption");
    }
}
