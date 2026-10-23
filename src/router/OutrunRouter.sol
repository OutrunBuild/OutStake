// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IOutrunRouter} from "./interfaces/IOutrunRouter.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {IPOLendGenesis} from "./interfaces/IPOLendGenesis.sol";
import {IGenesisCreditRegistry} from "./interfaces/IGenesisCreditRegistry.sol";
import {IPSM} from "../psm/interfaces/IPSM.sol";
import {IStandardizedYield} from "../yield/interfaces/IStandardizedYield.sol";
import {IERC20, TokenHelper, NativeAmountMismatch} from "../libraries/TokenHelper.sol";
import {GenesisGateLib} from "../libraries/GenesisGateLib.sol";
import {IOutrunStakeManager} from "../position/interfaces/IOutrunStakeManager.sol";

/**
 * @title OutrunRouter
 * @notice Main user-facing entry point for the OutStake protocol.
 *
 * Handles token-to-SY conversion and genesis flows.
 * SY = Standardized Yield (wrapper token that normalizes yield-bearing assets).
 * SP = Stake Position manager (creates and tracks staking positions).
 * uAsset = universal asset (receipt token minted when staking or PSM swapping).
 * Memeverse = the external launch platform used by genesis.
 * A verse is a launcher-managed launch target identified by a launcher-defined `verseId`.
 * Genesis has two gates: the PSM gate (`genesisByPSM`, reserve -> uAsset at face value, no position)
 * and the CDP gate with two denominated entries (`genesisByToken`, token -> SY -> genesis open, and
 * `genesisBySY`, stake SY directly into an open-term position for `genesisUser`). Both CDP-gate
 * entries are thin forwards over the SP-native physical gate (`SP.stakeForGenesis`, the only mint
 * entrypoint, minting at value parity): the SP mints the
 * uAsset to itself and hands it to its own genesis launcher atomically, so this router never touches
 * uAsset on that path. Any EOA or contract may call `SP.stakeForGenesis` directly; the router is a
 * convenience layer, not a required path.
 * Beyond the two gates, `leveragedGenesisByPSM` is a third genesis entry: it mints uAsset through the
 * PSM gate at face value and pays the full amount as Memeverse leveraged-genesis interest to the
 * owner-registered POLend target (no launcher delivery, no CDP position).
 */
