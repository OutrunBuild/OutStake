// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import "../common/OutrunERC20.sol";
import "../common/Initializable.sol";
import "./interfaces/IYieldToken.sol";

abstract contract OutrunYieldToken is IYieldToken, OutrunERC20, Initializable {
    address public SY;
    address public POT;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) OutrunERC20(name_, symbol_, decimals_) {
    }

    modifier onlyPositionOptionContract() {
        require(msg.sender == POT, PermissionDenied());
        _;
    }

    /**
     * @dev Initializer
     * @param _POT - Address of positionOptionContract
     */
    function initialize(address _SY, address _POT) external virtual override initializer {
        SY = _SY;
        POT = _POT;
    }

    /**
     * @dev Only positionOptionContract can mint when the user stake native yield token
     * @param account - Address who receive YT 
     * @param amount - The amount of minted YT
     */
    function mint(address account, uint256 amount) external override onlyPositionOptionContract{
        _mint(account, amount);
    }
}
