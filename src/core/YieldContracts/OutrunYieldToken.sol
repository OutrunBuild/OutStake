// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunERC20 } from "../common/OutrunERC20.sol";
import { OutrunERC20Pausable } from "../common/OutrunERC20Pausable.sol";
import { IYieldToken } from "./interfaces/IYieldToken.sol";
import { Initializable } from "../libraries/Initializable.sol";

abstract contract OutrunYieldToken is IYieldToken, OutrunERC20Pausable, Initializable {
    address public SY;
    address public SP;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) OutrunERC20(_name, _symbol, _decimals) {}

    modifier onlySP() {
        require(msg.sender == SP, PermissionDenied());
        _;
    }

    function initialize(address _SY, address _SP) external override onlyOwner initializer {
        SY = _SY;
        SP = _SP;
    }

    /**
     * @dev Only positionOptionContract can mint when the user stake native yield token
     * @param account - Address who receive YT 
     * @param amount - The amount of minted YT
     */
    function mint(address account, uint256 amount) external override whenNotPaused onlySP {
        _mint(account, amount);
    }
}
