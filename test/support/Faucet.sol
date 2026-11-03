// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMintable} from "./mocks/MockUSDC.sol";

interface ICreditMerkleClaim {
    function claim(uint256 amount, bytes32[] calldata merkleProof) external;
}

interface IFaucet {
    function addToken(address token, uint256 dailyLimit) external;
}

error InvalidTokenAddress();
error InvalidDailyLimit();
error UnsupportedToken();
error ClaimTooSoon();
error InsufficientFaucetBalance();
error BootstrapAlreadyDone();
error HeldTokenTransferFailed();

contract Faucet is Ownable {
    struct TokenInfo {
        uint256 dailyLimit;
        mapping(address => uint256) lastClaimed;
    }

    mapping(address => TokenInfo) public tokenInfos;

    /// @notice Held-token drip registry: tokens the faucet does NOT mint but drips from its own
    ///         balance by transfer (e.g. GenesisCredit pots — their only mint path is the
    ///         merkle-airdrop claim, so the owner claims a pot once and parks it here).
    struct HeldTokenInfo {
        uint256 dailyLimit;
        mapping(address => uint256) lastClaimed;
    }

    mapping(address => HeldTokenInfo) public heldTokenInfos;

    mapping(address => bool) public bootstrappedCredits;

    constructor(address _owner) Ownable(_owner) {}

    function addToken(address token, uint256 dailyLimit) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress();
        if (dailyLimit == 0) revert InvalidDailyLimit();

        tokenInfos[token].dailyLimit = dailyLimit;
    }

    /// @notice Register a held token for transfer-based daily drips (testnet faucet entry).
    /// @dev The faucet must already hold (or later receive) enough balance; claimHeld reverts
    ///      InsufficientFaucetBalance when the pot cannot cover one daily drip.
    function addHeldToken(address token, uint256 dailyLimit) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress();
        if (dailyLimit == 0) revert InvalidDailyLimit();

        heldTokenInfos[token].dailyLimit = dailyLimit;
    }

    /// @notice Claim the daily drip of a registered token (testnet faucet entry).
    /// @dev Testnet user entry point: no in-repo test or script invokes it; retained
    ///      for the mock-token/genesis testnet scaffolding, same retention basis as
    ///      `IWETH.sol::withdraw`.
    function claim(address token) public {
        uint256 dailyLimit = tokenInfos[token].dailyLimit;
        if (dailyLimit == 0) revert UnsupportedToken();

        uint256 lastClaimedTime = tokenInfos[token].lastClaimed[msg.sender];
        // lastClaimedTime == 0 means never claimed; without the guard a fresh claimant would be
        // blocked whenever block.timestamp < 1 days (only observable under tiny test timestamps).
        if (lastClaimedTime != 0 && block.timestamp < lastClaimedTime + 1 days) revert ClaimTooSoon();

        tokenInfos[token].lastClaimed[msg.sender] = block.timestamp;
        IMintable(token).mint(msg.sender, dailyLimit);
    }

    /// @notice Claim the daily drip of a registered held token by transfer (testnet faucet entry).
    /// @dev Same daily cooldown shape as `claim`; the balance check runs BEFORE the cooldown
    ///      slot is written so a claim against an empty pot does not burn the daily cooldown.
    function claimHeld(address token) public {
        uint256 dailyLimit = heldTokenInfos[token].dailyLimit;
        if (dailyLimit == 0) revert UnsupportedToken();

        uint256 lastClaimedTime = heldTokenInfos[token].lastClaimed[msg.sender];
        if (lastClaimedTime != 0 && block.timestamp < lastClaimedTime + 1 days) revert ClaimTooSoon();

        if (IERC20(token).balanceOf(address(this)) < dailyLimit) revert InsufficientFaucetBalance();

        heldTokenInfos[token].lastClaimed[msg.sender] = block.timestamp;
        bool ok = IERC20(token).transfer(msg.sender, dailyLimit);
        if (!ok) revert HeldTokenTransferFailed();
    }

    /// @notice Claim the daily drip of multiple registered tokens in one call.
    /// @dev Same retention basis as `claim` above: a testnet entry point, unused in-repo.
    function batchClaim(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length;) {
            claim(tokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice One-time merkle bootstrap of a GenesisCredit pot into this faucet.
    /// @dev GenesisCredit's only mint door is its merkle claim and the leaf binds msg.sender,
    ///      so the FAUCET must be the claimant: the credit owner rotates the root to a
    ///      single-leaf (this faucet, amount) tree, then calls this exactly once per credit;
    ///      the minted pot backs claimHeld. Guarded one-shot so a rotated root can never be
    ///      used to inflate the pot behind the owner's back.
    function bootstrapGenesisCredit(address credit, uint256 amount, bytes32[] calldata merkleProof) external onlyOwner {
        if (bootstrappedCredits[credit]) revert BootstrapAlreadyDone();
        bootstrappedCredits[credit] = true;
        ICreditMerkleClaim(credit).claim(amount, merkleProof);
    }

    /// @notice Claim the daily drip of multiple registered held tokens in one call.
    /// @dev Same retention basis as `batchClaim` above.
    function batchClaimHeld(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length;) {
            claimHeld(tokens[i]);
            unchecked {
                ++i;
            }
        }
    }
}
