// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun router interface
 * @notice User-facing entry surface of the OutStake protocol: token-to-SY conversion, locked staking,
 *      wrap-staking, and genesis flows. Implemented by OutrunRouter; every user-facing funded entrypoint is
 *      caller-funded (pulls its input from msg.sender) and enforces a per-flow slippage floor. Owner-managed target
 *      registration is required before a caller-supplied SY or SP can reach any downstream contract.
 *      uAsset (Universal Asset) is the protocol's unified debt/liquidity layer token; `NATIVE` is `address(0)` and
 *      selecting `tokenIn == address(0)` supplies the chain's native currency on token input entrypoints.
 */
interface IOutrunRouter {
    /**
     * @notice Emitted when an SY target is added to or removed from the router registry.
     */
    event TrustedSYUpdated(address indexed SY, bool trusted);

    /**
     * @notice Emitted when an SP is paired with its canonical SY, or revoked with address(0).
     */
    event TrustedSPUpdated(address indexed SP, address indexed SY);

    /**
     * @notice Emitted when the memeverse launcher address changes.
     * @param oldLauncher Previous launcher contract address.
     * @param newLauncher New launcher contract address.
     */
    event SetMemeverseLauncher(address indexed oldLauncher, address indexed newLauncher);

    error UntrustedRouterTarget(address target);
    error RouterTargetMismatch(address SP, address expectedSY, address actualSY);

    /**
     * @notice Parameters shared by locked-stake router entrypoints.
     * @dev `minSyOut` and `minUAssetMinted` are slippage floors, not preview guarantees. `owner` controls the
     * created position, and `receiver == address(0)` defaults the uAsset receiver to `owner`.
     * `lockupDays == 0` creates an immediately redeemable position; non-zero values lock until `lockupDays` days
     * after creation.
     */
    struct StakeParam {
        uint128 lockupDays;
        uint256 minSyOut;
        uint256 minUAssetMinted;
        address owner;
        address receiver; // uAsset receiver; falls back to owner when address(0)
    }

    /**
     * @notice Registers or revokes a standardized-yield target for router entrypoints.
     * @dev Owner-only configuration. A registered SY must be a deployed contract; revocation uses `trusted = false`.
     */
    function setTrustedSY(address SY, bool trusted) external;

    /**
     * @notice Registers or revokes an SP and its canonical SY pair.
     * @dev Owner-only configuration. A nonzero SY must already be trusted and must equal `SP.SY()`.
     */
    function setTrustedSP(address SP, address SY) external;

    function trustedSY(address SY) external view returns (bool);

    function trustedSYForSP(address SP) external view returns (address);

    /**
     * @notice Deposits an input token into a standardized yield contract.
     * @dev Caller-funded path. Always pulls `tokenIn` from `msg.sender` before forwarding the deposit into SY;
     * native deposits are forwarded as `msg.value`; `tokenIn == address(0)` (`NATIVE`) selects the native currency.
     * @param SY Standardized yield contract that receives the deposit.
     * @param tokenIn Token to supply when minting SY (`NATIVE` = address(0) for the native currency).
     * @param receiver Recipient of the minted SY.
     * @param amountInput Amount of input token to deposit.
     * @param minSyOut Minimum acceptable SY output.
     * @return amountInSYOut Amount of SY minted for `receiver`.
     */
    function mintSYFromToken(address SY, address tokenIn, address receiver, uint256 amountInput, uint256 minSyOut)
        external
        payable
        returns (uint256 amountInSYOut);

    /**
     * @notice Redeems standardized yield into an output token.
     * @dev Caller-funded path. Requires an owner-registered SY, pulls SY from `msg.sender` into the SY contract and calls redeem with
     * `burnFromInternalBalance = true`.
     * @param SY Standardized yield contract being redeemed.
     * @param receiver Recipient of the redeemed token output.
     * @param tokenOut Token requested on redemption.
     * @param amountInSY Amount of SY to redeem.
     * @param minTokenOut Minimum acceptable token output.
     * @return amountInTokenOut Amount of `tokenOut` sent to `receiver`.
     */
    function redeemSyToToken(address SY, address receiver, address tokenOut, uint256 amountInSY, uint256 minTokenOut)
        external
        returns (uint256 amountInTokenOut);

