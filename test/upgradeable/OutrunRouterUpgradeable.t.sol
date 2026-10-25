// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {GenesisGateLib} from "../../src/libraries/GenesisGateLib.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {OutrunPSMUpgradeable} from "../../src/psm/OutrunPSMUpgradeable.sol";
import {IPSM} from "../../src/psm/interfaces/IPSM.sol";
import {NativeAmountMismatch} from "../../src/libraries/TokenHelper.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";
import {
    MockGenesisLauncher,
    MockGenesisPartialLauncher,
    MockGenesisEmptyLauncher,
    MockGenesisTransferBackLauncher,
    MockGenesisRevertingLauncher,
    MockPreorderRevertingLauncher,
    MockPreorderPartialLauncher,
    MockPreorderEmptyLauncher,
    MockPreorderTransferBackLauncher,
    MockPOLend,
    MockCreditRegistry
} from "./mocks/LauncherMocks.sol";
import {RouterMockSY, RouterMockERC20, RouterMockUAsset} from "./mocks/RouterMocks.sol";

/**
 * @title OutrunRouterTestBase
 * @notice Shared fixtures for every router suite in this file: the mock stack (underlying / SY /
 *     uAsset / dual-leg PSM / staking position / router / launcher), the selector constants, and
 *     the cross-suite assertion helpers.
 * @dev Declared abstract so inheriting scenario suites reuse the fixtures WITHOUT re-executing
 *      the base suite's test functions — Foundry runs inherited `test*` functions in every
 *      concrete contract, which previously duplicated the base suite once per inheriting suite.
 */
