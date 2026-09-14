// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IOutrunRouter} from "./interfaces/IOutrunRouter.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {IPOLendGenesis} from "./interfaces/IPOLendGenesis.sol";
import {IPSM} from "../psm/interfaces/IPSM.sol";
import {IStandardizedYield} from "../yield/interfaces/IStandardizedYield.sol";
import {IERC20, TokenHelper} from "../libraries/TokenHelper.sol";
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
 */
contract OutrunRouter is IOutrunRouter, TokenHelper, Ownable {
    // These targets are configured after deployment; owner setters remain live for dynamic addition under Ownable (multisig off-chain).
    mapping(address => bool) public trustedSY;
    mapping(address => address) public trustedSYForSP;
    // (uAsset, reserveToken) -> PSM pairing for the PSM-gate genesis entrypoint (path A); zero value means unregistered.
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
            if (!trustedSY[SY]) revert UntrustedRouterTarget(SY);
            address actualSY = IOutrunStakeManager(SP).SY();
            if (actualSY != SY) revert RouterTargetMismatch(SP, SY, actualSY);
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
        amountInSYOut = _mintSY(SY, tokenIn, receiver, amountInput, minSyOut);
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
        address psm = _registeredPsm(uAsset, reserveToken);
        // Zero credited user would burn the launch into an unrecoverable sink; fail before any pull.
        if (genesisUser == address(0)) revert ZeroInput();

        (uint256 amountOut, uint256 uAssetBalanceBefore) = _psmMintForRouter(psm, uAsset, reserveToken, amountIn);
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
        address SY = _trustedSYWithLauncherParity(SP);
        // (1) Convert the caller's token into SY held by the router (registry check ran before any funds moved).
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, minSyOut);
        // (2) Thin forward into the SP genesis open.
        _forwardGenesisToSP(SP, SY, amountInSY, genesisUser, verseId, minUAssetMinted);
    }

    /// @inheritdoc IOutrunRouter
    function genesisBySY(address SP, uint256 amountInSY, uint256 verseId, address genesisUser, uint256 minUAssetMinted)
        external
        nonReentrant
    {
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
        address psm = _registeredPsm(uAsset, reserveToken);
        // POLend gate: target configured and the verse market is bound to this uAsset family;
        // both re-reads fail closed before any pull, mirroring the launcher-parity style.
        address polend_ = polend;
        if (polend_ == address(0)) revert PolendNotSet();
        address marketUAsset = IPOLendGenesis(polend_).marketUAsset(verseId);
        if (marketUAsset != uAsset) revert PolendMarketUAssetMismatch(verseId, uAsset, marketUAsset);
        // The interest ledger target must not be a burn sink; fail before any pull.
        if (genesisUser == address(0)) revert ZeroInput();

        (uint256 amountOut, uint256 uAssetBalanceBefore) = _psmMintForRouter(psm, uAsset, reserveToken, amountIn);
        // (3) Pay the minted uAsset to POLend as interest; the borrowed debt is credited to genesisUser.
        _approveExact(uAsset, polend_, amountOut);
        borrowedAmount = IPOLendGenesis(polend_).leveragedGenesis(verseId, amountOut, genesisUser);
        // (4) POLend must have consumed the approval in full; any residual reverts the whole call.
        GenesisGateLib.assertFullConsumption(uAsset, polend_, uAssetBalanceBefore);
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
        // Execution rejects opens against a drifted launcher, so the quote must fail the same
        // way instead of pricing an open that cannot execute.
        address SY = _trustedSYWithLauncherParity(SP);
        uint256 amountInSY = IStandardizedYield(SY).previewDeposit(tokenIn, tokenAmount);
        UAssetMintable = IOutrunStakeManager(SP).previewStake(amountInSY);
    }

    /// @inheritdoc IOutrunRouter
    function previewStakeFromSY(address SP, uint256 amountInSY) external view returns (uint256 UAssetMintable) {
        // Same launcher-parity gate as the execution path: a quote for an unexecutable open reverts.
        _trustedSYWithLauncherParity(SP);
        UAssetMintable = IOutrunStakeManager(SP).previewStake(amountInSY);
    }

    /**
     * @notice Mints Standardized Yield by depositing an input token into the SY contract.
     * @dev Pulls `tokenIn` from the caller and forwards it to `SY.deposit`. Supports both
     * ERC20 and native tokens (NATIVE sentinel = address(0)).
     * @param SY Standardized yield contract that receives the deposit.
     * @param tokenIn Token to supply when minting SY (NATIVE for the chain's native currency).
     * @param receiver Recipient of the minted SY.
     * @param amountInput Amount of input token to deposit.
     * @param minSyOut Minimum acceptable SY output or the call reverts.
     * @return amountInSYOut Amount of SY minted for `receiver`.
     */
    function _mintSY(address SY, address tokenIn, address receiver, uint256 amountInput, uint256 minSyOut)
        internal
        returns (uint256 amountInSYOut)
    {
        _requireTrustedSY(SY);

        _transferIn(tokenIn, msg.sender, amountInput);

        uint256 amountInNative = tokenIn == NATIVE ? amountInput : 0;
        _approveExact(tokenIn, SY, amountInput);
        // SY passed the trusted-registry check above; native value only reaches registered SY implementations.
        amountInSYOut = IStandardizedYield(SY).deposit{value: amountInNative}(receiver, tokenIn, amountInput, minSyOut);
    }

    /**
     * @notice Shared movement tail of the two PSM-backed genesis entries: pre-mint baseline
     *      snapshot, reserve pull from the caller, exact PSM approval, and the face-value mint
     *      to the router.
     * @dev Single source for the sequence both PSM gates must keep identical (baseline-before-mint
     *      placement, exact approval, value forwarding); the per-entry registry gates run in the
     *      callers before this tail.
     * @param psm Registered PSM handling the reserve-to-uAsset face-value mint.
     * @param uAsset Universal asset minted by the PSM.
     * @param reserveToken Reserve token pulled from the caller (`NATIVE` for the chain's native currency).
     * @param amountIn Reserve amount to swap in, in the reserve token's own decimals.
     * @return amountOut uAsset minted to the router by the PSM.
     * @return uAssetBalanceBefore Pre-mint snapshot of the router's uAsset balance (assertion baseline).
     */
    function _psmMintForRouter(address psm, address uAsset, address reserveToken, uint256 amountIn)
        internal
        returns (uint256 amountOut, uint256 uAssetBalanceBefore)
    {
        uAssetBalanceBefore = IERC20(uAsset).balanceOf(address(this));
        // Native leg: msg.value == amountIn; ERC20 leg: msg.value == 0.
        _transferIn(reserveToken, msg.sender, amountIn);
        _approveExact(reserveToken, psm, amountIn);
        uint256 amountInNative = reserveToken == NATIVE ? amountIn : 0;
        amountOut = IPSM(psm).mint{value: amountInNative}(address(this), amountIn);
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
        IMemeverseLauncher(launcher).genesis(verseId, uint128(mintedUAsset), genesisUser);
        GenesisGateLib.assertFullConsumption(uAsset, launcher, uAssetBalanceBefore);
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

    function _requireTrustedSY(address SY) internal view {
        if (!trustedSY[SY]) revert UntrustedRouterTarget(SY);
    }

    function _trustedSYForSP(address SP) internal view returns (address SY) {
        SY = trustedSYForSP[SP];
        if (SY == address(0)) revert UntrustedRouterTarget(SP);
        _requireTrustedSY(SY);
        address actualSY = IOutrunStakeManager(SP).SY();
        if (actualSY != SY) revert RouterTargetMismatch(SP, SY, actualSY);
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
