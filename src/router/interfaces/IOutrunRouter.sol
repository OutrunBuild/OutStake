// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun router interface
 * @notice User-facing entry surface of the OutStake protocol: token-to-SY conversion and genesis
 *      flows. Implemented by OutrunRouter; every user-facing funded entrypoint is
 *      caller-funded (pulls its input from msg.sender) and, except the deterministic PSM-gated entries
 *      `genesisByPSM` and `leveragedGenesisByPSM` (which take no floor parameter), enforces a per-flow
 *      slippage floor. Owner-managed target
 *      registration is required before a caller-supplied SY, SP, or uAsset-family PSM can reach any downstream
 *      contract.
 *      uAsset (Universal Asset) is the protocol's unified debt/liquidity layer token; `NATIVE` is `address(0)` and
 *      selecting `tokenIn == address(0)` supplies the chain's native currency on token input entrypoints.
 */
interface IOutrunRouter {
    /**
     * @notice Funding source a combined-entrypoint leg draws its input from.
     * @dev `UAsset` pulls the verse's uAsset directly from the caller; `Psm` mints uAsset through the
     *      owner-registered PSM for the (uAsset, reserveToken) pair; `Stake` converts an input token
     *      into a genesis CDP position through a trusted SP; `Credit` pays pre-minted GenesisCredit.
     *      The allowed matrix is family-scoped and enforced per leg before any funds move
     *      (see `FundSourceNotAllowed`).
     */
    enum FundSource {
        UAsset,
        Psm,
        Stake,
        Credit
    }

    /**
     * @notice Per-leg funding instruction of a combined entrypoint call.
     * @dev Fields unused by the selected `source` are not ignored: they must be left zero or the
     *      call reverts `FundFieldMustBeZero` before any funds move.
     * @param source Funding source the leg draws from.
     * @param token Input token address (`NATIVE` = address(0) for the native currency); must be zero
     *      unless `source` is `Psm` (the reserve token) or `Stake` (the token converted into SY).
     * @param amount Input amount to fund the leg with.
     * @param sp Stake manager driving the stake-funded genesis leg; must be zero unless `source` is `Stake`.
     * @param minSyOut Minimum acceptable SY output for the stake-funded conversion; zero disables the
     *      floor. Accepted but ignored when `token` is the SP's canonical SY (direct charge in SY
     *      units; the only explicitly silent-ignored `FundInput` field value).
     * @param minUAssetMinted Minimum acceptable minted uAsset for the stake-funded genesis; zero disables the floor.
     */
    struct FundInput {
        FundSource source;
        address token;
        uint256 amount;
        address sp;
        uint256 minSyOut;
        uint256 minUAssetMinted;
    }

    /**
     * @notice Emitted when an SY target is added to or removed from the router registry.
     */
    event TrustedSYUpdated(address indexed SY, bool trusted);

    /**
     * @notice Emitted when an SP is paired with its canonical SY, or revoked with address(0).
     */
    event TrustedSPUpdated(address indexed SP, address indexed SY);

    /**
     * @notice Emitted when a (uAsset, reserveToken) pair is paired with its PSM, or revoked with address(0).
     */
    event PsmForUAssetUpdated(address indexed uAsset, address indexed reserveToken, address indexed psm);

    /**
     * @notice Emitted when the memeverse launcher address changes.
     * @param oldLauncher Previous launcher contract address.
     * @param newLauncher New launcher contract address.
     */
    event SetMemeverseLauncher(address indexed oldLauncher, address indexed newLauncher);

    /// @notice Emitted when the POLend target for the leveraged-genesis entry changes.
    event SetPolend(address indexed oldPolend, address indexed newPolend);

    event Sweep(address indexed token, address indexed to, uint256 amount);

    error UntrustedRouterTarget(address target);
    error RouterTargetMismatch(address SP, address expectedSY, address actualSY);

    /**
     * @notice Thrown by `genesisByPSM` and `leveragedGenesisByPSM` when the (uAsset, reserveToken) pair has
     *      no registered PSM.
     */
    error UnregisteredPsm(address uAsset, address reserveToken);

    /**
     * @notice Thrown when a PSM's bound uAsset does not match the registry key: at registration time by
     *      `setPsmForUAsset`, and at runtime by `genesisByPSM`'s and `leveragedGenesisByPSM`'s per-call
     *      binding re-read.
     */
    error PsmBindingMismatch(address psm, address uAsset, address actualUAsset);