abstract contract OutrunRouterTestBase is Test {
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

    // --------------------------------------------------------------------------
    // Shared helpers (inherited by every router suite in this file)
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
contract OutrunRouterTest is OutrunRouterTestBase {
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

    /// @notice The launcher setter performs no zero-address check and no code check: the zero
    ///         address and a codeless EOA both register, then the original launcher is restored.
    function test_SetMemeverseLauncherAcceptsZeroAndCodelessAddress() external {
        address eoaLauncher = address(0x1234);
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.SetMemeverseLauncher(address(launcher), address(0));
        router.setMemeverseLauncher(address(0));
        assertEq(router.memeverseLauncher(), address(0), "zero launcher stored without a code check");

        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.SetMemeverseLauncher(address(0), eoaLauncher);
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
        // Unregistered (uAsset, reserve) and wrong msg.value: expect the native error, not UnregisteredPsm.
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisByPSM{value: 1}(address(uAsset), address(0xBEEF), 10e18, VERSE_ID, user);
    }

    /// @notice Same entry-top ordering for the leveraged PSM genesis: a wrong `msg.value` surfaces
    ///         before both the PSM registry gate and the POLend gate on a multi-fault input.
    function test_RevertIf_LeveragedGenesisByPSMNativeValueCheckPrecedesRegistryGates() external {
        vm.prank(user);
        // Unregistered (uAsset, reserve), wrong msg.value, and no POLend wired: expect the native
        // error, not UnregisteredPsm or PolendNotSet.
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.leveragedGenesisByPSM{value: 1}(address(uAsset), address(0xBEEF), 10e18, VERSE_ID, user);
    }

    /// @notice Same entry-top ordering for the preorder-only PSM entry: a wrong `msg.value`
    ///         surfaces before the PSM registry gate on a multi-fault input.
    function test_RevertIf_PreorderByPSMNativeValueCheckPrecedesRegistryGate() external {
        vm.prank(user);
        // Unregistered (uAsset, reserve) and wrong msg.value: expect the native error, not UnregisteredPsm.
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.preorderByPSM{value: 1}(address(uAsset), address(0xBEEF), 10e18, VERSE_ID, user);
    }
}

/**
 * @title OutrunRouterCombinedEntryBase
 * @notice Combined-entry fixtures: extends the base router fixture with the test-owned uAsset
 *     minting cap, the family credit token plus its resolution factory, and the FundInput
 *     helpers used by the combined-entry suites.
 * @dev Fixture extending `OutrunRouterTestBase`, split out for the same solc 0.8.35 via-ir
 *     assembly-tag ceiling that froze the consolidated suite (see `OutrunRouterTestNativeValueGate`).
 *     The POLend market is wired per-test via `_wirePolendFixture` instead of in setUp, so suites
 *     that never wire it keep a pristine `router.polend() == address(0)` start; the credit token
 *     and its factory are setUp-scoped.
 */
abstract contract OutrunRouterCombinedEntryBase is OutrunRouterTestBase {
    MockPOLend internal polend;
    RouterMockERC20 internal credit;
    MockCreditRegistry internal creditFactory;

    function setUp() public virtual override {
        super.setUp();
        // This contract owns the mock uAsset: open a minting cap so tests can mint user-side uAsset
        // (mirrors the parent fixture's cap grant to the position).
        uAsset.setMintingCap(address(this), type(uint128).max);
        // Credit fixture: the family credit token resolved by the mock factory and escrowed by
        // POLend. RouterMockERC20 exposes an open faucet mint, so the user-side pile is minted
        // directly here (individual tests may rewire the factory or the cached token).
        credit = new RouterMockERC20("Mock Genesis Credit", "mGC");
        creditFactory = new MockCreditRegistry(address(credit));
        credit.mint(user, 1e24);
        vm.prank(user);
        credit.approve(address(router), type(uint256).max);
    }

    /// @dev Wires the leveraged-family fixture: a POLend market bound to the family uAsset, serving
    ///      the verse, with its credit resolution pointed at the setUp-scoped factory and its hot
    ///      path pulling the cached credit token. Per-test (not setUp) so suites that never wire it
    ///      keep a pristine `router.polend() == address(0)` start.
    function _wirePolendFixture() internal {
        polend = new MockPOLend(address(uAsset), 1e17);
        polend.setMarketUAsset(VERSE_ID, address(uAsset));
        polend.setCreditWiring(address(creditFactory), address(credit));
        vm.prank(owner);
        router.setPolend(address(polend));
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
 * @title OutrunRouterCombinedEntryTest
 * @notice Combined-entrypoint coverage: the FundInput validation matrix (family-scoped source
 *     gating and zero-field gating, both rejected before any funds move), the full end-to-end
 *     leg-pair matrix (normal family: {UAsset, Psm, Stake} genesis x {UAsset, Psm} preorder;
 *     leveraged family: {UAsset, Psm, Credit} genesis x {UAsset, Psm} preorder) with the summed
 *     native accounting (msg.value == sum of per-leg native requirements, fee-adjusted mint output
 *     credited by the preorder leg, and oversize native sums reverting the named value-gate
 *     error instead of an arithmetic panic), the stake-funded genesis sub-paths (the tokenIn
 *     deposit through SY.deposit with both slippage floors and the token == canonical-SY direct
 *     charge in SY units that skips the deposit), the stake-leg verse-SP uAsset family binding
 *     (a foreign-family SP reverts RouterTargetMismatch before any pull), and the credit-funded
 *     leveraged interest legs (factory-resolved credit pull escrowed by POLend, the cached-token
 *     divergence fail-closed, and the unresolved-factory rejection).
 */
contract OutrunRouterCombinedEntryTest is OutrunRouterCombinedEntryBase {
    /// @notice Normal family: uAsset genesis + uAsset preorder, one atomic call, each leg crediting `user`.
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

    /// @notice Leveraged family: uAsset interest leg + uAsset preorder leg.
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

    /// @notice Leveraged family: uAsset interest leg + PSM preorder (ERC20 reserve); the interest is
    ///         escrowed by POLend and the preorder mint reaches the launcher.
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

    /// @notice Leveraged family: PSM interest leg + uAsset preorder; the fee-free mint pays the
    ///         interest in full and the preorder pulls uAsset.
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

    /// @notice Normal family: uAsset genesis + PSM preorder; the preorder base is the fee-adjusted
    ///         mint output, not the reserve input amount.
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

    /// @notice Normal family: PSM genesis (ERC20 reserve, fee-free) + uAsset preorder; the launcher's
    ///         records are exact for each leg.
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

    /// @notice Leveraged family, native: the PSM interest leg and PSM preorder leg share the
    ///         native reserve; msg.value is the sum of both legs.
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

    /// @notice Normal family: both legs share one ERC20 reserve; each mint independently completes
    ///         its full-consumption assertion.
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

    /// @notice Normal family: stake genesis (tokenIn through the SY.deposit sub-path) + uAsset preorder.
    /// @dev Same mock parity facts as `test_CombinedStakeTokenInLegAndPsmPreorder`: the launcher
    ///      receives tokenInAmount + preorder uAsset, and the position opens at value parity.
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

    /// @notice Normal family: yield-bearing tokenIn genesis (through SY.deposit) + PSM preorder; the
    ///         SP opens the position and delivers straight to the launcher.
    /// @dev Mock parity facts: RouterMockSY deposits 1:1, the real SP mints uAsset 1:1 at value
    ///      parity to the same mock launcher, and the PSM fee starts at zero — so the launcher's
    ///      intake is exactly assertable as tokenInAmount + preorderReserve.
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

    /// @notice When the leg's token is the SP's canonical SY it is charged directly in SY units,
    ///         bypassing deposit/minSyOut.
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
        // The direct-charge path consumes no underlying: the SP receives the syIn principal itself,
        // and the launcher intake is syIn + the preorder mint.
        assertEq(sy.balanceOf(address(position)), syIn, "SY transferred to the SP without a deposit");
        assertEq(underlying.balanceOf(address(sy)), syUnderlyingBefore, "no deposit consumed the underlying token");
        assertEq(
            uAsset.balanceOf(address(launcher)), syIn + preorderReserve, "parity stake + fee-free preorder delivered"
        );
    }

    /// @notice Stake-leg family binding: when the SP is bound to a foreign-family uAsset, the call
    ///         must be rejected with RouterTargetMismatch (the verse↔SP family three-party payload)
    ///         before any pull.
    /// @dev The foreign SP is deployed like the setUp fixture (same trusted-SY pair, launcher
    ///      parity, open mint cap) so the uAsset family is the only divergence: before the fix the
    ///      call pulled the SY first and reverted with an unrelated error at the launcher's
    ///      foreign-family transferFrom; after the fix it hits the family error exactly, pre-pull.
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

    /// @notice Leveraged family: credit interest leg + uAsset preorder; the credit reaches POLend in full.
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

    /// @notice Leveraged family: credit interest leg + PSM preorder; the credit reaches POLend in
    ///         full and the preorder runs through the PSM mint.
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

    /// @notice Cached-token divergence: after the factory is rewired, POLend's cached token no
    ///         longer matches the router's resolution, and POLend's own transferFrom on the cached
    ///         token reverts the whole call. The router approved the factory-resolved token while
    ///         POLend pulls its cached one, so the failure surface is the OZ allowance check on the
    ///         cached token: `ERC20InsufficientAllowance(polend, 0, creditAmount)` — the router has
    ///         pulled and approved the factory token, never the cached one.
    function test_CombinedCreditLegCachedTokenDivergenceReverts() external {
        _wirePolendFixture();
        RouterMockERC20 divergent = new RouterMockERC20("Divergent Credit", "dGC");
        polend.setCreditWiring(address(creditFactory), address(divergent));
        uint256 userCreditBefore = credit.balanceOf(user);
        uAsset.mint(user, 1e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(polend), 0, 1e18)
        );
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundCredit(1e18), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(credit.balanceOf(user), userCreditBefore, "credit pull must roll back with the call");
        assertEq(credit.balanceOf(address(polend)), 0, "polend escrow empty after the rollback");
        assertEq(divergent.balanceOf(address(polend)), 0, "no cached token reached polend");
        assertEq(credit.allowance(address(router), address(polend)), 0, "credit allowance must roll back");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "preorder pull must roll back with the call");
    }

    /// @notice No credit contract for this uAsset: a zero resolution is rejected before any pull.
    function test_RevertIf_CombinedCreditUnresolved() external {
        _wirePolendFixture();
        polend.setCreditWiring(address(new MockCreditRegistry(address(0))), address(credit));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOutrunRouter.NoCreditForUAsset.selector, address(uAsset)));
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundCredit(1e18), _fundUAsset(1e18), user);
    }

    /// @notice A native total mismatch (underpaid msg.value) rejects the whole call.
    function test_RevertIf_CombinedNativeUnderfunded() external {
        vm.startPrank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisAndPreorder{value: 1}(VERSE_ID, _fundPsm(NATIVE, 1e18), _fundPsm(NATIVE, 1e18), user);
        vm.stopPrank();
    }

    /// @notice The two native legs' sum overflows uint256 (adversarial-domain input): the wrapped sum
    ///         no longer equals msg.value, so the named NativeAmountMismatch error rejects the call
    ///         instead of an arithmetic Panic(0x11), before any funds move.
    function test_RevertIf_CombinedNativeLegSumOverflowsUint256() external {
        vm.prank(user);
        // type(uint256).max + 2 wraps to 1, which differs from the zero msg.value: the value gate
        // fires with the named error.
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisAndPreorder(VERSE_ID, _fundPsm(NATIVE, type(uint256).max), _fundPsm(NATIVE, 2), user);

        assertEq(address(router).balance, 0, "failed call must not move any native into the flow");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
    }

    /// @notice `genesisBySY`'s zero-value rule is enforced structurally by the non-payable
    ///         dispatcher: a value-carrying call reverts before the function body (and any registry
    ///         read). A low-level call (bypassing Solidity's type-level ban on value to non-payable
    ///         entrypoints) anchors that revert surface by asserting the raw failure, keeping the
    ///         removal of the unreachable explicit `_requireNoNativeValue` check
    ///         behavior-equivalent.
    function test_RevertIf_GenesisBySYCallCarriesValue() external {
        vm.prank(user);
        (bool ok,) = address(router).call{value: 1}(
            abi.encodeCall(IOutrunRouter.genesisBySY, (address(position), 1e18, VERSE_ID, user, 0))
        );
        // The non-payable dispatcher rejects the value before the function body (and any registry
        // read) runs.
        assertFalse(ok, "value-carrying call must be rejected by the non-payable dispatcher");

        _assertNoPositionCreated();
        assertEq(sy.balanceOf(address(router)), 0, "value-carrying call must not pull SY");
    }

    /// @notice Family matrix: Credit on the normal family, Stake on the leveraged family, and
    ///         Stake|Credit on the preorder leg are all rejected before any funds move.
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

    /// @notice Mandatory zero fields: a UAsset source carrying token/sp/min violations is rejected.
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
    // Registry gates / atomicity tripwire / zero fields / mixed native split /
    // wrap-to-zero edge
    // --------------------------------------------------------------------------

    /// @notice The combined leveraged entrypoint rejects with `PolendNotSet` before any funds move
    ///         when POLend is not wired (the family-level gate shares `_polendMarketGate` with the
    ///         single-leg entrypoint `leveragedGenesisByPSM`).
    function test_RevertIf_CombinedLeveragedEntryPolendNotWired() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, 1e18);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(POLEND_NOT_SET_SELECTOR);
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundPsm(address(underlying), 1e18), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "gate must fire before any reserve pull");
        assertEq(uAsset.balanceOf(user), 1e18, "gate must fire before any uAsset pull");
        assertEq(uAsset.balanceOf(address(router)), 0, "router uAsset unchanged");
        assertEq(address(router).balance, 0, "router native unchanged");
    }

    /// @notice Atomicity tripwire: the genesis leg (UAsset, full booking + pull) succeeds, the
    ///         preorder leg reverts, and the whole call rolls back — zero launcher holdings,
    ///         zeroed genesis records, unchanged caller/router balances. This pins the combined
    ///         entrypoint's atomicity promise (any leg reverting rolls back the entire call, per
    ///         EVM same-transaction revert semantics) and trips if a future refactor swallows the
    ///         preorder leg's revert surface.
    function test_CombinedGenesisLegRollsBackWhenPreorderReverts() external {
        MockPreorderRevertingLauncher preorderReverting = new MockPreorderRevertingLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(preorderReverting));
        uint256 genesisAmount = 10e18;
        uint256 preorderAmount = 2e18;
        uAsset.mint(user, genesisAmount + preorderAmount);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(MockPreorderRevertingLauncher.PreorderLauncherReverted.selector);
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(genesisAmount), _fundUAsset(preorderAmount), user);
        vm.stopPrank();

        // The genesis leg fully executed first (mock pull + booking) yet the call still rolled back:
        // zero launcher holdings, zeroed records.
        assertEq(uAsset.balanceOf(address(preorderReverting)), 0, "launcher holds zero uAsset after rollback");
        (uint256 lastVerseId, uint256 lastAmount, address lastUser) = preorderReverting.snapshot();
        assertEq(lastVerseId, 0, "no genesis verse record survived the rollback");
        assertEq(lastAmount, 0, "no genesis amount record survived the rollback");
        assertEq(lastUser, address(0), "no genesis user record survived the rollback");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "caller uAsset unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(preorderReverting)), 0, "no allowance residual");
    }

    /// @notice A combined PSM genesis leg on an unregistered (uAsset, reserve) pair is rejected
    ///         with `UnregisteredPsm` (pair-key payload) before any pull.
    function test_RevertIf_CombinedPsmGenesisLegUnregisteredPair() external {
        RouterMockERC20 strayReserve = new RouterMockERC20("Stray", "STR");
        strayReserve.mint(user, 1e18);

        vm.startPrank(user);
        strayReserve.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(UNREGISTERED_PSM_SELECTOR, address(uAsset), address(strayReserve)));
        router.genesisAndPreorder(VERSE_ID, _fundPsm(address(strayReserve), 1e18), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(strayReserve.balanceOf(user), 1e18, "failed call must not pull the reserve");
        assertEq(strayReserve.balanceOf(address(router)), 0, "failed call must not leave reserve on the router");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
    }

    /// @notice A combined PSM leg on a post-registration drifted PSM binding is rejected with
    ///         `PsmBindingMismatch` / `PsmReserveMismatch` before any pull (the drift mock follows
    ///         the parent suite's `test_RevertIf_GenesisByPSMOnPsmBindingDrift` pattern).
    function test_RevertIf_CombinedPsmLegOnPsmBindingDrift() external {
        PairDriftPSM driftPsm = new PairDriftPSM(address(uAsset), address(underlying));
        vm.prank(owner);
        router.setPsmForUAsset(address(uAsset), address(underlying), address(driftPsm));
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        // uAsset binding drift: flipped to a foreign-family address after registration.
        address driftedUAsset = address(0xDEAD);
        driftPsm.setBoundUAsset(driftedUAsset);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(PSM_BINDING_MISMATCH_SELECTOR, address(driftPsm), address(uAsset), driftedUAsset)
        );
        router.genesisAndPreorder(VERSE_ID, _fundPsm(address(underlying), 1e18), _fundUAsset(1e18), user);

        // Reserve binding drift: uAsset binding restored, then the reserve flipped.
        driftPsm.setBoundUAsset(address(uAsset));
        address driftedReserve = address(0xBEEF);
        driftPsm.setBoundReserve(driftedReserve);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PSM_RESERVE_MISMATCH_SELECTOR, address(driftPsm), address(underlying), driftedReserve
            )
        );
        router.genesisAndPreorder(VERSE_ID, _fundPsm(address(underlying), 1e18), _fundUAsset(1e18), user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "drift reverts must fire before any pull");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed calls must not mint uAsset to the router");
    }

    /// @notice A combined stake genesis leg on an SP bound to a different launcher (fixture
    ///         following the foreign-family SP deployment pattern) is rejected with
    ///         `GenesisLauncherMismatch` before any SY moves.
    function test_RevertIf_CombinedStakeLegOnLauncherMismatchSP() external {
        MockGenesisLauncher otherLauncher = new MockGenesisLauncher(address(uAsset));
        OutrunStakingPositionUpgradeable otherPosition = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, address(sy), address(uAsset), treasury)
            )
        );
        vm.startPrank(owner);
        router.setTrustedSP(address(otherPosition), address(sy));
        otherPosition.setGenesisLauncher(address(otherLauncher));
        vm.stopPrank();
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOutrunRouter.GenesisLauncherMismatch.selector, address(launcher), address(otherLauncher)
            )
        );
        router.genesisAndPreorder(
            VERSE_ID, _fundStake(address(otherPosition), address(sy), 1e18), _fundUAsset(1e18), user
        );

        assertEq(sy.balanceOf(user), userSYBefore, "parity mismatch must reject before any SY is pulled");
        assertEq(sy.balanceOf(address(otherPosition)), 0, "SP must hold no SY from the rejected leg");
        assertEq(sy.balanceOf(address(router)), 0, "router must hold no SY from the rejected leg");
    }

    /// @notice A UAsset genesis leg carrying `sp` reverts with `FundFieldMustBeZero`.
    function test_RevertIf_CombinedUAssetGenesisLegWithSp() external {
        IOutrunRouter.FundInput memory bad = _fundUAsset(1e18);
        bad.sp = address(position);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.UAsset)
        );
        router.genesisAndPreorder(VERSE_ID, bad, _fundUAsset(1e18), user);
    }

    /// @notice A UAsset genesis leg carrying `minSyOut` reverts with `FundFieldMustBeZero`.
    function test_RevertIf_CombinedUAssetGenesisLegWithMinSyOut() external {
        IOutrunRouter.FundInput memory bad = _fundUAsset(1e18);
        bad.minSyOut = 1;
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.UAsset)
        );
        router.genesisAndPreorder(VERSE_ID, bad, _fundUAsset(1e18), user);
    }

    /// @notice A preorder leg with `source = Credit` reverts with `FundSourceNotAllowed`.
    function test_RevertIf_CombinedPreorderLegCreditSource() external {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundSourceNotAllowed.selector, IOutrunRouter.FundSource.Credit, false)
        );
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(1e18), _fundCredit(1e18), user);
    }

    /// @notice Mixed legs, native (genesis) + ERC20 (preorder): `msg.value` exactly matching the
    ///         genesis leg passes the value gate; the native reaches only the genesis leg's PSM
    ///         and the ERC20 only the preorder leg, each leg's snapshots exact, zero router
    ///         residual.
    function test_CombinedNativeGenesisAndErc20PreorderMixedValueSplit() external {
        uint256 genesisNativeIn = 2e18;
        uint256 preorderReserve = 3e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        router.genesisAndPreorder{value: genesisNativeIn}(
            VERSE_ID, _fundPsm(NATIVE, genesisNativeIn), _fundPsm(address(underlying), preorderReserve), user
        );

        assertEq(address(psmNative).balance, genesisNativeIn, "native reached only the genesis leg's PSM");
        assertEq(
            userUnderlyingBefore - underlying.balanceOf(user),
            preorderReserve,
            "ERC20 reserve paid only the preorder leg"
        );
        assertEq(underlying.balanceOf(address(psm)), preorderReserve, "preorder reserve held by the ERC20 PSM");
        (, uint256 g, address genesisUser) = launcher.snapshot();
        (, uint256 p, address preorderUser) = launcher.preorderSnapshot();
        assertEq(g, genesisNativeIn, "genesis leg credited the fee-free native mint");
        assertEq(genesisUser, user, "genesis user");
        assertEq(p, preorderReserve, "preorder leg credited the fee-free ERC20 mint");
        assertEq(preorderUser, user, "preorder user");
        assertEq(uAsset.balanceOf(address(router)), 0, "no uAsset residual on router");
        assertEq(address(router).balance, 0, "no native residual on router");
    }

    /// @notice Mixed legs, overpaid: with the same leg pair, `msg.value = g + p` (overpaying
    ///         native for the ERC20 preorder leg) reverts with `NativeAmountMismatch` —
    ///         overpayment is rejected in the mixed case too, before any funds move.
    function test_RevertIf_CombinedNativeGenesisAndErc20PreorderOverpaid() external {
        uint256 genesisNativeIn = 2e18;
        uint256 preorderReserve = 3e18;

        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisAndPreorder{value: genesisNativeIn + preorderReserve}(
            VERSE_ID, _fundPsm(NATIVE, genesisNativeIn), _fundPsm(address(underlying), preorderReserve), user
        );

        assertEq(address(psmNative).balance, 0, "failed call must not move native into the PSM");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
    }

    /// @notice Wrap-to-zero edge: two native legs whose sum wraps to exactly 0 (g=1,
    ///         p=type(uint256).max) with `msg.value = 0` pass the entrypoint value gate, and the
    ///         whole call reverts at the first native forwarding (the genesis leg's PSM mint CALL
    ///         value, with the router's actual balance 0): empty revert, fail-closed, balances
    ///         unchanged.
    function test_RevertIf_CombinedNativeLegSumWrapsToZero() external {
        vm.prank(user);
        vm.expectRevert();
        router.genesisAndPreorder(VERSE_ID, _fundPsm(NATIVE, 1), _fundPsm(NATIVE, type(uint256).max), user);

        assertEq(address(router).balance, 0, "router native unchanged");
        assertEq(address(psmNative).balance, 0, "PSM native unchanged");
        assertEq(uAsset.balanceOf(address(router)), 0, "no uAsset minted to the router");
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

/**
 * @title OutrunRouterPreorderByPSMTest
 * @notice Covers the preorder-only PSM entry `preorderByPSM`: the ERC20/NATIVE reserve roundtrips
 *     (fee-adjusted mint output reaching the launcher preorder), the entry-level value gate, the
 *     zero-user guard, and the uint128 launcher-domain bound. Grows in a fresh contract because the
 *     consolidated `OutrunRouterTest` sits at the solc 0.8.35 via-ir assembly-tag ceiling.
 */
contract OutrunRouterPreorderByPSMTest is OutrunRouterTestBase {
    /// @notice ERC20 reserve leg: the caller pays `amountIn`, the PSM mints the fee-adjusted face-value
    ///         amount to the router, and the launcher preorder credits the full minted amount; no
    ///         residual stays anywhere and no genesis position is created.
    function test_PreorderByPSMERC20LegRoundtrip() external {
        vm.prank(owner);
        psm.setFees(1e16, 0); // 1% mint fee so the fee math is observable.
        uint256 amountIn = 10e18;
        uint256 expectedOut = IPSM(address(psm)).quoteMint(amountIn);
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        router.preorderByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore - amountIn, "caller did not pay the full reserve");
        assertEq(underlying.balanceOf(address(psm)), amountIn, "PSM holds the taken reserve");
        (uint256 lastVerseId, uint256 lastPreorderBase, address lastPreorderUser) = launcher.preorderSnapshot();
        assertEq(lastVerseId, VERSE_ID, "verse id forwarded");
        assertEq(lastPreorderBase, expectedOut, "preorder credited the fee-adjusted mint output");
        assertEq(lastPreorderUser, user, "preorder user credited");
        assertEq(uAsset.balanceOf(address(launcher)), expectedOut, "launcher holds the preorder mint");
        _assertGenesisLeftNoResidual(address(underlying));
        assertEq(underlying.allowance(address(router), address(psm)), 0, "PSM reserve allowance not cleared");
        _assertNoPositionCreated();
    }

    /// @notice NATIVE reserve leg: `msg.value` carries the reserve into the PSM and the minted uAsset
    ///         reaches the launcher preorder in full.
    function test_PreorderByPSMNativeLegRoundtrip() external {
        uint256 amountIn = 2e18;

        vm.prank(user);
        router.preorderByPSM{value: amountIn}(address(uAsset), NATIVE, amountIn, VERSE_ID, user);

        assertEq(address(psmNative).balance, amountIn, "native reserve stayed in the PSM");
        assertEq(uAsset.balanceOf(address(launcher)), amountIn, "launcher holds the preorder mint");
        (, uint256 lastPreorderBase,) = launcher.preorderSnapshot();
        assertEq(lastPreorderBase, amountIn, "preorder credited the fee-free mint");
        _assertGenesisLeftNoResidual(NATIVE);
    }

    /// @notice The ERC20 reserve leg rejects any attached native value.
    function test_RevertWhen_PreorderByPSMERC20LegWithValue() external {
        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.preorderByPSM{value: 1}(address(uAsset), address(underlying), 1e18, VERSE_ID, user);
    }

    /// @notice The NATIVE reserve leg requires `msg.value == amountIn` exactly.
    function test_RevertWhen_PreorderByPSMNativeLegValueMismatch() external {
        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.preorderByPSM{value: 1e18}(address(uAsset), NATIVE, 2e18, VERSE_ID, user);
    }

    /// @notice A zero credited user fails ZeroInput before any funds move.
    function test_RevertWhen_PreorderByPSMZeroUser() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.preorderByPSM(address(uAsset), address(underlying), 1e18, VERSE_ID, address(0));
        assertEq(IPSM(address(psm)).netUAssetMinted(), 0, "failed call must not move the PSM ledger");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
    }

    /// @notice A mint above the uint128 launcher domain reverts InvalidParam before the launcher
    ///         approval and the preorder call.
    function test_RevertWhen_PreorderByPSMMintsAboveUint128Max() external {
        vm.prank(user);
        vm.expectRevert(INVALID_PARAM_SELECTOR);
        router.preorderByPSM(address(uAsset), address(underlying), 4e38, VERSE_ID, user);
    }

    /// @notice A mint of exactly type(uint128).max passes the bound and is forwarded in full.
    function test_PreorderByPSMAtUint128MaxSucceeds() external {
        vm.prank(user);
        router.preorderByPSM(address(uAsset), address(underlying), MAX_UINT128, VERSE_ID, user);

        (, uint256 lastPreorderBase,) = launcher.preorderSnapshot();
        assertEq(lastPreorderBase, type(uint128).max, "preorder credited exactly the uint128 cap");
        assertEq(uAsset.balanceOf(address(launcher)), MAX_UINT128, "launcher holds the full cap amount");
    }
}

