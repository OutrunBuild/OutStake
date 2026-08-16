// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Outrun upgradeable ERC20 base contract
/// @notice Minimal upgradeable ERC20 implementation holding name, symbol, decimals, balances, allowances, and
///      totalSupply in ERC-7201 namespaced storage; state is set through `__OutrunERC20_init` guarded by
///      `onlyInitializing`, never a constructor. Every mint, burn, and transfer funnels through the virtual
///      `_update` hook — the single override point for subclasses. Root base of the Outrun token family:
///      inherited by OutrunERC20PausableUpgradeable and, through it, by every SY adapter (SYBaseUpgradeable)
///      and the omnichain OutrunOFTUpgradeable/uAsset contracts.
abstract contract OutrunERC20Upgradeable is Initializable, ContextUpgradeable, IERC20, IERC20Metadata, IERC20Errors {
    /// @custom:storage-location erc7201:outrun.storage.OutrunERC20
    // forge-lint: disable-next-line(pascal-case-struct)
    struct OutrunERC20Storage {
        mapping(address account => uint256) balances;
        mapping(address account => mapping(address spender => uint256)) allowances;
        uint256 totalSupply;
        string name;
        string symbol;
        uint8 decimals;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunERC20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_ERC20_STORAGE_LOCATION =
        0x77d1373660b69e27ef6b7052ba58efede68bac459506eb86ffbe444e4aa4d100;

    function _getOutrunERC20Storage() private pure returns (OutrunERC20Storage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := OUTRUN_ERC20_STORAGE_LOCATION
        }
    }

    function __OutrunERC20_init(string memory name_, string memory symbol_, uint8 decimals_) internal onlyInitializing {
        OutrunERC20Storage storage $ = _getOutrunERC20Storage();
        $.name = name_;
        $.symbol = symbol_;
        $.decimals = decimals_;
    }

    function name() public view virtual returns (string memory) {
        return _getOutrunERC20Storage().name;
    }

    function symbol() public view virtual returns (string memory) {
        return _getOutrunERC20Storage().symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return _getOutrunERC20Storage().decimals;
    }

    function totalSupply() public view virtual returns (uint256) {
        return _getOutrunERC20Storage().totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _getOutrunERC20Storage().balances[account];
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _getOutrunERC20Storage().allowances[owner][spender];
    }

    function transfer(address to, uint256 value) external virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0), ERC20InvalidSender(address(0)));
        require(to != address(0), ERC20InvalidReceiver(address(0)));
        _update(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal virtual {
        OutrunERC20Storage storage $ = _getOutrunERC20Storage();
        if (from == address(0)) {
            $.totalSupply += value;
        } else {
            uint256 fromBalance = $.balances[from];
            require(fromBalance >= value, ERC20InsufficientBalance(from, fromBalance, value));
            unchecked {
                $.balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                $.totalSupply -= value;
            }
        } else {
            unchecked {
                $.balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    function _mint(address account, uint256 value) internal {
        require(account != address(0), ERC20InvalidReceiver(address(0)));
        _update(address(0), account, value);
    }

    function _burn(address account, uint256 value) internal {
        require(account != address(0), ERC20InvalidSender(address(0)));
        _update(account, address(0), value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal {
        require(owner != address(0), ERC20InvalidApprover(address(0)));
        require(spender != address(0), ERC20InvalidSpender(address(0)));

        _getOutrunERC20Storage().allowances[owner][spender] = value;
        if (emitEvent) emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, ERC20InsufficientAllowance(spender, currentAllowance, value));
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}
