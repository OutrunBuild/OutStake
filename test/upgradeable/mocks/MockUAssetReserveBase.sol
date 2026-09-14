// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniversalAssets} from "../../../src/assets/interfaces/IUniversalAssets.sol";

/// @title MockUAssetReserveBase
/// @notice Shared reserve-path and mint-cap seams for uAsset mocks.
/// @dev Single source for the reserve registry and its three entry points, mirroring
///      `OutrunUniversalAssetsUpgradeable` reserve semantics (owner-gated registry,
///      `NotReserveMinter` auth, `ZeroInput` validation, allowance branch on
///      `reserveBurn` and `repay`, the reserve-minter destination guard on
///      `transferMinterDebt`, and `ReserveMintUAsset`/`ReserveBurnUAsset` events), plus the
///      mint-cap ledger (`mintingStatusTable`) and its six entry points.
///      `reserveMint`, `reserveBurn`, `mint` and `repay` call `_requireNotPaused()` so
///      pause-aware mocks can enforce the production `whenNotPaused` invariant
///      via a virtual hook; pause-unaware mocks inherit the no-op default.
///      `repay` calls `_afterRepay()` before burning so mocks with repay probes
///      (e.g. position snapshots) can hook in without duplicating the ledger.
abstract contract MockUAssetReserveBase is ERC20, IUniversalAssets {
    address public immutable owner;

    mapping(address minter => bool) public reserveMinters;

    error OwnableUnauthorizedAccount(address account);

    modifier onlyOwner() {
        require(msg.sender == owner, OwnableUnauthorizedAccount(msg.sender));
        _;
    }

    constructor() ERC20("Mock UAsset", "mUAsset") {
        owner = msg.sender;
    }

    /// @notice Hook for pause-aware mocks; base is no-op.
    function _requireNotPaused() internal view virtual {}

    /// @notice Registers or revokes a reserve minter. Owner-only.
    function setReserveMinter(address minter, bool status) external virtual onlyOwner {
        require(minter != address(0), ZeroInput());
        reserveMinters[minter] = status;
        emit SetReserveMinter(minter, status);
    }

    /// @notice Hook for repay probes; base is no-op.
    function _afterRepay(address, uint256) internal virtual {}

    /// @notice Mints uAsset through the reserve path.
    function reserveMint(address receiver, uint256 amount) external virtual {
        _requireNotPaused();
        require(reserveMinters[msg.sender], NotReserveMinter());
        require(receiver != address(0) && amount != 0, ZeroInput());
        _mint(receiver, amount);
        emit ReserveMintUAsset(msg.sender, receiver, amount);
    }

    /// @notice Burns uAsset through the reserve path, with allowance when burning another account.
    function reserveBurn(address account, uint256 amount) external virtual {
        _requireNotPaused();
        require(reserveMinters[msg.sender], NotReserveMinter());
        require(account != address(0) && amount != 0, ZeroInput());
        if (account != msg.sender) _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
        emit ReserveBurnUAsset(msg.sender, amount);
    }

    mapping(address minter => MintingStatus) public mintingStatusTable;

    function checkMintableAmount(address minter) external view virtual returns (uint256 amountInMintable) {
        MintingStatus storage status = mintingStatusTable[minter];
        amountInMintable = status.mintingCap > status.amountInMinted ? status.mintingCap - status.amountInMinted : 0;
    }

    function setMintingCap(address minter, uint256 mintingCap) public virtual onlyOwner {
        require(minter != address(0), ZeroInput());
        mintingStatusTable[minter].mintingCap = mintingCap;
    }

    function revokeMinter(address minter) external virtual onlyOwner {
        require(minter != address(0), ZeroInput());
        mintingStatusTable[minter].mintingCap = 0;
    }

    function transferMinterDebt(address from, address to, uint256 amount) external virtual onlyOwner {
        require(from != address(0) && to != address(0) && from != to && amount != 0, ZeroInput());
        // A reserve-minter destination would strand the debt: the reserve path never reads this ledger.
        require(!reserveMinters[to], InvalidTransferParams());

        MintingStatus storage fromStatus = mintingStatusTable[from];
        require(fromStatus.amountInMinted >= amount, ReachBurnCap());

        MintingStatus storage toStatus = mintingStatusTable[to];
        require(toStatus.mintingCap >= toStatus.amountInMinted, ReachMintCap());
        require(amount <= toStatus.mintingCap - toStatus.amountInMinted, ReachMintCap());

        fromStatus.amountInMinted -= amount;
        toStatus.amountInMinted += amount;
    }

    function mint(address receiver, uint256 amount) external virtual {
        _requireNotPaused();
        MintingStatus storage status = mintingStatusTable[msg.sender];
        require(
            status.mintingCap >= status.amountInMinted && amount <= status.mintingCap - status.amountInMinted,
            ReachMintCap()
        );
        status.amountInMinted += amount;
        _mint(receiver, amount);
    }

    function repay(address account, uint256 amount) external virtual {
        _requireNotPaused();
        MintingStatus storage status = mintingStatusTable[msg.sender];
        require(status.amountInMinted >= amount, ReachBurnCap());
        // Self-repay (account == msg.sender) spends no allowance, mirroring the production branch.
        if (account != msg.sender) _spendAllowance(account, msg.sender, amount);
        status.amountInMinted -= amount;
        _afterRepay(account, amount);
        _burn(account, amount);
    }
}
