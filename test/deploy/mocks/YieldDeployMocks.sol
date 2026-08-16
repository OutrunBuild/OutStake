// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract YieldDeployMockToken is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
}

contract YieldDeployMockAToken is YieldDeployMockToken {
    address public immutable UNDERLYING_ASSET_ADDRESS;

    constructor(address underlying_) YieldDeployMockToken("Aave aUSDC", "aUSDC", 18) {
        UNDERLYING_ASSET_ADDRESS = underlying_;
    }
}

contract YieldDeployMockAavePool {
    uint256 internal constant RAY = 1e27;

    function getReserveNormalizedIncome(address) external pure returns (uint256) {
        return RAY;
    }
}

contract YieldDeployMockUniversalAsset {
    error Unauthorized();

    address public immutable owner;
    address public lastMinter;
    uint256 public lastMintingCap;
    uint256 public capUpdateCount;

    mapping(address minter => uint256 cap) public mintingCaps;

    constructor(address owner_) {
        owner = owner_;
    }

    function setMintingCap(address minter, uint256 mintingCap) external {
        if (msg.sender != owner) revert Unauthorized();

        mintingCaps[minter] = mintingCap;
        lastMinter = minter;
        lastMintingCap = mintingCap;
        ++capUpdateCount;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