    /**
     * @notice Quotes the uAsset amount minted when staking from an input token.
     * @dev Requires an owner-registered SP -> SY pair, then derives canonical SY from `SP.SY()` and combines `SY.previewDeposit` and `SP.previewStake`.
     * Preview does not reserve liquidity, cap, or slippage floors. `stakeParam` fields do not alter the quote.
     * @param SP Stake manager receiving the SY stake.
     * @param tokenIn Token to deposit into SY (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @param stakeParam Stake settings accepted for ABI consistency; fields do not alter the quote.
     * @return UAssetMintable Estimated uAsset minted by the stake flow.
     */
    function previewStakeFromToken(address SP, address tokenIn, uint256 tokenAmount, StakeParam calldata stakeParam)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Quotes the uAsset amount minted when staking existing SY.
     * @dev Requires an owner-registered SP -> SY pair, then reads `SP.previewStake` for a quote-only SY-funded stake. `stakeParam` fields do not alter the quote.
     * @param SP Stake manager receiving the SY stake.
     * @param amountInSY Amount of SY to stake.
     * @param stakeParam Stake settings accepted for ABI consistency; fields do not alter the quote.
     * @return UAssetMintable Estimated uAsset minted by the stake flow.
     */
    function previewStakeFromSY(address SP, uint256 amountInSY, StakeParam calldata stakeParam)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Quotes the uAsset amount minted when wrap-staking from an input token.
     * @dev Requires an owner-registered SP -> SY pair, then derives canonical SY from `SP.SY()` and combines `SY.previewDeposit` and `SP.previewWrapStake`.
     * Preview does not reserve liquidity, cap, or slippage floors.
     * @param SP Stake manager receiving the wrapped stake.
     * @param tokenIn Token to deposit into SY (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @return UAssetMintable Estimated uAsset minted by the wrap-stake flow.
     */
    function previewWrapStakeFromToken(address SP, address tokenIn, uint256 tokenAmount)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Deposits an input token, converts it into SY, and stakes it.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from `SP.SY()`, mints SY into the router, creates a locked
     * position for `stakeParam.owner`, and sends uAsset to `stakeParam.receiver` or owner when receiver is zero.
     * @param SP Stake manager receiving the SY stake.
     * @param tokenIn Token to deposit into SY (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert and stake.
     * @param stakeParam Stake settings including lockup, SY/uAsset slippage floors, owner, and receiver.
     * @return positionId Newly created staking position id.
     * @return mintedUAsset Amount of uAsset minted for the stake.
     */
    function stakeFromToken(address SP, address tokenIn, uint256 tokenAmount, StakeParam calldata stakeParam)
        external
        payable
        returns (uint256 positionId, uint256 mintedUAsset);

    /**
     * @notice Stakes existing SY into the stake manager.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from `SP.SY()`, pulls SY from `msg.sender`, creates a locked
     * position for `stakeParam.owner`, and sends uAsset to `stakeParam.receiver` or owner when receiver is zero.
     * @param SP Stake manager receiving the SY stake.
     * @param amountInSY Amount of SY to stake.
     * @param stakeParam Stake settings including lockup, uAsset slippage floor, owner, and receiver.
     * @return positionId Newly created staking position id.
     * @return mintedUAsset Amount of uAsset minted for the stake.
     */
    function stakeFromSY(address SP, uint256 amountInSY, StakeParam calldata stakeParam)
        external
        returns (uint256 positionId, uint256 mintedUAsset);

    /**
     * @notice Deposits an input token, converts it into SY, and wrap-stakes it.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from `SP.SY()`, mints SY into the router, and enters the
     * shared wrap pool for `uAssetReceiver`; no locked position id is created.
     * @param SP Stake manager receiving the wrapped stake.
     * @param tokenIn Token to deposit into SY (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert and wrap-stake.
     * @param minSyOut Minimum acceptable SY output from deposit.
     * @param uAssetReceiver Recipient of the wrapped uAsset position.
     * @param minUAssetMinted Minimum acceptable uAsset minted by wrap stake.
     * @return mintedUAsset Amount of uAsset minted to `uAssetReceiver`.
     */
    function wrapStakeFromToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        address uAssetReceiver,
        uint256 minUAssetMinted
    ) external payable returns (uint256 mintedUAsset);

    /**
     * @notice Wrap-stakes existing SY into uAsset.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from `SP.SY()`, pulls SY from `msg.sender`, and enters the
     * shared wrap pool for `uAssetReceiver`; no locked position id is created.
     * @param SP Stake manager receiving the wrapped stake.
     * @param amountInSY Amount of SY to wrap-stake.
     * @param uAssetReceiver Recipient of the minted uAsset.
     * @param minUAssetMinted Minimum acceptable uAsset minted by wrap stake.
     * @return mintedUAsset Amount of uAsset minted to `uAssetReceiver`.
     */
    function wrapStakeFromSY(address SP, uint256 amountInSY, address uAssetReceiver, uint256 minUAssetMinted)
        external
        returns (uint256 mintedUAsset);

    /**
     * @notice Creates a genesis position starting from an input token.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from `SP.SY()`, creates a locked position for `genesisUser`,
     * mints uAsset to the router, then forwards that uAsset into launcher genesis.
     * @param SP Stake manager receiving the genesis stake.
     * @param tokenIn Token to deposit into SY before staking (`NATIVE` = address(0) for the native currency).
     * @param tokenAmount Amount of `tokenIn` to convert and stake.
     * @param minSyOut Minimum acceptable SY output from deposit.
     * @param lockupDays Lockup duration forwarded to the stake manager; `0` creates an immediately redeemable position.
     * @param verseId Opaque launcher-assigned identifier for the target verse; the router forwards it unchanged and does not validate it.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted by the locked stake.
     */
    function genesisByToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        uint128 lockupDays,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) external payable;