    /**
     * @notice Thrown when a PSM's bound reserve does not match the registry key: at registration time by
     *      `setPsmForUAsset`, and at runtime by `genesisByPSM`'s and `leveragedGenesisByPSM`'s per-call
     *      binding re-read.
     */
    error PsmReserveMismatch(address psm, address reserveToken, address actualReserveToken);

    /**
     * @notice Thrown when the router's launcher and the SP's genesis launcher diverge.
     * @dev Thrown by `genesisByToken`/`genesisBySY` and by the `previewStakeFromToken`/`previewStakeFromSY`
     *      quotes when `memeverseLauncher != IOutrunStakeManager(SP).genesisLauncher()`.
     *      Mirrors the existing binding re-read pattern (`PsmBindingMismatch`/`RouterTargetMismatch`): the mismatch is checked
     *      before any user funds move or allowances are granted, so a drifted launcher fails closed.
     *      The previews enforce the same check, so within the launcher-drift domain a quote never describes an open the
     *      execution path would reject. The parity comparison is equality-only with no zero-address exclusion: with
     *      both launchers unset it passes, the previews still quote, and execution reverts at the SP-side zero-address
     *      gate with `GenesisLauncherNotSet` — a successful quote is not evidence that a genesis launcher is wired.
     */
    error GenesisLauncherMismatch(address routerLauncher, address spLauncher);

    /**
     * @notice Thrown by `genesisByPSM` and `leveragedGenesisByPSM` when `genesisUser` is the zero address.
     * @dev Scoped to `genesisUser` only; other zero inputs keep each function's existing errors.
     */
    error ZeroInput();

    /// @notice Thrown by `leveragedGenesisByPSM` when the POLend target has not been configured.
    error PolendNotSet();

    /// @notice Thrown by `leveragedGenesisByPSM` when the verse market's bound uAsset diverges from
    ///      the registry-keyed uAsset (an unregistered verse reads address(0) and fails closed here).
    error PolendMarketUAssetMismatch(uint256 verseId, address uAsset, address marketUAsset);

    /**
     * @notice Thrown by the combined entrypoints when a leg's funding source is outside the family's
     *      allowed matrix; checked before any funds move.
     * @dev Family matrix: the genesis leg rejects `Credit` on the normal family and `Stake` on the
     *      leveraged family; the preorder leg accepts only `UAsset` and `Psm` on both families.
     * @param source Rejected funding source.
     * @param leveragedFamily Whether the rejecting entrypoint is the leveraged family
     *      (`leveragedGenesisAndPreorder`).
     */
    error FundSourceNotAllowed(FundSource source, bool leveragedFamily);

    /**
     * @notice Thrown by the combined entrypoints when a `FundInput` sets a field its funding source
     *      leaves unused; checked before any funds move.
     * @param source Funding source whose must-be-zero fields are set.
     */
    error FundFieldMustBeZero(FundSource source);

    /// @notice Thrown by `leveragedGenesisAndPreorder`'s credit-funded genesis leg when no
    ///      GenesisCredit token is registered for the uAsset family; fails closed before any funds
    ///      move.
    error NoCreditForUAsset(address uAsset);

    /**
     * @notice Registers or revokes a standardized-yield target for router entrypoints.
     * @dev Owner-only configuration. Registration performs no code check on the token; revocation uses `trusted = false`.
     */
    function setTrustedSY(address SY, bool trusted) external;

    /**
     * @notice Registers or revokes an SP and its canonical SY pair.
     * @dev Owner-only configuration. Registration performs no code check on the token. A nonzero SY must already be trusted and must equal `SP.SY()`.
     */
    function setTrustedSP(address SP, address SY) external;

    /**
     * @notice Registers or revokes the PSM paired with a (uAsset, reserveToken) pair for the PSM-gate genesis
     *      entrypoints.
     * @dev Owner-only configuration. Registration performs no code check. A nonzero PSM's `IPSM.uAsset()` must equal
     *      the registered `uAsset` (binding mismatch reverts PsmBindingMismatch) and its `IPSM.reserveToken()`
     *      must equal the registered `reserveToken` (mismatch reverts PsmReserveMismatch); revocation passes
     *      `psm == address(0)` and only affects subsequent `genesisByPSM` and `leveragedGenesisByPSM`
     *      calls for that pair (both entries resolve the pair through the same registry lookup).
     * @param uAsset Family uAsset served by the PSM.
     * @param reserveToken Reserve token served by the PSM (`NATIVE` = address(0) for the native currency).
     * @param psm PSM handling the pair's reserve-to-uAsset swaps, or address(0) to revoke.
     */
    function setPsmForUAsset(address uAsset, address reserveToken, address psm) external;

