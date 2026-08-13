// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IOutrunRouter {
    /**
     * @notice Parameters shared by locked-stake router entrypoints.
     * @dev `minSyOut` and `minUAssetMinted` are slippage floors, not preview guarantees. `owner` controls the
     * created position, and `receiver == address(0)` defaults the uAsset receiver to `owner`.
     */
    struct StakeParam {
        uint128 lockupDays;
        uint256 minSyOut;
        uint256 minUAssetMinted;
        address owner;
        address receiver; // uAsset receiver; falls back to owner when address(0)
    }

    /**
     * @notice Deposits an input token into a standardized yield contract.
     * @dev Caller-funded path. Always pulls `tokenIn` from `msg.sender` before forwarding the deposit into SY;
     * native deposits are forwarded as `msg.value`.
     * @param SY Standardized yield contract that receives the deposit.
     * @param tokenIn Token to supply when minting SY.
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
     * @dev Caller-funded path. Pulls SY from `msg.sender` into the SY contract and calls redeem with
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
     * @dev Derives canonical SY from `SP.SY()`, then combines `SY.previewDeposit` and `SP.previewStake`.
     * Preview does not reserve liquidity, cap, or slippage floors.
     * @param SP Stake manager receiving the SY stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @param stakeParam Stake settings carried into the preview.
     * @return UAssetMintable Estimated uAsset minted by the stake flow.
     */
    function previewStakeFromToken(address SP, address tokenIn, uint256 tokenAmount, StakeParam calldata stakeParam)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Quotes the uAsset amount minted when staking existing SY.
     * @dev Reads `SP.previewStake` for a quote-only SY-funded stake. `stakeParam` fields other than the
     * current implementation's unused-variable touch do not alter the quote.
     * @param SP Stake manager receiving the SY stake.
     * @param amountInSY Amount of SY to stake.
     * @param stakeParam Stake settings carried into the preview.
     * @return UAssetMintable Estimated uAsset minted by the stake flow.
     */
    function previewStakeFromSY(address SP, uint256 amountInSY, StakeParam calldata stakeParam)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Quotes the uAsset amount minted when wrap-staking from an input token.
     * @dev Derives canonical SY from `SP.SY()`, then combines `SY.previewDeposit` and `SP.previewWrapStake`.
     * Preview does not reserve liquidity, cap, or slippage floors.
     * @param SP Stake manager receiving the wrapped stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @return UAssetMintable Estimated uAsset minted by the wrap-stake flow.
     */
    function previewWrapStakeFromToken(address SP, address tokenIn, uint256 tokenAmount)
        external
        view
        returns (uint256 UAssetMintable);

    /**
     * @notice Deposits an input token, converts it into SY, and stakes it.
     * @dev Caller-funded path. Derives canonical SY from `SP.SY()`, mints SY into the router, creates a locked
     * position for `stakeParam.owner`, and sends uAsset to `stakeParam.receiver` or owner when receiver is zero.
     * @param SP Stake manager receiving the SY stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert and stake.
     * @param stakeParam Stake settings including lockup, SY/uAsset slippage floors, owner, and receiver.
     * @return positionId Newly created staking position id.
     * @return UAssetMinted Amount of uAsset minted for the stake.
     */
    function stakeFromToken(address SP, address tokenIn, uint256 tokenAmount, StakeParam calldata stakeParam)
        external
        payable
        returns (uint256 positionId, uint256 UAssetMinted);

    /**
     * @notice Stakes existing SY into the stake manager.
     * @dev Caller-funded path. Derives canonical SY from `SP.SY()`, pulls SY from `msg.sender`, creates a locked
     * position for `stakeParam.owner`, and sends uAsset to `stakeParam.receiver` or owner when receiver is zero.
     * @param SP Stake manager receiving the SY stake.
     * @param amountInSY Amount of SY to stake.
     * @param stakeParam Stake settings including lockup, uAsset slippage floor, owner, and receiver.
     * @return positionId Newly created staking position id.
     * @return UAssetMinted Amount of uAsset minted for the stake.
     */
    function stakeFromSY(address SP, uint256 amountInSY, StakeParam calldata stakeParam)
        external
        returns (uint256 positionId, uint256 UAssetMinted);

    /**
     * @notice Deposits an input token, converts it into SY, and wrap-stakes it.
     * @dev Caller-funded path. Derives canonical SY from `SP.SY()`, mints SY into the router, and enters the
     * shared wrap pool for `uAssetRecipient`; no locked position id is created.
     * @param SP Stake manager receiving the wrapped stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert and wrap-stake.
     * @param minSyOut Minimum acceptable SY output from deposit.
     * @param uAssetRecipient Recipient of the wrapped uAsset position.
     * @param minUAssetMinted Minimum acceptable uAsset minted by wrap stake.
     * @return UAssetMinted Amount of uAsset minted to `uAssetRecipient`.
     */
    function wrapStakeFromToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        address uAssetRecipient,
        uint256 minUAssetMinted
    ) external payable returns (uint256 UAssetMinted);

    /**
     * @notice Wrap-stakes existing SY into uAsset.
     * @dev Caller-funded path. Derives canonical SY from `SP.SY()`, pulls SY from `msg.sender`, and enters the
     * shared wrap pool for `uAssetRecipient`; no locked position id is created.
     * @param SP Stake manager receiving the wrapped stake.
     * @param amountInSY Amount of SY to wrap-stake.
     * @param uAssetRecipient Recipient of the minted uAsset.
     * @param minUAssetMinted Minimum acceptable uAsset minted by wrap stake.
     * @return UAssetMinted Amount of uAsset minted to `uAssetRecipient`.
     */
    function wrapStakeFromSY(address SP, uint256 amountInSY, address uAssetRecipient, uint256 minUAssetMinted)
        external
        returns (uint256 UAssetMinted);

    /**
     * @notice Creates a genesis position starting from an input token.
     * @dev Caller-funded path. Derives canonical SY from `SP.SY()`, creates a locked position for `genesisUser`,
     * mints uAsset to the router, then forwards that uAsset into launcher genesis.
     * @param SP Stake manager receiving the genesis stake.
     * @param tokenIn Token to deposit into SY before staking.
     * @param tokenAmount Amount of `tokenIn` to convert and stake.
     * @param minSyOut Minimum acceptable SY output from deposit.
     * @param minUAssetMinted Minimum acceptable uAsset minted by the locked stake.
     * @param lockupDays Lockup duration forwarded to the stake manager.
     * @param verseId Memeverse verse identifier to launch against.
     * @param genesisUser User credited for the genesis position.
     */
    function genesisByToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        uint256 minUAssetMinted,
        uint128 lockupDays,
        uint256 verseId,
        address genesisUser
    ) external payable;

    /**
     * @notice Creates a genesis position starting from existing SY.
     * @dev Caller-funded path. Derives canonical SY from `SP.SY()`, pulls SY from `msg.sender`, creates a locked
     * position for `genesisUser`, mints uAsset to the router, then forwards that uAsset into launcher genesis.
     * @param SP Stake manager receiving the genesis stake.
     * @param amountInSY Amount of SY to stake for genesis.
     * @param lockupDays Lockup duration forwarded to the stake manager.
     * @param verseId Memeverse verse identifier to launch against.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted by the locked stake.
     */
    function genesisBySY(
        address SP,
        uint128 amountInSY,
        uint128 lockupDays,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) external;

    /**
     * @notice Updates the memeverse launcher address.
     * @dev Owner-only maintenance hook for the pre-mainnet launcher wiring.
     * @param memeverseLauncher New launcher contract address.
     */
    function setMemeverseLauncher(address memeverseLauncher) external;

    error InvalidParam();
    error InsufficientUAssetMinted(uint256 UAssetMinted, uint256 minMinted);
}