    /**
     * @notice Creates a genesis position starting from existing SY.
     * @dev Caller-funded path. Requires an owner-registered SP -> SY pair, derives canonical SY from `SP.SY()`, pulls SY from `msg.sender`, creates a locked
     * position for `genesisUser`, mints uAsset to the router, then forwards that uAsset into launcher genesis.
     * `amountInSY` is uint256 (no input-side cap); the launcher genesis amount is uint128-bounded, so when the
     * stake's minted uAsset exceeds type(uint128).max the call reverts with InvalidParam().
     * @param SP Stake manager receiving the genesis stake.
     * @param amountInSY Amount of SY to stake for genesis.
     * @param lockupDays Lockup duration forwarded to the stake manager; `0` creates an immediately redeemable position.
     * @param verseId Opaque launcher-assigned identifier for the target verse; the router forwards it unchanged and does not validate it.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted by the locked stake.
     */
    function genesisBySY(
        address SP,
        uint256 amountInSY,
        uint128 lockupDays,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) external;

    /**
     * @notice Updates the memeverse launcher address.
     * @dev Owner-only maintenance hook for the pre-mainnet launcher wiring. Pre-mainnet only; planned for removal at mainnet launch.
     * @param memeverseLauncher New launcher contract address.
     */
    function setMemeverseLauncher(address memeverseLauncher) external;

    error InvalidParam();
    error InsufficientUAssetMinted(uint256 mintedUAsset, uint256 minMinted);
    error NativeAmountMismatch();
    error InvalidMemeverseLauncher(address launcher);
}