    /**
     * @notice Deposits an input token into a standardized yield contract.
     * @dev Caller-funded path. Always pulls `tokenIn` from `msg.sender` before forwarding the deposit into SY;
     * native deposits are forwarded as `msg.value`; `tokenIn == address(0)` (`NATIVE`) selects the native currency.
     * Zero floor disables protection: `minSyOut == 0` silently accepts any positive SY output.
     * @param SY Standardized yield contract that receives the deposit.
     * @param tokenIn Token to supply when minting SY (`NATIVE` = address(0) for the native currency).
     * @param receiver Recipient of the minted SY.
     * @param amountInput Amount of input token to deposit.
     * @param minSyOut Minimum acceptable SY output; `0` means no slippage protection.
     * @return amountInSYOut Amount of SY minted for `receiver`.
     */
    function mintSYFromToken(address SY, address tokenIn, address receiver, uint256 amountInput, uint256 minSyOut)
        external
        payable
        returns (uint256 amountInSYOut);

    /**
     * @notice Redeems standardized yield into an output token.
     * @dev Caller-funded path. Requires an owner-registered SY, pulls SY from `msg.sender` into the SY contract and calls redeem with
     * `burnFromInternalBalance = true`. Zero floor disables protection: `minTokenOut == 0` silently accepts any positive token output.
     * @dev Deployment precondition: each registered SY must be configured so `SY.trustedRouter() == address(this)`
     * (the SY's owner calls `SY.setTrustedRouter(address(this))` on the SY); otherwise the call reverts with
     * `SYUnauthorizedInternalRedeemer(address(router))` inside `SY.redeem(..., true)`. On router rotation the new
     * router must be set on every SY before its redemption entry is opened and the old one revoked.
     * @param SY Standardized yield contract being redeemed.
     * @param receiver Recipient of the redeemed token output.
     * @param tokenOut Token requested on redemption.
     * @param amountInSY Amount of SY to redeem.
     * @param minTokenOut Minimum acceptable token output; `0` means no slippage protection.
     * @return amountInTokenOut Amount of `tokenOut` sent to `receiver`.
     */
    function redeemSyToToken(address SY, address receiver, address tokenOut, uint256 amountInSY, uint256 minTokenOut)
        external
        returns (uint256 amountInTokenOut);

    /**
     * @notice Mints uAsset through the owner-registered PSM for that (uAsset, reserveToken) pair and forwards the full
     * minted amount into launcher genesis.
     * @dev Caller-funded path (PSM gate: no position, no debt). Requires the
     * owner-registered pair -> PSM entry and re-reads `IPSM(psm).uAsset()` and `IPSM(psm).reserveToken()`
     * against the registry keys on every call; drift reverts PsmBindingMismatch/PsmReserveMismatch before
     * any funds move. The reserve leg follows the
     * native/ERC20 value rules: `reserveToken == NATIVE` requires `msg.value == amountIn`, an ERC20 leg
     * requires `msg.value == 0` and a prior caller approval to the router. The PSM output is deterministic
     * face-value math (`quoteMint` equals the `mint` output on inputs that quote non-zero and fit the
     * remaining stock-cap headroom; a dust input that floors to a zero output quotes 0 while `mint`
     * reverts ZeroInput; beyond the headroom the quote stays positive while `mint` reverts
     * StockCapExceeded), so there is no slippage floor parameter.
     * `amountIn` is uint256 (no input-side cap); when the minted amount exceeds type(uint128).max the call
     * reverts InvalidParam(). After `genesis` returns, the router's uAsset balance must be back at its
     * pre-mint snapshot and the launcher allowance zero, else GenesisUAssetNotConsumed reverts the whole call.
     * @param uAsset Family uAsset minted through the PSM gate.
     * @param reserveToken Registered PSM reserve token to spend (`NATIVE` = address(0) for the native currency).
     * @param amountIn Reserve amount to swap in, in the reserve token's own decimals.
     * @param verseId Opaque launcher-assigned identifier for the target verse; the router forwards it unchanged and does not validate it.
     * @param genesisUser User credited for the genesis action.
     */
    function genesisByPSM(address uAsset, address reserveToken, uint256 amountIn, uint256 verseId, address genesisUser)
        external
        payable;

