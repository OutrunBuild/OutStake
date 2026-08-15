// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// OutrunTODO Delete the Ownable when the mainnet goes live
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IOutrunRouter} from "./interfaces/IOutrunRouter.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {IStandardizedYield} from "../yield/interfaces/IStandardizedYield.sol";
import {IERC20, NativeAmountMismatch, TokenHelper} from "../libraries/TokenHelper.sol";
import {IOutrunStakeManager} from "../position/interfaces/IOutrunStakeManager.sol";

/**
 * @title OutrunRouter
 * @notice Main user-facing entry point for the OutStake protocol.
 *
 * Handles token-to-SY conversion, staking, and genesis flows.
 * SY = Standardized Yield (wrapper token that normalizes yield-bearing assets).
 * SP = Stake Position manager (creates and tracks staking positions).
 * uAsset = universal asset (receipt token minted when staking or wrap-staking).
 */
contract OutrunRouter is IOutrunRouter, TokenHelper, Ownable {
    error InvalidMemeverseLauncher(address launcher);

    // Memeverse is the launch platform; this address is called during genesis flows.
    address public memeverseLauncher;

    constructor(address _owner, address _memeverseLauncher) Ownable(_owner) {
        _setMemeverseLauncher(_memeverseLauncher);
    }

    /**
     * @notice Deposits an input token into a standardized yield contract.
     * @dev Always pulls `tokenIn` from the caller before forwarding the deposit into SY.
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
        returns (uint256 amountInSYOut)
    {
        amountInSYOut = _mintSY(SY, tokenIn, receiver, amountInput, minSyOut);
    }

    /**
     * @notice Redeems standardized yield into an output token.
     * @dev Always pulls SY from the caller and burns it from SY internal balance during redemption.
     * @param SY Standardized yield contract being redeemed.
     * @param receiver Recipient of the redeemed token output.
     * @param tokenOut Token requested on redemption.
     * @param amountInSY Amount of SY to redeem.
     * @param minTokenOut Minimum acceptable token output.
     * @return amountInTokenOut Amount of `tokenOut` sent to `receiver`.
     */
    function redeemSyToToken(address SY, address receiver, address tokenOut, uint256 amountInSY, uint256 minTokenOut)
        external
        returns (uint256 amountInTokenOut)
    {
        // transferFrom moves caller's SY into the SY contract, then burnFromInternalBalance=true burns from SY's own balance.
        _transferFrom(IERC20(SY), msg.sender, SY, amountInSY);
        amountInTokenOut = IStandardizedYield(SY).redeem(receiver, amountInSY, tokenOut, minTokenOut, true);
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
        // NATIVE is the sentinel address(0), meaning native token (ETH/BNB) rather than an ERC20.
        if (tokenIn != NATIVE && msg.value != 0) revert NativeAmountMismatch();

        _transferIn(tokenIn, msg.sender, amountInput);

        uint256 amountInNative = tokenIn == NATIVE ? amountInput : 0;
        _approveExact(tokenIn, SY, amountInput);
        amountInSYOut = IStandardizedYield(SY).deposit{value: amountInNative}(receiver, tokenIn, amountInput, minSyOut);
    }

    /**
     * @notice Quotes the uAsset amount minted when staking from an input token.
     * @dev Derives canonical SY from `SP.SY()`, then uses the SY deposit preview and stake-manager preview.
     * @param SP Stake manager receiving the SY stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @param stakeParam Stake settings carried into the preview.
     * @return UAssetMintable Estimated uAsset minted by the stake flow.
     */
    function previewStakeFromToken(address SP, address tokenIn, uint256 tokenAmount, StakeParam calldata stakeParam)
        external
        view
        returns (uint256 UAssetMintable)
    {
        address SY = IOutrunStakeManager(SP).SY();
        uint256 amountInSY = IStandardizedYield(SY).previewDeposit(tokenIn, tokenAmount);
        UAssetMintable = IOutrunStakeManager(SP).previewStake(amountInSY);
        // No-op: references stakeParam to silence the unused-function-parameter compiler warning; the quote does not depend on lockupDays, and the parameter is kept for ABI consistency.
        stakeParam.lockupDays;
    }

    /**
     * @notice Quotes the uAsset amount minted when staking existing SY.
     * @dev Reads the stake-manager preview for an SY-funded stake without changing state.
     * @param SP Stake manager receiving the SY stake.
     * @param amountInSY Amount of SY to stake.
     * @param stakeParam Stake settings carried into the preview.
     * @return UAssetMintable Estimated uAsset minted by the stake flow.
     */
    function previewStakeFromSY(address SP, uint256 amountInSY, StakeParam calldata stakeParam)
        external
        view
        returns (uint256 UAssetMintable)
    {
        UAssetMintable = IOutrunStakeManager(SP).previewStake(amountInSY);
        // No-op: references stakeParam to silence the unused-function-parameter compiler warning; the quote does not depend on lockupDays, and the parameter is kept for ABI consistency.
        stakeParam.lockupDays;
    }

    /**
     * @notice Quotes the uAsset amount minted when wrap-staking from an input token.
     * @dev Derives canonical SY from `SP.SY()`, then combines the SY deposit preview with the wrap preview.
     * @param SP Stake manager receiving the wrapped stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert.
     * @return UAssetMintable Estimated uAsset minted by the wrap-stake flow.
     */
    function previewWrapStakeFromToken(address SP, address tokenIn, uint256 tokenAmount)
        external
        view
        returns (uint256 UAssetMintable)
    {
        address SY = IOutrunStakeManager(SP).SY();
        uint256 amountInSY = IStandardizedYield(SY).previewDeposit(tokenIn, tokenAmount);
        UAssetMintable = IOutrunStakeManager(SP).previewWrapStake(amountInSY);
    }

    /**
     * @notice Deposits an input token, converts it into SY, and stakes it.
     * @dev Derives canonical SY from `SP.SY()`, mints it, and stakes on behalf of `stakeParam.owner`.
     * @param SP Stake manager receiving the SY stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert and stake.
     * @param stakeParam Stake settings including lockup, slippage floor, and receiver.
     * @return positionId Newly created staking position id.
     * @return mintedUAsset Amount of uAsset minted for the stake.
     */
    function stakeFromToken(address SP, address tokenIn, uint256 tokenAmount, StakeParam calldata stakeParam)
        public
        payable
        returns (uint256 positionId, uint256 mintedUAsset)
    {
        address SY = IOutrunStakeManager(SP).SY();
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, stakeParam.minSyOut);
        // receiver defaults to owner when not specified (address(0))
        address uAssetReceiver = stakeParam.receiver == address(0) ? stakeParam.owner : stakeParam.receiver;
        (positionId, mintedUAsset) =
            _stakeFromSYBalance(SY, SP, amountInSY, stakeParam.lockupDays, stakeParam.owner, uAssetReceiver);
        _assertMinUAssetMinted(mintedUAsset, stakeParam.minUAssetMinted);
    }

    /**
     * @notice Stakes existing SY into the stake manager.
     * @dev Derives canonical SY from `SP.SY()` and pulls it into the router before staking.
     * @param SP Stake manager receiving the SY stake.
     * @param amountInSY Amount of SY to stake.
     * @param stakeParam Stake settings including lockup, slippage floor, and receiver.
     * @return positionId Newly created staking position id.
     * @return mintedUAsset Amount of uAsset minted for the stake.
     */
    function stakeFromSY(address SP, uint256 amountInSY, StakeParam calldata stakeParam)
        public
        returns (uint256 positionId, uint256 mintedUAsset)
    {
        address SY = IOutrunStakeManager(SP).SY();
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);
        // receiver defaults to owner when not specified (address(0))
        address uAssetReceiver = stakeParam.receiver == address(0) ? stakeParam.owner : stakeParam.receiver;
        (positionId, mintedUAsset) =
            _stakeFromSYBalance(SY, SP, amountInSY, stakeParam.lockupDays, stakeParam.owner, uAssetReceiver);
        _assertMinUAssetMinted(mintedUAsset, stakeParam.minUAssetMinted);
    }

    /**
     * @notice Deposits an input token, converts it into SY, and wrap-stakes it.
     * @dev Mints SY into the router and immediately wrap-stakes into uAsset for `uAssetReceiver`.
     * @dev Derives SY from `SP.SY()`. SP owner is a fully trusted role across the system.
     * @param SP Stake manager receiving the wrapped stake.
     * @param tokenIn Token to deposit into SY.
     * @param tokenAmount Amount of `tokenIn` to convert and wrap-stake.
     * @param minSyOut Minimum acceptable SY output from the deposit step.
     * @param uAssetReceiver Recipient of the wrapped uAsset position.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts.
     * @return mintedUAsset Amount of uAsset minted to `uAssetReceiver`.
     */
    function wrapStakeFromToken(
        address SP,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minSyOut,
        address uAssetReceiver,
        uint256 minUAssetMinted
    ) public payable returns (uint256 mintedUAsset) {
        // Wrap stake enters the shared pool — no individual position id is created, no lockup applies.
        address SY = IOutrunStakeManager(SP).SY();
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, minSyOut);
        mintedUAsset = _wrapStakeFromSYBalance(SY, SP, amountInSY, uAssetReceiver, minUAssetMinted);
    }

    /**
     * @notice Wrap-stakes existing SY into uAsset.
     * @dev Derives canonical SY from `SP.SY()` and forwards it to the stake manager for wrap staking.
     * @param SP Stake manager receiving the wrapped stake.
     * @param amountInSY Amount of SY to wrap-stake.
     * @param uAssetReceiver Recipient of the minted uAsset.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts.
     * @return mintedUAsset Amount of uAsset minted to `uAssetReceiver`.
     */
    function wrapStakeFromSY(address SP, uint256 amountInSY, address uAssetReceiver, uint256 minUAssetMinted)
        public
        returns (uint256 mintedUAsset)
    {
        // Wrap stake enters the shared pool — no individual position id is created, no lockup applies.
        address SY = IOutrunStakeManager(SP).SY();
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);
        mintedUAsset = _wrapStakeFromSYBalance(SY, SP, amountInSY, uAssetReceiver, minUAssetMinted);
    }

    /**
     * @notice Approves SY to the stake manager and creates a locked staking position.
     * @param SY Standardized yield token address.
     * @param SP Stake position manager address.
     * @param amountInSY Amount of SY to stake.
     * @param lockupDays Number of days the position is locked.
     * @param positionOwner Owner of the newly created staking position.
     * @param uAssetReceiver Recipient of the minted uAsset.
     * @return positionId Unique identifier for the created staking position.
     * @return mintedUAsset Amount of uAsset minted.
     */
    function _stakeFromSYBalance(
        address SY,
        address SP,
        uint256 amountInSY,
        uint128 lockupDays,
        address positionOwner,
        address uAssetReceiver
    ) internal returns (uint256 positionId, uint256 mintedUAsset) {
        _approveExact(SY, SP, amountInSY);
        (positionId, mintedUAsset) =
            IOutrunStakeManager(SP).stake(amountInSY, lockupDays, positionOwner, uAssetReceiver);
    }

    /**
     * @notice Shared wrap-stake tail: approves SY to the stake manager, wrap-stakes into the shared pool,
     *      and enforces the minted-uAsset floor.
     * @dev Single source of truth for the steps both wrap entry points share after preparing SY.
     * @param SY Standardized yield token address.
     * @param SP Stake manager receiving the wrapped stake.
     * @param amountInSY Amount of SY to wrap-stake.
     * @param uAssetReceiver Recipient of the minted uAsset.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts.
     * @return mintedUAsset Amount of uAsset minted to `uAssetReceiver`.
     */
    function _wrapStakeFromSYBalance(
        address SY,
        address SP,
        uint256 amountInSY,
        address uAssetReceiver,
        uint256 minUAssetMinted
    ) internal returns (uint256 mintedUAsset) {
        _approveExact(SY, SP, amountInSY);
        mintedUAsset = IOutrunStakeManager(SP).wrapStake(amountInSY, uAssetReceiver);
        _assertMinUAssetMinted(mintedUAsset, minUAssetMinted);
    }

    /**
     * @notice Shared genesis tail: stakes SY, enforces the minted uAsset floor and uint128 bound, then approves
     *      and forwards the minted uAsset into the memeverse launcher.
     * @dev Single source of truth for the steps both genesis entry points share after preparing SY.
     * @param SY Canonical standardized-yield token holding the stake balance.
     * @param SP Stake manager receiving the genesis stake.
     * @param amountInSY Amount of SY to stake for genesis.
     * @param lockupDays Lockup duration forwarded to the stake manager.
     * @param verseId Memeverse verse identifier to launch against.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts.
     */
    function _genesisFromSYBalance(
        address SY,
        address SP,
        uint256 amountInSY,
        uint128 lockupDays,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) internal {
        address uAsset = IOutrunStakeManager(SP).uAsset();
        // (2) Stake SY to create a locked position for genesisUser.
        (, uint256 mintedUAsset) = _stakeFromSYBalance(SY, SP, amountInSY, lockupDays, genesisUser, address(this));
        _assertMinUAssetMinted(mintedUAsset, minUAssetMinted);
        if (mintedUAsset > type(uint128).max) revert InvalidParam();
        // (3) Approve uAsset to the launcher.
        _approveExact(uAsset, memeverseLauncher, mintedUAsset);
        // (4) Call launcher genesis with the staked uAsset.
        // mintedUAsset is bounded by type(uint128).max immediately before this cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        IMemeverseLauncher(memeverseLauncher).genesis(verseId, uint128(mintedUAsset), genesisUser);
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
     * @notice Reverts if the minted uAsset amount is below the caller's minimum acceptable threshold.
     * @dev Slippage guard: enforces the floor specified by the caller (minUAssetMinted).
     * @param mintedUAsset Amount of uAsset actually minted.
     * @param minUAssetMinted Minimum uAsset amount the caller is willing to accept.
     */
    function _assertMinUAssetMinted(uint256 mintedUAsset, uint256 minUAssetMinted) internal pure {
        require(mintedUAsset >= minUAssetMinted, InsufficientUAssetMinted(mintedUAsset, minUAssetMinted));
    }

    /**
     * @notice Sets the memeverse launcher address, reverting if the address has no code.
     * @param _memeverseLauncher New launcher contract address (must be a deployed contract).
     */
    function _setMemeverseLauncher(address _memeverseLauncher) internal {
        if (_memeverseLauncher.code.length == 0) revert InvalidMemeverseLauncher(_memeverseLauncher);
        memeverseLauncher = _memeverseLauncher;
    }

    /**
     * @notice Creates a genesis position starting from an input token.
     * @dev Mints and stakes through the router, then forwards the resulting uAsset amount into the launcher genesis flow.
     * @dev Derives SY from `SP.SY()`. SP owner is a fully trusted role across the system.
     * @param SP Stake manager receiving the genesis stake.
     * @param tokenIn Token to deposit into SY before staking.
     * @param tokenAmount Amount of `tokenIn` to convert and stake.
     * @param minSyOut Minimum acceptable SY output from the deposit step.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts.
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
    ) external payable {
        address SY = IOutrunStakeManager(SP).SY();
        // (1) Mint SY from the input token.
        uint256 amountInSY = _mintSY(SY, tokenIn, address(this), tokenAmount, minSyOut);
        _genesisFromSYBalance(SY, SP, amountInSY, lockupDays, verseId, genesisUser, minUAssetMinted);
    }

    /**
     * @notice Creates a genesis position starting from existing SY.
     * @dev Derives canonical SY from `SP.SY()`, stakes it for `genesisUser`, then launches genesis.
     * @param SP Stake manager receiving the genesis stake.
     * @param amountInSY Amount of SY to stake for genesis.
     * @param lockupDays Lockup duration forwarded to the stake manager.
     * @param verseId Memeverse verse identifier to launch against.
     * @param genesisUser User credited for the genesis position.
     * @param minUAssetMinted Minimum acceptable uAsset minted or the call reverts.
     */
    function genesisBySY(
        address SP,
        uint128 amountInSY,
        uint128 lockupDays,
        uint256 verseId,
        address genesisUser,
        uint256 minUAssetMinted
    ) external {
        address SY = IOutrunStakeManager(SP).SY();
        // (1) Pull caller's SY into the router.
        _transferFrom(IERC20(SY), msg.sender, address(this), amountInSY);
        _genesisFromSYBalance(SY, SP, amountInSY, lockupDays, verseId, genesisUser, minUAssetMinted);
    }

    /**
     * @notice Updates the memeverse launcher address.
     * @dev Owner-only maintenance hook for the pre-mainnet launcher wiring. OutrunTODO: delete when mainnet goes live.
     * @param _memeverseLauncher New launcher contract address.
     */
    function setMemeverseLauncher(address _memeverseLauncher) external onlyOwner {
        _setMemeverseLauncher(_memeverseLauncher);
    }
}
