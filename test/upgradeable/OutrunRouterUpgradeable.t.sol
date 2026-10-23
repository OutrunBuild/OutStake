// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {GenesisGateLib} from "../../src/libraries/GenesisGateLib.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {IPSM} from "../../src/psm/interfaces/IPSM.sol";
import {NativeAmountMismatch} from "../../src/libraries/TokenHelper.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {
    MockGenesisLauncher,
    MockGenesisPartialLauncher,
    MockGenesisEmptyLauncher,
    MockGenesisTransferBackLauncher,
    MockGenesisRevertingLauncher,
    MockPOLend,
    MockCreditFactory
} from "./mocks/LauncherMocks.sol";
import {RouterMockSY, RouterMockERC20, RouterMockUAsset} from "./mocks/RouterMocks.sol";

/**
 * @title OutrunRouterTest
 * @notice Router coverage for the genesis dual-gate surface and the target registries: the trusted-SP
 *     registry gating on the genesis path, the PSM registry (registration checks, events, revocation,
 *     runtime binding drift), genesis path A (`genesisByPSM`: ERC20 and NATIVE reserve legs, fee math,
 *     uint128 bound, strict full-consumption post-condition), and genesis path B (`genesisBySY` and its
 *     token-denominated entry `genesisByToken`: ERC20/NATIVE legs, two-level slippage floors, registry
 *     gating, uint128 bound, two-step composition equivalence, rollback on launcher failure), plus the
 *     leveraged PSM genesis (`leveragedGenesisByPSM`: POLend target gating and registration,
 *     market-uAsset pairing, native/ERC20 value rules, and strict full-consumption).
 */