    /**
     * @notice Mints uAsset through the owner-registered PSM for that (uAsset, reserveToken) pair and forwards the
     * full minted amount as Memeverse leveraged-genesis interest, crediting the borrowed debt to `genesisUser`.
     * @dev Caller-funded path (PSM gate: no genesis launcher delivery, no CDP position). Requires the
     * owner-registered pair -> PSM entry and the owner-registered `polend` target, re-reads `IPSM(psm).uAsset()`
     * and `IPSM(psm).reserveToken()` against the registry keys on every call (drift reverts
     * PsmBindingMismatch/PsmReserveMismatch before any funds move), and re-reads
     * `IPOLendGenesis(polend).marketUAsset(verseId)` against `uAsset` (mismatch reverts
     * PolendMarketUAssetMismatch; an unregistered verse reads address(0) and takes the same path). A zero `polend`
     * reverts PolendNotSet and a zero `genesisUser` reverts ZeroInput, both before any funds move. The reserve leg
     * follows the native/ERC20 value rules: `reserveToken == NATIVE` requires `msg.value == amountIn`, an ERC20 leg
     * requires `msg.value == 0` and a prior caller approval to the router. Pricing is deterministic on both legs —
     * the PSM output is deterministic face-value math (`quoteMint` parity within the remaining stock-cap
     * headroom, so there is no slippage floor parameter) and POLend derives `borrowedAmount` from the interest
     * rate snapshotted at its market registration — and the minted amount is forwarded as uint256 interest (no
     * uint128 bound, no InvalidParam guard). After
     * `leveragedGenesis` returns, the router's uAsset balance must be back at its pre-mint snapshot and the
     * allowance to `polend` zero, else GenesisUAssetNotConsumed reverts the whole call. PSM-side (`ZeroInput`,
     * `StockCapExceeded`, `NotReserveMinter`, `EnforcedPause`) and POLend-side errors propagate unchanged; the
     * router emits no event of its own.
     * @param uAsset Family uAsset minted through the PSM gate and paid as interest.
     * @param reserveToken Registered PSM reserve token to spend (`NATIVE` = address(0) for the native currency).
     * @param amountIn Reserve amount to swap in, in the reserve token's own decimals.
     * @param verseId POLend market identifier the interest is booked against; the router forwards it unchanged and
     * validates only its uAsset pairing.
     * @param genesisUser User credited with the borrowed debt.
     * @return borrowedAmount uAsset-denominated debt generated for `genesisUser`, forwarded unchanged from POLend.
     */
    function leveragedGenesisByPSM(
        address uAsset,
        address reserveToken,
        uint256 amountIn,
        uint256 verseId,
        address genesisUser
    ) external payable returns (uint256 borrowedAmount);

    /**
     * @notice Atomically runs a genesis leg and a preorder leg for `user` against one verse, each leg
     *      funded by its own `FundInput`.
     * @dev Caller-funded path. The shared preamble validates both legs before any funds move: a zero
     *      `user` or leg amount reverts `ZeroInput`; the verse's uAsset is resolved through
     *      `IMemeverseLauncher(memeverseLauncher).getUAssetByVerseId(verseId)` and a zero read fails
     *      closed with `ZeroInput`; each leg's funding source is checked against the family matrix
     *      (reverting `FundSourceNotAllowed`: the genesis leg rejects `Credit`, the preorder leg
     *      accepts only `UAsset` and `Psm`) and unused fields must be zero (reverting
     *      `FundFieldMustBeZero`); and `msg.value` must equal the legs' combined native need
     *      (uAsset-funded legs take none; the sum is computed unchecked, so a wrapped sum that
     *      differs from `msg.value` reverts `NativeAmountMismatch` at the entry gate, while the
     *      exact wrap-to-zero pair — the two native legs summing to zero — with `msg.value == 0`
     *      passes the gate and reverts the whole call empty at the first native forwarding
     *      (PSM mint / SY deposit CALL value), still fail-closed with no fund movement). The uAsset- and
     *      PSM-funded genesis legs and the preorder leg fund `IMemeverseLauncher.genesis` /
     *      `IMemeverseLauncher.preorder`, each crediting `user` with the leg's full amount, and
     *      every such leg must consume its uAsset in full or the whole call reverts (GenesisGateLib
     *      full-consumption assertion). The stake-funded genesis leg goes through the
     *      owner-registered SP (same gates as `genesisByToken`/`genesisBySY`): the SP's uAsset
     *      family is bound to the verse-resolved uAsset (`SP.uAsset()` must equal it, else
     *      `RouterTargetMismatch` with the family addresses before any pull or deposit), a
     *      `token` equal to the SP's canonical SY is charged directly in SY units (its `minSyOut`
     *      is accepted but
     *      ignored — `FundInput`'s only explicit silent-ignore exception, since no deposit
     *      conversion runs), any other input token converts through `SY.deposit` under `minSyOut`,
     *      and the SP performs the value-parity mint, the atomic launcher hand-off, and the
     *      full-consumption assertion SP-side (the router never touches uAsset on that branch).
     * @param verseId Opaque launcher-assigned identifier for the target verse; the router resolves it
     *      to the verse's uAsset and forwards it unchanged.
     * @param genesisInput Funding instruction for the genesis leg.
     * @param preorderInput Funding instruction for the preorder leg.
     * @param user User credited for both the genesis action and the preorder participation.
     */
    function genesisAndPreorder(
        uint256 verseId,
        FundInput calldata genesisInput,
        FundInput calldata preorderInput,
        address user
    ) external payable;

