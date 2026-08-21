// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IUniversalAssets} from "../interfaces/IUniversalAssets.sol";
import {OutrunOFTUpgradeable} from "../omnichain/OutrunOFTUpgradeable.sol";

/// @title Outrun universal asset (uAsset) token
/// @notice uAsset is a receipt token minted by staking positions. Each minter (a StakeManager contract) has its
///      own debt tracking: mintingCap is the ceiling, amountInMinted is outstanding debt. Minters repay by
///      burning uAsset, which reduces their outstanding debt. amountInMinted is a minter debt ledger, not a
///      same-chain totalSupply invariant: OFT cross-chain sends burn on the source chain and mint on the
///      destination chain without changing this minter debt ledger.
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
        mapping(address minter => MintingStatus) mintingStatusTable;
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
    ///      blocks mint until the cap is raised again (see revokeMinter).
    /// @param minter Address of the minter
    /// @param mintingCap New maximum number of uAsset this minter can mint
    function setMintingCap(address minter, uint256 mintingCap) public override onlyOwner {
        require(minter != address(0), ZeroInput());

        MintingStatus storage status = _mintingStatus(minter);
        uint256 oldMintingCap = status.mintingCap;
        status.mintingCap = mintingCap;

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
    /// @dev Owner-only accounting operation. Used when migrating or rebalancing stake manager allocations.
    ///      Migrates only the uAsset minter-level debt; if the minter is also constrained by position, wrap,
    ///      or other module ledgers, those ledgers must be migrated in the same coordinated flow because this
    ///      operation does not update them.
    ///      @dev PA-6: this is the ONLY operation that can silently break the cross-ledger invariant
    ///      `uAsset.mintingStatusTable[SP].amountInMinted == Σ positions[id].UAssetMinted + wrapUAssetDebt`
    ///      (see `OutrunStakingPositionUpgradeable` and `docs/deployment.md` PA-6). Pre-mainnet the
    ///      `owner` must be a timelock/multisig and this call must be atomically bundled with the SP-side
    ///      ledger migration in a single deployment script; standalone use will desync the ledgers and
    ///      is not self-healing (unlike `setMintingCap` over-cap which self-heals via repay).
    /// @param from Source minter address
    /// @param to Destination minter address
    /// @param amount Amount of debt to transfer
    function transferMinterDebt(address from, address to, uint256 amount) external override onlyOwner {
        require(from != address(0) && to != address(0) && from != to && amount != 0, InvalidTransferParams());

        MintingStatus storage fromStatus = _mintingStatus(from);
        uint256 fromAmountInMinted = fromStatus.amountInMinted;
        require(fromAmountInMinted >= amount, ReachBurnCap());

        MintingStatus storage toStatus = _mintingStatus(to);
        uint256 toAmountInMinted = toStatus.amountInMinted;
        uint256 toMintingCap = toStatus.mintingCap;
        // Keep the cap/debt invariant explicit so this reverts with ReachMintCap instead of a raw underflow panic.
        require(amount <= _remainingMintable(toMintingCap, toAmountInMinted), ReachMintCap());

        unchecked {
            fromStatus.amountInMinted = fromAmountInMinted - amount;
            toStatus.amountInMinted = toAmountInMinted + amount;
        }

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
        // Check the minter (msg.sender) hasn't exceeded its cap.
        require(amount <= _remainingMintable(mintingCap, amountInMinted), ReachMintCap());

        // Update debt before _mint — keeps C-E-I ordering in case future
        // hook overrides introduce external calls.
        unchecked {
            status.amountInMinted = amountInMinted + amount;
        }
        // Mint uAsset tokens to receiver.
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
        // Check the minter has enough outstanding debt to cover the repayment.
        require(amountInMinted >= amount, ReachBurnCap());

        // Update debt before _burn — keeps C-E-I ordering in case future
        // hook overrides introduce external calls.
        unchecked {
            status.amountInMinted = amountInMinted - amount;
        }

        // If repaying another account's balance, check allowance.
        if (account != msg.sender) _spendAllowance(account, msg.sender, amount);
        // Burn uAsset from the account.
        _burn(account, amount);

        emit BurnUAsset(msg.sender, amount);
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
