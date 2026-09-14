// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {IPSM} from "../../src/psm/interfaces/IPSM.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {MockGenesisLauncher} from "./mocks/LauncherMocks.sol";
import {RouterMockSY, RouterMockERC20, RouterMockUAsset} from "./mocks/RouterMocks.sol";

/**
 * @title OutrunRouterFuzzTest
 * @notice Router fuzz coverage over amount ranges: the CDP-gate genesis path (`genesisBySY`)
 *     mints at value parity (debt equals collateral at the mock rate, SP holds the staked SY,
 *     launcher consumes the full mint), and the PSM-gate genesis path (`genesisByPSM`)
 *     deterministically forwards the fee-adjusted face-value mint in full.
 *     Deterministic edges, registry reverts, native-leg value contracts, and pause behavior live in
 *     the OutrunRouterUpgradeable.t.sol suite; this file only sweeps randomized amounts.
 */
contract OutrunRouterFuzzTest is Test {
    RouterMockERC20 internal underlying;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunPSMUpgradeable internal psm;
    OutrunRouter internal router;
    MockGenesisLauncher internal launcher;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE);
    address internal user = address(0xB0B);

    uint256 internal constant VERSE_ID = 42;

    function setUp() external {
        underlying = new RouterMockERC20("Mock Asset", "mAST");
        sy = new RouterMockSY(address(underlying));
        uAsset = new RouterMockUAsset();
        launcher = new MockGenesisLauncher(address(uAsset));

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        router = new OutrunRouter(owner, address(launcher));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));

        // PSM-gate wiring: this test contract owns the mock uAsset, so it registers the single-reserve
        // PSM as the family's reserve minter; the max stock cap keeps the fuzz range open and fees stay zero.
        psm = OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunPSMUpgradeable()),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize,
                    (address(uAsset), address(underlying), owner, makeAddr("psmFeeRecipient"), type(uint256).max, 0, 0)
                )
            )
        );
        uAsset.setReserveMinter(address(psm), true);
        vm.prank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(psm));

        uAsset.setMintingCap(address(position), type(uint256).max);
        // Path B (CDP gate) is a thin forward into `SP.stakeForGenesis`: wire the same
        // full-consumption mock launcher as the SP's genesis target so parity holds.
        vm.prank(owner);
        position.setGenesisLauncher(address(launcher));

        underlying.mint(user, 1_000_000e18);
        sy.mintShares(user, 1_000_000e18);
        vm.startPrank(user);
        underlying.approve(address(router), type(uint256).max);
        sy.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice The CDP-gate genesis path mints debt at value parity and leaves the SP holding the
    ///         staked SY while the launcher consumes the full mint (identity mock rate).
    function testFuzz_GenesisBySYMintsAtValueParity(uint256 syAmount) external {
        syAmount = bound(syAmount, 2e18, 1000e18);

        vm.prank(user);
        router.genesisBySY(address(position), syAmount, VERSE_ID, user, syAmount);

        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(1);
        assertEq(positionOwner, user, "genesisUser owns the position");
        assertEq(principalDebt, syAmount, "debt must equal collateral at value parity");
        assertEq(uAsset.balanceOf(address(launcher)), syAmount, "launcher consumed the full mint");
        assertEq(syStaked, syAmount, "identity mock rate stakes 1:1");
        assertEq(sy.balanceOf(address(position)), syAmount, "SP holds the staked SY");
        assertEq(sy.balanceOf(address(router)), 0, "router kept residual SY");
    }

    /// @notice The PSM-gate genesis path conserves the reserve and forwards the full deterministic
    ///         mint across input ranges: quoteMint == executed output, the caller pays exactly
    ///         `amountIn`, the PSM holds the reserve, and the launcher receives everything minted.
    function testFuzz_GenesisByPSMForwardsFullDeterministicMint(uint256 amountIn) external {
        // Upper bound stays below the caller's 1e24 fixture balance.
        amountIn = bound(amountIn, 1e6, 1e23);
        uint256 expectedOut = IPSM(address(psm)).quoteMint(amountIn);
        assertEq(expectedOut, amountIn, "zero-fee 18-dec reserve must quote 1:1 face value");
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore - amountIn, "caller did not pay the full reserve");
        assertEq(underlying.balanceOf(address(psm)), amountIn, "PSM holds the taken reserve");
        assertEq(IPSM(address(psm)).netUAssetMinted(), amountIn, "PSM net minted ledger");
        assertEq(uAsset.balanceOf(address(launcher)), amountIn, "launcher holds the full minted uAsset");
        (, uint128 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, uint128(amountIn), "launcher received uint128(minted)");
        assertEq(uAsset.balanceOf(address(router)), 0, "router kept residual uAsset");
        assertEq(uAsset.allowance(address(router), address(launcher)), 0, "launcher allowance not cleared");
        assertEq(underlying.allowance(address(router), address(psm)), 0, "PSM reserve allowance not cleared");
    }
}
