// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUniversalAssets} from "../interfaces/IUniversalAssets.sol";
import {OutrunOFTUpgradeable} from "../omnichain/OutrunOFTUpgradeable.sol";

/// @title Outrun universal asset (uAsset) token
/// @notice uAsset is a receipt token minted by staking positions. Each minter (a StakeManager contract) has its
///      own debt tracking: mintingCap is the ceiling, amountInMinted is outstanding debt. Minters repay by
///      burning uAsset, which reduces their outstanding debt. amountInMinted is a minter debt ledger, not a
///      same-chain totalSupply invariant: OFT cross-chain sends burn on the source chain and mint on the
///      destination chain without changing this minter debt ledger, and registered reserve minters (e.g., PSM
///      instances) mint and burn through the reserve path without reading or writing mintingCap/amountInMinted
///      either — the same exemption family, backed by locked reserves instead of minter debt.
/// @dev No `sweep` rescue exists by design — the contract does not inherit `TokenHelper` and the full
///      inheritance chain (`OutrunOFTUpgradeable`, `OutrunERC20PausableUpgradeable`, `OFTCoreUpgradeable`,
///      `OutrunRateLimiterUpgradeable`) exposes no rescue entrypoint. Stranded ERC20/NATIVE balances have
///      no owner rescue path. Any future rescue `sweep` MUST be `onlyOwner nonReentrant` behind a
///      timelock/multisig, MUST revert on `token == address(this)` (uAsset itself), `token == SY`,
///      and `token == NATIVE (address(0))` before `TokenHelper::_transferOut`, and MUST NOT move
///      `balanceOf` without updating `amountInMinted` — otherwise it desyncs
///      `OutrunUniversalAssetsUpgradeable.sol::checkMintableAmount`/`OutrunUniversalAssetsUpgradeable.sol::mintingStatusTable`
///      from `totalSupply` and breaks the cross-ledger invariant
///      `OutrunUniversalAssetsUpgradeable.sol::mintingStatusTable[SP].amountInMinted == Σ active positions[id].principalDebt`
///      (every staking position's minted principal; settled interest never enters the minter ledger),
///      which is not self-healing (unlike `OutrunUniversalAssetsUpgradeable.sol::setMintingCap` over-cap).
contract OutrunUniversalAssetsUpgradeable 
    // solhint-disable-next-line gas-small-strings
    layout at erc7201("outrun.storage.OutrunUniversalAssets")
    is
    Initializable,
    IUniversalAssets,
    OutrunOFTUpgradeable,
    UUPSUpgradeable
{
    struct OutrunUniversalAssetsStorage {
        // IMMUTABLE STORAGE LAYOUT: the contract-level layout at erc7201("outrun.storage.OutrunUniversalAssets")
        // allocates this contract's own variables from the namespace base slot in declaration order, and this
        // struct is the only own variable, so it sits at the base slot. Once deployed the layout below is
        // contract:
        //   ns+0 = mintingStatusTable mapping base (each minter's value slot keccak256(abi.encode(minter, ns+0));
        //          the MintingStatus value is one packed slot — mintingCap in the lower 128 bits,
        //          amountInMinted in the upper 128 bits; the value types are declared in IUniversalAssets.sol)
        //   ns+1 = reserveMinters mapping base (each minter's bool value slot keccak256(abi.encode(minter, ns+1)))
        // Field ORDER and count must never change (no reorder, no insertion before or between fields); new
        // storage is only allowed as a tail append. Any drift silently misreads the minter debt ledger or
        // forges reserve-minting authorization. The layout is pinned by raw-slot assertions in
        // test/upgradeable/OutrunUniversalAssetsStorageLayout.t.sol.
        mapping(address minter => MintingStatus) mintingStatusTable;
        // Registered reserve minters (e.g., PSM instances) may mint/burn through the reserve path,
        // which never touches the debt ledger in the mapping above.
        mapping(address minter => bool isReserveMinter) reserveMinters;
    }

    OutrunUniversalAssetsStorage private outrunUniversalAssetsStorage;

    error InvalidOFTUpgradeConfig();

    constructor(uint8 localDecimals_, address lzEndpoint) OutrunOFTUpgradeable(localDecimals_, lzEndpoint) {}

    /// @notice Initializes the uAsset token with name, symbol, and owner.
    /// @dev ERC20 `decimals()` derives from the constructor-frozen `localDecimals()` — decimals and OFT local
    ///      decimals are a single source of truth, so the init path does not accept a separate decimals argument.
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param owner_ Initial owner address
    function initialize(string calldata name_, string calldata symbol_, address owner_) external initializer {
        __OutrunOFT_init(name_, symbol_, owner_);
    }

    function _mintingStatus(address minter) private view returns (MintingStatus storage) {
        return outrunUniversalAssetsStorage.mintingStatusTable[minter];
    }

    function _isReserveMinter(address minter) private view returns (bool) {
        return outrunUniversalAssetsStorage.reserveMinters[minter];
    }

    function _remainingMintable(uint256 mintingCap, uint256 amountInMinted)
        private
        pure
        returns (uint256 amountInMintable)
    {
        return mintingCap > amountInMinted ? mintingCap - amountInMinted : 0;
    }

    /// @notice Returns the full minting status for a minter, including cap and outstanding debt.
    /// @param minter Address of the minter (a StakeManager contract)
    /// @return MintingStatus struct containing mintingCap and amountInMinted
    function mintingStatusTable(address minter) public view returns (MintingStatus memory) {
        return _mintingStatus(minter);
    }

    /// @notice Returns how many more uAsset the minter can mint before hitting its cap.
    /// @param minter Address of the minter
    /// @return amountInMintable Remaining mintable amount (mintingCap - amountInMinted)
    function checkMintableAmount(address minter) external view override returns (uint256 amountInMintable) {
        MintingStatus storage status = _mintingStatus(minter);
        return _remainingMintable(status.mintingCap, status.amountInMinted);
    }

    /// @notice Sets the minting cap for a minter. Owner-only.
    /// @dev The cap may be lowered below the minter's current amountInMinted: mint then reverts
    ///      ReachMintCap until repay reduces amountInMinted below the new cap. For a nonzero cap
    ///      this transient over-cap state is expected and self-heals through repay; a zero cap
    ///      blocks mint until the cap is raised again (see revokeMinter). Caps above
    ///      `type(uint128).max` revert `MintingCapTooLarge` — the cap persists in a packed 128-bit field.
    /// @param minter Address of the minter
    /// @param mintingCap New maximum number of uAsset this minter can mint
    function setMintingCap(address minter, uint256 mintingCap) public override onlyOwner {
        require(minter != address(0), ZeroInput());
        // The cap is a packed uint128 storage field; a larger value could not persist losslessly.
        require(mintingCap <= type(uint128).max, MintingCapTooLarge());

        MintingStatus storage status = _mintingStatus(minter);
        uint256 oldMintingCap = status.mintingCap;
        status.mintingCap = SafeCast.toUint128(mintingCap);

        emit SetMintingCap(minter, oldMintingCap, mintingCap);
    }

    /// @notice Revokes minting rights for a minter by setting its cap to zero. Owner-only.
    /// @param minter Address of the minter to revoke
    function revokeMinter(address minter) external override onlyOwner {
        require(minter != address(0), ZeroInput());

        MintingStatus storage status = _mintingStatus(minter);
        uint256 oldMintingCap = status.mintingCap;
        status.mintingCap = 0;

        emit RevokeMinter(minter, oldMintingCap);
    }

    /// @notice Moves outstanding debt between minter records without minting or burning tokens.
    /// @dev Owner-only accounting repair tool. Intended ONLY for correcting debt records that have no
    ///      position-debt backing (e.g. stray debt created by an operational incident): it migrates
    ///      only the uAsset minter-level debt and never updates staking-position or other module ledgers.
    ///      Live SP retirement or SY replacement must use the wind-down path instead
    ///      (`setMintingCap(SP, 0)` → `redeem` burn down → `revokeMinter`):
    ///      the SP side exposes no ledger export/import entrypoint and a full-ledger move cannot fit
    ///      in one transaction, so a live-ledger transfer would leave a non-self-healing desync.
    ///      This is the ONLY operation that can silently break the cross-ledger invariant
    ///      `uAsset.mintingStatusTable[SP].amountInMinted == Σ active positions[id].principalDebt`
    ///      (see `OutrunStakingPositionUpgradeable`). Pre-mainnet the
    ///      `owner` must be a timelock/multisig; every call must be followed by a mirror reconciliation
    ///      (`mintingStatusTable` direct read vs Σ active position principal debts; `checkMintableAmount`
    ///      clamps to zero when debt exceeds cap and is not a reconciliation source) with the desync
    ///      alert clearing as repair confirmation. Any call against position-backed debt desyncs
    ///      the ledgers and is not self-healing (unlike `setMintingCap` over-cap which self-heals via repay).
    ///      The destination must not be a registered reserve minter (e.g. a PSM instance): the reserve
    ///      path never reads the debt ledger, so such a transfer would strand debt with no repay path.
    /// @param from Source minter address
    /// @param to Destination minter address
    /// @param amount Amount of debt to transfer
    function transferMinterDebt(address from, address to, uint256 amount) external override onlyOwner {
        require(from != address(0) && to != address(0) && from != to && amount != 0, InvalidTransferParams());
        require(!_isReserveMinter(to), InvalidTransferParams());

        MintingStatus storage fromStatus = _mintingStatus(from);
        uint256 fromAmountInMinted = fromStatus.amountInMinted;
        require(fromAmountInMinted >= amount, ReachBurnCap());

        MintingStatus storage toStatus = _mintingStatus(to);
        uint256 toAmountInMinted = toStatus.amountInMinted;
        uint256 toMintingCap = toStatus.mintingCap;
        // Keep the cap/debt invariant explicit so this reverts with ReachMintCap instead of a raw underflow panic.
        require(amount <= _remainingMintable(toMintingCap, toAmountInMinted), ReachMintCap());

        // Both requires bound the packed uint128 writes: from-side debt cannot underflow,
        // to-side debt stays within its uint128 minting cap.
        fromStatus.amountInMinted -= SafeCast.toUint128(amount);
        toStatus.amountInMinted += SafeCast.toUint128(amount);

        emit TransferMinterDebt(from, to, amount);
    }

    /// @notice Mints uAsset tokens to a receiver, increasing the minter's outstanding debt.
    /// @dev Respects the pause state and the minter's minting cap.
    /// @param receiver Address to receive the newly minted tokens
    /// @param amount Amount of uAsset to mint
    function mint(address receiver, uint256 amount) external override whenNotPaused {
        require(amount != 0 && receiver != address(0), ZeroInput());

        MintingStatus storage status = _mintingStatus(msg.sender);
        uint256 amountInMinted = status.amountInMinted;
        uint256 mintingCap = status.mintingCap;
        require(amount <= _remainingMintable(mintingCap, amountInMinted), ReachMintCap());

        // Update debt before _mint — keeps C-E-I ordering in case future
        // hook overrides introduce external calls. The ReachMintCap check bounds
        // amountInMinted + amount by the uint128 cap, so the packed write cannot overflow.
        status.amountInMinted += SafeCast.toUint128(amount);
        _mint(receiver, amount);

        emit MintUAsset(msg.sender, receiver, amount);
    }

    /// @notice Burns uAsset from an account and decreases the minter's outstanding debt.
    /// @param account Address whose uAsset will be burned
    /// @param amount Amount of uAsset to burn
    function repay(address account, uint256 amount) external override whenNotPaused {
        require(account != address(0) && amount != 0, ZeroInput());

        MintingStatus storage status = _mintingStatus(msg.sender);
        uint256 amountInMinted = status.amountInMinted;
        require(amountInMinted >= amount, ReachBurnCap());

        // Update debt before _burn — keeps C-E-I ordering in case future
        // hook overrides introduce external calls. The ReachBurnCap check bounds
        // amount by the outstanding uint128 debt, so the packed write cannot underflow.
        status.amountInMinted -= SafeCast.toUint128(amount);

        // If repaying another account's balance, check allowance.
        if (account != msg.sender) _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);

        emit BurnUAsset(msg.sender, amount);
    }

    /// @notice Registers or revokes a reserve minter allowed to use the reserve mint/burn path. Owner-only.
    /// @dev Independent of the debt ledger: this registration neither creates nor clears any
    ///      `mintingStatusTable` record, and `setMintingCap`/`revokeMinter` do not constrain the reserve
    ///      path. Revoking a live reserve minter is the kill switch for its reserve path — both directions
    ///      then revert NotReserveMinter, fail-closed.
    /// @param minter Address to register or revoke
    /// @param status True to register, false to revoke
    function setReserveMinter(address minter, bool status) external override onlyOwner {
        require(minter != address(0), ZeroInput());

        outrunUniversalAssetsStorage.reserveMinters[minter] = status;

        emit SetReserveMinter(minter, status);
    }

    /// @notice Mints uAsset to a receiver through the reserve path.
    /// @dev Caller must be a registered reserve minter. Exempt from the debt ledger: `mintingCap` and
    ///      `amountInMinted` are neither read nor written (same exemption family as the OFT credit path),
    ///      so a zero cap or revoked debt-ledger status does not constrain this path.
    /// @param receiver Address to receive the newly minted tokens
    /// @param amount Amount of uAsset to mint
    function reserveMint(address receiver, uint256 amount) external override whenNotPaused {
        // Authorization first: an unregistered caller learns NotReserveMinter regardless of arguments.
        require(_isReserveMinter(msg.sender), NotReserveMinter());
        require(receiver != address(0) && amount != 0, ZeroInput());

        _mint(receiver, amount);

        emit ReserveMintUAsset(msg.sender, receiver, amount);
    }

    /// @notice Burns uAsset from an account through the reserve path.
    /// @dev Caller must be a registered reserve minter. The burn never touches the debt ledger
    ///      (`mintingCap`/`amountInMinted` are neither read nor written), mirroring the OFT debit
    ///      exemption. When `account` is not the caller, the caller must hold allowance on `account`'s
    ///      balance (same allowance branch as repay).
    /// @param account Address whose uAsset will be burned
    /// @param amount Amount of uAsset to burn
    function reserveBurn(address account, uint256 amount) external override whenNotPaused {
        // Authorization first: an unregistered caller learns NotReserveMinter regardless of arguments.
        require(_isReserveMinter(msg.sender), NotReserveMinter());
        require(account != address(0) && amount != 0, ZeroInput());

        // If burning another account's balance, check allowance.
        if (account != msg.sender) _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);

        emit ReserveBurnUAsset(msg.sender, amount);
    }

    /// @notice Validates that a new implementation preserves the LayerZero OFT configuration.
    /// @dev Defense layer over the constructor-frozen immutables of a new implementation.
    ///      Each field must stay unchanged because:
    ///      - endpoint: routes all cross-chain messages; a different endpoint would send through a
    ///        wrong or unconfigured LayerZero messaging layer.
    ///      - decimalConversionRate: drives every LD<->SD amount conversion; a different rate would
    ///        silently corrupt cross-chain amounts.
    ///      - localDecimals: binds the ERC20 `decimals()` metadata to the OFT conversion math; a
    ///        different value would make metadata and cross-chain amounts disagree.
    ///      These values are self-reported by `newImplementation`; the check only detects configuration
    ///      mismatches in implementations that report honestly and does not authenticate candidate code.
    ///      The owner must still review and trust the candidate implementation.
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        OutrunUniversalAssetsUpgradeable implementation = OutrunUniversalAssetsUpgradeable(newImplementation);
        if (
            address(implementation.endpoint()) != address(endpoint)
                || implementation.decimalConversionRate() != decimalConversionRate
                || implementation.localDecimals() != localDecimals()
        ) revert InvalidOFTUpgradeConfig();
    }
}