    /**
     * @notice Atomically runs a leveraged-genesis interest leg and a preorder leg for `user` against
     *      one verse, each leg funded by its own `FundInput`.
     * @dev Caller-funded path. Same shared preamble as `genesisAndPreorder` with the leveraged family
     *      matrix (the genesis leg accepts `UAsset`, `Psm`, and `Credit` and rejects `Stake`; the
     *      preorder leg accepts only `UAsset` and `Psm`), then the POLend family gate runs
     *      source-independently before any funds move: a zero `polend` reverts `PolendNotSet` and
     *      `IPOLendGenesis(polend).marketUAsset(verseId)` must equal the launcher-resolved uAsset
     *      (an unregistered verse reads address(0) and reverts `PolendMarketUAssetMismatch`),
     *      mirroring `leveragedGenesisByPSM`. The interest leg books its source into POLend — the
     *      uAsset-funded branch pulls the caller's uAsset, the PSM-funded branch mints through the
     *      registered PSM, and the credit-funded branch resolves the family's credit token through
     *      `IGenesisCreditRegistry(IPOLendGenesis(polend).creditFactory()).creditOf(uAsset)` (a zero
     *      resolution reverts `NoCreditForUAsset` before any funds move) and pays it via
     *      `leveragedGenesisWithCredit` — each branch approving exactly its amount to `polend` and
     *      crediting the borrowed debt to `user`; the preorder leg funds
     *      `IMemeverseLauncher.preorder`. Every leg must consume its token in full or the whole
     *      call reverts (GenesisGateLib full-consumption assertion).
     * @param verseId POLend market identifier the interest is booked against; the router resolves it
     *      to the verse's uAsset and forwards it unchanged.
     * @param genesisInput Funding instruction for the leveraged-genesis interest leg.
     * @param preorderInput Funding instruction for the preorder leg.
     * @param user User credited with the borrowed debt and the preorder participation.
     */
    function leveragedGenesisAndPreorder(
        uint256 verseId,
        FundInput calldata genesisInput,
        FundInput calldata preorderInput,
        address user
    ) external payable;

