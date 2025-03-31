// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunOFT } from "../common/OutrunOFT.sol";
import { IUniversalPrincipalToken } from "./interfaces/IUniversalPrincipalToken.sol";

/**
 * @dev Outrun Universal Principal Token
 */
contract OutrunUniversalPrincipalToken is IUniversalPrincipalToken, OutrunOFT {
    mapping(address SP => bool) public isAuthorized;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _lzEndpoint,
        address _owner
    ) OutrunOFT(_name, _symbol, _decimals, _lzEndpoint, _owner) Ownable(_owner) {}

    
    modifier onlyAuthorized() {
        require(isAuthorized[msg.sender], PermissionDenied());
        _;
    }

    /**
     * @param SP - Address of SP
     * @param authorized - Authorization status
     */
    function setAuthorized(address SP, bool authorized) external override onlyOwner {
        isAuthorized[SP] = authorized;
    }

    /**
     * @dev Mint UPT if obtaining authorization
     * @param receiver - Address of UPT receiver
     * @param amount - Amount of UPT
     */
    function mint(address receiver, uint256 amount) external override onlyAuthorized whenNotPaused {
        _mint(receiver, amount);

        emit MintUPT(msg.sender, receiver, amount);
    }

    /**
     * @dev Only authorized contract can burn
     * @param account - The address of the account
     * @param amount - The amount of the UPT to burn
     */
    function burn(address account, uint256 amount) external override onlyAuthorized {
        _burn(account, amount);
    }
}