/**
 * @title OutrunRouterConsumptionFailureTest
 * @notice Failure injection into every router-side strict full-consumption post-condition: the
 *     preorder-only PSM entry (`preorderByPSM`) against partial / zero / transfer-back launcher
 *     consumption, the combined entry's preorder leg and the `_uAssetToLauncher` genesis/preorder
 *     legs against partial consumption, the leveraged family's three interest legs (uAsset, Psm,
 *     credit) against a half-pulling POLend, and the router-side path-A genesis tail against a
 *     transfer-back launcher — each asserting the exact
 *     `GenesisUAssetNotConsumed(residualBalance, residualAllowance)` payload and a full balance
 *     rollback of the already-executed legs.
 * @dev Grows in a fresh contract because the consolidated `OutrunRouterTest` sits at the solc
 *     0.8.35 via-ir assembly-tag ceiling (see `OutrunRouterTestNativeValueGate`); inherits the
 *     combined-entry fixture for the PSM/credit/POLend wiring and the FundInput helpers. The PSM
 *     fee starts at zero, so the fee-free mint equals the reserve input and every residual payload
 *     is exact.
 */
contract OutrunRouterConsumptionFailureTest is OutrunRouterCombinedEntryBase {
    /// @notice `preorderByPSM` with a launcher pulling only half of the preorder mint: the residual
    ///         balance and the residual allowance are both reported and the whole call reverts.
    function test_RevertWhen_PreorderByPSMLauncherConsumesHalf() external {
        MockPreorderPartialLauncher partialLauncher = new MockPreorderPartialLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(partialLauncher));
        uint256 amountIn = 10e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, amountIn / 2, amountIn / 2));
        router.preorderByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(partialLauncher)), 0, "half pull must roll back with the call");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds no uAsset after the rollback");
        assertEq(uAsset.allowance(address(router), address(partialLauncher)), 0, "allowance must roll back");
        assertEq(IPSM(address(psm)).netUAssetMinted(), 0, "PSM ledger must roll back");
    }

    /// @notice `preorderByPSM` with a launcher consuming none of the preorder mint: the full mint
    ///         is reported on both dimensions (balance and untouched allowance).
    function test_RevertWhen_PreorderByPSMLauncherConsumesNothing() external {
        MockPreorderEmptyLauncher emptyLauncher = new MockPreorderEmptyLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(emptyLauncher));
        uint256 amountIn = 10e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, amountIn, amountIn));
        router.preorderByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(router)), 0, "mint must roll back with the call");
        assertEq(uAsset.allowance(address(router), address(emptyLauncher)), 0, "allowance must roll back");
        (,, address recordedUser) = emptyLauncher.preorderSnapshot();
        assertEq(recordedUser, address(0), "no preorder record survived the rollback");
    }

    /// @notice `preorderByPSM` with a launcher pulling the full mint and transferring a tenth back:
    ///         the balance dimension fires with the transfer-back residual and a zero allowance.
    function test_RevertWhen_PreorderByPSMLauncherTransfersBack() external {
        MockPreorderTransferBackLauncher transferBackLauncher = new MockPreorderTransferBackLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(transferBackLauncher));
        uint256 amountIn = 10e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, amountIn / 10, 0));
        router.preorderByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(transferBackLauncher)), 0, "launcher holding must roll back");
        assertEq(uAsset.balanceOf(address(router)), 0, "transfer-back must roll back with the call");
        assertEq(uAsset.allowance(address(router), address(transferBackLauncher)), 0, "no allowance residual");
    }

    /// @notice Combined entry with a preorder leg whose launcher pulls only half of the PSM mint:
    ///         the already-completed genesis leg rolls back with the failing preorder leg.
    function test_RevertWhen_CombinedPreorderLegLauncherConsumesHalf() external {
        MockPreorderPartialLauncher partialLauncher = new MockPreorderPartialLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(partialLauncher));
        uint256 genesisAmount = 2e18;
        uint256 preorderReserve = 10e18;
        uAsset.mint(user, genesisAmount);
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, preorderReserve / 2, preorderReserve / 2)
        );
        router.genesisAndPreorder(
            VERSE_ID, _fundUAsset(genesisAmount), _fundPsm(address(underlying), preorderReserve), user
        );
        vm.stopPrank();

        // The genesis leg fully executed first (full pull + record) yet the call rolled back.
        assertEq(uAsset.balanceOf(address(partialLauncher)), 0, "launcher holds zero uAsset after rollback");
        (, uint256 recordedGenesis,) = partialLauncher.snapshot();
        assertEq(recordedGenesis, 0, "no genesis record survived the rollback");
        (,, address recordedPreorderUser) = partialLauncher.preorderSnapshot();
        assertEq(recordedPreorderUser, address(0), "no preorder record survived the rollback");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "caller uAsset unchanged after rollback");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "caller reserve unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(partialLauncher)), 0, "no allowance residual");
    }

    /// @notice Combined entry with a preorder leg whose launcher consumes none of the PSM mint:
    ///         the full mint stays as residual balance and the allowance stays untouched.
    function test_RevertWhen_CombinedPreorderLegLauncherConsumesNothing() external {
        MockPreorderEmptyLauncher emptyLauncher = new MockPreorderEmptyLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(emptyLauncher));
        uint256 genesisAmount = 2e18;
        uint256 preorderReserve = 10e18;
        uAsset.mint(user, genesisAmount);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, preorderReserve, preorderReserve));
        router.genesisAndPreorder(
            VERSE_ID, _fundUAsset(genesisAmount), _fundPsm(address(underlying), preorderReserve), user
        );
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(emptyLauncher)), 0, "launcher holds zero uAsset after rollback");
        (, uint256 recordedGenesis,) = emptyLauncher.snapshot();
        assertEq(recordedGenesis, 0, "no genesis record survived the rollback");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "caller uAsset unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(emptyLauncher)), 0, "no allowance residual");
    }

    /// @notice The uAsset-funded genesis leg (`_uAssetToLauncher`, preorderLeg = false) with a
    ///         half-consuming launcher: the residual is measured against the pre-pull baseline, so
    ///         half the pulled amount stays on both dimensions.
    function test_RevertWhen_CombinedUAssetGenesisLegLauncherConsumesHalf() external {
        MockGenesisPartialLauncher partialLauncher = new MockGenesisPartialLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(partialLauncher));
        uint256 genesisAmount = 10e18;
        uAsset.mint(user, genesisAmount + 1e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, genesisAmount / 2, genesisAmount / 2)
        );
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(genesisAmount), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(partialLauncher)), 0, "half pull must roll back with the call");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "caller uAsset unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(partialLauncher)), 0, "no allowance residual");
    }

    /// @notice The uAsset-funded preorder leg (`_uAssetToLauncher`, preorderLeg = true) with a
    ///         half-consuming launcher: the genesis leg consumes in full first (router balance back
    ///         at its zero baseline), then the preorder leg leaves half of its pull as residual.
    function test_RevertWhen_CombinedUAssetPreorderLegLauncherConsumesHalf() external {
        MockPreorderPartialLauncher partialLauncher = new MockPreorderPartialLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(partialLauncher));
        uint256 genesisAmount = 2e18;
        uint256 preorderAmount = 10e18;
        uAsset.mint(user, genesisAmount + preorderAmount);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, preorderAmount / 2, preorderAmount / 2)
        );
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(genesisAmount), _fundUAsset(preorderAmount), user);
        vm.stopPrank();

        // Both legs rolled back: the completed genesis pull and record are gone with the call.
        assertEq(uAsset.balanceOf(address(partialLauncher)), 0, "launcher holds zero uAsset after rollback");
        (, uint256 recordedGenesis,) = partialLauncher.snapshot();
        assertEq(recordedGenesis, 0, "no genesis record survived the rollback");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "caller uAsset unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(partialLauncher)), 0, "no allowance residual");
    }

    /// @notice Leveraged family, uAsset interest leg with a half-pulling POLend: the residual is
    ///         measured against the pre-pull baseline and half the interest stays on both dimensions.
    function test_RevertWhen_CombinedLeveragedUAssetLegPolendConsumesHalf() external {
        _wirePolendFixture();
        polend.setPullHalf();
        uint256 interest = 6e18;
        uAsset.mint(user, interest + 1e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, interest / 2, interest / 2));
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundUAsset(interest), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(polend)), 0, "half pull must roll back with the call");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "caller uAsset unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(polend)), 0, "no allowance residual");
    }

    /// @notice Leveraged family, PSM interest leg with a half-pulling POLend: the fee-free mint
    ///         equals the reserve input, so half of it stays on both dimensions.
    function test_RevertWhen_CombinedLeveragedPsmLegPolendConsumesHalf() external {
        _wirePolendFixture();
        polend.setPullHalf();
        uint256 interestReserve = 8e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, interestReserve / 2, interestReserve / 2)
        );
        router.leveragedGenesisAndPreorder(
            VERSE_ID, _fundPsm(address(underlying), interestReserve), _fundUAsset(1e18), user
        );
        vm.stopPrank();

        assertEq(uAsset.balanceOf(address(polend)), 0, "half pull must roll back with the call");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "caller reserve unchanged after rollback");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds zero uAsset after rollback");
        assertEq(uAsset.allowance(address(router), address(polend)), 0, "no allowance residual");
    }

    /// @notice Leveraged family, credit interest leg with a half-pulling POLend: the strict
    ///         consumption assertion runs on the credit token and half the pulled credit stays on
    ///         both dimensions.
    function test_RevertWhen_CombinedLeveragedCreditLegPolendConsumesHalf() external {
        _wirePolendFixture();
        polend.setPullHalfCredit();
        uint256 creditIn = 6e18;
        uAsset.mint(user, 1e18);
        uint256 userCreditBefore = credit.balanceOf(user);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, creditIn / 2, creditIn / 2));
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundCredit(creditIn), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(credit.balanceOf(address(polend)), 0, "half pull must roll back with the call");
        assertEq(credit.balanceOf(user), userCreditBefore, "caller credit unchanged after rollback");
        assertEq(credit.balanceOf(address(router)), 0, "router holds zero credit after rollback");
        assertEq(credit.allowance(address(router), address(polend)), 0, "no credit allowance residual");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "preorder pull must roll back with the call");
    }

    /// @notice Path A (`genesisByPSM`) with a launcher that pulls the full mint and transfers a
    ///         tenth back: the router-side `_genesisTail` fires on the balance dimension with a
    ///         fully consumed allowance — the path-A twin of the SP-side transfer-back test.
    function test_RevertWhen_GenesisByPSMLauncherTransfersBack() external {
        MockGenesisTransferBackLauncher transferBackLauncher = new MockGenesisTransferBackLauncher(address(uAsset));
        vm.prank(owner);
        router.setMemeverseLauncher(address(transferBackLauncher));
        uint256 amountIn = 10e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GENESIS_U_ASSET_NOT_CONSUMED_SELECTOR, amountIn / 10, 0));
        router.genesisByPSM(address(uAsset), address(underlying), amountIn, VERSE_ID, user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(transferBackLauncher)), 0, "launcher holding must roll back");
        assertEq(uAsset.balanceOf(address(router)), 0, "transfer-back must roll back with the call");
        assertEq(uAsset.allowance(address(router), address(transferBackLauncher)), 0, "no allowance residual");
    }
}

