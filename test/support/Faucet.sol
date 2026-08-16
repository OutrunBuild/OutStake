// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMintable} from "./mocks/MockUSDC.sol";

interface IFaucet {
    function addToken(address token, uint256 dailyLimit) external;
}

error InvalidTokenAddress();
error InvalidDailyLimit();
error UnsupportedToken();
error ClaimTooSoon();

contract Faucet is Ownable {
    struct TokenInfo {
        uint256 dailyLimit;
        mapping(address => uint256) lastClaimed;
    }

    mapping(address => TokenInfo) public tokenInfos;

    constructor(address _owner) Ownable(_owner) {}

    function addToken(address token, uint256 dailyLimit) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress();
        if (dailyLimit == 0) revert InvalidDailyLimit();

        tokenInfos[token].dailyLimit = dailyLimit;
    }

    function claim(address token) public {
        uint256 dailyLimit = tokenInfos[token].dailyLimit;
        if (dailyLimit == 0) revert UnsupportedToken();

        uint256 lastClaimedTime = tokenInfos[token].lastClaimed[msg.sender];
        if (block.timestamp < lastClaimedTime + 1 days) revert ClaimTooSoon();

        tokenInfos[token].lastClaimed[msg.sender] = block.timestamp;
        IMintable(token).mint(msg.sender, dailyLimit);
    }

    function batchClaim(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length;) {
            claim(tokens[i]);
            unchecked {
                ++i;
            }
        }
    }
}
