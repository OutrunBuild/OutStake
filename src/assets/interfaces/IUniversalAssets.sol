// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun omnichain universal assets interface
 * @notice uAsset exposes a minter-scoped debt token surface for position accounting, plus a
 *      reserve-backed mint/burn path for registered reserve minters (e.g., PSM instances) that is exempt
 *      from the debt ledger.
 */
interface IUniversalAssets {
    /**
     * @notice Minting state for one minter address.
     * @dev `mintingCap` is the minter's configured ceiling; `amountInMinted` is that minter's outstanding
     * debt after mints minus repayments. The table is not a global debt pool.
     */
    struct MintingStatus {
        uint256 mintingCap;
        uint256 amountInMinted;
    }

    /**
     * @notice Returns the remaining uAsset minting allowance for a minter.
     * @dev Computes `max(mintingCap - amountInMinted, 0)` for the queried minter.
     * @param minter Address whose minting capacity is being queried.
     * @return amountInMintable Remaining amount the minter can mint.
     */
    function checkMintableAmount(address minter) external view returns (uint256 amountInMintable);

    /**
     * @notice Sets the minting cap for a minter.
     * @dev Owner-controlled configuration. Updating the cap changes only future mint headroom; it does not
     * rewrite `amountInMinted`.
     * @param minter Address whose cap is updated.
     * @param mintingCap New minting cap assigned to the minter.
     */
    function setMintingCap(address minter, uint256 mintingCap) external;

    /**
     * @notice Revokes minting permission by clearing a minter's cap.
     * @dev Sets `mintingCap` to zero. Existing `amountInMinted` remains outstanding until the minter repays.
     * @param minter Address whose minting permission is revoked.
     */
    function revokeMinter(address minter) external;

    /**
     * @notice Transfers outstanding minted debt from one minter record to another.
     * @dev Owner-only debt accounting repair tool. Does not mint, burn, transfer, or change total supply.
     * `from` and `to` must be nonzero, distinct minter records, and `to` must not be a registered reserve minter
     * (e.g. a PSM instance). Intended ONLY for correcting debt records
     * with no position-debt backing: it migrates only uAsset minter-level debt and never updates
     * position or other module ledgers. Live SP retirement uses the wind-down path
     * (cap to zero → repay down → revoke) instead of moving backed debt.
     * @param from Minter whose outstanding debt is decreased.
     * @param to Minter whose outstanding debt is increased.
     * @param amount Amount of outstanding debt to transfer.
     */
    function transferMinterDebt(address from, address to, uint256 amount) external;

    /**
     * @notice Mints uAsset to a receiver using the caller's minting allowance.
     * @dev `msg.sender` is the minter whose `amountInMinted` increases and whose cap is checked.
     * @param receiver Address receiving the minted uAsset.
     * @param amount Amount of uAsset to mint.
     */
    function mint(address receiver, uint256 amount) external;

    /**
     * @notice Repays the caller's own minted debt using uAsset held by an account.
     * @dev `msg.sender` is the minter whose `amountInMinted` decreases. `account` is the balance burned; when
     * `account != msg.sender`, the caller must have allowance to burn `account`'s uAsset.
     * @param account Address whose uAsset balance is burned.
     * @param amount Amount of uAsset to burn.
     */
    function repay(address account, uint256 amount) external;

    /**
     * @notice Registers or revokes a reserve minter that may use the reserve mint/burn path.
     * @dev Registration is independent of the debt ledger: `setMintingCap`/`revokeMinter` affect only
     * debt-ledger minting and do not influence the reserve path, and vice versa. Revoking a live reserve
     * minter is the kill switch for its reserve path: both directions then revert `NotReserveMinter`.
     * @param minter Address being registered or revoked as a reserve minter.
     * @param status True to register, false to revoke.
     */
    function setReserveMinter(address minter, bool status) external;

    /**
     * @notice Mints uAsset to a receiver through the reserve path.
     * @dev `msg.sender` must be a registered reserve minter. The reserve path is exempt from the debt
     * ledger: `mintingCap` and `amountInMinted` are neither read nor written (the same exemption family
     * as the OFT cross-chain credit path — minting is backed by locked reserves, not minter debt).
     * @param receiver Address receiving the minted uAsset.
     * @param amount Amount of uAsset to mint.
     */
    function reserveMint(address receiver, uint256 amount) external;

