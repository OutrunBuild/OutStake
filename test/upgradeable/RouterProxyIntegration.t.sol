// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {PositionStackTestBase} from "./helpers/PositionStackTestBase.sol";
import {EmptyMockLauncher} from "./mocks/EmptyMockLauncher.sol";
import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";

contract RouterProxyIntegrationTest is PositionStackTestBase {
    uint256 internal constant VERSE_ID = 42;

    OutrunRouter internal router;
    // SP-side genesis launcher: path B is a thin forward into `SP.stakeForGenesis`, whose atomic
    // hand-off and consumption assertion live inside the SP.
    MockGenesisLauncher internal genesisLauncher;

    function setUp() external {
        _deployPositionStack();
        router = new OutrunRouter(owner, address(new EmptyMockLauncher()));
        genesisLauncher = new MockGenesisLauncher(address(uAsset));
        vm.prank(owner);
        position.setGenesisLauncher(address(genesisLauncher));
        vm.prank(owner);
        router.setMemeverseLauncher(address(genesisLauncher));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));
        vm.prank(owner);
        sy.setTrustedRouter(address(router));
    }

    function testRouterRedeemSyToTokenUsesProxyBackedContracts() external {
        uint256 prefund = 1e18;
        uint256 amountInSY = 10e18;
        address receiver = address(0xCAFE);
        _prepareRedeem(amountInSY, prefund);

        vm.prank(user);
        uint256 amountOut = router.redeemSyToToken(address(sy), receiver, address(token), amountInSY, amountInSY);

        assertEq(amountOut, amountInSY);
        assertEq(token.balanceOf(receiver), amountInSY);
        assertEq(sy.balanceOf(user), 0);
        assertEq(sy.balanceOf(address(sy)), prefund);
        assertEq(token.balanceOf(address(sy)), prefund);
        assertEq(sy.allowance(user, address(router)), 0);
    }

    /// @notice The mint entry always funds the deposit from the caller: even when the router already
    ///         holds a same-token prefund, the caller is debited by exactly `amountInput` and the
    ///         router's pre-existing balance stays untouched.
    function testRouterMintSYFromTokenPullsCallerFundsAndKeepsRouterPrefund() external {
        uint256 prefund = 20e18;
        uint256 amountInput = 30e18;
        address receiver = address(0xBEEF);
        uint256 callerBefore = token.balanceOf(user);

        token.mint(address(router), prefund);
        vm.startPrank(user);
        token.approve(address(router), amountInput);
        uint256 syOut = router.mintSYFromToken(address(sy), address(token), receiver, amountInput, amountInput);
        vm.stopPrank();

        assertEq(syOut, amountInput, "identity deposit rate mints 1:1 SY");
        assertEq(token.balanceOf(user), callerBefore - amountInput, "caller debited exactly amountInput");
        assertEq(token.balanceOf(address(router)), prefund, "router prefund persists untouched");
        assertEq(token.balanceOf(address(sy)), amountInput, "SY received exactly the pulled deposit");
        assertEq(sy.balanceOf(receiver), amountInput, "SY shares delivered to the receiver");
    }

    function _prepareRedeem(uint256 amountInSY, uint256 prefund) internal {
        token.mint(address(this), prefund);
        token.approve(address(sy), prefund);
        sy.deposit(address(sy), address(token), prefund, prefund);

        vm.startPrank(user);
        token.approve(address(sy), amountInSY);
        sy.deposit(user, address(token), amountInSY, amountInSY);
        sy.approve(address(router), amountInSY);
        vm.stopPrank();
    }

    /// @notice Deposits `amount` token 1:1 into SY for `user` and approves both the router and
    ///         the SP, so the same SY balance can fund either the router entry or a direct call.
    function _mintSyForUser(uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(sy), amount);
        sy.deposit(user, address(token), amount, amount);
        sy.approve(address(router), amount);
        sy.approve(address(position), amount);
        vm.stopPrank();
    }

    /// @notice The SY-funded router entry is a thin forward over the SP-native gate: with the same
    ///         inputs it produces the same position fields (owner, collateral, principal) and the
    ///         same launcher receipt as a direct `SP.stakeForGenesis` call, and the router never
    ///         holds uAsset on the path. Minting is at value parity (no LTV scaling, no multiplier).
    function testRouterGenesisBySYEqualsDirectSPStakeForGenesis() external {
        uint256 amountInSY = 10e18;
        uint256 expectedMinted = 10e18;
        _mintSyForUser(2 * amountInSY);

        vm.prank(user);
        router.genesisBySY(address(position), amountInSY, VERSE_ID, user, expectedMinted);
        // The router entry returns nothing; ids are monotonic, so the opened id is the counter.
        uint256 routerPositionId = position.idCounter();
        vm.prank(user);
        uint256 directPositionId = position.stakeForGenesis(amountInSY, user, VERSE_ID, expectedMinted);

        (address routerOwner, uint256 routerSyStaked, uint256 routerPrincipal,,) = position.positions(routerPositionId);
        (address directOwner, uint256 directSyStaked, uint256 directPrincipal,,) = position.positions(directPositionId);
        assertEq(routerOwner, directOwner, "same position owner");
        assertEq(routerSyStaked, directSyStaked, "same SY collateral");
        assertEq(routerPrincipal, directPrincipal, "same principal debt");
        assertEq(directPrincipal, expectedMinted, "minted at value parity");

        // Same launcher receipt per path: the mock holds exactly two mints and the router never
        // held any uAsset (it only pulled and forwarded SY).
        assertEq(uAsset.balanceOf(address(genesisLauncher)), 2 * expectedMinted, "launcher consumed one mint per path");
        (uint256 lastVerseId, uint128 lastAmount, address lastUser) = genesisLauncher.snapshot();
        assertEq(lastVerseId, VERSE_ID, "verseId forwarded unchanged");
        assertEq(lastAmount, uint128(expectedMinted), "launcher received uint128(minted)");
        assertEq(lastUser, user, "genesis user credited");
        assertEq(uAsset.balanceOf(address(router)), 0, "router held no uAsset on path B");
        assertEq(uAsset.balanceOf(address(position)), 0, "SP balance conserved by the physical gate");
    }

    /// @notice The token-denominated router entry forwards into the same SP-native gate: the same
    ///         token input produces the same position fields and launcher receipt as a direct
    ///         `SP.stakeForGenesis` call funded by an identical SY deposit.
    function testRouterGenesisByTokenMatchesDirectSPStakeForGenesis() external {
        uint256 tokenAmount = 10e18;
        uint256 expectedMinted = 10e18;
        _mintSyForUser(tokenAmount); // funds the direct leg (identity 1:1 deposit rate)

        vm.startPrank(user);
        token.approve(address(router), tokenAmount);
        // The router itself is the SY deposit's caller and receiver on this path (it pulls the
        // token and forwards the minted SY to the SP); pin the full event payload.
        vm.expectEmit(true, true, true, true, address(sy));
        emit IStandardizedYield.Deposit(address(router), address(router), address(token), tokenAmount, tokenAmount);
        router.genesisByToken(
            address(position), address(token), tokenAmount, tokenAmount, VERSE_ID, user, expectedMinted
        );
        vm.stopPrank();
        uint256 routerPositionId = position.idCounter();
        vm.prank(user);
        uint256 directPositionId = position.stakeForGenesis(tokenAmount, user, VERSE_ID, expectedMinted);

        (address routerOwner, uint256 routerSyStaked, uint256 routerPrincipal,,) = position.positions(routerPositionId);
        (address directOwner, uint256 directSyStaked, uint256 directPrincipal,,) = position.positions(directPositionId);
        assertEq(routerOwner, directOwner, "same position owner");
        assertEq(routerSyStaked, directSyStaked, "same SY collateral");
        assertEq(routerPrincipal, directPrincipal, "same principal debt");
        assertEq(directPrincipal, expectedMinted, "minted at value parity");

        assertEq(uAsset.balanceOf(address(genesisLauncher)), 2 * expectedMinted, "launcher consumed one mint per path");
        assertEq(uAsset.balanceOf(address(router)), 0, "router held no uAsset on path B");
        assertEq(uAsset.balanceOf(address(position)), 0, "SP balance conserved by the physical gate");
    }

    /// @notice Composability: an EOA bypasses the router entirely, deposits token into SY, and
    ///         calls `SP.stakeForGenesis` directly — the gate is SP-native and the router
    ///         is a convenience layer, not a required path.
    function testEOACallsSPStakeForGenesisDirectlyBypassingRouter() external {
        uint256 amountInSY = 10e18;
        uint256 expectedMinted = 10e18;
        _mintSyForUser(amountInSY);

        vm.prank(user);
        uint256 positionId = position.stakeForGenesis(amountInSY, user, VERSE_ID, expectedMinted);

        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(positionId);
        assertEq(positionOwner, user, "EOA owns the directly-opened position");
        assertEq(syStaked, amountInSY, "SY collateral recorded");
        assertEq(principalDebt, expectedMinted, "principal debt equals the minted uAsset");

        (, uint128 lastAmount,) = genesisLauncher.snapshot();
        assertEq(lastAmount, uint128(expectedMinted), "launcher received the full mint");
        assertEq(uAsset.balanceOf(address(genesisLauncher)), expectedMinted, "launcher holds the minted amount");
        assertEq(uAsset.balanceOf(address(position)), 0, "SP balance conserved by the physical gate");
        assertEq(uAsset.balanceOf(address(router)), 0, "router was never involved");
    }
}