contract OutrunRouterTest is Test {
    bytes4 internal constant UNTRUSTED_ROUTER_TARGET_SELECTOR = IOutrunRouter.UntrustedRouterTarget.selector;
    bytes4 internal constant ROUTER_TARGET_MISMATCH_SELECTOR = IOutrunRouter.RouterTargetMismatch.selector;
    bytes4 internal constant UNREGISTERED_PSM_SELECTOR = IOutrunRouter.UnregisteredPsm.selector;
    bytes4 internal constant PSM_BINDING_MISMATCH_SELECTOR = IOutrunRouter.PsmBindingMismatch.selector;
    bytes4 internal constant PSM_RESERVE_MISMATCH_SELECTOR = IOutrunRouter.PsmReserveMismatch.selector;
    bytes4 internal constant INVALID_PARAM_SELECTOR = IOutrunRouter.InvalidParam.selector;
    bytes4 internal constant INSUFFICIENT_U_ASSET_MINTED_SELECTOR =
        IOutrunStakeManager.InsufficientUAssetMinted.selector;
    bytes4 internal constant POLEND_NOT_SET_SELECTOR = IOutrunRouter.PolendNotSet.selector;
    bytes4 internal constant POLEND_MARKET_U_ASSET_MISMATCH_SELECTOR =
        IOutrunRouter.PolendMarketUAssetMismatch.selector;
    bytes4 internal constant GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR = GenesisGateLib.GenesisUAssetNotConsumed.selector;
    bytes4 internal constant NATIVE_AMOUNT_MISMATCH_SELECTOR = NativeAmountMismatch.selector;
    // Same signature as the production SYInsufficientSharesOut, declared on the mock for test-side access.
    bytes4 internal constant ROUTER_INSUFFICIENT_SHARES_OUT_SELECTOR =
        RouterMockSY.RouterInsufficientSharesOut.selector;
    // Same signature as the production Pausable error, declared on the mock for test-side access.
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = RouterMockUAsset.EnforcedPause.selector;
    bytes4 internal constant OWNABLE_UNAUTHORIZED_SELECTOR = Ownable.OwnableUnauthorizedAccount.selector;

    // NATIVE sentinel matching TokenHelper: address(0) routes to the native currency leg.
    address internal constant NATIVE = address(0);
    uint256 internal constant VERSE_ID = 42;
    uint256 internal constant MAX_UINT128 = type(uint128).max;

    RouterMockERC20 internal underlying;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunPSMUpgradeable internal psm;
    OutrunPSMUpgradeable internal psmNative;
    OutrunRouter internal router;
    MockGenesisLauncher internal launcher;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE);
    address internal user = address(0xB0B);

    function setUp() public virtual {
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
        // Caps at max keep the fixture open to the uint128-boundary amounts; fees start at zero so the
        // deterministic face-value math is exact and fee cases opt in via setFees. One single-reserve
        // instance per leg, each registered as its own (uAsset, reserveToken) pair.
        psm = _deployPSM(address(uAsset), address(underlying));
        psmNative = _deployPSM(address(uAsset), NATIVE);
        router = new OutrunRouter(owner, address(launcher));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));
        // This test contract owns the mock uAsset: wire each PSM as a reserve minter.
        uAsset.setReserveMinter(address(psm), true);
        uAsset.setReserveMinter(address(psmNative), true);
        vm.startPrank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(psm));
        router.setPsmForUAsset(address(uAsset), NATIVE, address(psmNative));
        vm.stopPrank();

        uAsset.setMintingCap(address(position), type(uint128).max);
        // Path B (face/value-parity CDP gate) is a thin forward into `SP.stakeForGenesis`, whose
        // post-condition and hand-off are SP-side: wire the same full-consumption mock launcher
        // as the SP's genesis target. The router's own launcher registry serves path A only.
        vm.prank(owner);
        position.setGenesisLauncher(address(launcher));

        // Big enough piles for the uint128-boundary cases (type(uint128).max is about 3.4e38).
        sy.mintShares(user, 1e40);
        underlying.mint(user, 1e40);
        vm.deal(user, 1_000e18);
        vm.startPrank(user);
        sy.approve(address(router), type(uint256).max);
        underlying.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice The launcher registry performs no code check: the constructor accepts the zero address.
    function test_ConstructorAcceptsZeroMemeverseLauncher() external {
        OutrunRouter zeroLauncherRouter = new OutrunRouter(owner, address(0));
        assertEq(zeroLauncherRouter.memeverseLauncher(), address(0), "zero launcher stored without a code check");
    }

    /// @notice A drifted `SP.SY()` binding must fail closed with the three-party mismatch payload
    ///         before any SY is pulled or approved.
    function test_RevertIf_GenesisBySYOnSPBindingDrift() external {
        address driftedSY = address(0xDEAD);
        vm.mockCall(address(position), abi.encodeWithSelector(IOutrunStakeManager.SY.selector), abi.encode(driftedSY));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ROUTER_TARGET_MISMATCH_SELECTOR, address(position), address(sy), driftedSY)
        );
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);
    }

    // --------------------------------------------------------------------------
    // Unchanged entry surfaces (native legs, exact approvals, owner setters)
    // --------------------------------------------------------------------------

    /// @notice The native leg of `mintSYFromToken` forwards `msg.value` to SY.deposit and records the
    ///         NATIVE sentinel as the input token.
    function test_MintSYFromTokenSupportsNativePath() external {
        uint256 amount = 100e18;
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        uint256 syOut = router.mintSYFromToken{value: amount}(address(sy), NATIVE, user, amount, amount);

        (address tokenIn, uint256 depositAmount, uint256 depositValue) = sy.lastDeposit();
        assertEq(syOut, amount, "identity deposit rate mints 1:1 SY");
        assertEq(sy.balanceOf(user), userSYBefore + amount, "SY delivered to the receiver");
        assertEq(tokenIn, NATIVE, "native path records the NATIVE sentinel as tokenIn");
        assertEq(depositAmount, amount, "deposit amount forwarded unchanged");
        assertEq(depositValue, amount, "msg.value forwarded to SY.deposit");
    }

    /// @notice An ERC20 input leg must not carry any native value.
    function test_RevertWhen_MintSYFromTokenERC20InputCarriesMsgValue() external {
        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.mintSYFromToken{value: 1}(address(sy), address(underlying), user, 1e18, 0);
    }

    /// @notice The router rejects infinite approvals: a uint256.max deposit amount that survives the
    ///         pull must still fail at the exact-approval step.
    function test_RevertWhen_MintSYFromTokenApprovalAmountIsUint256Max() external {
        // The max pull must survive, so the user must hold exactly max with totalSupply
        // capped at max: redeem the SY backing to the user first, then top up the remainder.
        uint256 userShares = sy.balanceOf(user);
        vm.prank(user);
        sy.redeem(user, userShares, address(underlying), 0, false);
        underlying.mint(user, type(uint256).max - underlying.totalSupply());

        vm.prank(user);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.mintSYFromToken(address(sy), address(underlying), user, type(uint256).max, 0);
    }

    /// @notice The launcher setter performs no code check: the zero address registers, then the
    ///         original launcher is restored.
    function test_SetMemeverseLauncherAcceptsZeroAddress() external {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.SetMemeverseLauncher(address(launcher), address(0));
        router.setMemeverseLauncher(address(0));
        assertEq(router.memeverseLauncher(), address(0), "zero launcher stored without a code check");
        router.setMemeverseLauncher(address(launcher));
        vm.stopPrank();
        assertEq(router.memeverseLauncher(), address(launcher), "launcher restore failed");
    }

    /// @notice A codeless launcher registers successfully; the original launcher is restored afterwards.
    function test_SetMemeverseLauncherAcceptsCodelessAddress() external {
        address eoaLauncher = address(0x1234);
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.SetMemeverseLauncher(address(launcher), eoaLauncher);
        router.setMemeverseLauncher(eoaLauncher);
        assertEq(router.memeverseLauncher(), eoaLauncher, "codeless launcher stored without a code check");
        router.setMemeverseLauncher(address(launcher));
        vm.stopPrank();
        assertEq(router.memeverseLauncher(), address(launcher), "launcher restore failed");
    }

    /// @notice Registering an SP pair whose `SP.SY()` differs from the registered SY fails with the
    ///         three-party mismatch payload at registration time.
    function test_RevertWhen_SetTrustedSPRegisteredSYDoesNotMatchSP() external {
        address actualSY = address(underlying);
        vm.mockCall(address(position), abi.encodeWithSelector(IOutrunStakeManager.SY.selector), abi.encode(actualSY));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ROUTER_TARGET_MISMATCH_SELECTOR, address(position), address(sy), actualSY)
        );
        router.setTrustedSP(address(position), address(sy));
    }

    /// @notice Registering an SP pair with a nonzero SY outside the trusted whitelist fails with the
    ///         untrusted-target payload before any `SP.SY()` read.
    function test_RevertWhen_SetTrustedSPWithUntrustedSY() external {
        address untrustedSY = address(0xDEAD);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, untrustedSY));
        router.setTrustedSP(address(position), untrustedSY);
    }

    // --------------------------------------------------------------------------
    // PSM registry (path A addressing)
    // --------------------------------------------------------------------------

    /// @notice Only the owner may maintain the (uAsset, reserveToken) -> PSM registry.
    function test_RevertWhen_SetPsmForUAssetCalledByNonOwner() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, user));
        router.setPsmForUAsset(address(uAsset), address(underlying), address(psm));
    }

    /// @notice A zero uAsset key is rejected with the shared untrusted-target error.
    function test_RevertWhen_SetPsmForUAssetWithZeroUAsset() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, address(0)));
        router.setPsmForUAsset(address(0), address(underlying), address(psm));
    }

    /// @notice A codeless PSM registers successfully: registration performs no code check, only the
    ///         binding re-reads gate the write (mocked here). Revocation restores the zero state.
    function test_SetPsmForUAssetAcceptsCodelessPsm() external {
        address codeless = address(0xC0DE);
        vm.mockCall(codeless, abi.encodeWithSelector(IPSM.uAsset.selector), abi.encode(address(uAsset)));
        vm.mockCall(codeless, abi.encodeWithSelector(IPSM.reserveToken.selector), abi.encode(address(underlying)));
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit IOutrunRouter.PsmForUAssetUpdated(address(uAsset), address(underlying), codeless);
        router.setPsmForUAsset(address(uAsset), address(underlying), codeless);
        assertEq(
            router.psmForUAsset(address(uAsset), address(underlying)),
            codeless,
            "codeless PSM stored without a code check"
        );
        router.setPsmForUAsset(address(uAsset), address(underlying), address(0));
        vm.stopPrank();
        vm.clearMockedCalls();
        assertEq(
            router.psmForUAsset(address(uAsset), address(underlying)),
            address(0),
            "revocation must clear the pair entry"
        );
    }

    /// @notice A PSM bound to another uAsset family fails registration with the binding-mismatch payload.
    function test_RevertWhen_SetPsmForUAssetWithMismatchedBinding() external {
        RouterMockUAsset otherUAsset = new RouterMockUAsset();
        OutrunPSMUpgradeable otherFamilyPsm = _deployPSM(address(otherUAsset), address(underlying));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                PSM_BINDING_MISMATCH_SELECTOR, address(otherFamilyPsm), address(uAsset), address(otherUAsset)
            )
        );
        router.setPsmForUAsset(address(uAsset), address(underlying), address(otherFamilyPsm));
    }

    /// @notice A PSM bound to another reserve fails registration with the reserve-mismatch payload.
    function test_RevertWhen_SetPsmForUAssetWithMismatchedReserveBinding() external {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PSM_RESERVE_MISMATCH_SELECTOR, address(psm), NATIVE, address(underlying))
        );
        router.setPsmForUAsset(address(uAsset), NATIVE, address(psm));
    }

    /// @notice Registration and revocation emit `PsmForUAssetUpdated`, update the getter, and revoking
    ///         one pair leaves other pairs untouched.
    function test_SetPsmForUAssetRegistersRevokesAndEmits() external {
        RouterMockUAsset otherUAsset = new RouterMockUAsset();
        RouterMockERC20 otherReserve = new RouterMockERC20("Other", "OTH");
        OutrunPSMUpgradeable otherPairPsm = _deployPSM(address(otherUAsset), address(otherReserve));

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit IOutrunRouter.PsmForUAssetUpdated(address(otherUAsset), address(otherReserve), address(otherPairPsm));
        router.setPsmForUAsset(address(otherUAsset), address(otherReserve), address(otherPairPsm));
        assertEq(
            router.psmForUAsset(address(otherUAsset), address(otherReserve)),
            address(otherPairPsm),
            "pair PSM not registered"
        );

        vm.expectEmit(true, true, true, true);
        emit IOutrunRouter.PsmForUAssetUpdated(address(uAsset), address(underlying), address(0));
        router.setPsmForUAsset(address(uAsset), address(underlying), address(0));
        vm.stopPrank();

        assertEq(
            router.psmForUAsset(address(uAsset), address(underlying)),
            address(0),
            "revocation must clear the pair entry"
        );
        assertEq(
            router.psmForUAsset(address(otherUAsset), address(otherReserve)),
            address(otherPairPsm),
            "revoking one pair must not clear another"
        );
        // The sibling leg on the same uAsset is untouched by the ERC20-leg revocation.
        assertEq(
            router.psmForUAsset(address(uAsset), NATIVE),
            address(psmNative),
            "native leg must survive the ERC20 revocation"
        );
    }

    /// @notice An unregistered uAsset family fails `genesisByPSM` before any funds move.
    function test_RevertWhen_GenesisByPSMWithUnregisteredUAsset() external {
        address unregistered = address(new RouterMockUAsset());
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UNREGISTERED_PSM_SELECTOR, unregistered, address(underlying)));
        router.genesisByPSM(unregistered, address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice An unregistered reserve for a registered uAsset fails `genesisByPSM` before any funds move.
    function test_RevertWhen_GenesisByPSMWithUnregisteredReserveForRegisteredUAsset() external {
        address strayReserve = address(new RouterMockERC20("Stray", "STR"));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UNREGISTERED_PSM_SELECTOR, address(uAsset), strayReserve));
        router.genesisByPSM(address(uAsset), strayReserve, 1e18, VERSE_ID, user);
    }

    /// @notice Revoking the pair PSM fails the entry closed for subsequent calls on that pair only.
    function test_RevertWhen_GenesisByPSMAfterRevocation() external {
        vm.prank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(0));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UNREGISTERED_PSM_SELECTOR, address(uAsset), address(underlying)));
        router.genesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);

        // The sibling native leg stays available.
        vm.prank(user);
        router.genesisByPSM{value: 1e18}(address(uAsset), NATIVE, 1e18, VERSE_ID, user);
        assertEq(uAsset.balanceOf(address(launcher)), 1e18, "native leg must survive the ERC20 revocation");
    }

    /// @notice A PSM whose uAsset binding drifted after registration fails the per-call re-read with
    ///         the mismatch payload, before any reserve is pulled.
    function test_RevertIf_GenesisByPSMOnPsmBindingDrift() external {
        PairDriftPSM driftPsm = new PairDriftPSM(address(uAsset), address(underlying));
        vm.prank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(driftPsm));
        address driftedUAsset = address(0xDEAD);
        driftPsm.setBoundUAsset(driftedUAsset);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(PSM_BINDING_MISMATCH_SELECTOR, address(driftPsm), address(uAsset), driftedUAsset)
        );
        router.genesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice A PSM whose reserve binding drifted after registration fails the per-call re-read with
    ///         the reserve-mismatch payload, before any reserve is pulled.
    function test_RevertIf_GenesisByPSMOnPsmReserveDrift() external {
        PairDriftPSM driftPsm = new PairDriftPSM(address(uAsset), address(underlying));
        vm.prank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(driftPsm));
        address driftedReserve = address(0xDEAD);
        driftPsm.setBoundReserve(driftedReserve);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PSM_RESERVE_MISMATCH_SELECTOR, address(driftPsm), address(underlying), driftedReserve
            )
        );
        router.genesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice A zero genesisUser fails closed on the registered pair before any reserve is pulled.
    function test_RevertWhen_GenesisByPSMWithZeroGenesisUser() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.genesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, address(0));

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
    }

    // --------------------------------------------------------------------------
    // Path A: genesisByPSM roundtrips (PSM gate)
    // --------------------------------------------------------------------------

    /// @notice ERC20 reserve leg: the caller pays `amountIn`, the PSM mints the fee-adjusted face-value
    ///         amount to the router, and the launcher receives the full minted amount; quoteMint equals
    ///         the executed output (deterministic math) and no residual stays anywhere.
    function test_GenesisByPSMERC20LegRoundtrip() external {
        vm.prank(owner);
        psm.setFees(1e16, 0); // 1% mint fee so the fee math is observable.
        uint256 amountIn = 10e18;
        uint256 expectedOut = IPSM(address(psm)).quoteMint(amountIn);
        assertEq(expectedOut, amountIn * (1e18 - 1e16) / 1e18, "expected fee-adjusted output");
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectEmit(true, true, false, true, address(psm));
        emit IPSM.SwapMintForUAsset(address(underlying), address(router), amountIn, expectedOut, amountIn - expectedOut);
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore - amountIn, "caller did not pay the full reserve");
        assertEq(underlying.balanceOf(address(psm)), amountIn, "PSM holds the taken reserve");
        assertEq(IPSM(address(psm)).netUAssetMinted(), expectedOut, "PSM net minted ledger");
        (uint256 lastVerseId, uint256 lastAmount, address lastUser) = launcher.snapshot();
        assertEq(lastVerseId, VERSE_ID, "verse id forwarded");
        assertEq(lastAmount, expectedOut, "launcher received the minted amount");
        assertEq(lastUser, user, "genesis user credited");
        assertEq(uAsset.balanceOf(address(launcher)), expectedOut, "launcher holds the minted uAsset");
        _assertGenesisLeftNoResidual(address(underlying));
        assertEq(underlying.allowance(address(router), address(psm)), 0, "PSM reserve allowance not cleared");
        _assertNoPositionCreated();
    }

    /// @notice NATIVE reserve leg: `msg.value` carries the reserve into the PSM and the minted uAsset
    ///         reaches the launcher in full.
    function test_GenesisByPSMNativeLegRoundtrip() external {
        uint256 amountIn = 2e18;

        vm.prank(user);
        router.genesisByPSM{value: amountIn}(address(uAsset), NATIVE, amountIn, VERSE_ID, user);

        assertEq(address(psmNative).balance, amountIn, "native reserve stayed in the PSM");
        assertEq(uAsset.balanceOf(address(launcher)), amountIn, "launcher holds the minted uAsset");
        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, amountIn, "launcher received the minted amount");
        _assertGenesisLeftNoResidual(NATIVE);
    }

    /// @notice The ERC20 reserve leg rejects any attached native value.
    function test_RevertWhen_GenesisByPSMERC20LegWithValue() external {
        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByPSM{value: 1}(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice The NATIVE reserve leg requires `msg.value == amountIn` exactly.
    function test_RevertWhen_GenesisByPSMNativeLegValueMismatch() external {
        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByPSM{value: 1e18}(address(uAsset), NATIVE, 2e18, VERSE_ID, user);
    }

    /// @notice A reserve with no pair entry for a registered uAsset fails the pair lookup before any
    ///         funds move: no reserve pull, no PSM ledger movement, no residual allowance.
    function test_RevertWhen_GenesisByPSMWithUnregisteredReserve() external {
        RouterMockERC20 strayReserve = new RouterMockERC20("Stray", "STR");
        strayReserve.mint(user, 1e18);
        vm.startPrank(user);
        strayReserve.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(UNREGISTERED_PSM_SELECTOR, address(uAsset), address(strayReserve)));
        router.genesisByPSM(address(uAsset), address(strayReserve), 1e18, VERSE_ID, user);
        vm.stopPrank();

        assertEq(IPSM(address(psm)).netUAssetMinted(), 0, "failed call must not move the PSM ledger");
        assertEq(strayReserve.balanceOf(address(router)), 0, "failed call must not leave reserve on the router");
        assertEq(strayReserve.balanceOf(user), 1e18, "failed call must not pull the reserve from the caller");
        assertEq(uAsset.allowance(address(router), address(launcher)), 0, "failed call must not leave an allowance");
    }

    /// @notice A mint above the uint128 launcher domain reverts InvalidParam before the launcher
    ///         approval and the genesis call.
    function test_RevertWhen_GenesisByPSMMintsAboveUint128Max() external {
        uint256 amountIn = 4e38; // type(uint128).max is about 3.4e38.
        vm.prank(user);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);
    }

    /// @notice A mint of exactly type(uint128).max passes the bound and is forwarded in full.
    function test_GenesisByPSMAtUint128MaxSucceeds() external {
        vm.prank(user);
        router.genesisByPSM(address(uAsset), address(underlying), MAX_UINT128, VERSE_ID, user);

        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, type(uint128).max, "launcher received exactly the uint128 cap");
        assertEq(uAsset.balanceOf(address(launcher)), MAX_UINT128, "launcher holds the full cap amount");
    }

    // --------------------------------------------------------------------------
    // Leveraged genesis: leveragedGenesisByPSM (PSM gate -> POLend interest leg)
    // --------------------------------------------------------------------------

    /// @notice Reserve -> PSM -> POLend one-shot: interest lands on the param user and the router
    ///         keeps nothing (ERC20 leg).
    function test_LeveragedGenesisByPSMRoundtripErc20() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17); // borrowed = 10x interest
        polendMock.setMarketUAsset(VERSE_ID, address(uAsset));
        vm.prank(owner);
        router.setPolend(address(polendMock));

        uint256 amountIn = 100e18;
        vm.prank(user);
        uint256 borrowed = router.leveragedGenesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(borrowed, 1000e18, "borrowed forwarded from POLend math");
        assertEq(polendMock.leveragedInterestPaid(VERSE_ID, user), amountIn, "interest ledger keyed by user");
        assertEq(polendMock.lastPayer(), address(router), "payer is the router");
        assertEq(polendMock.lastUser(), user, "user forwarded");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds nothing");
        assertEq(uAsset.balanceOf(address(polendMock)), amountIn, "POLend pulled the full interest");
    }

    /// @notice Same roundtrip on the native reserve leg.
    function test_LeveragedGenesisByPSMRoundtripNative() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        polendMock.setMarketUAsset(VERSE_ID, address(uAsset));
        vm.prank(owner);
        router.setPolend(address(polendMock));

        uint256 userNativeBefore = user.balance;

        vm.prank(user);
        router.leveragedGenesisByPSM{value: 100e18}(address(uAsset), NATIVE, 100e18, VERSE_ID, user);

        assertEq(polendMock.leveragedInterestPaid(VERSE_ID, user), 100e18);
        assertEq(uAsset.balanceOf(address(router)), 0);
        // msg.value == amountIn is enforced on entry and forwarded to the PSM in full: no native residue.
        assertEq(address(router).balance, 0, "router holds no native after the flow");
        assertEq(user.balance, userNativeBefore - 100e18, "user paid exactly amountIn");
    }

    /// @notice Unconfigured POLend target fails closed before any funds move.
    function test_RevertWhen_LeveragedGenesisByPSMPolendNotSet() external {
        vm.prank(user);
        vm.expectRevert(POLEND_NOT_SET_SELECTOR);
        router.leveragedGenesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice A verse market bound to a different uAsset family fails closed (unregistered verse
    ///         reads address(0) and takes the same path).
    function test_RevertWhen_LeveragedGenesisByPSMMarketUAssetMismatch() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        polendMock.setMarketUAsset(VERSE_ID, address(underlying)); // wrong family
        vm.prank(owner);
        router.setPolend(address(polendMock));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                POLEND_MARKET_U_ASSET_MISMATCH_SELECTOR, VERSE_ID, address(uAsset), address(underlying)
            )
        );
        router.leveragedGenesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice Unregistered verse: marketUAsset reads address(0), same mismatch error, nothing moves.
    function test_RevertWhen_LeveragedGenesisByPSMVerseUnregistered() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        vm.prank(owner);
        router.setPolend(address(polendMock));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(POLEND_MARKET_U_ASSET_MISMATCH_SELECTOR, VERSE_ID, address(uAsset), address(0))
        );
        router.leveragedGenesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice Zero credited user reverts before any pull (direct-launcher rationale: the interest
    ///         ledger target must not be a burn sink).
    function test_RevertWhen_LeveragedGenesisByPSMZeroUser() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        polendMock.setMarketUAsset(VERSE_ID, address(uAsset));
        vm.prank(owner);
        router.setPolend(address(polendMock));

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.leveragedGenesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, address(0));
    }

    /// @notice Native/ERC20 value rules carry over from path A.
    function test_RevertWhen_LeveragedGenesisByPSMNativeAmountMismatch() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        polendMock.setMarketUAsset(VERSE_ID, address(uAsset));
        vm.prank(owner);
        router.setPolend(address(polendMock));

        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.leveragedGenesisByPSM{value: 1}(address(uAsset), address(underlying), 1e18, VERSE_ID, user); // ERC20 leg must send no value
    }

    /// @notice A half-pulling POLend leaves residual allowance -> strict consumption reverts all.
    function test_RevertWhen_LeveragedGenesisByPSMPartialConsumption() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        polendMock.setMarketUAsset(VERSE_ID, address(uAsset));
        polendMock.setPullHalf();
        vm.prank(owner);
        router.setPolend(address(polendMock));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR,
                50e18, // residual balance over baseline: polend pulls half of the 100e18 face-value mint
                50e18 // unpulled half of the 100e18 allowance remains after the half pull (100e18 -> 50e18)
            )
        );
        router.leveragedGenesisByPSM(address(uAsset), address(underlying), 100e18, VERSE_ID, user);
    }

    /// @notice setPolend emits, stores, and stays owner-gated.
    function test_SetPolendStoresAndEmits() external {
        MockPOLend polendMock = new MockPOLend(address(uAsset), 1e17);
        vm.expectEmit(true, true, true, true);
        emit IOutrunRouter.SetPolend(address(0), address(polendMock));
        vm.prank(owner);
        router.setPolend(address(polendMock));
        assertEq(router.polend(), address(polendMock));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, user));
        router.setPolend(address(polendMock));
    }

    // --------------------------------------------------------------------------
    // Path B: genesisBySY roundtrips (face/value-parity CDP gate)
    // --------------------------------------------------------------------------

    /// @notice SY-funded genesis creates the open-term position for `genesisUser` at value parity,
    ///         and the launcher consumes exactly the minted principal.
    function test_GenesisBySYRoundtrip() external {
        uint256 amountInSY = 10e18;
        uint256 expectedMinted = amountInSY; // value parity at the 1e18 mock rate
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        vm.expectEmit(true, true, false, true, address(position));
        emit IOutrunStakeManager.Stake(1, user, amountInSY, expectedMinted);
        vm.expectEmit(true, true, false, true, address(position));
        emit IOutrunStakeManager.StakeForGenesis(1, user, VERSE_ID, expectedMinted);
        router.genesisBySY(address(position), amountInSY, VERSE_ID, user, expectedMinted);

        (
            address positionOwner,
            uint256 syStaked,
            uint256 principalDebt,
            uint256 accruedInterest,
            uint256 lastRateUnit
        ) = position.positions(1);
        assertEq(positionOwner, user, "genesisUser owns the position");
        assertEq(syStaked, amountInSY, "SY collateral recorded");
        assertEq(principalDebt, expectedMinted, "principal debt equals the minted uAsset");
        assertEq(accruedInterest, 0, "fresh position has no settled interest");
        assertEq(lastRateUnit, position.currentRate(), "lastRateUnit snapshot settled to the opening block");
        // The SP-side physical gate conserves the SP's own uAsset balance (mint -> consume in-tx).
        assertEq(uAsset.balanceOf(address(position)), 0, "SP uAsset balance conserved by the gate");
        assertEq(uAsset.allowance(address(position), address(launcher)), 0, "SP launcher allowance cleared");
        assertEq(sy.balanceOf(user), userSYBefore - amountInSY, "caller paid the staked SY");
        assertEq(sy.balanceOf(address(position)), amountInSY, "SP holds the staked SY");
        // Borrowed == consumed: principal debt == forwarded amount == launcher holding, wei-exact.
        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, expectedMinted, "launcher received the minted amount");
        assertEq(uAsset.balanceOf(address(launcher)), expectedMinted, "launcher holds exactly the minted amount");
        assertEq(expectedMinted, principalDebt, "borrowed amount must equal the genesis consumption");
        _assertGenesisLeftNoResidual(address(sy));
        assertEq(sy.allowance(address(router), address(position)), 0, "SY allowance to SP not cleared");
    }

    /// @notice A launcher-side revert rolls the whole genesis back: no position, no uAsset supply, no
    ///         SY movement, and no residual balances or allowances anywhere.
    function test_GenesisBySYRollsBackWhenLauncherReverts() external {
        MockGenesisRevertingLauncher revertingLauncher = new MockGenesisRevertingLauncher();
        _setLaunchersInParity(address(revertingLauncher));
        uint256 userSYBefore = sy.balanceOf(user);
        uint256 uAssetSupplyBefore = uAsset.totalSupply();

        vm.prank(user);
        vm.expectRevert(MockGenesisRevertingLauncher.GenesisLauncherReverted.selector);
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);

        _assertNoPositionCreated();
        assertEq(sy.balanceOf(user), userSYBefore, "caller SY unchanged after rollback");
        assertEq(sy.balanceOf(address(position)), 0, "SP holds no SY after rollback");
        assertEq(uAsset.totalSupply(), uAssetSupplyBefore, "uAsset supply unchanged after rollback");
        _assertGenesisLeftNoResidual(address(sy));
    }

    /// @notice The SY-gate slippage floor reverts the whole call when the stake under-mints.
    function test_RevertWhen_GenesisBySYBelowMinUAssetMinted() external {
        uint256 minted = 10e18; // value parity at the 1e18 mock rate
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_U_ASSET_MINTED_SELECTOR, minted, minted + 1));
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, minted + 1);

        _assertNoPositionCreated();
        _assertGenesisLeftNoResidual(address(sy));
    }

    /// @notice A stake minting above the uint128 launcher domain reverts InvalidParam before the
    ///         launcher approval and the genesis call.
    function test_RevertWhen_GenesisBySYMintsAboveUint128Max() external {
        uint256 amountInSY = MAX_UINT128 + 1; // value parity: minted == amountInSY at the mock rate.
        vm.prank(user);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.genesisBySY(address(position), amountInSY, VERSE_ID, user, 0);
    }

    /// @notice A stake minting exactly type(uint128).max passes the bound and is forwarded in full.
    function test_GenesisBySYAtUint128MaxSucceeds() external {
        uint256 amountInSY = MAX_UINT128; // value parity at the mock rate.

        vm.prank(user);
        router.genesisBySY(address(position), amountInSY, VERSE_ID, user, MAX_UINT128);

        (,, uint256 principalDebt,,) = position.positions(1);
        assertEq(principalDebt, MAX_UINT128, "principal debt equals exactly the uint128 cap");
        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, type(uint128).max, "launcher received exactly the uint128 cap");
    }

    // --------------------------------------------------------------------------
    // Strict full-consumption post-condition (shared genesis tail)
    // --------------------------------------------------------------------------

    /// @notice Path A with a launcher consuming only half: the residual balance and the residual
    ///         allowance are both reported and the whole call reverts.
    function test_RevertWhen_GenesisByPSMLauncherConsumesHalf() external {
        MockGenesisPartialLauncher partialLauncher = new MockGenesisPartialLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(partialLauncher));
        uint256 amountIn = 10e18;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR,
                amountIn / 2, // residual balance over baseline
                amountIn / 2 // residual allowance left untouched by the half pull
            )
        );
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);
    }

    /// @notice Path B with a launcher consuming only half: same shared-tail revert.
    function test_RevertWhen_GenesisBySYLauncherConsumesHalf() external {
        MockGenesisPartialLauncher partialLauncher = new MockGenesisPartialLauncher(address(uAsset));
        _setLaunchersInParity(address(partialLauncher));
        uint256 minted = 10e18; // value parity at the 1e18 mock rate

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, minted / 2, minted / 2));
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);
    }

    /// @notice A launcher that pulls the full amount and transfers part of it back reverts through the
    ///         balance dimension (allowance is fully consumed).
    function test_RevertWhen_GenesisBySYLauncherTransfersBack() external {
        MockGenesisTransferBackLauncher transferBackLauncher = new MockGenesisTransferBackLauncher(address(uAsset));
        _setLaunchersInParity(address(transferBackLauncher));
        uint256 minted = 10e18; // value parity at the 1e18 mock rate

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, minted / 10, 0));
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);
    }

    /// @notice The router refuses an SP-path genesis when the SP's launcher diverges from the
    ///         router's registry: parity is checked before any mint, approval, or launcher call.
    function test_RevertWhen_GenesisBySYLauncherParityMismatch() external {
        MockGenesisRevertingLauncher revertingLauncher = new MockGenesisRevertingLauncher();
        vm.prank(owner);
        position.setGenesisLauncher(address(revertingLauncher));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOutrunRouter.GenesisLauncherMismatch.selector, address(launcher), address(revertingLauncher)
            )
        );
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);

        _assertNoPositionCreated();
        _assertGenesisLeftNoResidual(address(sy));
    }

    /// @notice A PSM that mints its output to someone else masks the balance dimension (the router's
    ///         balance sits exactly at its pre-mint baseline), and only the untouched launcher
    ///         allowance catches the cheat; the revert also rolls the donated mint back atomically.
    function test_RevertWhen_GenesisByPSMDonatedMintMasksBalance() external {
        address donatee = address(0xD0E);
        PairDonatingPSM donatingPsm = new PairDonatingPSM(address(uAsset), address(underlying), donatee);
        uAsset.setReserveMinter(address(donatingPsm), true);
        vm.startPrank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(donatingPsm));
        router.setMemeverseLauncher(address(new MockGenesisEmptyLauncher()));
        vm.stopPrank();
        uint256 amountIn = 1e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, 0, amountIn));
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        // The whole transaction rolled back: the donated mint and the reserve pull never happened.
        assertEq(uAsset.balanceOf(donatee), 0, "donated mint must roll back with the call");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "reserve pull must roll back with the call");
    }

    /// @notice Pre-donated uAsset dust stays outside the post-condition baseline: a fully consumed
    ///         genesis succeeds while the router still holds the dust, recoverable via sweep.
    function test_GenesisByPSMDustExcludedFromPostAssertion() external {
        uint256 dust = 123;
        uAsset.setMintingCap(address(this), type(uint128).max);
        uAsset.mint(address(router), dust);
        uint256 amountIn = 5e18;

        vm.prank(user);
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(uAsset.balanceOf(address(router)), dust, "pre-donated dust must survive the genesis");
        vm.prank(owner);
        router.sweep(address(uAsset), treasury, dust);
        assertEq(uAsset.balanceOf(treasury), dust, "dust recovered by the owner sweep");
    }

    // --------------------------------------------------------------------------
    // Path B token entry: genesisByToken roundtrips (face/value-parity CDP gate, token-denominated)
    // --------------------------------------------------------------------------

    /// @notice ERC20 leg: the caller pays `tokenAmount`, SY is minted 1:1 to the router at the identity
    ///         rate, the face/value-parity CDP position is created for `genesisUser`,
    ///         and the launcher consumes exactly the minted principal (strict equality, no residual).
    function test_GenesisByTokenERC20LegRoundtrip() external {
        uint256 tokenAmount = 10e18;
        uint256 expectedMinted = tokenAmount; // value parity at the 1e18 mock rate
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectEmit(true, true, false, true, address(position));
        emit IOutrunStakeManager.Stake(1, user, tokenAmount, expectedMinted);
        vm.expectEmit(true, true, false, true, address(position));
        emit IOutrunStakeManager.StakeForGenesis(1, user, VERSE_ID, expectedMinted);
        router.genesisByToken(
            address(position), address(underlying), tokenAmount, tokenAmount, VERSE_ID, user, expectedMinted
        );

        (
            address positionOwner,
            uint256 syStaked,
            uint256 principalDebt,
            uint256 accruedInterest,
            uint256 lastRateUnit
        ) = position.positions(1);
        assertEq(positionOwner, user, "genesisUser owns the position");
        assertEq(syStaked, tokenAmount, "SY collateral recorded at the identity deposit rate");
        assertEq(principalDebt, expectedMinted, "principal debt equals the minted uAsset");
        assertEq(accruedInterest, 0, "fresh position has no settled interest");
        assertEq(lastRateUnit, position.currentRate(), "lastRateUnit snapshot settled to the opening block");
        // The router never touches uAsset on path B; the SP-side gate conserves the SP balance.
        assertEq(uAsset.balanceOf(address(position)), 0, "SP uAsset balance conserved by the gate");
        assertEq(uAsset.allowance(address(position), address(launcher)), 0, "SP launcher allowance cleared");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore - tokenAmount, "caller paid the input token");
        assertEq(sy.balanceOf(address(position)), tokenAmount, "SP holds the staked SY");
        // Borrowed == consumed: principal debt == forwarded amount == launcher holding, wei-exact.
        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, expectedMinted, "launcher received the minted amount");
        assertEq(uAsset.balanceOf(address(launcher)), expectedMinted, "launcher holds exactly the minted amount");
        assertEq(expectedMinted, principalDebt, "borrowed amount must equal the genesis consumption");
        _assertGenesisLeftNoResidual(address(underlying));
        assertEq(sy.balanceOf(address(router)), 0, "router kept residual SY");
        assertEq(sy.allowance(address(router), address(position)), 0, "SY allowance to SP not cleared");
        assertEq(underlying.allowance(address(router), address(sy)), 0, "underlying allowance to SY not cleared");
    }

    /// @notice NATIVE leg: `msg.value` funds the SY deposit, and the minted uAsset reaches the launcher
    ///         in full with the same strict equality.
    function test_GenesisByTokenNativeLegRoundtrip() external {
        uint256 tokenAmount = 10e18;
        uint256 expectedMinted = tokenAmount; // value parity at the 1e18 mock rate

        vm.prank(user);
        router.genesisByToken{value: tokenAmount}(
            address(position), NATIVE, tokenAmount, tokenAmount, VERSE_ID, user, expectedMinted
        );

        (address tokenIn, uint256 depositAmount, uint256 depositValue) = sy.lastDeposit();
        assertEq(tokenIn, NATIVE, "native path records the NATIVE sentinel as tokenIn");
        assertEq(depositAmount, tokenAmount, "deposit amount forwarded unchanged");
        assertEq(depositValue, tokenAmount, "msg.value forwarded to SY.deposit");
        (, uint256 syStaked, uint256 principalDebt,,) = position.positions(1);
        assertEq(syStaked, tokenAmount, "SY collateral recorded");
        // Borrowed == consumed, wei-exact on the native leg too.
        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, expectedMinted, "launcher received the minted amount");
        assertEq(uAsset.balanceOf(address(launcher)), expectedMinted, "launcher holds exactly the minted amount");
        assertEq(
            principalDebt, uAsset.balanceOf(address(launcher)), "borrowed amount must equal the genesis consumption"
        );
        _assertGenesisLeftNoResidual(NATIVE);
    }

    /// @notice The atomic entry equals the two-step composition: `mintSYFromToken` + `genesisBySY` and
    ///         `genesisByToken` with the same input mint the same collateral, debt, and launcher
    ///         consumption, wei-exact; the atomic path never routes SY through the caller.
    function test_GenesisByTokenMatchesTwoStepComposition() external {
        uint256 tokenAmount = 10e18;
        uint256 expectedMinted = tokenAmount; // value parity at the 1e18 mock rate
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 userSYBefore = sy.balanceOf(user);

        vm.startPrank(user);
        uint256 syOut = router.mintSYFromToken(address(sy), address(underlying), user, tokenAmount, tokenAmount);
        assertEq(syOut, tokenAmount, "identity deposit rate mints 1:1 SY");
        router.genesisBySY(address(position), syOut, VERSE_ID, user, expectedMinted);
        vm.stopPrank();

        (address composedOwner, uint256 composedSyStaked, uint256 composedDebt,,) = position.positions(1);

        vm.prank(user);
        router.genesisByToken(
            address(position), address(underlying), tokenAmount, tokenAmount, VERSE_ID, user, expectedMinted
        );

        (address atomicOwner, uint256 atomicSyStaked, uint256 atomicDebt,,) = position.positions(2);
        assertEq(atomicOwner, composedOwner, "same position owner");
        assertEq(atomicSyStaked, composedSyStaked, "same SY collateral, wei-exact");
        assertEq(atomicDebt, composedDebt, "same minted debt, wei-exact");
        assertEq(composedDebt, expectedMinted, "composed path mints the expected debt");
        // Launcher consumption is identical: one expectedMinted per path, no share left anywhere.
        assertEq(uAsset.balanceOf(address(launcher)), 2 * expectedMinted, "launcher consumed the same amount per path");
        assertEq(
            underlying.balanceOf(user), userUnderlyingBefore - 2 * tokenAmount, "both paths charge the same token input"
        );
        assertEq(sy.balanceOf(user), userSYBefore, "atomic path never routes SY through the caller");
        _assertGenesisLeftNoResidual(address(underlying));
    }

    /// @notice A launcher-side revert rolls the whole token genesis back: no position, no SY, no token
    ///         movement, no uAsset supply, and no residual balances or allowances anywhere.
    function test_GenesisByTokenRollsBackWhenLauncherReverts() external {
        MockGenesisRevertingLauncher revertingLauncher = new MockGenesisRevertingLauncher();
        _setLaunchersInParity(address(revertingLauncher));
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 uAssetSupplyBefore = uAsset.totalSupply();

        vm.prank(user);
        vm.expectRevert(MockGenesisRevertingLauncher.GenesisLauncherReverted.selector);
        router.genesisByToken(address(position), address(underlying), 10e18, 10e18, VERSE_ID, user, 0);

        _assertNoPositionCreated();
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "caller token unchanged after rollback");
        assertEq(sy.balanceOf(address(position)), 0, "SP holds no SY after rollback");
        assertEq(uAsset.totalSupply(), uAssetSupplyBefore, "uAsset supply unchanged after rollback");
        assertEq(sy.balanceOf(address(router)), 0, "router kept no SY from the reverted conversion");
        _assertGenesisLeftNoResidual(address(underlying));
    }

    /// @notice The first slippage floor: a token -> SY conversion below `minSyOut` reverts with the SY
    ///         deposit error payload and leaves nothing behind.
    function test_RevertWhen_GenesisByTokenBelowMinSyOut() external {
        uint256 tokenAmount = 10e18;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ROUTER_INSUFFICIENT_SHARES_OUT_SELECTOR, tokenAmount, tokenAmount + 1));
        router.genesisByToken(address(position), address(underlying), tokenAmount, tokenAmount + 1, VERSE_ID, user, 0);

        _assertNoPositionCreated();
        assertEq(sy.balanceOf(address(router)), 0, "router kept no SY from the reverted conversion");
        _assertGenesisLeftNoResidual(address(underlying));
    }

    /// @notice The second slippage floor: a stake minting below `minUAssetMinted` reverts with the
    ///         router payload and rolls the conversion back.
    function test_RevertWhen_GenesisByTokenBelowMinUAssetMinted() external {
        uint256 tokenAmount = 10e18;
        uint256 minted = tokenAmount; // value parity at the 1e18 mock rate
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_U_ASSET_MINTED_SELECTOR, minted, minted + 1));
        router.genesisByToken(
            address(position), address(underlying), tokenAmount, tokenAmount, VERSE_ID, user, minted + 1
        );

        _assertNoPositionCreated();
        assertEq(sy.balanceOf(address(router)), 0, "router kept no SY from the reverted conversion");
        _assertGenesisLeftNoResidual(address(underlying));
    }

    /// @notice The token entry is registry-gated exactly like the SY entry: an unregistered SP fails
    ///         before any token moves.
    function test_RevertWhen_GenesisByTokenTargetsUnregisteredSP() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, user));
        router.genesisByToken(user, address(underlying), 1e18, 0, VERSE_ID, user, 0);
    }

    /// @notice Revoking the SY trust fails the token entry closed through the shared pairing check.
    function test_RevertWhen_GenesisByTokenWithUntrustedSY() external {
        vm.prank(owner);
        router.setTrustedSY(address(sy), false);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, address(sy)));
        router.genesisByToken(address(position), address(underlying), 1e18, 0, VERSE_ID, user, 0);
    }

    /// @notice A drifted `SP.SY()` binding fails the token entry with the three-party mismatch payload
    ///         before any token is pulled or approved.
    function test_RevertIf_GenesisByTokenOnSPBindingDrift() external {
        address driftedSY = address(0xDEAD);
        vm.mockCall(address(position), abi.encodeWithSelector(IOutrunStakeManager.SY.selector), abi.encode(driftedSY));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ROUTER_TARGET_MISMATCH_SELECTOR, address(position), address(sy), driftedSY)
        );
        router.genesisByToken(address(position), address(underlying), 1e18, 0, VERSE_ID, user, 0);
    }

    /// @notice The ERC20 input leg rejects any attached native value.
    function test_RevertWhen_GenesisByTokenERC20LegWithValue() external {
        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByToken{value: 1}(address(position), address(underlying), 1e18, 0, VERSE_ID, user, 0);
    }

    /// @notice The NATIVE input leg requires `msg.value == tokenAmount` exactly, both short and over.
    function test_RevertWhen_GenesisByTokenNativeLegValueMismatch() external {
        uint256 tokenAmount = 2e18;

        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByToken{value: 1e18}(address(position), NATIVE, tokenAmount, 0, VERSE_ID, user, 0);

        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByToken{value: tokenAmount + 1}(address(position), NATIVE, tokenAmount, 0, VERSE_ID, user, 0);

        _assertNoPositionCreated();
    }

    /// @notice A stake minting above the uint128 launcher domain reverts InvalidParam before the
    ///         launcher approval and the genesis call.
    function test_RevertWhen_GenesisByTokenMintsAboveUint128Max() external {
        uint256 tokenAmount = MAX_UINT128 + 1; // value parity: minted == tokenAmount at the mock rate.
        vm.prank(user);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.genesisByToken(address(position), address(underlying), tokenAmount, tokenAmount, VERSE_ID, user, 0);
    }

    /// @notice A stake minting exactly type(uint128).max passes the bound and is forwarded in full.
    function test_GenesisByTokenAtUint128MaxSucceeds() external {
        uint256 tokenAmount = MAX_UINT128; // value parity at the mock rate.

        vm.prank(user);
        router.genesisByToken(
            address(position), address(underlying), tokenAmount, tokenAmount, VERSE_ID, user, MAX_UINT128
        );

        (,, uint256 principalDebt,,) = position.positions(1);
        assertEq(principalDebt, MAX_UINT128, "principal debt equals exactly the uint128 cap");
        (, uint256 lastAmount,) = launcher.snapshot();
        assertEq(lastAmount, type(uint128).max, "launcher received exactly the uint128 cap");
    }

    // --------------------------------------------------------------------------
    // Pause matrix sampling
    // --------------------------------------------------------------------------

    /// @notice A paused uAsset fails both genesis gates closed: path A at the PSM's reserveMint step
    ///         and path B at the SP's mint step.
    function test_RevertWhen_UAssetPausedBlocksBothPaths() external {
        uAsset.pause();

        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        router.genesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);

        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);
    }

    /// @notice A paused stake manager blocks only path B; the PSM gate stays available.
    function test_RevertWhen_SPPausedBlocksOnlyPathB() external {
        vm.prank(owner);
        position.pause();

        vm.prank(user);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);

        vm.prank(user);
        router.genesisByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
        assertEq(uAsset.balanceOf(address(launcher)), 1e18, "path A stayed available while SP is paused");
    }

    // --------------------------------------------------------------------------
    // Preview launcher parity
    // --------------------------------------------------------------------------

    /// @notice Both previews refuse to price an open the execution path would reject: a one-sided
    ///         launcher rotation makes previewStakeFromToken and previewStakeFromSY revert with the
    ///         same GenesisLauncherMismatch payload as genesisBySY.
    function test_RevertWhen_PreviewsOnLauncherParityMismatch() external {
        MockGenesisRevertingLauncher revertingLauncher = new MockGenesisRevertingLauncher();
        vm.prank(owner);
        position.setGenesisLauncher(address(revertingLauncher));
        bytes memory expected = abi.encodeWithSelector(
            IOutrunRouter.GenesisLauncherMismatch.selector, address(launcher), address(revertingLauncher)
        );

        vm.expectRevert(expected);
        router.previewStakeFromToken(address(position), address(underlying), 10e18);

        vm.expectRevert(expected);
        router.previewStakeFromSY(address(position), 10e18);
    }

    /// @notice With both launchers in agreement the previews keep quoting the identity mock rate.
    function test_PreviewsQuoteUnchangedWhenLaunchersAgree() external {
        assertEq(
            router.previewStakeFromToken(address(position), address(underlying), 10e18),
            10e18,
            "token-denominated quote must track the mock identity rate"
        );
        assertEq(
            router.previewStakeFromSY(address(position), 10e18),
            10e18,
            "SY-denominated quote must track the mock identity rate"
        );
    }

    /// @notice Launcher parity compares values with no zero-address exclusion: with both launchers
    ///         unset the equality passes, the previews keep quoting, and the execution entry reverts
    ///         at the SP's zero-address gate instead of at the router gate. Both genesis entries share
    ///         the same thin-forward tail, so the SY entry pins the execution side.
    function test_PreviewsQuoteWhenBothLaunchersUnsetWhileExecutionReverts() external {
        _setLaunchersInParity(address(0));

        assertGt(router.previewStakeFromSY(address(position), 10e18), 0, "unset-launcher parity must still quote SY");
        assertGt(
            router.previewStakeFromToken(address(position), address(underlying), 10e18),
            0,
            "unset-launcher parity must still quote the token leg"
        );

        vm.prank(user);
        vm.expectRevert(IOutrunStakeManager.GenesisLauncherNotSet.selector);
        router.genesisBySY(address(position), 10e18, VERSE_ID, user, 0);
    }

    // --------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------

    /// @dev Deploys a fresh single-reserve PSM proxy with a max stock cap and zero fees, bound to
    ///      `uAsset_` and `reserve_` and owned by `owner`.
    function _deployPSM(address uAsset_, address reserve_) internal returns (OutrunPSMUpgradeable psm_) {
        psm_ = OutrunPSMUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunPSMUpgradeable()),
                abi.encodeCall(
                    OutrunPSMUpgradeable.initialize,
                    (uAsset_, reserve_, owner, makeAddr("psmFeeRecipient"), type(uint256).max, 0, 0)
                )
            )
        );
    }

    /// @dev Rotates both launcher registries to `newLauncher` in lockstep, preserving the
    ///      SP/router launcher parity the SP-path genesis gate requires.
    function _setLaunchersInParity(address newLauncher) internal {
        vm.startPrank(owner);
        position.setGenesisLauncher(newLauncher);
        // Launcher parity must hold on the SP path too: keep the router registry in lockstep.
        router.setMemeverseLauncher(newLauncher);
        vm.stopPrank();
    }

    /// @dev Asserts the router holds no residual uAsset, no residual input token (NATIVE resolves to the
    ///      router's native balance), and no leftover launcher allowance after a genesis flow.
    function _assertGenesisLeftNoResidual(address inputToken) internal view {
        assertEq(uAsset.balanceOf(address(router)), 0, "router kept residual uAsset");
        assertEq(uAsset.allowance(address(router), address(launcher)), 0, "launcher allowance not cleared");
        uint256 inputLeft =
            inputToken == NATIVE ? address(router).balance : IERC20(inputToken).balanceOf(address(router));
        assertEq(inputLeft, 0, "router kept a residual input-token balance");
    }

    /// @dev Asserts no position with id 1 exists (a zero owner marks a missing position).
    function _assertNoPositionCreated() internal view {
        (address positionOwner,,,,) = position.positions(1);
        assertEq(positionOwner, address(0), "no position may exist");
    }
}

