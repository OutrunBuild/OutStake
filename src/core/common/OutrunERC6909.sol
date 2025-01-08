// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC6909 is IERC165 {
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);


    function isOperator(address owner, address operator) external view returns (bool);

    function balanceOf(address account, uint256 id) external view returns (uint256);

    function allowance(address owner, address spender, uint256 id) external view returns (uint256);


    function transfer(
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool);

    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool);

    function approve(
        address spender,
        uint256 id,
        uint256 amount
    ) external returns (bool);

    function setOperator(address operator, bool approved) external returns (bool);
}

/**
 * @dev Outrun's ERC6909 implementation, modified from @solmate implementation
 */
contract OutrunERC6909 is IERC6909 {
    string public name;

    string public symbol;

    uint8 public immutable decimals;

    mapping(address => mapping(address => bool)) public isOperator;

    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC6909 LOGIC
    //////////////////////////////////////////////////////////////*/

    function transfer(
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        balanceOf[msg.sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);

        return true;
    }

    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }

        balanceOf[sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }

    function approve(
        address spender,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;

        emit Approval(msg.sender, spender, id, amount);

        return true;
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0x0f632fb3; // ERC165 Interface ID for ERC6909
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(
        address receiver,
        uint256 id,
        uint256 amount
    ) internal {
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, address(0), receiver, id, amount);
    }

    function _burn(
        address sender,
        uint256 id,
        uint256 amount
    ) internal {
        balanceOf[sender][id] -= amount;

        emit Transfer(msg.sender, sender, address(0), id, amount);
    }
}
