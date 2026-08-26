// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutrunStakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunStakedUsdsSYUpgradeable.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {MockToken, MockVault} from "./mocks/SYAdapterMocks.sol";

/**
 * @title SYPerActorConservationHandler
 * @notice Handler-based fuzz driver for the per-actor SY conservation invariants.
 * @dev Drives a real OutrunStakedUsdsSYUpgradeable (behind a proxy) backed by a MockVault whose
 *      asset-per-share rate only moves through the `bumpRate` op (monotone up from 1e18), and keeps
 *      per-actor ghost ledgers so the invariants can bound what each actor redeemed against what
 *      they actually deposited. Donations model third-party vault-share gifts to the SY contract,
 *      asset-covered at the current rate so the vault can always honour redemptions.
 */
contract SYPerActorConservationHandler is Test {
    IStandardizedYield internal immutable sy;
    IERC20 internal immutable syErc20;
    MockToken internal immutable usds;
    MockVault internal immutable sUsdsVault;

    /// @dev Fixed actor set: two depositors plus the trusted-router caller address.
    address internal immutable alice;
    address internal immutable bob;
    address internal immutable routerCaller;

    /// @dev Per-actor ghosts: assets in/out, share movements, and redeem op count (rounding slack).
    mapping(address actor => uint256 depositedAssets) public ghostDepositedAssets;
    mapping(address actor => uint256 redeemedAssets) public ghostRedeemedAssets;
    mapping(address actor => uint256 sharesMinted) public ghostSharesMinted;
    mapping(address actor => uint256 sharesBurnedDirect) public ghostSharesBurnedDirect;
    mapping(address actor => uint256 sharesSentToRouter) public ghostSharesSentToRouter;
    mapping(address actor => uint256 redeemOps) public ghostRedeemOps;

    /// @dev Vault-share ledger ghosts: shares the SY gained/lost through deposits/redemptions/donations.
    uint256 public ghostVaultSharesIn;
    uint256 public ghostVaultSharesOut;
    uint256 public ghostDonatedShares;

    /// @dev Rate model: `ghostModelRate` only changes in bumpRate; `ghostMaxRate` is its running max.
    uint256 public ghostModelRate = 1e18;
    uint256 public ghostMaxRate = 1e18;

    constructor(
        IStandardizedYield sy_,
        MockToken usds_,
        MockVault sUsdsVault_,
        address alice_,
        address bob_,
        address routerCaller_
    ) {
        sy = sy_;
        // The SY is also an ERC20; keep a typed reference for balance/transfer calls.
        syErc20 = IERC20(address(sy_));
        usds = usds_;
        sUsdsVault = sUsdsVault_;
        alice = alice_;
        bob = bob_;
        routerCaller = routerCaller_;
    }

    /// @dev Actor lookup for the fuzz-selected index (two depositors alternate).
    function _actor(uint8 actorIdx) internal view returns (address) {
        return actorIdx % 2 == 0 ? alice : bob;
    }

    /// @notice Deposits USDS into the SY for a fuzzed actor (minSharesOut = 0: no slippage floor).
    function deposit(uint8 actorIdx, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        address actor = _actor(actorIdx);
        vm.startPrank(actor);
        usds.approve(address(sy), amount);
        uint256 shares = sy.deposit(actor, address(usds), amount, 0);
        vm.stopPrank();
        ghostDepositedAssets[actor] += amount;
        ghostSharesMinted[actor] += shares;
        ghostVaultSharesIn += shares;
    }

    /// @notice Redeems SY shares straight back to USDS (burnFromInternalBalance = false).
    /// @dev Caps the share amount at the actor's balance and at what the vault's asset holdings can
    ///      pay out at the current rate, so the op stays non-reverting for the invariant fuzzer.
    function redeemDirect(uint8 actorIdx, uint256 shares) external {
        address actor = _actor(actorIdx);
        uint256 balance = syErc20.balanceOf(actor);
        if (balance == 0) return;
        uint256 payableShares = usds.balanceOf(address(sUsdsVault)) * 1e18 / ghostModelRate;
        // After rate bumps the vault's assets may not cover any share at the current rate.
        if (payableShares == 0) return;
        shares = _min(bound(shares, 1, balance), payableShares);
        vm.startPrank(actor);
        uint256 assetsOut = sy.redeem(actor, shares, address(usds), 0, false);
        vm.stopPrank();
        ghostRedeemedAssets[actor] += assetsOut;
        ghostSharesBurnedDirect[actor] += shares;
        ghostVaultSharesOut += shares;
        ghostRedeemOps[actor] += 1;
    }

    /// @notice Router-path redeem: the actor transfers SY into the SY contract, then the trusted
    ///      router calls redeem(..., burnFromInternalBalance = true), burning the SY's own balance.
    /// @dev The real SY only allows the configured trustedRouter to use the internal-balance path,
    ///      so the two legs run under separate pranks (actor for the transfer, router for the burn).
    function redeemViaRouter(uint8 actorIdx, uint256 shares) external {
        address actor = _actor(actorIdx);
        uint256 balance = syErc20.balanceOf(actor);
        if (balance == 0) return;
        uint256 payableShares = usds.balanceOf(address(sUsdsVault)) * 1e18 / ghostModelRate;
        // Same vault-coverage edge as redeemDirect: skip when nothing is payable at the current rate.
        if (payableShares == 0) return;
        shares = _min(bound(shares, 1, balance), payableShares);
        vm.prank(actor);
        syErc20.transfer(address(sy), shares);
        vm.prank(routerCaller);
        uint256 assetsOut = sy.redeem(actor, shares, address(usds), 0, true);
        ghostRedeemedAssets[actor] += assetsOut;
        ghostSharesSentToRouter[actor] += shares;
        ghostVaultSharesOut += shares;
        ghostRedeemOps[actor] += 1;
    }

    /// @notice Donates vault shares (plus covering assets at the current rate) to the SY contract.
    /// @dev Models a third-party donation: the SY's vault balance grows, but the per-share rate the
    ///      SY quotes must not move — donations only create sweep-locked surplus.
    function donate(uint256 shares) external {
        shares = bound(shares, 1, 1e21);
        sUsdsVault.mint(address(sy), shares);
        usds.mint(address(sUsdsVault), shares * ghostModelRate / 1e18);
        ghostDonatedShares += shares;
    }

    /// @notice Raises the vault's asset-per-share rate by 1%..10% (monotone up from 1e18).
    function bumpRate(uint256 seed) external {
        uint256 step = ghostModelRate / 10;
        if (step == 0) step = 1;
        uint256 newRate = ghostModelRate + bound(seed, 1, step);
        sUsdsVault.setAssetsPerShare(newRate);
        ghostModelRate = newRate;
        ghostMaxRate = newRate;
    }

    /// @dev Thin helper so the cap reads naturally on two values.
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/**
 * @title SYPerActorConservationUpgradeableTest
 * @notice Per-actor deposit/redeem conservation invariants for SY tokens.
 * @dev Upgrades the aggregate ghosts of SYInvariant.t.sol to per-actor granularity: each actor's
 *      redeemed assets are bounded by their deposits valued at the maximum observed rate (plus one
 *      wei of floor slack per redeem op), the SY's vault-share ledger matches the ghost ledger
 *      exactly (donations included as stranded surplus), per-actor share balances match their
 *      mint/burn/transfer ghosts, and the quoted exchange rate only moves through the explicit
 *      rate-bump op — never through deposits, redeems, or donations.
 */
contract SYPerActorConservationUpgradeableTest is StdInvariant, Test {
    OutrunStakedUsdsSYUpgradeable internal sy;
    MockToken internal usds;
    MockVault internal sUsdsVault;
    SYPerActorConservationHandler internal handler;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal routerCaller = makeAddr("routerCaller");
    address internal owner = makeAddr("owner");

    function setUp() external {
        usds = new MockToken("USDS", "USDS", 18);
        sUsdsVault = new MockVault(address(usds));
        sy = _deployStakedUsdsSY();
        vm.prank(owner);
        sy.setTrustedRouter(routerCaller);

        usds.mint(alice, 1e27);
        usds.mint(bob, 1e27);

        handler = new SYPerActorConservationHandler(sy, usds, sUsdsVault, alice, bob, routerCaller);
        // Restrict the fuzzer to the handler: the SY, vault, and token have no other callers here.
        targetContract(address(handler));
    }

    /// @notice Redeemed assets per actor never exceed deposits valued at the max observed rate.
    function invariant_perActorRedeemBoundedByDepositsAtMaxRate() external view {
        uint256 maxRate = handler.ghostMaxRate();
        assertLe(
            handler.ghostRedeemedAssets(alice),
            handler.ghostDepositedAssets(alice) * maxRate / 1e18 + handler.ghostRedeemOps(alice),
            "alice redeemed beyond deposits at max rate"
        );
        assertLe(
            handler.ghostRedeemedAssets(bob),
            handler.ghostDepositedAssets(bob) * maxRate / 1e18 + handler.ghostRedeemOps(bob),
            "bob redeemed beyond deposits at max rate"
        );
    }

    /// @notice The SY's vault-share balance matches the ghost ledger exactly: deposits in, redeems
    ///      out, donations stranded as surplus. Nothing enters or leaves outside those ops.
    function invariant_vaultShareLedgerMatchesGhosts() external view {
        uint256 expected = handler.ghostVaultSharesIn() - handler.ghostVaultSharesOut() + handler.ghostDonatedShares();
        assertEq(sUsdsVault.balanceOf(address(sy)), expected, "SY vault-share ledger diverged");
    }

    /// @notice The quoted exchange rate equals the handler-side model rate: only bumpRate may move it.
    /// @dev Pins the donation-surplus property — a vault-share gift changes the SY's holdings but
    ///      must not change the per-share rate any participant is quoted.
    function invariant_exchangeRateOnlyMovesViaBump() external view {
        assertEq(sy.exchangeRate(), handler.ghostModelRate(), "exchange rate moved outside bumpRate");
    }

    /// @notice Per-actor SY balances equal minted minus burned minus router-transferred shares.
    function invariant_shareBalancesMatchGhosts() external view {
        assertEq(
            sy.balanceOf(alice),
            handler.ghostSharesMinted(alice) - handler.ghostSharesBurnedDirect(alice)
                - handler.ghostSharesSentToRouter(alice),
            "alice share balance diverged"
        );
        assertEq(
            sy.balanceOf(bob),
            handler.ghostSharesMinted(bob) - handler.ghostSharesBurnedDirect(bob)
                - handler.ghostSharesSentToRouter(bob),
            "bob share balance diverged"
        );
    }

    /// @dev Deploys the real StakedUsds SY behind an ERC1967 proxy (mirrors SYAdaptersUpgradeable wiring).
    function _deployStakedUsdsSY() internal returns (OutrunStakedUsdsSYUpgradeable proxy) {
        proxy = OutrunStakedUsdsSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunStakedUsdsSYUpgradeable()),
                    abi.encodeCall(
                        OutrunStakedUsdsSYUpgradeable.initialize, (owner, address(usds), address(sUsdsVault))
                    )
                ))
        );
    }
}
