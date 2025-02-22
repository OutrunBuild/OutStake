// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunOFT } from "../common/OutrunOFT.sol";
import { TokenHelper } from "../libraries/TokenHelper.sol";
import { IPrincipalToken } from "./interfaces/IPrincipalToken.sol";
import { IUniversalPrincipalToken } from "./interfaces/IUniversalPrincipalToken.sol";

/**
 * @dev Outrun Universal Principal Token
 */
contract OutrunUniversalPrincipalToken is IUniversalPrincipalToken, OutrunOFT, TokenHelper {
    mapping(address PT => bool) public authorizedPTs;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address _lzEndpoint,
        address _delegate
    ) OutrunOFT(name_, symbol_, decimals_, _lzEndpoint, _delegate) Ownable(_delegate) {}

    modifier onlyAuthorizedPT(address PT) {
        require(authorizedPTs[PT], PermissionDenied());
        _;
    }

    /**
     * @param PT - Address of PT
     * @param authorized - Authorization status
     */
    function setAuthorizedPTs(address PT, bool authorized) external override onlyOwner {
        authorizedPTs[PT] = authorized;
    }

    /**
     * @dev Mint UPT from authorized PT
     * @param authorizedPT - Address of authorized PT
     * @param receiver - Address of UPT receiver
     * @param amountInPT - Amount of PT
     */
    function mintUPTFromPT(address authorizedPT, address receiver, uint256 amountInPT) external override onlyAuthorizedPT(authorizedPT) {
        IPrincipalToken(authorizedPT).burn(msg.sender, amountInPT);
        _mint(receiver, amountInPT);

        emit MintUPT(authorizedPT, receiver, amountInPT);
    }

    /**
     * @dev Redeem authorized PT from UPT
     * @param authorizedPT - Address of authorized PT
     * @param receiver - Address of PT receiver
     * @param amountInUPT - Amount of UPT
     */
    function redeemPTFromUPT(address authorizedPT, address receiver, uint256 amountInUPT) external override onlyAuthorizedPT(authorizedPT) {
        _burn(msg.sender, amountInUPT);
        IPrincipalToken(authorizedPT).mint(receiver, amountInUPT);

        emit RedeemPT(authorizedPT, receiver, amountInUPT);
    }

    /**
     * @dev Any can burn their UPT
     * @param amount - The amount of burned UPT
     */
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }
}