/**
 * @title OutrunRouterCombinedGuardTest
 * @notice Guard-surface coverage of the combined entrypoints: the shared preamble's four
 *     `ZeroInput` branches (zero user, zero genesis amount, zero preorder amount, unknown verse
 *     resolving to the zero address), the remaining `FundInput` validation-matrix branches
 *     (preorder-leg Stake/Credit on the leveraged family, stake-only fields on non-Stake sources,
 *     preorder-leg field violations), the direct-SY stake leg's silent `minSyOut` ignore, the
 *     leveraged family's native value corners (underpaid, mixed native/ERC20 split, mixed
 *     overpaid, and the wrap-to-zero exact-wrap pair), and the value gate's precedence over the
 *     PSM registry gate on a multi-fault input.
 * @dev Grows in a fresh contract because the consolidated `OutrunRouterTest` sits at the solc
 *     0.8.35 via-ir assembly-tag ceiling (see `OutrunRouterTestNativeValueGate`); inherits the
 *     combined-entry fixture.
 */
contract OutrunRouterCombinedGuardTest is OutrunRouterCombinedEntryBase {
    // --------------------------------------------------------------------------
    // Shared preamble ZeroInput branches
    // --------------------------------------------------------------------------

    /// @notice A zero credited user reverts `ZeroInput` before any funds move.
    function test_RevertWhen_CombinedEntryWithZeroUser() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, 1e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.genesisAndPreorder(VERSE_ID, _fundPsm(address(underlying), 1e18), _fundUAsset(1e18), address(0));

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "zero-user guard must fire before any pull");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "zero-user guard must fire before any uAsset pull");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds no uAsset");
        assertEq(address(router).balance, 0, "router holds no native");
    }

    /// @notice A zero genesis-leg amount reverts `ZeroInput` before the verse read or any pull.
    function test_RevertWhen_CombinedEntryWithZeroGenesisAmount() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, 1e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(0), _fundUAsset(1e18), user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "zero-amount guard must fire before any pull");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "zero-amount guard must fire before any uAsset pull");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds no uAsset");
    }

    /// @notice A zero preorder-leg amount reverts `ZeroInput` before the verse read or any pull.
    function test_RevertWhen_CombinedEntryWithZeroPreorderAmount() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.genesisAndPreorder(VERSE_ID, _fundPsm(address(underlying), 1e18), _fundPsm(address(underlying), 0), user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "zero-amount guard must fire before any pull");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds no uAsset");
    }

    /// @notice An unknown verse (launcher binding read returning the zero address) reverts
    ///         `ZeroInput` after the amount checks and before any pull.
    function test_RevertWhen_CombinedEntryWithUnknownVerse() external {
        // Deploy before the prank: `vm.prank` would otherwise be consumed by the constructor call.
        MockGenesisEmptyLauncher emptyLauncher = new MockGenesisEmptyLauncher();
        vm.prank(owner);
        router.setMemeverseLauncher(address(emptyLauncher));
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uAsset.mint(user, 2e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IOutrunRouter.ZeroInput.selector);
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(1e18), _fundUAsset(1e18), user);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "unknown-verse guard must fire before any pull");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "unknown-verse guard must fire before any uAsset pull");
        assertEq(uAsset.balanceOf(address(router)), 0, "router holds no uAsset");
    }

    // --------------------------------------------------------------------------
    // FundInput validation matrix: remaining branches
    // --------------------------------------------------------------------------

    /// @notice The preorder leg accepts only `UAsset` and `Psm` on the leveraged family too:
    ///         `Stake` is rejected with the leveraged-family flag set, before any SY moves.
    function test_RevertWhen_CombinedPreorderLegStakeSourceOnLeveragedFamily() external {
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundSourceNotAllowed.selector, IOutrunRouter.FundSource.Stake, true)
        );
        router.leveragedGenesisAndPreorder(
            VERSE_ID, _fundUAsset(1e18), _fundStake(address(position), address(sy), 1e18), user
        );

        assertEq(sy.balanceOf(user), userSYBefore, "source guard must fire before any SY is pulled");
    }

    /// @notice The preorder leg rejects `Credit` on the leveraged family with the leveraged-family
    ///         flag set, before any credit moves.
    function test_RevertWhen_CombinedPreorderLegCreditSourceOnLeveragedFamily() external {
        uint256 userCreditBefore = credit.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundSourceNotAllowed.selector, IOutrunRouter.FundSource.Credit, true)
        );
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundUAsset(1e18), _fundCredit(1e18), user);

        assertEq(credit.balanceOf(user), userCreditBefore, "source guard must fire before any credit is pulled");
    }

    /// @notice A UAsset-funded leg carrying `minUAssetMinted` (stake-only field) reverts
    ///         `FundFieldMustBeZero` before any funds move.
    function test_RevertWhen_CombinedUAssetLegWithMinUAssetMinted() external {
        IOutrunRouter.FundInput memory bad = _fundUAsset(1e18);
        bad.minUAssetMinted = 1;
        uAsset.mint(user, 2e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.UAsset)
        );
        router.genesisAndPreorder(VERSE_ID, bad, _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(uAsset.balanceOf(user), userUAssetBefore, "field guard must fire before any uAsset pull");
    }

    /// @notice A Psm-funded leg must leave the three stake-only fields (`sp`, `minSyOut`,
    ///         `minUAssetMinted`) zero: each violation reverts `FundFieldMustBeZero` before any
    ///         reserve moves.
    function test_RevertWhen_CombinedPsmLegWithStakeOnlyFields() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.startPrank(user);
        IOutrunRouter.FundInput memory withSp = _fundPsm(address(underlying), 1e18);
        withSp.sp = address(position);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.Psm)
        );
        router.genesisAndPreorder(VERSE_ID, withSp, _fundUAsset(1e18), user);

        IOutrunRouter.FundInput memory withMinSyOut = _fundPsm(address(underlying), 1e18);
        withMinSyOut.minSyOut = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.Psm)
        );
        router.genesisAndPreorder(VERSE_ID, withMinSyOut, _fundUAsset(1e18), user);

        IOutrunRouter.FundInput memory withMinUAssetMinted = _fundPsm(address(underlying), 1e18);
        withMinUAssetMinted.minUAssetMinted = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.Psm)
        );
        router.genesisAndPreorder(VERSE_ID, withMinUAssetMinted, _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "field guards must fire before any pull");
    }

    /// @notice A Credit-funded leg (leveraged family genesis) carrying a `token` reverts
    ///         `FundFieldMustBeZero` before any credit moves.
    function test_RevertWhen_CombinedCreditLegWithToken() external {
        IOutrunRouter.FundInput memory bad = _fundCredit(1e18);
        bad.token = address(underlying);
        uint256 userCreditBefore = credit.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.Credit)
        );
        router.leveragedGenesisAndPreorder(VERSE_ID, bad, _fundUAsset(1e18), user);

        assertEq(credit.balanceOf(user), userCreditBefore, "field guard must fire before any credit pull");
    }

    /// @notice Preorder-leg field violations (the existing field tests all hit the genesis leg):
    ///         a Psm preorder leg with `sp` and a UAsset preorder leg with `token` each revert
    ///         `FundFieldMustBeZero` before any funds move.
    function test_RevertWhen_CombinedPreorderLegFieldViolations() external {
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.startPrank(user);
        IOutrunRouter.FundInput memory preorderPsmWithSp = _fundPsm(address(underlying), 1e18);
        preorderPsmWithSp.sp = address(position);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.Psm)
        );
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(1e18), preorderPsmWithSp, user);

        IOutrunRouter.FundInput memory preorderUAssetWithToken = _fundUAsset(1e18);
        preorderUAssetWithToken.token = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(IOutrunRouter.FundFieldMustBeZero.selector, IOutrunRouter.FundSource.UAsset)
        );
        router.genesisAndPreorder(VERSE_ID, _fundUAsset(1e18), preorderUAssetWithToken, user);
        vm.stopPrank();

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "field guards must fire before any pull");
    }

    // --------------------------------------------------------------------------
    // Direct-SY stake leg: silent minSyOut ignore
    // --------------------------------------------------------------------------

    /// @notice The direct-SY stake leg charges SY units without a deposit, so `minSyOut` is
    ///         accepted but ignored (`FundInput`'s only explicit silent-ignore exception): even
    ///         `type(uint256).max` must not act as a floor. Pins the ignore against a future
    ///         deposit-side floor being added to the direct-charge branch.
    function test_CombinedStakeDirectSYLegIgnoresMinSyOut() external {
        uint256 syIn = 4e18;
        uint256 preorderReserve = 1e18;
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        router.genesisAndPreorder(
            VERSE_ID,
            _fundStakeWithMins(address(position), address(sy), syIn, type(uint256).max, 0),
            _fundPsm(address(underlying), preorderReserve),
            user
        );

        (address positionOwner, uint256 syStaked,,,) = position.positions(1);
        assertEq(positionOwner, user, "position opened despite the max minSyOut");
        assertEq(syStaked, syIn, "direct SY charge recorded the full leg amount");
        assertEq(sy.balanceOf(user), userSYBefore - syIn, "caller paid the SY principal");
        assertEq(uAsset.balanceOf(address(launcher)), syIn + preorderReserve, "parity mint + preorder delivered");
    }

    // --------------------------------------------------------------------------
    // Leveraged family native corners
    // --------------------------------------------------------------------------

    /// @notice An underpaid `msg.value` on the leveraged family (native PSM genesis leg plus a
    ///         uAsset preorder leg) reverts `NativeAmountMismatch` before any funds move.
    function test_RevertIf_LeveragedCombinedNativeUnderfunded() external {
        _wirePolendFixture();
        uint256 userNativeBefore = user.balance;
        uAsset.mint(user, 1e18);
        uint256 userUAssetBefore = uAsset.balanceOf(user);

        vm.startPrank(user);
        uAsset.approve(address(router), type(uint256).max);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.leveragedGenesisAndPreorder{value: 1}(VERSE_ID, _fundPsm(NATIVE, 1e18), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(address(psmNative).balance, 0, "failed call must not move native into the PSM");
        assertEq(uAsset.balanceOf(user), userUAssetBefore, "failed call must not pull the preorder uAsset");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
        assertEq(address(router).balance, 0, "failed call leaves no native on the router");
        assertEq(user.balance, userNativeBefore, "reverted value returns to the caller");
    }

    /// @notice Mixed legs on the leveraged family, native (interest) + ERC20 (preorder): the exact
    ///         `msg.value` matching only the native interest leg passes the gate, native reaches
    ///         only the interest leg's PSM, the ERC20 pays only the preorder leg, and neither leg
    ///         leaves a router residual.
    function test_LeveragedCombinedNativeGenesisAndErc20PreorderMixedValueSplit() external {
        _wirePolendFixture();
        uint256 interestNativeIn = 2e18;
        uint256 preorderReserve = 3e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        router.leveragedGenesisAndPreorder{value: interestNativeIn}(
            VERSE_ID, _fundPsm(NATIVE, interestNativeIn), _fundPsm(address(underlying), preorderReserve), user
        );

        assertEq(address(psmNative).balance, interestNativeIn, "native reached only the interest leg's PSM");
        assertEq(
            userUnderlyingBefore - underlying.balanceOf(user),
            preorderReserve,
            "ERC20 reserve paid only the preorder leg"
        );
        (, uint256 lastInterest,) = polend.interestSnapshot();
        (, uint256 lastPreorderBase,) = launcher.preorderSnapshot();
        assertEq(lastInterest, interestNativeIn, "interest leg credited the fee-free native mint");
        assertEq(uAsset.balanceOf(address(polend)), interestNativeIn, "interest escrowed in polend");
        assertEq(lastPreorderBase, preorderReserve, "preorder leg credited the fee-free ERC20 mint");
        assertEq(uAsset.balanceOf(address(router)), 0, "no uAsset residual on router");
        assertEq(address(router).balance, 0, "no native residual on router");
    }

    /// @notice Mixed legs, overpaid: `msg.value = interest + preorderReserve` (overpaying native
    ///         for the ERC20 preorder leg) reverts `NativeAmountMismatch` before any funds move.
    function test_RevertIf_LeveragedCombinedNativeGenesisAndErc20PreorderOverpaid() external {
        _wirePolendFixture();
        uint256 interestNativeIn = 2e18;
        uint256 preorderReserve = 3e18;
        uint256 userUnderlyingBefore = underlying.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.leveragedGenesisAndPreorder{value: interestNativeIn + preorderReserve}(
            VERSE_ID, _fundPsm(NATIVE, interestNativeIn), _fundPsm(address(underlying), preorderReserve), user
        );

        assertEq(address(psmNative).balance, 0, "failed call must not move native into the PSM");
        assertEq(uAsset.balanceOf(address(polend)), 0, "failed call must not escrow interest");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
    }

    /// @notice Wrap-to-zero edge on the leveraged family: two native legs whose sum wraps to
    ///         exactly 0 (1 + type(uint256).max) with `msg.value = 0` pass the preamble's value
    ///         gate and the POLend market gate, then the whole call reverts empty at the first
    ///         native forwarding (the interest leg's PSM mint CALL value, with the router's actual
    ///         balance 0): fail-closed, balances unchanged.
    function test_RevertIf_LeveragedCombinedNativeLegSumWrapsToZero() external {
        _wirePolendFixture();

        vm.prank(user);
        // Empty revert data: the router bubbles the raw returndata of the failed native
        // forwarding CALL (insufficient balance => success = false, no returndata).
        vm.expectRevert(bytes(""));
        router.leveragedGenesisAndPreorder(VERSE_ID, _fundPsm(NATIVE, 1), _fundPsm(NATIVE, type(uint256).max), user);

        assertEq(address(router).balance, 0, "router native unchanged");
        assertEq(address(psmNative).balance, 0, "PSM native unchanged");
        assertEq(uAsset.balanceOf(address(polend)), 0, "no interest escrowed");
        assertEq(uAsset.balanceOf(address(router)), 0, "no uAsset minted to the router");
    }

    // --------------------------------------------------------------------------
    // Value gate precedes the PSM registry gate on the combined entry
    // --------------------------------------------------------------------------

    /// @notice A combined PSM genesis leg on an unregistered (uAsset, reserve) pair plus a wrong
    ///         `msg.value` surfaces `NativeAmountMismatch` (preamble value gate), not
    ///         `UnregisteredPsm` (leg-runner registry gate) — the combined-entry twin of the
    ///         single-leg entry-top ordering tests.
    function test_RevertIf_CombinedValueGatePrecedesPsmRegistryGate() external {
        RouterMockERC20 strayReserve = new RouterMockERC20("Stray", "STR");
        strayReserve.mint(user, 1e18);

        vm.startPrank(user);
        strayReserve.approve(address(router), 1e18);
        vm.expectRevert(NATIVE_AMOUNT_MISMATCH_SELECTOR);
        router.genesisAndPreorder{value: 1}(VERSE_ID, _fundPsm(address(strayReserve), 1e18), _fundUAsset(1e18), user);
        vm.stopPrank();

        assertEq(strayReserve.balanceOf(user), 1e18, "failed call must not pull the reserve");
        assertEq(uAsset.balanceOf(address(router)), 0, "failed call must not mint uAsset to the router");
        assertEq(address(router).balance, 0, "reverted value returns to the caller");
    }
}