    /**
     * @notice Creates a genesis position starting from an input token: the token-denominated front door
     * of the genesis CDP gate (value-parity mint, no discount). Thin forward over the SP-native physical gate.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from
     *      `SP.SY()`, converts `tokenIn` into SY held by the router, then forwards the SY into
     *      `SP.stakeForGenesis`: the SP opens the genesis CDP for `genesisUser` (minting uAsset at the
     *      collateral's value parity, no LTV or discount factor), mints the uAsset to
     *      itself, and hands the full mint to its own genesis launcher within the same transaction
     *      (router-side uAsset approve/assert removed — the router never touches uAsset on this path).
     *      Equivalent to composing `mintSYFromToken` (receiver = caller) with `genesisBySY`, minus the
     *      intermediate SY hop through the caller's account.
     *      Slippage is guarded by two independent floors: `minSyOut` bounds the token -> SY conversion
     *      (enforced inside `SY.deposit`, reverting SYInsufficientSharesOut) and `minUAssetMinted`
     *      bounds the stake mint (enforced SP-side, reverting InsufficientUAssetMinted); `0` disables
     *      either floor. The native leg follows the shared value rules: `tokenIn == NATIVE` requires
     *      `msg.value == tokenAmount`, an ERC20 leg requires `msg.value == 0` and a prior caller
     *      approval to the router. SP-side genesis errors — `InsufficientUAssetMinted`, `InvalidParam`
     *      (mint above the launcher's uint128 domain), `GenesisLauncherNotSet` (SP entry disabled,
     *      reachable via router only after launcher parity passes — a diverged router-nonzero/SP-zero
     *      configuration reverts `GenesisLauncherMismatch` first), and
     *      `GenesisUAssetNotConsumed` (launcher did not consume in full) — propagate unchanged.
     *      Composability: any EOA or contract may call `SP.stakeForGenesis` directly; this entry is a
     *      convenience layer, not a required path.
     * @param SP Stake manager receiving the genesis stake.
     * @param tokenIn Token to deposit into SY (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert and stake for genesis.
     * @param minSyOut Minimum acceptable SY output from the deposit; `0` means no slippage protection.
     * @param verseId Opaque launcher-assigned identifier for the target verse; the router forwards it unchanged and does not validate it.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted by the stake; `0` means no slippage protection.
     */
    function genesisByToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) external payable;

    /**
     * @notice Creates a genesis position starting from existing SY. Thin forward over the SP-native
     * physical gate.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from
     *      `SP.SY()`, pulls SY from `msg.sender`, and forwards it into `SP.stakeForGenesis`: the SP
     *      opens the genesis CDP for `genesisUser` (value-parity mint, no discount), mints the uAsset to itself, and hands the full
     *      mint to its own genesis launcher within the same transaction (the router never touches
     *      uAsset on this path and asserts nothing about the consumption — the SP-side post-condition
     *      governs). `amountInSY` is uint256 (no input-side cap); the mint's uint128 bound, the
     *      `minUAssetMinted` floor, the launcher-disabled guard, and the full-consumption assertion
     *      are all SP-side checks whose errors are the same four as `genesisByToken` and propagate
     *      unchanged once launcher parity passes (same divergence rule as `genesisByToken`);
     *      see `genesisByToken` for the full list.
     *      Composability: any EOA or contract may call `SP.stakeForGenesis` directly; this entry is a
     *      convenience layer, not a required path.
     * @param SP Stake manager receiving the genesis stake.
     * @param amountInSY Amount of SY to stake for genesis.
     * @param verseId Opaque launcher-assigned identifier for the target verse; the router forwards it unchanged and does not validate it.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts; `0` means no slippage protection.
     */
    function genesisBySY(address SP, uint256 amountInSY, uint256 verseId, address genesisUser, uint256 minUAssetMinted)
        external;

    /**
     * @notice Updates the memeverse launcher address.
     * @dev Test-phase only: live `onlyOwner` capability for test deployment iteration.
     *      Production will delete this method and make `OutrunRouter.memeverseLauncher` `immutable`, set only via constructor.
     *      Operational invariant: `memeverseLauncher` must equal each SP's `genesisLauncher()` for the two genesis
     *      gates to target one launcher; a single-side rotation makes router path-B entries and previews
     *      revert fail-closed (`GenesisLauncherMismatch`), while the residual silent surface is router path-A (router
     *      launcher) versus direct-SP (SP launcher) targeting different launchers. Rotation must be atomic — update
     *      `OutrunRouter.memeverseLauncher` and every `SP.genesisLauncher` in the same governance transaction and
     *      verify `SP.genesisLauncher() == router.memeverseLauncher()` before opening new genesis.
     * @param memeverseLauncher New launcher contract address.
     */
    function setMemeverseLauncher(address memeverseLauncher) external;

    /// @notice Registers or revokes the POLend target serving `leveragedGenesisByPSM`.
    /// @dev Owner-only configuration, no code check; revocation passes address(0) and the entry
    ///      fails closed with PolendNotSet afterwards. Test-phase only.
    function setPolend(address polend) external;

    /**
     * @notice Rescues stranded tokens (including native via NATIVE sentinel) accidentally held by the router.
     * @dev Only owner, nonReentrant. Mirrors SYBase sweep pattern but without yield-token blocking (router has no backing token).
     * @param token Token to rescue (NATIVE = address(0) for native).
     * @param to Recipient.
     * @param amount Amount to rescue.
     */
    function sweep(address token, address to, uint256 amount) external;

    function trustedSY(address SY) external view returns (bool);

    function trustedSYForSP(address SP) external view returns (address);

    /**
     * @notice Returns the PSM registered for a (uAsset, reserveToken) pair.
     * @param uAsset Family uAsset key.
     * @param reserveToken Reserve token key (`NATIVE` = address(0) for the native currency).
     * @return psm Registered PSM address, or address(0) when unregistered.
     */
    function psmForUAsset(address uAsset, address reserveToken) external view returns (address psm);

    /// @notice Returns the POLend target serving `leveragedGenesisByPSM`.
    function polend() external view returns (address);

    /// @notice Returns the memeverse launcher address the genesis gates hand minted uAsset to.
    /// @dev Operational invariant: must equal each SP's `genesisLauncher()`; drift reverts `GenesisLauncherMismatch` on
    ///      the SP-backed genesis entries and previews, while the PSM-gated path stays silent (see `setMemeverseLauncher`).
    function memeverseLauncher() external view returns (address);

    /**
     * @notice Quotes the uAsset amount a genesis open from an input token would mint.
     * @dev Requires an owner-registered SP -> SY pair, then derives canonical SY from `SP.SY()` and combines `SY.previewDeposit` and `SP.previewStake`.
     * Requires launcher parity (`memeverseLauncher == SP.genesisLauncher()`); a drifted launcher reverts
     * `GenesisLauncherMismatch`, mirroring the execution gate, so within the launcher-drift domain the quote never
     * describes an unexecutable open. Parity is equality-only: with both launchers unset (`address(0)` each side)
     * it passes, this preview still quotes, and execution reverts at the SP-side zero-address gate with
     * `GenesisLauncherNotSet` — a successful quote is not evidence that a genesis launcher is wired.
     * Preview is quote-only and does not reserve liquidity, uAsset mint cap, or slippage floors; execution can revert
     * with `ReachMintCap`/`SYZeroSharesOut`/`InsufficientUAssetMinted`/`DustRoundedToZero`/`GenesisLauncherNotSet`
     * where preview succeeded.
     * Integrators must treat the quote as an estimate, pass `minSyOut`/`minUAssetMinted` as `quote±slippage`,
     * and handle `ReachMintCap` reverts. These previews take no slippage floors; apply `minSyOut`/`minUAssetMinted` at execution.
     * @param SP Stake manager receiving the genesis stake.
     * @param tokenIn Token to deposit into SY (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @return UAssetMintable Estimated uAsset minted by the genesis flow.
     */
    function previewStakeFromToken(address SP, address tokenIn, uint256 tokenAmount)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Quotes the uAsset amount a genesis open from existing SY would mint.
     * @dev Requires an owner-registered SP -> SY pair, then reads `SP.previewStake` for a quote-only SY-funded genesis open.
     * Requires launcher parity (`memeverseLauncher == SP.genesisLauncher()`); a drifted launcher reverts
     * `GenesisLauncherMismatch`, mirroring the execution gate, so within the launcher-drift domain the quote never
     * describes an unexecutable open. Parity is equality-only: with both launchers unset (`address(0)` each side)
     * it passes, this preview still quotes, and execution reverts at the SP-side zero-address gate with
     * `GenesisLauncherNotSet` — a successful quote is not evidence that a genesis launcher is wired.
     * Preview is quote-only and does not reserve uAsset mint cap or slippage floors; execution can revert
     * with `ReachMintCap`/`DustRoundedToZero`/`InsufficientUAssetMinted`/`GenesisLauncherNotSet` where preview succeeded.
     * Integrators must treat the quote as an estimate and handle `ReachMintCap` reverts. These previews take no slippage floors; apply `minUAssetMinted` at execution.
     * @param SP Stake manager receiving the genesis stake.
     * @param amountInSY Amount of SY to stake.
     * @return UAssetMintable Estimated uAsset minted by the genesis flow.
     */
    function previewStakeFromSY(address SP, uint256 amountInSY) external view returns (uint256 UAssetMintable);

    error InvalidParam();
    // GenesisUAssetNotConsumed is the single-source physical-gate error defined in GenesisGateLib
    // (router path A reverts via GenesisGateLib.assertFullConsumption; path B propagates SP revert).
    error SweepZeroAddress();
    error SweepZeroAmount();
}