/**
 * @title OutrunRouterTestNativeValueGate
 * @notice Anchors the entry-top placement of the router's `msg.value` gate: a wrong `msg.value`
 *     surfaces before the PSM registry gate on a multi-fault input.
 * @dev Sibling of `OutrunRouterTest` in this shared file rather than another member function:
 *     the consolidated contract sits at a solc 0.8.35 via-ir assembly-tag ceiling ("Tag too large
 *     for reserved space" ICE on any added test function), so further router tests grow in fresh
 *     contracts. The check under test runs before any registry read, so a minimal fixture with no
 *     PSM registration suffices: every pair is unregistered against a fresh router.
 */
contract OutrunRouterTestNativeValueGate is Test {
    bytes4 internal constant NATIVE_AMOUNT_MISMATCH_SELECTOR = NativeAmountMismatch.selector;
    uint256 internal constant VERSE_ID = 42;

    RouterMockUAsset internal uAsset;
    OutrunRouter internal router;
    address internal user = address(0xB0B);

    function setUp() external {
        uAsset = new RouterMockUAsset();
        router = new OutrunRouter(makeAddr("owner"), makeAddr("launcher"));
        vm.deal(user, 1 ether);
    }

    /// @notice The native-value check moved to the entry top: a wrong `msg.value` now surfaces
    ///         before the PSM registry gate for a multi-fault input.
    function test_RevertIf_GenesisByPSMNativeValueCheckPrecedesRegistryGate() external {
        vm.prank(user);
        // 未注册的 (uAsset, reserve) 且 msg.value 错误：期望 native 错误而非 UnregisteredPsm。
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByPSM{value: 1}(address(uAsset), address(0xBEEF), 10e18, VERSE_ID, user);
    }
}