/**
 * @title OutrunRouterAdminSurfaceTest
 * @notice Admin and read-surface coverage outside the genesis flows: the `sweep` guards (zero
 *     recipient, zero amount, non-owner) and the NATIVE rescue with its `Sweep` event, the
 *     `redeemSyToToken` registry gate and the SY-side `SYInsufficientTokenOut` propagation with a
 *     full rollback, the `setTrustedSY`/`setTrustedSP` setter surface (NATIVE and zero-address
 *     rejections, non-owner reverts, events and registry updates), and the preview registry gates
 *     (unregistered SP and `SP.SY()` drift mirrored from the execution entries onto
 *     `previewStakeFromToken`/`previewStakeFromSY`).
 * @dev Grows in a fresh contract because the consolidated `OutrunRouterTest` sits at the solc
 *     0.8.35 via-ir assembly-tag ceiling (see `OutrunRouterTestNativeValueGate`); inherits the
 *     base router fixture.
 */
contract OutrunRouterAdminSurfaceTest is OutrunRouterTestBase {
    // --------------------------------------------------------------------------
    // sweep
    // --------------------------------------------------------------------------

    /// @notice A zero recipient is rejected before any transfer.
    function test_RevertWhen_SweepToZeroAddress() external {
        uAsset.setMintingCap(address(this), type(uint128).max);
        uAsset.mint(address(router), 1e18);

        vm.prank(owner);
        vm.expectRevert(IOutrunRouter.SweepZeroAddress.selector);
        router.sweep(address(uAsset), address(0), 1e18);

        assertEq(uAsset.balanceOf(address(router)), 1e18, "failed sweep must leave the router balance intact");
    }

    /// @notice A zero amount is rejected before any transfer.
    function test_RevertWhen_SweepZeroAmount() external {
        uAsset.setMintingCap(address(this), type(uint128).max);
        uAsset.mint(address(router), 1e18);

        vm.prank(owner);
        vm.expectRevert(IOutrunRouter.SweepZeroAmount.selector);
        router.sweep(address(uAsset), treasury, 0);

        assertEq(uAsset.balanceOf(treasury), 0, "failed sweep must move nothing");
    }

    /// @notice Only the owner may sweep; a non-owner call reverts at the Ownable gate.
    function test_RevertWhen_SweepCalledByNonOwner() external {
        uAsset.setMintingCap(address(this), type(uint128).max);
        uAsset.mint(address(router), 1e18);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, user));
        router.sweep(address(uAsset), treasury, 1e18);

        assertEq(uAsset.balanceOf(treasury), 0, "unauthorized sweep must move nothing");
        assertEq(uAsset.balanceOf(address(router)), 1e18, "router balance untouched");
    }

    /// @notice The NATIVE sentinel routes the sweep to a native transfer and emits `Sweep`.
    function test_SweepNativeSucceedsAndEmits() external {
        uint256 amount = 1 ether;
        vm.deal(address(router), amount);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.Sweep(NATIVE, treasury, amount);
        router.sweep(NATIVE, treasury, amount);

        assertEq(treasury.balance, amount, "native rescued to the recipient");
        assertEq(address(router).balance, 0, "router native drained");
    }

    // --------------------------------------------------------------------------
    // redeemSyToToken
    // --------------------------------------------------------------------------

    /// @notice An SY outside the trusted registry fails `redeemSyToToken` before any SY is pulled.
    function test_RevertWhen_RedeemSyToTokenWithUntrustedSY() external {
        RouterMockSY untrustedSY = new RouterMockSY(address(underlying));
        uint256 userSYBefore = sy.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, address(untrustedSY)));
        router.redeemSyToToken(address(untrustedSY), user, address(underlying), 1e18, 0);

        assertEq(untrustedSY.balanceOf(user), 0, "untrusted gate must fire before any pull");
        assertEq(sy.balanceOf(user), userSYBefore, "trusted SY balance untouched");
    }

    /// @notice An output floor above the identity-rate redemption reverts with the SY-side
    ///         `SYInsufficientTokenOut` payload and rolls the whole call back: no SY left the
    ///         caller and no underlying left the SY contract.
    function test_RevertWhen_RedeemSyToTokenBelowMinTokenOut() external {
        uint256 amountInSY = 1e18;
        uint256 minTokenOut = 2e18;
        uint256 userSYBefore = sy.balanceOf(user);
        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 syUnderlyingBefore = underlying.balanceOf(address(sy));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardizedYield.SYInsufficientTokenOut.selector, amountInSY, minTokenOut)
        );
        router.redeemSyToToken(address(sy), user, address(underlying), amountInSY, minTokenOut);

        assertEq(sy.balanceOf(user), userSYBefore, "SY pull must roll back with the call");
        assertEq(sy.balanceOf(address(sy)), 0, "SY contract holds no burned shares");
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "redeem output must roll back");
        assertEq(underlying.balanceOf(address(sy)), syUnderlyingBefore, "SY underlying unchanged");
    }

    // --------------------------------------------------------------------------
    // setTrustedSY / setTrustedSP
    // --------------------------------------------------------------------------

    /// @notice Registering the NATIVE sentinel as a trusted SY target is rejected: the shared
    ///         untrusted-target payload fires with the sentinel itself.
    function test_RevertWhen_SetTrustedSYWithNativeAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, NATIVE));
        router.setTrustedSY(NATIVE, true);

        assertFalse(router.trustedSY(NATIVE), "NATIVE must stay untrusted");
    }

    /// @notice Registering a zero-address SP is rejected with the shared untrusted-target payload.
    function test_RevertWhen_SetTrustedSPWithZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, address(0)));
        router.setTrustedSP(address(0), address(sy));
    }

    /// @notice Only the owner may maintain the SY trust registry.
    function test_RevertWhen_SetTrustedSYCalledByNonOwner() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, user));
        router.setTrustedSY(address(sy), false);

        assertTrue(router.trustedSY(address(sy)), "non-owner call must not flip the trust flag");
    }

    /// @notice Only the owner may maintain the SP pair registry.
    function test_RevertWhen_SetTrustedSPCalledByNonOwner() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, user));
        router.setTrustedSP(address(position), address(0));

        assertEq(router.trustedSYForSP(address(position)), address(sy), "non-owner call must not revoke the pair");
    }

    /// @notice Both setters emit their events and update the getters on registration and
    ///         revocation.
    function test_SetTrustedSYAndSPUpdateRegistriesAndEmit() external {
        RouterMockSY extraSY = new RouterMockSY(address(underlying));

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.TrustedSYUpdated(address(extraSY), true);
        router.setTrustedSY(address(extraSY), true);
        assertTrue(router.trustedSY(address(extraSY)), "extra SY trusted");

        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.TrustedSYUpdated(address(extraSY), false);
        router.setTrustedSY(address(extraSY), false);
        assertFalse(router.trustedSY(address(extraSY)), "revocation clears the trust flag");

        vm.expectEmit(true, true, false, true);
        emit IOutrunRouter.TrustedSPUpdated(address(position), address(sy));
        router.setTrustedSP(address(position), address(sy));
        vm.stopPrank();

        assertEq(router.trustedSYForSP(address(position)), address(sy), "SP pair re-registered");
    }

    // --------------------------------------------------------------------------
    // Preview registry gates
    // --------------------------------------------------------------------------

    /// @notice Both previews refuse to quote an unregistered SP with the shared untrusted-target
    ///         payload, mirroring the execution entries' registry gate.
    function test_RevertWhen_PreviewsOnUnregisteredSP() external {
        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, user));
        router.previewStakeFromToken(user, address(underlying), 10e18);

        vm.expectRevert(abi.encodeWithSelector(UNTRUSTED_ROUTER_TARGET_SELECTOR, user));
        router.previewStakeFromSY(user, 10e18);
    }

    /// @notice Both previews refuse to quote a drifted `SP.SY()` binding with the three-party
    ///         mismatch payload — the preview-side twin of the `genesisBySY`/`genesisByToken`
    ///         drift gates.
    function test_RevertIf_PreviewsOnSPBindingDrift() external {
        address driftedSY = address(0xDEAD);
        vm.mockCall(address(position), abi.encodeWithSelector(IOutrunStakeManager.SY.selector), abi.encode(driftedSY));
        bytes memory expected =
            abi.encodeWithSelector(ROUTER_TARGET_MISMATCH_SELECTOR, address(position), address(sy), driftedSY);

        vm.expectRevert(expected);
        router.previewStakeFromToken(address(position), address(underlying), 10e18);

        vm.expectRevert(expected);
        router.previewStakeFromSY(address(position), 10e18);
    }
}