contract OutrunRouter is IOutrunRouter, TokenHelper, Ownable {
    // These targets are configured after deployment; owner setters remain live for dynamic addition under Ownable (multisig off-chain).
    mapping(address => bool) public trustedSY;
    mapping(address => address) public trustedSYForSP;
    // (uAsset, reserveToken) -> PSM pairing for the PSM-gate genesis entrypoints (path A and the leveraged-genesis entry); zero value means unregistered.
    mapping(address => mapping(address => address)) public psmForUAsset;

    // Memeverse is the launch platform; this address is called during genesis flows.
    // Test-phase mutability: kept as mutable storage with `setMemeverseLauncher` for test deployment iteration.
    // Production plan: delete `setMemeverseLauncher` and make `memeverseLauncher` `immutable`, set only via constructor.
    address public memeverseLauncher;

    // POLend target for the PSM-gate leveraged-genesis entrypoint; zero means unconfigured.
    address public polend;

    constructor(address _owner, address _memeverseLauncher) Ownable(_owner) {
        _setMemeverseLauncher(_memeverseLauncher);
    }

    /**
     * @notice Registers or revokes a standardized-yield target for router entrypoints.
     * @dev Registration performs no code check on the token. Revocation is allowed with `trusted = false`.
     */
    function setTrustedSY(address SY, bool trusted) external onlyOwner {
        if (trusted && SY == NATIVE) revert UntrustedRouterTarget(SY);
        trustedSY[SY] = trusted;
        emit TrustedSYUpdated(SY, trusted);
    }

    /**
     * @notice Registers or revokes an SP and its canonical SY pair.
     * @dev Registration performs no code check on the token. A nonzero SY must already be trusted and must equal `SP.SY()`.
     */
    function setTrustedSP(address SP, address SY) external onlyOwner {
        if (SP == address(0)) revert UntrustedRouterTarget(SP);
        if (SY != address(0)) {
            _requireSpSyPair(SP, SY);
        }
        trustedSYForSP[SP] = SY;
        emit TrustedSPUpdated(SP, SY);
    }

    /// @inheritdoc IOutrunRouter
    function setPsmForUAsset(address uAsset, address reserveToken, address psm) external onlyOwner {
        if (uAsset == address(0)) revert UntrustedRouterTarget(uAsset);
        if (psm != address(0)) {
            // Registration performs no code check; both binding re-reads against the registry keys run
            // before the write. The PSM's bindings are set at initialization
            // and have no setters, so the consistency check is stable across upgrades.
            _requirePsmBindings(psm, uAsset, reserveToken);
        }
        psmForUAsset[uAsset][reserveToken] = psm;
        emit PsmForUAssetUpdated(uAsset, reserveToken, psm);
    }

    /// @notice Registers or revokes the POLend target for the leveraged-genesis entrypoint.
    /// @dev Registration performs no code check; a zero address revokes and the entry fails
    ///      closed with `PolendNotSet` afterwards. Runtime safety comes from the per-call
    ///      market-uAsset binding re-read and the strict consumption post-condition.
    /// @dev OutrunTODO: production deletes this setter; polend becomes immutable, constructor-wired only.
    function setPolend(address polend_) external onlyOwner {
        _setPolend(polend_);
    }

    /// @inheritdoc IOutrunRouter
    function mintSYFromToken(address SY, address tokenIn, address receiver, uint256 amountInput, uint256 minSyOut)
        external
        payable
        nonReentrant
        returns (uint256 amountInSYOut)
    {
        // Entry-level value gate (native leg: msg.value == amountInput; ERC20 leg: msg.value == 0);
        // the resolved amount is passed down as the primitive's explicit `nativeValue`.
        uint256 nativeValue = tokenIn == NATIVE ? amountInput : 0;
        if (msg.value != nativeValue) revert NativeAmountMismatch();
        amountInSYOut = _mintSY(SY, tokenIn, receiver, amountInput, minSyOut, nativeValue);
    }

    /**
     * @notice Redeems standardized yield into an output token.
     * @dev Always pulls SY from the caller and burns it from SY internal balance during redemption.
     * Zero floor means no protection: `minTokenOut == 0` accepts any positive token output; SY only
     * enforces `amountTokenOut >= minTokenOut`.
     * @dev Deployment precondition: see `IOutrunRouter.redeemSyToToken`.
     * @param SY Standardized yield contract being redeemed.
     * @param receiver Recipient of the redeemed token output.
     * @param tokenOut Token requested on redemption.
     * @param amountInSY Amount of SY to redeem.
     * @param minTokenOut Minimum acceptable token output; `0` means no slippage protection.
     * @return amountInTokenOut Amount of `tokenOut` sent to `receiver`.
     */
    function redeemSyToToken(address SY, address receiver, address tokenOut, uint256 amountInSY, uint256 minTokenOut)
        external
        nonReentrant
        returns (uint256 amountInTokenOut)
    {
        _requireTrustedSY(SY);
        // transferFrom moves caller's SY into the SY contract, then burnFromInternalBalance=true burns from SY's own balance.
        _transferFrom(IERC20(SY), msg.sender, SY, amountInSY);
        amountInTokenOut = IStandardizedYield(SY).redeem(receiver, amountInSY, tokenOut, minTokenOut, true);
    }

    /// @inheritdoc IOutrunRouter
    function genesisByPSM(address uAsset, address reserveToken, uint256 amountIn, uint256 verseId, address genesisUser)
        external
        payable
        nonReentrant
    {
        // Entry-level value gate (native leg: msg.value == amountIn; ERC20 leg: msg.value == 0), hoisted
        // above the registry reads so a multi-fault input surfaces the value error first.
        uint256 nativeValue = reserveToken == NATIVE ? amountIn : 0;
        if (msg.value != nativeValue) revert NativeAmountMismatch();
        address psm = _registeredPsm(uAsset, reserveToken);
        // Zero credited user would burn the launch into an unrecoverable sink; fail before any pull.
        if (genesisUser == address(0)) revert ZeroInput();

        (uint256 amountOut, uint256 uAssetBalanceBefore) =
            _psmMintForRouter(psm, uAsset, reserveToken, amountIn, nativeValue);
        _genesisTail(uAsset, verseId, genesisUser, amountOut, uAssetBalanceBefore);
    }

    /// @inheritdoc IOutrunRouter
    function genesisByToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) external payable nonReentrant {
        // Entry-level value gate (native leg: msg.value == tokenAmount; ERC20 leg: msg.value == 0).
        uint256 nativeValue = tokenIn == NATIVE ? tokenAmount : 0;
        if (msg.value != nativeValue) revert NativeAmountMismatch();
        address SY = _trustedSYWithLauncherParity(SP);
        // (1) Convert the caller's token into SY held by the router (registry check ran before any funds moved).
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, minSyOut, nativeValue);
        // (2) Thin forward into the SP genesis open.
        _forwardGenesisToSP(SP, SY, amountInSY, genesisUser, verseId, minUAssetMinted);
    }

    /// @inheritdoc IOutrunRouter
    function genesisBySY(address SP, uint256 amountInSY, uint256 verseId, address genesisUser, uint256 minUAssetMinted)
        external
        nonReentrant
    {
        // Entry-level value gate: the zero-value rule is structurally enforced by the non-payable
        // dispatcher — a value-carrying call reverts before the body runs (and before `msg.value`
        // is even readable here), so no explicit check is needed or reachable.
        address SY = _trustedSYWithLauncherParity(SP);
        // (1) Pull the caller's SY into the router.
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);
        // (2) Thin forward into the SP genesis open.
        _forwardGenesisToSP(SP, SY, amountInSY, genesisUser, verseId, minUAssetMinted);
    }

    /// @inheritdoc IOutrunRouter
    function leveragedGenesisByPSM(
        address uAsset,
        address reserveToken,
        uint256 amountIn,
        uint256 verseId,
        address genesisUser
    ) external payable nonReentrant returns (uint256 borrowedAmount) {
        // Entry-level value gate (native leg: msg.value == amountIn; ERC20 leg: msg.value == 0), hoisted
        // above the registry reads so a multi-fault input surfaces the value error first.
        uint256 nativeValue = reserveToken == NATIVE ? amountIn : 0;
        if (msg.value != nativeValue) revert NativeAmountMismatch();
        address psm = _registeredPsm(uAsset, reserveToken);
        // POLend gate: target configured and the verse market is bound to this uAsset family;
        // both re-reads fail closed before any pull, mirroring the launcher-parity style.
        address polend_ = _polendMarketGate(verseId, uAsset);
        // The interest ledger target must not be a burn sink; fail before any pull.
        if (genesisUser == address(0)) revert ZeroInput();

        (uint256 amountOut, uint256 uAssetBalanceBefore) =
            _psmMintForRouter(psm, uAsset, reserveToken, amountIn, nativeValue);
        // (3) Pay the minted uAsset to POLend as interest; the borrowed debt is credited to genesisUser.
        _approveExact(uAsset, polend_, amountOut);
        borrowedAmount = IPOLendGenesis(polend_).leveragedGenesis(verseId, amountOut, genesisUser);
        // (4) POLend must have consumed the approval in full; any residual reverts the whole call.
        GenesisGateLib.assertFullConsumption(uAsset, polend_, uAssetBalanceBefore);
    }

    /// @inheritdoc IOutrunRouter
    function preorderByPSM(
        address uAsset,
        address reserveToken,
        uint256 amountIn,
        uint256 verseId,
        address preorderUser
    ) external payable nonReentrant {
        // Entry-level value gate (native leg: msg.value == amountIn; ERC20 leg: msg.value == 0), hoisted
        // above the registry reads so a multi-fault input surfaces the value error first.
        uint256 nativeValue = reserveToken == NATIVE ? amountIn : 0;
        if (msg.value != nativeValue) revert NativeAmountMismatch();
        address psm = _registeredPsm(uAsset, reserveToken);
        // Zero credited user would burn the preorder into an unrecoverable sink; fail before any pull.
        if (preorderUser == address(0)) revert ZeroInput();

        (uint256 minted, uint256 uAssetBalanceBefore) =
            _psmMintForRouter(psm, uAsset, reserveToken, amountIn, nativeValue);
        // Same tail discipline as the combined entries' PSM preorder leg (_runPreorderLeg): launcher
        // amount bound, exact approval, preorder call, strict full-consumption post-condition.
        GenesisGateLib.requireLauncherAmount(minted);
        _approveExact(uAsset, memeverseLauncher, minted);
        IMemeverseLauncher(memeverseLauncher).preorder(verseId, minted, preorderUser);
        GenesisGateLib.assertFullConsumption(uAsset, memeverseLauncher, uAssetBalanceBefore);
    }

    /// @inheritdoc IOutrunRouter
    function genesisAndPreorder(
        uint256 verseId,
        FundInput calldata genesisInput,
        FundInput calldata preorderInput,
        address user
    ) external payable nonReentrant {
        (address uAsset, uint256 genesisNative, uint256 preorderNative) =
            _combinedPreamble(verseId, genesisInput, preorderInput, user, false);
        _runGenesisLeg(uAsset, verseId, genesisInput, user, genesisNative);
        _runPreorderLeg(uAsset, verseId, preorderInput, user, preorderNative);
    }

    /// @inheritdoc IOutrunRouter
    function leveragedGenesisAndPreorder(
        uint256 verseId,
        FundInput calldata genesisInput,
        FundInput calldata preorderInput,
        address user
    ) external payable nonReentrant {
        (address uAsset, uint256 genesisNative, uint256 preorderNative) =
            _combinedPreamble(verseId, genesisInput, preorderInput, user, true);
        // POLend family gate: source-independent and fail-closed before any funds move; the market
        // binding re-read shares the existing leveraged entry's discipline.
        address polend_ = _polendMarketGate(verseId, uAsset);
        _runLeveragedGenesisLeg(uAsset, verseId, genesisInput, user, polend_, genesisNative);
        _runPreorderLeg(uAsset, verseId, preorderInput, user, preorderNative);
    }

    /// @inheritdoc IOutrunRouter
    /// @dev Test-phase only: this setter exists for test deployment flexibility.
    /// Production will delete this method and make `memeverseLauncher` `immutable`, set only via constructor.
    /// Operational invariant: `memeverseLauncher` must equal each SP's `genesisLauncher()` for the two genesis
    /// gates to target one launcher; a single-side rotation
    /// makes router path-B entries and previews revert fail-closed (`GenesisLauncherMismatch`), while the residual
    /// silent surface is router path-A (router launcher) versus direct-SP (SP launcher) targeting different launchers.
    /// Rotate atomically with `SP.setGenesisLauncher` in the same transaction and verify
    /// `SP.genesisLauncher() == memeverseLauncher` afterwards.
    /// @dev OutrunTODO: production deletes this setter; memeverseLauncher becomes immutable, constructor-wired only.
    function setMemeverseLauncher(address _memeverseLauncher) external onlyOwner {
        _setMemeverseLauncher(_memeverseLauncher);
    }

    /// @inheritdoc IOutrunRouter
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert SweepZeroAddress();
        if (amount == 0) revert SweepZeroAmount();
        _transferOut(token, to, amount);
        emit Sweep(token, to, amount);
    }

    /// @inheritdoc IOutrunRouter
    function previewStakeFromToken(address SP, address tokenIn, uint256 tokenAmount)
        external
        view
        returns (uint256 UAssetMintable)
    {
        // Against a drifted launcher the quote fails exactly like execution; the parity check compares values
        // with no zero-address exclusion, so equal unset launchers pass it and leave the quote live while
        // execution reverts GenesisLauncherNotSet at the SP's zero-address gate.
        address SY = _trustedSYWithLauncherParity(SP);
        uint256 amountInSY = IStandardizedYield(SY).previewDeposit(tokenIn, tokenAmount);
        UAssetMintable = IOutrunStakeManager(SP).previewStake(amountInSY);
    }

    /// @inheritdoc IOutrunRouter
    function previewStakeFromSY(address SP, uint256 amountInSY) external view returns (uint256 UAssetMintable) {
        // Same launcher-parity gate as the execution path: a drifted launcher rejects the quote like
        // execution, while equal unset launchers pass parity and the quote stays live with execution
        // reverting GenesisLauncherNotSet at the SP's zero-address gate.
        _trustedSYWithLauncherParity(SP);
        UAssetMintable = IOutrunStakeManager(SP).previewStake(amountInSY);
    }

    /**
     * @notice Mints Standardized Yield by depositing an input token into the SY contract.
     * @dev Pulls `tokenIn` from the caller and forwards it to `SY.deposit`. Supports both
     * ERC20 and native tokens (NATIVE sentinel = address(0)). The msg.value rule (native leg:
     * `msg.value == amountInput`; ERC20 leg: `msg.value == 0`) is enforced by the calling
     * entrypoints, which pass the already-validated amount down as `nativeValue`.
     * @param SY Standardized yield contract that receives the deposit.
     * @param tokenIn Token to supply when minting SY (NATIVE for the chain's native currency).
     * @param receiver Recipient of the minted SY.
     * @param amountInput Amount of input token to deposit.
     * @param minSyOut Minimum acceptable SY output or the call reverts.
     * @param nativeValue Native value forwarded to `SY.deposit` (caller-validated; `amountInput`
     * on the native leg, `0` on an ERC20 leg).
     * @return amountInSYOut Amount of SY minted for `receiver`.
     */
    function _mintSY(
        address SY,
        address tokenIn,
        address receiver,
        uint256 amountInput,
        uint256 minSyOut,
        uint256 nativeValue
    ) internal returns (uint256 amountInSYOut) {
        _requireTrustedSY(SY);

        if (tokenIn != NATIVE) _transferFrom(IERC20(tokenIn), msg.sender, address(this), amountInput);
        _approveExact(tokenIn, SY, amountInput);
        // SY passed the trusted-registry check above; native value only reaches registered SY implementations.
        amountInSYOut = IStandardizedYield(SY).deposit{value: nativeValue}(receiver, tokenIn, amountInput, minSyOut);
    }

    /**
     * @notice Shared movement tail of the two PSM-backed genesis entries: pre-mint baseline
     *      snapshot, reserve pull from the caller, exact PSM approval, and the face-value mint
     *      to the router.
     * @dev Single source for the sequence both PSM gates must keep identical (baseline-before-mint
     *      placement, exact approval, value forwarding); the per-entry value gate and registry
     *      gates run in the callers before this tail.
     * @param psm Registered PSM handling the reserve-to-uAsset face-value mint.
     * @param uAsset Universal asset minted by the PSM.
     * @param reserveToken Reserve token pulled from the caller (`NATIVE` for the chain's native currency).
     * @param amountIn Reserve amount to swap in, in the reserve token's own decimals.
     * @param nativeValue Native value forwarded to the PSM mint (caller-validated; `amountIn` on
     *      the native leg, `0` on an ERC20 leg).
     * @return amountOut uAsset minted to the router by the PSM.
     * @return uAssetBalanceBefore Pre-mint snapshot of the router's uAsset balance (assertion baseline).
     */
    function _psmMintForRouter(address psm, address uAsset, address reserveToken, uint256 amountIn, uint256 nativeValue)
        internal
        returns (uint256 amountOut, uint256 uAssetBalanceBefore)
    {
        uAssetBalanceBefore = IERC20(uAsset).balanceOf(address(this));
        if (reserveToken != NATIVE) {
            _transferFrom(IERC20(reserveToken), msg.sender, address(this), amountIn);
            _approveExact(reserveToken, psm, amountIn);
        }
        amountOut = IPSM(psm).mint{value: nativeValue}(address(this), amountIn);
    }

    /**
     * @notice Tail of the PSM genesis gate (path A, `genesisByPSM` only): uint128 bound, exact
     *      launcher approval, genesis call, and the strict full-consumption post-condition.
     * @dev The CDP gate (path B) does not run through this tail: `genesisBySY` and
     *      `genesisByToken` thin-forward into `SP.stakeForGenesis`, which performs its own
     *      atomic hand-off and consumption assertion SP-side. The uint128 bound sits before the
     *      launcher approval, so an oversized mint never grants an allowance. The post-condition
     *      compares the router's uAsset balance against the pre-mint snapshot baseline taken by
     *      `genesisByPSM` before the PSM mint, so third-party pre-donated dust stays outside the
     *      assertion domain while any launcher shortfall or transfer-back reverts.
     * @param uAsset Universal asset minted by this genesis flow.
     * @param verseId Launcher-assigned identifier for the target verse.
     * @param genesisUser User credited for the genesis action.
     * @param mintedUAsset uAsset minted to the router by this transaction, to be fully consumed by the launcher.
     * @param uAssetBalanceBefore Pre-mint snapshot of the router's uAsset balance (assertion baseline).
     */
    function _genesisTail(
        address uAsset,
        uint256 verseId,
        address genesisUser,
        uint256 mintedUAsset,
        uint256 uAssetBalanceBefore
    ) internal {
        address launcher = memeverseLauncher;
        // Shared launcher-domain bound (GenesisGateLib): reject an oversized mint before granting any allowance.
        GenesisGateLib.requireLauncherAmount(mintedUAsset);
        _approveExact(uAsset, launcher, mintedUAsset);
        IMemeverseLauncher(launcher).genesis(verseId, mintedUAsset, genesisUser);
        GenesisGateLib.assertFullConsumption(uAsset, launcher, uAssetBalanceBefore);
    }

    /**
     * @notice Shared preamble of both combined entrypoints: zero-input guards, verse-to-uAsset
     *      resolution, the per-leg `FundInput` validation matrix, and the entry-level value gate —
     *      all before any funds move.
     * @dev The guards mirror the single-leg entries' ordering discipline: value and validity faults
     *      surface before any registry read or pull can move funds. An invalid verse fails closed
     *      through the launcher binding read (the real launcher reverts on an unknown verseId; a
     *      zero read covers the minimal-interface floor). The native sum is computed unchecked:
     *      a wrapped sum that differs from `msg.value` reverts `NativeAmountMismatch` at the entry
     *      gate, while the exact-wrap corner — the two legs' native values summing to zero with
     *      `msg.value == 0` — passes the gate and reverts the whole call empty at the first native
     *      forwarding (the CALL value of the PSM mint / SY deposit), still fail-closed with no
     *      fund movement.
     * @param verseId Opaque launcher-assigned identifier for the target verse.
     * @param genesisInput Funding instruction for the genesis leg.
     * @param preorderInput Funding instruction for the preorder leg.
     * @param user User credited by both legs.
     * @param leveragedFamily Whether the calling entrypoint is the leveraged family.
     * @return uAsset The verse's uAsset resolved through the launcher binding read.
     * @return genesisNative Native value the genesis leg requires (its PSM/stake `f.amount` when the
     *      leg's input token is NATIVE, else `0`), passed down as the leg runner's `nativeValueIn`.
     * @return preorderNative Native value the preorder leg requires, same rule as `genesisNative`.
     */
    function _combinedPreamble(
        uint256 verseId,
        FundInput calldata genesisInput,
        FundInput calldata preorderInput,
        address user,
        bool leveragedFamily
    ) internal view returns (address uAsset, uint256 genesisNative, uint256 preorderNative) {
        if (user == address(0) || genesisInput.amount == 0 || preorderInput.amount == 0) {
            revert ZeroInput();
        }
        // Invalid verse fails closed: the real launcher reverts on an unknown verseId; the zero-read
        // backstop covers the minimal-interface contract.
        uAsset = IMemeverseLauncher(memeverseLauncher).getUAssetByVerseId(verseId);
        if (uAsset == address(0)) revert ZeroInput();
        _validateFundInput(genesisInput, false, leveragedFamily);
        _validateFundInput(preorderInput, true, leveragedFamily);
        genesisNative = _legNativeValue(genesisInput);
        preorderNative = _legNativeValue(preorderInput);
        // Adversarial-domain input: the sum runs unchecked so an oversize native pair wraps instead
        // of panicking. A wrapped sum != msg.value fails the equality gate with the named error
        // pre-funds; the exact wrap-to-zero pair with msg.value == 0 passes the gate and reverts
        // the whole call empty at the first native forwarding (the PSM mint / SY deposit CALL
        // value) — fail-closed either way, with no fund movement.
        uint256 expectedNative;
        unchecked {
            expectedNative = genesisNative + preorderNative;
        }
        if (msg.value != expectedNative) revert NativeAmountMismatch();
    }

    /**
     * @notice Validates one leg's `FundInput` against the family-scoped source matrix and the
     *      forced-zero field rules, before any funds move.
     * @dev Source matrix: the preorder leg accepts only `UAsset` and `Psm` on both families; the
     *      genesis leg rejects `Credit` on the normal family and `Stake` on the leveraged family.
     *      Forced-zero fields: `token` may be nonzero only for `Psm` (reserve) and `Stake` (input
     *      token); `sp`, `minSyOut`, and `minUAssetMinted` may be nonzero only for `Stake`.
     * @param f Leg funding instruction under validation.
     * @param preorderLeg Whether the leg is the preorder leg.
     * @param leveragedFamily Whether the calling entrypoint is the leveraged family.
     */
    function _validateFundInput(FundInput calldata f, bool preorderLeg, bool leveragedFamily) internal pure {
        if (preorderLeg) {
            if (f.source != FundSource.UAsset && f.source != FundSource.Psm) {
                revert FundSourceNotAllowed(f.source, leveragedFamily);
            }
        } else if (leveragedFamily) {
            if (f.source == FundSource.Stake) revert FundSourceNotAllowed(f.source, true);
        } else {
            if (f.source == FundSource.Credit) revert FundSourceNotAllowed(f.source, false);
        }
        if (f.source != FundSource.Psm && f.source != FundSource.Stake && f.token != address(0)) {
            revert FundFieldMustBeZero(f.source);
        }
        if (f.source != FundSource.Stake && (f.sp != address(0) || f.minSyOut != 0 || f.minUAssetMinted != 0)) {
            revert FundFieldMustBeZero(f.source);
        }
    }

    /**
     * @notice Returns the native value a leg's funding source requires the caller to attach.
     * @dev Only the PSM and stake sources accept a native-currency input token; every other source
     *      takes an ERC20 pulled from the caller and must arrive with zero attached value.
     * @param f Leg funding instruction.
     * @return Native amount the leg contributes to the entrypoint's `msg.value` expectation.
     */
    function _legNativeValue(FundInput calldata f) internal pure returns (uint256) {
        if ((f.source == FundSource.Psm || f.source == FundSource.Stake) && f.token == NATIVE) return f.amount;
        return 0;
    }

    /**
     * @notice Runs the genesis leg of the normal-family combined entrypoint.
     * @dev The uAsset-funded branch pulls the caller's uAsset; the PSM-funded branch mints through
     *      the registered PSM and reuses `_genesisTail` (its consumer is `launcher.genesis`, the
     *      exact single-caller semantics that tail was factored for). The stake-funded branch
     *      mirrors the single-leg CDP-gate entries: it resolves the trusted SP and its canonical
     *      SY with the launcher-parity gate, then binds the SP's uAsset family to the
     *      verse-resolved uAsset (`SP.uAsset()` must equal it, else `RouterTargetMismatch` with
     *      the family addresses before any pull or deposit), and then either charges SY directly
     *      (token == canonical SY; `amount` is in SY units and `minSyOut` is accepted but
     *      ignored — FundInput's only explicit silent-ignore exception, since no deposit
     *      conversion runs) or converts through `SY.deposit` under `minSyOut`, and
     *      thin-forwards into `SP.stakeForGenesis`, whose uAsset-to-launcher atomic hand-off and
     *      full-consumption assertion are SP-side.
     * @param uAsset The verse's uAsset resolved by the preamble.
     * @param verseId Opaque launcher-assigned identifier for the target verse.
     * @param f Genesis-leg funding instruction (already validated by the preamble).
     * @param user User credited for the genesis action.
     * @param nativeValueIn Native value forwarded to the PSM mint or SY deposit (preamble-validated;
     *      `f.amount` when the leg's input token is NATIVE, `0` otherwise).
     */
    function _runGenesisLeg(address uAsset, uint256 verseId, FundInput calldata f, address user, uint256 nativeValueIn)
        internal
    {
        if (f.source == FundSource.UAsset) {
            _uAssetToLauncher(uAsset, verseId, f.amount, user, false);
        } else if (f.source == FundSource.Psm) {
            (uint256 minted, uint256 baseline) =
                _psmMintForRouter(_registeredPsm(uAsset, f.token), uAsset, f.token, f.amount, nativeValueIn);
            _genesisTail(uAsset, verseId, user, minted, baseline);
        } else {
            // Stake leg: when the leg's token is the SP's canonical SY it is charged directly in
            // SY units (equivalent to `genesisBySY`), otherwise it converts through `SY.deposit`
            // (equivalent to `genesisByToken`); the SP performs the uAsset→launcher atomic
            // hand-off and full-consumption assertion itself.
            address SY = _trustedSYWithLauncherParity(f.sp);
            // Verse↔SP uAsset family binding: the SP must mint the verse's own uAsset family, checked
            // before any pull or deposit. The payload reuses `RouterTargetMismatch` (SY-flavored param
            // names, same three-party SP/expected/actual shape) with the family addresses loaded.
            address spUAsset = IOutrunStakeManager(f.sp).uAsset();
            if (spUAsset != uAsset) revert RouterTargetMismatch(f.sp, uAsset, spUAsset);
            uint256 amountInSY;
            if (f.token == SY) {
                _transferFrom(IERC20(SY), msg.sender, address(this), f.amount);
                amountInSY = f.amount;
            } else {
                amountInSY = _mintSY(SY, f.token, address(this), f.amount, f.minSyOut, nativeValueIn);
            }
            _forwardGenesisToSP(f.sp, SY, amountInSY, user, verseId, f.minUAssetMinted);
        }
    }

    /**
     * @notice Runs the leveraged-genesis interest leg of the leveraged-family combined entrypoint.
     * @dev The uAsset-funded branch pulls the caller's uAsset and pays it to POLend as interest
     *      under the strict full-consumption post-condition, mirroring `leveragedGenesisByPSM`'s
     *      tail. The PSM-funded branch mints through the registered PSM and keeps that same
     *      explicit tail (it does not reuse `_genesisTail`, whose consumer is hardcoded to
     *      `launcher.genesis`). The credit-funded branch resolves the family's credit token
     *      through the POLend-registered factory (`IGenesisCreditRegistry(...).creditOf(uAsset)`,
     *      the deterministic per-uAsset derivation in production); a zero resolution reverts
     *      `NoCreditForUAsset` before any pull, then the pull / exact-approve /
     *      `leveragedGenesisWithCredit` / full-consumption sequence runs with the same discipline
     *      as the uAsset branch. The router approves the factory-resolved token while POLend's
     *      hot path pulls its own cached market token, so a factory/cache divergence surfaces as
     *      POLend's own transfer failure (fail-closed) instead of leaving a residual.
     * @param uAsset The verse's uAsset resolved by the preamble.
     * @param verseId POLend market identifier the interest is booked against.
     * @param f Genesis-leg funding instruction (already validated by the preamble).
     * @param user User credited with the borrowed debt.
     * @param polend_ Owner-registered POLend target (already market-checked by the entrypoint).
     * @param nativeValueIn Native value forwarded to the PSM mint (preamble-validated; `f.amount`
     *      when the leg's reserve token is NATIVE, `0` otherwise).
     */
    function _runLeveragedGenesisLeg(
        address uAsset,
        uint256 verseId,
        FundInput calldata f,
        address user,
        address polend_,
        uint256 nativeValueIn
    ) internal {
        if (f.source == FundSource.UAsset) {
            uint256 baseline = IERC20(uAsset).balanceOf(address(this));
            GenesisGateLib.requireLauncherAmount(f.amount);
            _transferFrom(IERC20(uAsset), msg.sender, address(this), f.amount);
            _approveExact(uAsset, polend_, f.amount);
            IPOLendGenesis(polend_).leveragedGenesis(verseId, f.amount, user);
            GenesisGateLib.assertFullConsumption(uAsset, polend_, baseline);
        } else if (f.source == FundSource.Psm) {
            (uint256 minted, uint256 baseline) =
                _psmMintForRouter(_registeredPsm(uAsset, f.token), uAsset, f.token, f.amount, nativeValueIn);
            GenesisGateLib.requireLauncherAmount(minted);
            _approveExact(uAsset, polend_, minted);
            IPOLendGenesis(polend_).leveragedGenesis(verseId, minted, user);
            GenesisGateLib.assertFullConsumption(uAsset, polend_, baseline);
        } else {
            // Credit leg: the credit token resolves deterministically from POLend's factory
            // (CREATE3 keyed by uAsset); the exact-approve and full-consumption assertion follow
            // the same discipline as the uAsset leg.
            address credit = IGenesisCreditRegistry(IPOLendGenesis(polend_).creditFactory()).creditOf(uAsset);
            if (credit == address(0)) revert NoCreditForUAsset(uAsset);
            uint256 baseline = IERC20(credit).balanceOf(address(this));
            _transferFrom(IERC20(credit), msg.sender, address(this), f.amount);
            _approveExact(credit, polend_, f.amount);
            IPOLendGenesis(polend_).leveragedGenesisWithCredit(verseId, f.amount, user);
            GenesisGateLib.assertFullConsumption(credit, polend_, baseline);
        }
    }

    /**
     * @notice Runs the preorder leg shared by both combined entrypoints.
     * @dev The uAsset-funded branch pulls the caller's uAsset; the PSM-funded branch mints through
     *      the registered PSM with an explicit tail (consumer `launcher.preorder`, so no
     *      `_genesisTail` reuse) and books the fee-adjusted mint output — not the reserve input —
     *      as the preorder base.
     * @param uAsset The verse's uAsset resolved by the preamble.
     * @param verseId Opaque launcher-assigned identifier for the target verse.
     * @param f Preorder-leg funding instruction (already validated by the preamble).
     * @param user User credited for the preorder participation.
     * @param nativeValueIn Native value forwarded to the PSM mint (preamble-validated; `f.amount`
     *      when the leg's reserve token is NATIVE, `0` otherwise).
     */
    function _runPreorderLeg(address uAsset, uint256 verseId, FundInput calldata f, address user, uint256 nativeValueIn)
        internal
    {
        if (f.source == FundSource.UAsset) {
            _uAssetToLauncher(uAsset, verseId, f.amount, user, true);
        } else {
            (uint256 minted, uint256 baseline) =
                _psmMintForRouter(_registeredPsm(uAsset, f.token), uAsset, f.token, f.amount, nativeValueIn);
            GenesisGateLib.requireLauncherAmount(minted);
            _approveExact(uAsset, memeverseLauncher, minted);
            IMemeverseLauncher(memeverseLauncher).preorder(verseId, minted, user);
            GenesisGateLib.assertFullConsumption(uAsset, memeverseLauncher, baseline);
        }
    }

    /**
     * @notice Consumer tail shared by the uAsset-funded genesis and preorder legs: uint128 bound,
     *      caller pull, exact launcher approval, and the launcher call, followed by the strict
     *      full-consumption post-condition.
     * @dev Both legs share the same physical gate discipline as `genesisByPSM`'s tail: the bound
     *      runs before the pull and the approval, and the post-condition compares the router's
     *      uAsset balance against the pre-pull snapshot baseline.
     * @param uAsset The verse's uAsset paid into the launcher.
     * @param verseId Opaque launcher-assigned identifier for the target verse.
     * @param amount uAsset amount pulled from the caller and forwarded.
     * @param user User credited for the launcher action.
     * @param preorderLeg Whether the launcher call is `preorder` (true) or `genesis` (false).
     */
    function _uAssetToLauncher(address uAsset, uint256 verseId, uint256 amount, address user, bool preorderLeg)
        internal
    {
        uint256 baseline = IERC20(uAsset).balanceOf(address(this));
        GenesisGateLib.requireLauncherAmount(amount);
        _transferFrom(IERC20(uAsset), msg.sender, address(this), amount);
        _approveExact(uAsset, memeverseLauncher, amount);
        if (preorderLeg) {
            IMemeverseLauncher(memeverseLauncher).preorder(verseId, amount, user);
        } else {
            IMemeverseLauncher(memeverseLauncher).genesis(verseId, amount, user);
        }
        GenesisGateLib.assertFullConsumption(uAsset, memeverseLauncher, baseline);
    }

    /**
     * @notice Thin fund-flow forward into the SP genesis open: exact SY approval then delegation.
     * @dev Single source for the tail both SP-backed genesis entries share (same call count,
     *      order, targets, and parameters). Internal, so the SP still observes the router as caller.
     * @param SP Staking position contract opening the genesis position.
     * @param SY Standardized yield token approved and staked.
     * @param amountInSY SY amount approved to the SP and passed to the genesis open.
     * @param genesisUser User credited for the genesis action.
     * @param verseId Launcher-assigned identifier for the target verse.
     * @param minUAssetMinted Minimum acceptable minted uAsset forwarded to the SP.
     */
    function _forwardGenesisToSP(
        address SP,
        address SY,
        uint256 amountInSY,
        address genesisUser,
        uint256 verseId,
        uint256 minUAssetMinted
    ) internal {
        _approveExact(SY, SP, amountInSY);
        // Callers observe the open through the SP's Stake/StakeForGenesis events.
        IOutrunStakeManager(SP).stakeForGenesis(amountInSY, genesisUser, verseId, minUAssetMinted);
    }

    /**
     * @notice Approves exactly `amount` to `spender`, reverting on infinite approval.
     * @dev uint256.max approval is rejected so router flows always use finite, exact approvals.
     * Native token (NATIVE = address(0)) is a no-op.
     * @param token ERC20 token to approve (NATIVE for native currency, which skips approval).
     * @param spender Address granted the allowance.
     * @param amount Exact allowance amount (must not be type(uint256).max).
     */
    function _approveExact(address token, address spender, uint256 amount) internal {
        if (token == NATIVE) return;
        // Reject infinite approval — leftover allowance after the operation masks whether the spender took the expected amount.
        if (amount == type(uint256).max) revert InvalidParam();
        _safeApprove(token, spender, amount);
    }

    /**
     * @notice Sets the memeverse launcher address.
     * @dev Registration performs no code check. Test-phase helper for constructor and `setMemeverseLauncher`; production will inline this into the constructor and remove the setter when `memeverseLauncher` becomes `immutable`.
     * @param _memeverseLauncher New launcher contract address.
     */
    function _setMemeverseLauncher(address _memeverseLauncher) internal {
        address oldLauncher = memeverseLauncher;
        memeverseLauncher = _memeverseLauncher;
        emit SetMemeverseLauncher(oldLauncher, _memeverseLauncher);
    }

    /**
     * @notice Sets the POLend target for the leveraged-genesis entrypoint.
     * @dev Registration performs no code check. Helper for `setPolend`; a zero address revokes and `leveragedGenesisByPSM` fails closed with `PolendNotSet` afterwards.
     * @param _polend New POLend contract address.
     */
    function _setPolend(address _polend) internal {
        address oldPolend = polend;
        polend = _polend;
        emit SetPolend(oldPolend, _polend);
    }

    /**
     * @notice Resolves the registered PSM for a (uAsset, reserveToken) pair.
     * @dev Shared registry gate of both PSM-backed genesis entries: the pair lookup, the
     *      unregistered check (`UnregisteredPsm(uAsset, reserveToken)` with the registry keys), and
     *      both binding re-reads run here in that fixed order, before any user asset moves or
     *      allowance is granted. Mirrors the SP re-read style: comparing the PSM's live bindings
     *      against the registry keys on every call makes a drifted binding fail closed before
     *      funds move.
     * @param uAsset Universal asset key of the registry pair.
     * @param reserveToken Reserve token key of the registry pair (`NATIVE` for the native currency).
     * @return psm Registered PSM address; nonzero with bindings matching the registry keys.
     */
    function _registeredPsm(address uAsset, address reserveToken) internal view returns (address psm) {
        psm = psmForUAsset[uAsset][reserveToken];
        if (psm == address(0)) revert UnregisteredPsm(uAsset, reserveToken);
        _requirePsmBindings(psm, uAsset, reserveToken);
    }

    /**
     * @notice Resolves the configured POLend target and re-reads its verse-market uAsset binding.
     * @dev Single source for the POLend family gate both leveraged-genesis entries share
     *      (`leveragedGenesisByPSM` and the combined `leveragedGenesisAndPreorder`), so the
     *      zero-target check, the `marketUAsset(verseId)` binding re-read, their order, and their
     *      errors cannot drift between sites. Both re-reads fail closed before any pull, mirroring
     *      the SP-parity and PSM-binding gate style.
     * @param verseId POLend market identifier the binding is re-read against.
     * @param uAsset Family uAsset the market must be bound to (the entry parameter on
     *      `leveragedGenesisByPSM`, the launcher-resolved uAsset on the combined entry).
     * @return polend_ Configured POLend target, nonzero with its market binding matching `uAsset`.
     */
    function _polendMarketGate(uint256 verseId, address uAsset) internal view returns (address polend_) {
        polend_ = polend;
        if (polend_ == address(0)) revert PolendNotSet();
        address marketUAsset = IPOLendGenesis(polend_).marketUAsset(verseId);
        if (marketUAsset != uAsset) revert PolendMarketUAssetMismatch(verseId, uAsset, marketUAsset);
    }

    function _requireTrustedSY(address SY) internal view {
        if (!trustedSY[SY]) revert UntrustedRouterTarget(SY);
    }

    function _trustedSYForSP(address SP) internal view returns (address SY) {
        SY = trustedSYForSP[SP];
        if (SY == address(0)) revert UntrustedRouterTarget(SP);
        _requireSpSyPair(SP, SY);
    }

    /// @dev Single source for the CDP-gate preamble shared by the execution and preview entries,
    ///      so the registry re-read and the launcher-parity re-read, their order, and their errors
    ///      cannot drift between sites.
    function _trustedSYWithLauncherParity(address SP) internal view returns (address SY) {
        SY = _trustedSYForSP(SP);
        _requireLauncherParity(SP);
    }

    function _requireLauncherParity(address SP) internal view {
        address routerLauncher = memeverseLauncher;
        address spLauncher = IOutrunStakeManager(SP).genesisLauncher();
        if (routerLauncher != spLauncher) revert GenesisLauncherMismatch(routerLauncher, spLauncher);
    }

    /// @dev Compares the SP's live canonical SY against the pair key, in gate order (trusted check,
    ///      then the external SY read). Shared by registration and the per-call SP gate so the trusted
    ///      check, the external read, their order, and their errors cannot drift between sites.
    function _requireSpSyPair(address SP, address SY) private view {
        _requireTrustedSY(SY);
        address actualSY = IOutrunStakeManager(SP).SY();
        if (actualSY != SY) revert RouterTargetMismatch(SP, SY, actualSY);
    }

    /// @dev Compares the PSM's live bindings against the registry keys, in binding order (uAsset leg,
    ///      then reserve leg). Shared by registration and the per-call genesis gate so the two external
    ///      view reads, their order, and their errors cannot drift between sites.
    function _requirePsmBindings(address psm, address uAsset, address reserveToken) private view {
        address actualUAsset = IPSM(psm).uAsset();
        if (actualUAsset != uAsset) revert PsmBindingMismatch(psm, uAsset, actualUAsset);
        address actualReserveToken = IPSM(psm).reserveToken();
        if (actualReserveToken != reserveToken) revert PsmReserveMismatch(psm, reserveToken, actualReserveToken);
    }
}