/**
 * @title OutrunRouterCombinedEntryTest
 * @notice Combined-entrypoint coverage: the FundInput validation matrix (family-scoped source
 *     gating and zero-field gating, both rejected before any funds move), the full 12-combo
 *     end-to-end matrix (#1-#6 normal family: {UAsset, Psm, Stake} genesis x {UAsset, Psm}
 *     preorder; #7-#12 leveraged family: {UAsset, Psm, Credit} genesis x {UAsset, Psm} preorder)
 *     with the summed native accounting (msg.value == sum of per-leg native requirements,
 *     fee-adjusted mint output credited by the preorder leg, and oversize native sums reverting
 *     the named value-gate error instead of an arithmetic panic), the stake-funded genesis
 *     sub-paths (the tokenIn deposit through SY.deposit with both slippage floors and the
 *     token == canonical-SY direct charge in SY units that skips the deposit), the stake-leg
 *     verse-SP uAsset family binding (a foreign-family SP reverts RouterTargetMismatch before
 *     any pull), and the credit-funded leveraged interest legs (combinations #11, #12:
 *     factory-resolved credit pull escrowed by POLend, the cached-token divergence fail-closed,
 *     and the unresolved-factory rejection).
 * @dev Sibling of `OutrunRouterTest` for the same solc 0.8.35 via-ir assembly-tag ceiling that
 *     froze the parent contract (see `OutrunRouterTestNativeValueGate`); inherits the parent
 *     fixture (so every parent test re-runs in this context) and extends it only with the
 *     test-owned uAsset minting cap. The POLend market is wired per-test via
 *     `_wirePolendFixture` instead of in setUp: inherited parent tests assert a pristine
 *     `router.polend() == address(0)` start. The credit token and its factory are setUp-scoped
 *     (inert to the parent tests); only the POLend-side wiring rides `_wirePolendFixture`.
 */
