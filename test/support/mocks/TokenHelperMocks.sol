// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {TokenHelper} from "../../../src/libraries/TokenHelper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Harness to expose internal functions
contract TokenHelperHarness is TokenHelper {
    constructor() {}

    function exposedTransferIn(address token, address from, uint256 amount) external payable {
        _transferIn(token, from, amount);
    }

    function exposedTransferOut(address token, address to, uint256 amount) external {
        _transferOut(token, to, amount);
    }

    function exposedSafeApprove(address token, address to, uint256 amount) external {
        _safeApprove(token, to, amount);
    }

    function exposedSafeApproveInf(address token, address to) external {
        _safeApproveInf(token, to);
    }

    function exposedSelfBalance(address token) external view returns (uint256) {
        return _selfBalance(token);
    }

    // Expose the production approval-refresh threshold so tests can anchor it
    function exposedLowerBoundApproval() external pure returns (uint256) {
        return LOWER_BOUND_APPROVAL;
    }

    // Receive ETH for native transfers
    receive() external payable {}
}

// Mock ERC20 with mint capability
contract MockERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Contract that always reverts in receive()
contract RevertingReceiver {
    receive() external payable {
        revert("I don't accept ETH");
    }
}
