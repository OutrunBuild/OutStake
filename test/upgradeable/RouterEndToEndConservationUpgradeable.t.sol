// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IUniversalAssets} from "../../src/assets/interfaces/IUniversalAssets.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";
import {RouterMockSY, RouterMockUAsset, RouterMockERC20} from "./mocks/RouterMocks.sol";

/**
 * @title RouterEndToEndConservationUpgradeableTest
 * @notice End-to-end conservation through the genesis gate: token -> mintSYFromToken -> genesisBySY
 *      (value-parity mint consumed by the launcher) -> owner redeem of a directly-opened position,
 *      asserting launcher receipt, minter-ledger symmetry, no residual balances/allowances on the
 *      router, and mint-cap headroom restoration once debt is repaid.
 */
contract RouterEndToEndConservationUpgradeableTest is Test {
    RouterMockERC20 internal token;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunRouter internal router;
    MockGenesisLauncher internal launcher;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal user = makeAddr("user");

    uint256 internal constant MINT_CAP = 1_000_000e18;
    uint256 internal constant VERSE_ID = 42;

    function setUp() external {
        token = new RouterMockERC20("Mock Token", "mTKN");
        sy = new RouterMockSY(address(token));
        uAsset = new RouterMockUAsset();
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        launcher = new MockGenesisLauncher(address(uAsset));
        router = new OutrunRouter(owner, address(launcher));
        vm.prank(owner);
        position.setGenesisLauncher(address(launcher));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));
        // The test contract deployed the mock uAsset, so it holds its owner-only admin seat.
        uAsset.setMintingCap(address(position), MINT_CAP);
        // The test's own record funds repay-leg cover below (mock mint draws on the caller's record).
        uAsset.setMintingCap(address(this), type(uint128).max);

        token.mint(user, 1e24);
        sy.mintShares(user, 1e24);
        vm.startPrank(user);
        token.approve(address(router), type(uint256).max);
        sy.approve(address(router), type(uint256).max);
        sy.approve(address(position), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Full genesis loop: SY -> genesisBySY (launcher consumes the value-parity mint) ->
    ///      launcher receipt equals principal debt, minter ledger tracks it, router keeps nothing.
    function testFuzz_GenesisLoopConservesAndTracksLedger(uint96 amount) external {
        amount = uint96(bound(amount, 1e18, 1e22));

        vm.prank(user);
        router.genesisBySY(address(position), amount, VERSE_ID, user, amount);

        // Identity mock rate: value parity mints 1:1.
        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(1);
        assertEq(positionOwner, user, "genesisUser owns the position");
        assertEq(syStaked, amount, "SP holds the staked SY");
        assertEq(principalDebt, amount, "value-parity debt");
        assertEq(uAsset.balanceOf(address(launcher)), amount, "launcher consumed the full mint");
        (, uint256 amountInMinted) = uAsset.mintingStatusTable(address(position));
        assertEq(amountInMinted, amount, "minter ledger tracks the genesis mint");
        _assertNoResidualsAnywhere();
    }

    /// @notice SY -> token exit stays whole: a directly-opened genesis position redeems through
    ///      redeemSyToToken back to the input token 1:1 on the identity mocks.
    function testFuzz_GenesisThenRedeemLoopConservesTokens(uint96 amount) external {
        amount = uint96(bound(amount, 1e18, 1e22));

        // The user funds the repay leg from the test's minter record (the genesis mint went to
        // the launcher, so the caller holds no uAsset to repay with).
        uAsset.mint(user, amount);
        vm.startPrank(user);
        uint256 syOut = router.mintSYFromToken(address(sy), address(token), user, amount, amount);
        assertEq(syOut, amount, "identity deposit rate mints 1:1 SY");
        router.genesisBySY(address(position), syOut, VERSE_ID, user, syOut);
        uAsset.approve(address(position), amount);
        (,, uint256 syBack) = position.redeem(1, amount, user, address(sy), 0);
        assertEq(syBack, amount, "position redeem did not return the staked SY");

        sy.approve(address(router), syBack);
        uint256 tokensBack = router.redeemSyToToken(address(sy), user, address(token), syBack, 0);
        vm.stopPrank();

        assertEq(tokensBack, amount, "SY redemption did not return the tokens 1:1");
        _assertNoResidualsAnywhere();
        // Mint-cap headroom is restored once the position debt was repaid.
        assertEq(uAsset.checkMintableAmount(address(position)), MINT_CAP, "mint cap headroom not restored");
    }

    /// @notice Revoking the mint cap blocks new genesis opens atomically with the dependency's error.
    function test_RevertWhen_GenesisAfterCapRevoke() external {
        uAsset.revokeMinter(address(position));

        vm.prank(user);
        vm.expectRevert(IUniversalAssets.ReachMintCap.selector);
        router.genesisBySY(address(position), 1e18, VERSE_ID, user, 0);
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
    }
}