contract OutrunRouterCombinedEntryTest is OutrunRouterTest {
    MockPOLend internal polend;
    RouterMockERC20 internal credit;
    MockCreditFactory internal creditFactory;

    function setUp() public virtual override {
        super.setUp();
        // This contract owns the mock uAsset: open a minting cap so tests can mint user-side uAsset
        // (mirrors the parent fixture's cap grant to the position).
        uAsset.setMintingCap(address(this), type(uint128).max);
        // Credit fixture: the family credit token resolved by the mock factory and escrowed by
        // POLend. RouterMockERC20 exposes an open faucet mint, so the user-side pile is minted
        // directly here (individual tests may rewire the factory or the cached token).
        credit = new RouterMockERC20("Mock Genesis Credit", "mGC");
        creditFactory = new MockCreditFactory(address(credit));
        credit.mint(user, 1e24);
        vm.prank(user);
        credit.approve(address(router), type(uint256).max);
    }

    /// @dev Wires the leveraged-family fixture: a POLend market bound to the family uAsset, serving
    ///      the verse, with its credit resolution pointed at the setUp-scoped factory and its hot
    ///      path pulling the cached credit token. Per-test (not setUp) so inherited parent tests
    ///      keep their pristine `router.polend() == address(0)` assumption.
    function _wirePolendFixture() internal {
        polend = new MockPOLend(address(uAsset), 1e17);
        polend.setMarketUAsset(VERSE_ID, address(uAsset));
        polend.setCreditWiring(address(creditFactory), address(credit));
        vm.prank(owner);
        router.setPolend(address(polend));
    }

    /// @notice 组合 #1：UAsset 创世 + UAsset 预购，一笔原子完成，两条腿各记名 user。
    function test_CombinedUAssetGenesisAndUAssetPreorder() external {
        uint256 genesisAmount = 10e18;
        uint256 preorderAmount = 2e18;
        uAsset.mint(user, 100e18);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);

        router.genesisAndPreorder(
            VERSE_ID,
            IOutrunRouter.FundInput({
                source: IOutrunRouter.FundSource.UAsset,
                token: address(0),
                amount: genesisAmount,
                sp: address(0),
                minSyOut: 0,
                minUAssetMinted: 0
            }),
            IOutrunRouter.FundInput({
                source: IOutrunRouter.FundSource.UAsset,
                token: address(0),
                amount: preorderAmount,
                sp: address(0),
                minSyOut: 0,
                minUAssetMinted: 0
            }),
            user
        );
        vm.stopPrank();

        (, uint256 lastGenesisAmount, address lastGenesisUser) = launcher.snapshot();
        (, uint256 lastPreorderBase, address lastPreorderUser) = launcher.preorderSnapshot();
        assertEq(lastGenesisAmount, genesisAmount, "genesis leg credited");
        assertEq(lastGenesisUser, user, "genesis user");
        assertEq(lastPreorderBase, preorderAmount, "preorder leg credited");
        assertEq(lastPreorderUser, user, "preorder user");
        assertEq(uAsset.balanceOf(address(launcher)), genesisAmount + preorderAmount, "launcher holds both legs");
        assertEq(uAsset.balanceOf(address(router)), 0, "no uAsset residual on router");
        assertEq(uAsset.allowance(address(router), address(launcher)), 0, "no allowance residual");
    }

    /// @notice 组合 #7：杠杆族 UAsset 利息腿 + UAsset 预购。
    function test_CombinedLeveragedUAssetAndUAssetPreorder() external {
        _wirePolendFixture();
        uint256 interest = 3e18;
        uint256 preorderAmount = 1e18;
        uAsset.mint(user, 100e18);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);

        router.leveragedGenesisAndPreorder(VERSE_ID, _fundUAsset(interest), _fundUAsset(preorderAmount), user);
        vm.stopPrank();

        (, uint256 lastInterest,) = polend.interestSnapshot();
        (, uint256 lastPreorderBase,) = launcher.preorderSnapshot();
        assertEq(lastInterest, interest, "polend interest credited");
        assertEq(lastPreorderBase, preorderAmount, "preorder credited");
    }

    /// @notice 组合 #8：杠杆族 UAsset 利息腿 + PSM 预购（ERC20 reserve）；利息入 POLend，预购 mint 入 launcher。
    function test_CombinedLeveragedUAssetAndPsmPreorder() external {
        _wirePolendFixture();
        uint256 interest = 3e18;
        uint256 preorderReserve = 2e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, interest);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        router.leveragedGenesisAndPreorder(
            VERSE_ID, _fundUAsset(interest), _fundPsm(address(underlying), preorderReserve), user
        );
        vm.stopPrank();

        (, uint256 lastInterest,) = polend.interestSnapshot();
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(lastInterest, interest, "polend interest credited");
        assertEq(uAsset.balanceOf(address(polend)), interest, "interest escrowed in polend");
        assertEq(p, preorderReserve, "psm preorder credited the fee-free mint");
        assertEq(uAsset.balanceOf(address(launcher)), preorderReserve, "launcher holds the preorder mint");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore - preorderReserve, "caller paid the preorder reserve");
    }

    /// @notice 组合 #9：杠杆族 PSM 利息腿 + UAsset 预购；零费 mint 全额付息，预购按 uAsset 拉取。
    function test_CombinedLeveragedPsmAndUAssetPreorder() external {
        _wirePolendFixture();
        uint256 interestReserve = 4e18;
        uint256 preorderAmount = 1e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, preorderAmount);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        router.leveragedGenesisAndPreorder(
            VERSE_ID, _fundPsm(address(underlying), interestReserve), _fundUAsset(preorderAmount), user
        );
        vm.stopPrank();

        (, uint256 lastInterest,) = polend.interestSnapshot();
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(lastInterest, interestReserve, "fee-free mint paid as interest in full");
        assertEq(uAsset.balanceOf(address(polend)), interestReserve, "interest escrowed in polend");
        assertEq(p, preorderAmount, "uAsset preorder credited");
        assertEq(uAsset.balanceOf(address(launcher)), preorderAmount, "launcher holds the preorder pull");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore - interestReserve, "caller paid the interest reserve");
    }

    /// @notice 组合 #2：UAsset 创世 + PSM 预购；预购额是扣 tin 后的 mint 输出，不是 reserve 输入量。
    function test_CombinedUAssetGenesisAndPsmPreorderFeeAdjustedPreorderAmount() external {
        vm.prank(owner);
        psm.setFees(1e16, 0); // 1% mint fee
        uint256 genesisAmount = 10e18;
        uint256 reserveIn = 10e18;
        uint256 expectedPreorder = IPSM(address(psm)).quoteMint(reserveIn);
        uAsset.mint(user, 100e18);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);

        router.genesisAndPreorder(VERSE_ID, _fundUAsset(genesisAmount), _fundPsm(address(underlying), reserveIn), user);
        vm.stopPrank();

        (, uint256 lastPreorderBase,) = launcher.preorderSnapshot();
        assertEq(lastPreorderBase, expectedPreorder, "preorder credited the fee-adjusted mint output");
        (, uint256 lastGenesisAmount,) = launcher.snapshot();
        assertEq(lastGenesisAmount, genesisAmount, "genesis leg exact");
    }

    /// @notice 组合 #3：Psm 创世（ERC20 reserve，零费）+ UAsset 预购；两条腿的 launcher 记录各自精确。
    function test_CombinedPsmGenesisAndUAssetPreorderErc20() external {
        uint256 genesisReserve = 5e18;
        uint256 preorderAmount = 3e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, preorderAmount);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        router.genesisAndPreorder(
            VERSE_ID, _fundPsm(address(underlying), genesisReserve), _fundUAsset(preorderAmount), user
        );
        vm.stopPrank();

        (, uint256 g, address genesisUser) = launcher.snapshot();
        (, uint256 p, address preorderUser) = launcher.preorderSnapshot();
        assertEq(g, genesisReserve, "genesis credited the fee-free face-value mint");
        assertEq(genesisUser, user, "genesis user");
        assertEq(p, preorderAmount, "preorder credited the pulled uAsset");
        assertEq(preorderUser, user, "preorder user");
        assertEq(uAsset.balanceOf(address(launcher)), genesisReserve + preorderAmount, "launcher holds both legs");
        assertEq(
            underlying.balanceOf(user), userUnderlyingBefore - genesisReserve, "caller paid only the genesis reserve"
        );
        assertEq(uAsset.balanceOf(address(router)), 0, "no uAsset residual on router");
    }

    /// @notice 组合 #10 native：杠杆 PSM 腿 + PSM 预购腿同用 native reserve，msg.value = 两腿之和。
    function test_CombinedPsmGenesisAndPsmPreorderNativeSum() external {
        _wirePolendFixture();
        uint256 interestReserve = 2e18;
        uint256 preorderReserve = 1e18;
        vm.startPrank(user);
        router.leveragedGenesisAndPreorder{value: interestReserve + preorderReserve}(
            VERSE_ID, _fundPsm(NATIVE, interestReserve), _fundPsm(NATIVE, preorderReserve), user
        );
        vm.stopPrank();
        assertEq(address(psmNative).balance, interestReserve + preorderReserve, "both native legs reached the PSM");
        (, uint256 lastPreorderBase,) = launcher.preorderSnapshot();
        assertEq(lastPreorderBase, preorderReserve, "native PSM preorder fee-free exact");
    }

    /// @notice 组合 #4：双腿同 ERC20 reserve，两次 mint 各自独立完成消费断言。
    function test_CombinedPsmGenesisAndPsmPreorderErc20() external {
        vm.startPrank(user);
        router.genesisAndPreorder(
            VERSE_ID, _fundPsm(address(underlying), 5e18), _fundPsm(address(underlying), 2e18), user
        );
        vm.stopPrank();
        (, uint256 g,) = launcher.snapshot();
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(g, 5e18, "genesis mint exact (fee-free)");
        assertEq(p, 2e18, "preorder mint exact (fee-free)");
        assertEq(uAsset.balanceOf(address(router)), 0, "no residual between legs");
    }

    /// @notice 组合 #5：Stake 创世（tokenIn 经 SY.deposit 的 deposit 子路径）+ UAsset 预购。
    /// @dev 同 #6 的 mock 平价事实：launcher 收款 = tokenInAmount + 预购 uAsset，仓位按价值平价开立。
    function test_CombinedStakeTokenInLegAndUAssetPreorder() external {
        uint256 tokenInAmount = 7e18;
        uint256 preorderAmount = 2e18;
        uAsset.mint(user, preorderAmount);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        router.genesisAndPreorder(
            VERSE_ID,
            _fundStakeWithMins(address(position), address(underlying), tokenInAmount, 1, 1),
            _fundUAsset(preorderAmount),
            user
        );
        vm.stopPrank();

        (address positionOwner, uint256 syStaked, uint256 principalDebt,,) = position.positions(1);
        assertEq(positionOwner, user, "position opened for user");
        assertEq(syStaked, tokenInAmount, "deposit sub-path collateral recorded");
        assertEq(principalDebt, tokenInAmount, "parity principal debt");
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(p, preorderAmount, "uAsset preorder credited");
        assertEq(
            uAsset.balanceOf(address(launcher)),
            tokenInAmount + preorderAmount,
            "launcher holds the parity mint and the preorder pull"
        );
        assertEq(uAsset.balanceOf(user), 0, "caller's preorder uAsset fully consumed");
    }

    /// @notice 组合 #6：生息资产（tokenIn 经 SY.deposit）创世 + PSM 预购；SP 侧开仓并直送 launcher。
    /// @dev mock 平价事实：RouterMockSY 以 1:1 存入、真实 SP 以价值平价 1:1 铸 uAsset 交付同一 mock
    ///      launcher、PSM fee 起始为零——launcher 收款可精确断言为 tokenInAmount + preorderReserve。
    function test_CombinedStakeTokenInLegAndPsmPreorder() external {
        uint256 tokenInAmount = 7e18;
        uint256 preorderReserve = 2e18;
        vm.startPrank(user);
        router.genesisAndPreorder(
            VERSE_ID,
            _fundStakeWithMins(address(position), address(underlying), tokenInAmount, 1, 1),
            _fundPsm(address(underlying), preorderReserve),
            user
        );
        vm.stopPrank();
        assertEq(
            uAsset.balanceOf(address(launcher)),
            tokenInAmount + preorderReserve,
            "stake parity mint + fee-free PSM preorder both reached the launcher"
        );
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(p, preorderReserve, "psm preorder exact");
    }

    /// @notice Review Focus 3：token == SP 的 canonical SY 时按 SY 单位直充，不经 deposit/minSyOut。
    function test_CombinedStakeDirectSYLegSkipsDeposit() external {
        uint256 syIn = 4e18;
        uint256 preorderReserve = 1e18;
        // mintShares backs user's shares 1:1 with underlying inside the SY, so "no deposit ran" is a
        // delta assertion: the SY's underlying balance must be untouched by this call.
        uint256 syUnderlyingBefore = underlying.balanceOf(address(sy));
        vm.startPrank(user);
        router.genesisAndPreorder(
            VERSE_ID,
            _fundStake(address(position), address(sy), syIn),
            _fundPsm(address(underlying), preorderReserve),
            user
        );
        vm.stopPrank();
        // 直充路径不消耗 underlying：SP 收到的 SY 就是 syIn 本金，launcher 收款 = syIn + 预购 mint。
        assertEq(sy.balanceOf(address(position)), syIn, "SY transferred to the SP without a deposit");
        assertEq(underlying.balanceOf(address(sy)), syUnderlyingBefore, "no deposit consumed the underlying token");
        assertEq(
            uAsset.balanceOf(address(launcher)), syIn + preorderReserve, "parity stake + fee-free preorder delivered"
        );
    }

    /// @notice SR-001：Stake 腿家族绑定——SP 绑定外族 uAsset 时，必须先于任何拉取以
    ///         RouterTargetMismatch（verse↔SP 家族三方负载）拒绝。
    /// @dev 外族 SP 按 setUp 模式部署（同一 trusted SY 对 + launcher parity + 开放 mint cap），
    ///      使 uAsset 家族成为唯一分歧：修复前调用会先拉 SY 并在 launcher 的外族 transferFrom
    ///      处以无关错误回滚，修复后在拉取前精确命中家族错误。
    function test_RevertIf_CombinedStakeLegOnForeignFamilySP() external {
        RouterMockUAsset foreignUAsset = new RouterMockUAsset();
        OutrunStakingPositionUpgradeable foreignPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(foreignUAsset), treasury)
            )
        );
        vm.startPrank(owner);
        router.setTrustedSP(address(foreignPosition), address(sy));
        foreignPosition.setGenesisLauncher(address(launcher));
        vm.stopPrank();
        foreignUAsset.setMintingCap(address(foreignPosition), type(uint128).max);
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ROUTER_TARGET_MISMATCH_SELECTOR, address(foreignPosition), address(uAsset), address(foreignUAsset)
            )
        );
        router.genesisAndPreorder(
            VERSE_ID, _fundStake(address(foreignPosition), address(sy), 1e18), _fundUAsset(1e18), user
        );

        assertEq(sy.balanceOf(user), userSYBefore, "family mismatch must reject before any SY is pulled");
        assertEq(sy.balanceOf(address(foreignPosition)), 0, "foreign SP must hold no SY");
        assertEq(sy.balanceOf(address(router)), 0, "router must hold no SY from the rejected leg");
    }

    /// @notice 组合 #11：Credit 利息腿 + UAsset 预购；credit 全额进入 POLend。
    function test_CombinedCreditInterestAndUAssetPreorder() external {
        _wirePolendFixture();
        uint256 creditIn = 6e18;
        uAsset.mint(user, 100e18);
        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundCredit(creditIn), _fundUAsset(1e18), user);
        vm.stopPrank();
        (, uint256 lastCreditAmount,) = polend.creditSnapshot();
        assertEq(lastCreditAmount, creditIn, "polend received the credit interest");
        assertEq(credit.balanceOf(address(polend)), creditIn, "credit escrowed in polend");
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(p, 1e18, "preorder credited");
    }

    /// @notice 组合 #12：Credit 利息腿 + PSM 预购；credit 全额进入 POLend，预购走 PSM mint。
    function test_CombinedCreditInterestAndPsmPreorder() external {
        _wirePolendFixture();
        uint256 creditIn = 6e18;
        uint256 preorderReserve = 2e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        vm.startPrank(user);
        router.leveragedGenesisAndPreorder(
            VERSE_ID, _fundCredit(creditIn), _fundPsm(address(underlying), preorderReserve), user
        );
        vm.stopPrank();

        (, uint256 lastCreditAmount,) = polend.creditSnapshot();
        (, uint256 p,) = launcher.preorderSnapshot();
        assertEq(lastCreditAmount, creditIn, "polend received the credit interest");
        assertEq(credit.balanceOf(address(polend)), creditIn, "credit escrowed in polend");
        assertEq(p, preorderReserve, "psm preorder credited the fee-free mint");
        assertEq(uAsset.balanceOf(address(launcher)), preorderReserve, "launcher holds the preorder mint");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore - preorderReserve, "caller paid the preorder reserve");
    }

    /// @notice Review Focus 5：factory 换绑后 POLend 缓存 token 与 router 解析不一致 → POLend 内
    ///         safeTransferFrom（router 对缓存 token 零 allowance）整笔回滚。
    function test_CombinedCreditLegCachedTokenDivergenceReverts() external {
        _wirePolendFixture();
        RouterMockERC20 divergent = new RouterMockERC20("Divergent Credit", "dGC");
        polend.setCreditWiring(address(creditFactory), address(divergent));
        vm.prank(user);
        vm.expectRevert();
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundCredit(1e18), _fundUAsset(1e18), user);
    }

    /// @notice 该 uAsset 无 credit 合约：解析为零即拒，先于任何拉取。
    function test_RevertIf_CombinedCreditUnresolved() external {
        _wirePolendFixture();
        polend.setCreditWiring(address(new MockCreditFactory(address(0))), address(credit));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.NoCreditForUAsset.selector, address(uAsset)));
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundCredit(1e18), _fundUAsset(1e18), user);
    }

    /// @notice native 总量错配（少付）整笔拒绝。
    function test_RevertIf_CombinedNativeUnderfunded() external {
        vm.startPrank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisAndPreorder{value: 1}(VERSE_ID, _fundPsm(NATIVE, 1e18), _fundPsm(NATIVE, 1e18), user);
        vm.stopPrank();
    }

    /// @notice LR-003：两条 native 腿之和溢出 uint256（对抗域输入）：求和回绕后不等于 msg.value，
    ///         按命名错误 NativeAmountMismatch 拒绝而非算术 Panic(0x11)，且先于任何资金移动。
    function test_RevertIf_CombinedNativeLegSumOverflowsUint256() external {
        vm.prank(user);
        // type(uint256).max + 2 回绕为 1，与零 msg.value 不等：值门以命名错误生效。
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisAndPreorder(VERSE_ID, _fundPsm(NATIVE, type(uint256).max), _fundPsm(NATIVE, 2), user);

        assertEq(address(router).balance, 0, "failed call must not move any native into the flow");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
    }

    /// @notice 族矩阵：普通族 Credit / 杠杆族 Stake / 预购腿 Stake|Credit 全部在资金移动前拒绝。
    function test_RevertIf_CombinedFamilyMatrixViolations() external {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundSourceNotAllowed.selector, IOutrunRouter.FundSource.Credit, false)
        );
        router.genesisAndPreorder(VERSE_ID, _fundCredit(1e18), _fundUAsset(1e18), user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundSourceNotAllowed.selector, IOutrunRouter.FundSource.Stake, true)
        );
        router.leveragedGenesisAndPreorder(
            VERSE_ID, _fundStake(address(position), address(sy), 1e18), _fundUAsset(1e18), user
        );
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundSourceNotAllowed.selector, IOutrunRouter.FundSource.Stake, false)
        );
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(1e18), _fundStake(address(position), address(sy), 1e18), user);
        vm.stopPrank();
    }

    /// @notice 强制零字段：UAsset 来源带 token/sp/min 违规即拒。
    function test_RevertIf_CombinedZeroFieldViolations() external {
        vm.startPrank(user);
        IOutrunRouter.FundInput memory bad = _fundUAsset(1e18);
        bad.token = address(0xBEEF);
        // Full-data expectation: FundFieldMustBeZero carries a FundSource argument, and a bare
        // selector only matches parameterless errors under foundry's strict expectRevert.
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.UAsset)
        );
        router.genesisAndPreorder(VERSE_ID, bad, _fundUAsset(1e18), user);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------
    // FundInput helpers
    // --------------------------------------------------------------------------

    function _fundUAsset(uint256 amount) internal pure returns (IOutrunRouter.FundInput memory f) {
        f = IOutrunRouter.FundInput(IOutrunRouter.FundSource.UAsset, address(0), amount, address(0), 0, 0);
    }

    function _fundPsm(address reserve, uint256 amount) internal pure returns (IOutrunRouter.FundInput memory f) {
        f = IOutrunRouter.FundInput(IOutrunRouter.FundSource.Psm, reserve, amount, address(0), 0, 0);
    }

    function _fundStake(address sp, address tokenIn, uint256 amount)
        internal
        pure
        returns (IOutrunRouter.FundInput memory f)
    {
        f = IOutrunRouter.FundInput(IOutrunRouter.FundSource.Stake, tokenIn, amount, sp, 0, 0);
    }

    /// @dev `_fundStake` plus the two stake-only slippage floors (`minSyOut`/`minUAssetMinted`).
    function _fundStakeWithMins(address sp, address tokenIn, uint256 amount, uint256 minSyOut, uint256 minUAssetMinted)
        internal
        pure
        returns (IOutrunRouter.FundInput memory f)
    {
        f = IOutrunRouter.FundInput(IOutrunRouter.FundSource.Stake, tokenIn, amount, sp, minSyOut, minUAssetMinted);
    }

    function _fundCredit(uint256 amount) internal pure returns (IOutrunRouter.FundInput memory f) {
        f = IOutrunRouter.FundInput(IOutrunRouter.FundSource.Credit, address(0), amount, address(0), 0, 0);
    }
}

