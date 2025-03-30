// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

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
