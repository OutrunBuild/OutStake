// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IBlast, BlastModeEnum } from "./IBlast.sol";

abstract contract BlastGovernorable {
    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);  // TODO mainnet

    address public blastGovernor;

    error BlastZeroAddress();

    error UnauthorizedAccount(address account);

    event ClaimMaxGas(address indexed recipient, uint256 gasAmount);

    event BlastGovernorTransferred(address indexed previousBlastGovernor, address indexed newBlastGovernor);

    constructor(address initialBlastGovernor) {
        require(initialBlastGovernor != address(0), BlastZeroAddress());
        blastGovernor = initialBlastGovernor;
    }

    modifier onlyBlastGovernor() {
        address msgSender = msg.sender;
        require(blastGovernor == msgSender, UnauthorizedAccount(msgSender));
        _;
    }

    function configure(BlastModeEnum.YieldMode yieldMode, BlastModeEnum.GasMode gasMode) external onlyBlastGovernor {
        BLAST.configure(yieldMode, gasMode, blastGovernor);
    }

    /**
     * @dev Read all gas remaining balance 
     */
    function readGasBalance() external view onlyBlastGovernor returns (uint256) {
        (, uint256 gasBanlance, , ) = BLAST.readGasParams(address(this));
        return gasBanlance;
    }

    /**
     * @dev Claim max gas of this contract
     * @param recipient - Address of receive gas
     */
    function claimMaxGas(address recipient) external onlyBlastGovernor returns (uint256 gasAmount) {
        require(recipient != address(0), BlastZeroAddress());

        gasAmount = BLAST.claimMaxGas(address(this), recipient);
        emit ClaimMaxGas(recipient, gasAmount);
    }

    function transferGasManager(address newBlastGovernor) public onlyBlastGovernor {
        require(newBlastGovernor != address(0), BlastZeroAddress());

        _transferBlastGovernor(newBlastGovernor);
    }

    function _transferBlastGovernor(address newBlastGovernor) internal {
        address oldBlastGovernor = blastGovernor;
        blastGovernor = newBlastGovernor;
        BLAST.configure(BlastModeEnum.YieldMode.CLAIMABLE, BlastModeEnum.GasMode.CLAIMABLE, newBlastGovernor);

        emit BlastGovernorTransferred(oldBlastGovernor, newBlastGovernor);
    }
}