    /**
     * @notice Burns uAsset from an account through the reserve path.
     * @dev `msg.sender` must be a registered reserve minter. The burn never touches the debt ledger
     * (`mintingCap`/`amountInMinted`). When `account != msg.sender`, the caller must hold allowance on
     * `account`'s balance, mirroring {repay}'s allowance branch.
     * @param account Address whose uAsset balance is burned.
     * @param amount Amount of uAsset to burn.
     */
    function reserveBurn(address account, uint256 amount) external;

    /**
     * @notice Emitted by {mint} after uAsset is minted successfully.
     * @param minter Minter whose outstanding debt increases (`msg.sender`).
     * @param receiver Address that receives the minted uAsset.
     * @param amount Amount of uAsset minted.
     */
    event MintUAsset(address indexed minter, address indexed receiver, uint256 amount);

    /**
     * @notice Emitted by {repay} after uAsset is burned successfully.
     * @param minter Minter whose outstanding debt decreases (`msg.sender`).
     * @param amount Amount of uAsset burned.
     */
    event BurnUAsset(address indexed minter, uint256 amount);

    /**
     * @notice Emitted by {setMintingCap} after a minter's cap is updated.
     * @param minter Minter whose cap changed.
     * @param oldMintingCap Previous minting cap.
     * @param newMintingCap New minting cap.
     */
    event SetMintingCap(address indexed minter, uint256 oldMintingCap, uint256 newMintingCap);

    /**
     * @notice Emitted by {revokeMinter} after a minter's cap is cleared.
     * @param minter Minter whose minting permission was revoked.
     * @param oldMintingCap Cap before revocation.
     */
    event RevokeMinter(address indexed minter, uint256 oldMintingCap);

    /**
     * @notice Emitted by {transferMinterDebt} after outstanding debt moves between minter records.
     * @param from Minter whose outstanding debt decreases.
     * @param to Minter whose outstanding debt increases.
     * @param amount Amount of outstanding debt transferred.
     */
    event TransferMinterDebt(address indexed from, address indexed to, uint256 amount);

    /**
     * @notice Emitted by {setReserveMinter} after a reserve minter is registered or revoked.
     * @param minter Address whose reserve-minter registration changed.
     * @param status True when registered, false when revoked.
     */
    event SetReserveMinter(address indexed minter, bool status);

    /**
     * @notice Emitted by {reserveMint} after uAsset is minted through the reserve path.
     * @param minter Registered reserve minter that called the mint (`msg.sender`).
     * @param receiver Address that receives the minted uAsset.
     * @param amount Amount of uAsset minted.
     */
    event ReserveMintUAsset(address indexed minter, address indexed receiver, uint256 amount);

    /**
     * @notice Emitted by {reserveBurn} after uAsset is burned through the reserve path.
     * @param minter Registered reserve minter that called the burn (`msg.sender`).
     * @param amount Amount of uAsset burned.
     */
    event ReserveBurnUAsset(address indexed minter, uint256 amount);

    /**
     * @notice Thrown by {setMintingCap}, {revokeMinter}, {mint}, {repay}, {setReserveMinter}, {reserveMint}, or {reserveBurn} when a required address or amount is zero.
     */
    error ZeroInput();

    /**
     * @notice Thrown by {mint} or {transferMinterDebt} when the operation would exceed a minter's minting cap.
     */
    error ReachMintCap();

    /**
     * @notice Thrown by {repay} or {transferMinterDebt} when the requested amount exceeds outstanding minted debt.
     * @dev The limit is `amountInMinted`, the minter's outstanding debt, rather than an independent burn cap.
     */
    error ReachBurnCap();

    /**
     * @notice Thrown by {transferMinterDebt} for zero addresses, identical minter records, a zero amount,
     * or a registered reserve minter as the destination.
     */
    error InvalidTransferParams();

    /**
     * @notice Thrown by {reserveMint} or {reserveBurn} when the caller is not a registered reserve minter.
     */
    error NotReserveMinter();
}