/**
 * @title PairDriftPSM
 * @notice Mock PSM whose uAsset and reserve bindings can each be flipped after registration.
 * @dev Partial mock: models only the `uAsset()` / `reserveToken()` getters with test-settable
 *      bindings, for registration checks and the router's per-call binding re-reads. Unmodeled:
 *      mint, quoteMint, caps, fees, and any other IPSM seam — the router reverts at the binding
 *      re-reads before reaching them.
 */
contract PairDriftPSM {
    address internal boundUAsset;
    address internal boundReserve;

    constructor(address uAsset_, address reserve_) {
        boundUAsset = uAsset_;
        boundReserve = reserve_;
    }

    /// @notice Flips the reported uAsset binding to model a drifted PSM.
    function setBoundUAsset(address uAsset_) external {
        boundUAsset = uAsset_;
    }

    /// @notice Flips the reported reserve binding to model a drifted PSM.
    function setBoundReserve(address reserve_) external {
        boundReserve = reserve_;
    }

    function uAsset() external view returns (address) {
        return boundUAsset;
    }

    function reserveToken() external view returns (address) {
        return boundReserve;
    }
}

/**
 * @title PairDonatingPSM
 * @notice Mock PSM that mints its uAsset output to a fixed donatee instead of the requested receiver.
 * @dev Partial mock: models only the `uAsset()` / `reserveToken()` getters and a lying `mint` that
 *      reports the full output while the minted uAsset lands on the donatee (so the caller's balance
 *      stays at its pre-mint baseline). Unmodeled: reserve pulls, fees, caps, and quote seams — the
 *      router's post-genesis assertion fires before any of them would matter.
 */
contract PairDonatingPSM {
    RouterMockUAsset internal immutable uAssetToken;
    address internal immutable boundReserve;
    address internal immutable donatee;

    constructor(address uAsset_, address reserve_, address donatee_) {
        uAssetToken = RouterMockUAsset(uAsset_);
        boundReserve = reserve_;
        donatee = donatee_;
    }

    function uAsset() external view returns (address) {
        return address(uAssetToken);
    }

    function reserveToken() external view returns (address) {
        return boundReserve;
    }

    function mint(address, uint256 amountIn) external payable returns (uint256 amountOut) {
        amountOut = amountIn;
        // Report the full amount while the minted uAsset never reaches the caller: the caller's balance
        // returns to its pre-mint baseline, so only the residual launcher allowance can catch the cheat.
        uAssetToken.reserveMint(donatee, amountOut);
    }
}
