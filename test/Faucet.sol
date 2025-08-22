// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IMintable } from "./MockUSDC.sol";

interface IFaucet {
    function addToken(address token, uint256 dailyLimit) external;
}

contract Faucet is Ownable {
    struct TokenInfo {
        uint256 dailyLimit;
        mapping(address => uint256) lastClaimed;
    }

    mapping(address => TokenInfo) public tokenInfos;

    constructor(address _owner) Ownable(_owner) {}

    function addToken(address token, uint256 dailyLimit) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(dailyLimit > 0, "Daily limit must be greater than 0");

        tokenInfos[token].dailyLimit = dailyLimit;
    }

    function claim(address token) public {
        uint256 dailyLimit = tokenInfos[token].dailyLimit;
        require(dailyLimit != 0, "Token not supported");

        uint256 lastClaimedTime = tokenInfos[token].lastClaimed[msg.sender];
        require(block.timestamp >= lastClaimedTime + 1 days, "Can only claim once per day");

        tokenInfos[token].lastClaimed[msg.sender] = block.timestamp;
        IMintable(token).mint(msg.sender, dailyLimit);
    }

    function batchClaim(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            claim(tokens[i]);
        }
    }
}