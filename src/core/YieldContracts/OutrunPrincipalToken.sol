// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunERC20 } from "../common/OutrunERC20.sol";
import { OutrunERC20Pausable } from "../common/OutrunERC20Pausable.sol";
import { OutrunERC20FlashMint } from "../common/OutrunERC20FlashMint.sol";
import { Initializable } from "../libraries/Initializable.sol";
import { IPrincipalToken } from "./interfaces/IPrincipalToken.sol";

contract OutrunPrincipalToken is IPrincipalToken, OutrunERC20FlashMint, OutrunERC20Pausable, Initializable {
    address public SP;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _owner
    ) OutrunERC20(_name, _symbol, _decimals) Ownable(_owner) {}

    modifier onlySP() {
        require(msg.sender == SP, PermissionDenied());
        _;
    }

    /**
     * @dev Initializer
     * @param _SP - Address of Staking Position contract
     */
    function initialize(address _SP) external override onlyOwner initializer {
        SP = _SP;
    }

    /**
     * @dev Only authorized contract can mint
     * @param account - Address who receive PT 
     * @param amount - The amount of minted PT
     */
    function mint(address account, uint256 amount) external override onlySP whenNotPaused {
        _mint(account, amount);
    }

    /**
     * @notice Burn the PT by self
     * @param amount - The amount of the PT to burn
     */
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Only authorized contract can burn
     * @param account - The address of the account
     * @param amount - The amount of the PT to burn
     */
    function burn(address account, uint256 amount) external override onlySP {
        _burn(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override(OutrunERC20, OutrunERC20Pausable) {
        super._update(from, to, value);
    }
}
