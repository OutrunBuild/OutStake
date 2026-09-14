// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMemeverseLauncher} from "../../../src/router/interfaces/IMemeverseLauncher.sol";
import {IPOLendGenesis} from "../../../src/router/interfaces/IPOLendGenesis.sol";

/**
 * @title MockGenesisLauncher
 * @notice Mock genesis launcher shared by router and position tests: pulls the exact approved
 *         uAsset amount and records the genesis call.
 * @dev Full mock of the launcher seam both genesis consumers share (`IMemeverseLauncher.genesis`:
 *      verseId / uint128 amount / user plus the transferFrom pull of the exact approved amount).
 *      Models no launcher-side verse bookkeeping beyond the last-call record.
 */
contract MockGenesisLauncher is IMemeverseLauncher {
    error GenesisTransferFailed();

    // IERC20-typed so the mock serves both mock-uAsset and real-uAsset fixtures.
    IERC20 internal immutable uAsset;
    uint256 internal lastVerseId;
    uint128 internal lastAmountInUAsset;
    address internal lastUser;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256 verseId, uint128 amountInUAsset, address user) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert GenesisTransferFailed();
        }
        lastVerseId = verseId;
        lastAmountInUAsset = amountInUAsset;
        lastUser = user;
    }

    function snapshot() external view returns (uint256 verseId, uint128 amountInUAsset, address user) {
        return (lastVerseId, lastAmountInUAsset, lastUser);
    }
}

/**
 * @title MockGenesisPartialLauncher
 * @notice Mock genesis launcher that consumes only half of the approved uAsset.
 * @dev Partial mock: models a launcher that pulls exactly half of `amountInUAsset` (transferFrom)
 *      so the caller's full-consumption post-condition must fire. Does not model the call record,
 *      full pulls, or any other genesis side effect.
 */
contract MockGenesisPartialLauncher is IMemeverseLauncher {
    IERC20 internal immutable uAsset;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256, uint128 amountInUAsset, address) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset / 2)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
    }
}

/**
 * @title MockGenesisEmptyLauncher
 * @notice Mock genesis launcher that consumes none of the approved uAsset.
 * @dev Partial mock: models a launcher that leaves the approved uAsset untouched (no transferFrom).
 *      Does not model the call record or any other genesis side effect.
 */
contract MockGenesisEmptyLauncher is IMemeverseLauncher {
    function genesis(uint256, uint128, address) external override {}
}

/**
 * @title MockGenesisTransferBackLauncher
 * @notice Mock genesis launcher that pulls the full approved uAsset and transfers part back.
 * @dev Partial mock: models the full-pull-then-return behavior (transferFrom of the full amount
 *      followed by a transfer of one tenth back to the caller). Does not model the call record or
 *      any other genesis side effect.
 */
contract MockGenesisTransferBackLauncher is IMemeverseLauncher {
    IERC20 internal immutable uAsset;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256, uint128 amountInUAsset, address) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
        if (!uAsset.transfer(msg.sender, amountInUAsset / 10)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
    }
}

/**
 * @title MockGenesisRevertingLauncher
 * @notice Mock genesis launcher whose genesis always reverts with a custom error.
 * @dev Partial mock: models a launcher-side failure only (genesis reverts before any uAsset
 *      movement). Does not model the call record, pulls, or any other genesis side effect.
 */
contract MockGenesisRevertingLauncher is IMemeverseLauncher {
    error GenesisLauncherReverted();

    function genesis(uint256, uint128, address) external pure override {
        revert GenesisLauncherReverted();
    }
}

/**
 * @title MockPOLend
 * @notice Mock POLend leveraged-genesis market: quotes borrowed debt at a fixed rate and pulls
 *         the interest from the payer.
 * @dev Partial mock: models only the POLend seams the router's leveraged-genesis entry depends
 *      on — the marketUAsset binding read, the exact interest pull via transferFrom, the
 *      user-keyed interest ledger, and the borrowedAmount quote at a fixed rate. Does not model
 *      market states, debt caps, launcher reads, credit paths, or settlement.
 */
contract MockPOLend is IPOLendGenesis {
    using Math for uint256;

    address public immutable uAsset;
    uint256 public immutable interestRate;
    // Failure-injection switch: pull only half the interest so the caller's
    // full-consumption post-condition fires.
    bool public pullHalf;

    mapping(uint256 => address) public marketUAsset;
    mapping(uint256 => mapping(address => uint256)) public leveragedInterestPaid;
    address public lastPayer;
    address public lastUser;

    constructor(address uAsset_, uint256 interestRate_) {
        uAsset = uAsset_;
        interestRate = interestRate_;
    }

    function setMarketUAsset(uint256 verseId, address uAsset_) external {
        marketUAsset[verseId] = uAsset_;
    }

    function setPullHalf() external {
        pullHalf = true;
    }

    function leveragedGenesis(uint256 verseId, uint256 interestAmount, address user)
        external
        returns (uint256 borrowedAmount)
    {
        require(interestAmount != 0 && user != address(0), "zero input");
        borrowedAmount = interestAmount.mulDiv(1e18, interestRate);
        leveragedInterestPaid[verseId][user] += interestAmount;
        (lastPayer, lastUser) = (msg.sender, user);
        IERC20(uAsset).transferFrom(msg.sender, address(this), pullHalf ? interestAmount / 2 : interestAmount);
    }
}
