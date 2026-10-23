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
 * @dev Full mock of the launcher seam both genesis consumers share (`IMemeverseLauncher`:
 *      genesis / preorder with verseId / uint256 amount / user plus the transferFrom pull of the
 *      exact approved amount, and the getUAssetByVerseId binding read). Models no launcher-side
 *      verse bookkeeping beyond the last-call records.
 */
contract MockGenesisLauncher is IMemeverseLauncher {
    error GenesisTransferFailed();

    // IERC20-typed so the mock serves both mock-uAsset and real-uAsset fixtures.
    IERC20 internal immutable uAsset;
    uint256 internal lastVerseId;
    uint256 internal lastAmountInUAsset;
    address internal lastUser;
    uint256 internal lastPreorderVerseId;
    uint256 internal lastPreorderAmount;
    address internal lastPreorderUser;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256 verseId, uint256 amountInUAsset, address user) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert GenesisTransferFailed();
        }
        lastVerseId = verseId;
        lastAmountInUAsset = amountInUAsset;
        lastUser = user;
    }

    function preorder(uint256 verseId, uint256 amountInUAsset, address user) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert GenesisTransferFailed();
        }
        lastPreorderVerseId = verseId;
        lastPreorderAmount = amountInUAsset;
        lastPreorderUser = user;
    }

    function getUAssetByVerseId(uint256) external view override returns (address) {
        return address(uAsset);
    }

    function snapshot() external view returns (uint256 verseId, uint256 amountInUAsset, address user) {
        return (lastVerseId, lastAmountInUAsset, lastUser);
    }

    function preorderSnapshot() external view returns (uint256 verseId, uint256 amountInUAsset, address user) {
        return (lastPreorderVerseId, lastPreorderAmount, lastPreorderUser);
    }
}

/**
 * @title MockGenesisPartialLauncher
 * @notice Mock genesis launcher that consumes only half of the approved uAsset.
 * @dev Partial mock: models a launcher that pulls exactly half of `amountInUAsset` (transferFrom)
 *      so the caller's full-consumption post-condition must fire. The preorder / getUAssetByVerseId
 *      members are inert stubs satisfying the widened interface; tests never exercise them here.
 *      Does not model the call record, full pulls, or any other genesis side effect.
 */
contract MockGenesisPartialLauncher is IMemeverseLauncher {
    IERC20 internal immutable uAsset;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256, uint256 amountInUAsset, address) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset / 2)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
    }

    function preorder(uint256, uint256, address) external override {}

    function getUAssetByVerseId(uint256) external view override returns (address) {
        return address(uAsset);
    }
}

/**
 * @title MockGenesisEmptyLauncher
 * @notice Mock genesis launcher that consumes none of the approved uAsset.
 * @dev Partial mock: models a launcher that leaves the approved uAsset untouched (no transferFrom).
 *      The preorder / getUAssetByVerseId members are inert stubs satisfying the widened interface.
 *      Does not model the call record or any other genesis side effect.
 */
contract MockGenesisEmptyLauncher is IMemeverseLauncher {
    function genesis(uint256, uint256, address) external override {}

    function preorder(uint256, uint256, address) external override {}

    function getUAssetByVerseId(uint256) external view override returns (address) {
        return address(0);
    }
}

/**
 * @title MockGenesisTransferBackLauncher
 * @notice Mock genesis launcher that pulls the full approved uAsset and transfers part back.
 * @dev Partial mock: models the full-pull-then-return behavior (transferFrom of the full amount
 *      followed by a transfer of one tenth back to the caller). The preorder / getUAssetByVerseId
 *      members are inert stubs satisfying the widened interface; tests never exercise them here.
 *      Does not model the call record or any other genesis side effect.
 */
contract MockGenesisTransferBackLauncher is IMemeverseLauncher {
    IERC20 internal immutable uAsset;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256, uint256 amountInUAsset, address) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
        if (!uAsset.transfer(msg.sender, amountInUAsset / 10)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
    }

    function preorder(uint256, uint256, address) external override {}

    function getUAssetByVerseId(uint256) external view override returns (address) {
        return address(uAsset);
    }
}

/**
 * @title MockGenesisRevertingLauncher
 * @notice Mock genesis launcher whose genesis always reverts with a custom error.
 * @dev Partial mock: models a launcher-side failure only (genesis reverts before any uAsset
 *      movement). The preorder / getUAssetByVerseId members are inert stubs satisfying the widened
 *      interface. Does not model the call record, pulls, or any other genesis side effect.
 */
contract MockGenesisRevertingLauncher is IMemeverseLauncher {
    error GenesisLauncherReverted();

    function genesis(uint256, uint256, address) external pure override {
        revert GenesisLauncherReverted();
    }

    function preorder(uint256, uint256, address) external pure override {
        revert GenesisLauncherReverted();
    }

    function getUAssetByVerseId(uint256) external view override returns (address) {
        return address(0);
    }
}

/**
 * @title MockPreorderRevertingLauncher
 * @notice Mock genesis launcher whose `genesis` fully pulls and records while `preorder` always
 *         reverts with a custom error.
 * @dev Partial mock: models the combined-entry atomicity seam — `genesis` keeps the full mock
 *      accounting (exact transferFrom pull plus the last-call record), then `preorder` reverts so
 *      the caller's transaction-level rollback must undo the already-recorded genesis leg. The
 *      `getUAssetByVerseId` binding read returns the wired uAsset. Does not model verse
 *      bookkeeping, preorder accounting, or any other launcher side effect.
 */
contract MockPreorderRevertingLauncher is IMemeverseLauncher {
    error PreorderLauncherReverted();

    IERC20 internal immutable uAsset;
    uint256 internal lastVerseId;
    uint256 internal lastAmountInUAsset;
    address internal lastUser;

    constructor(address uAsset_) {
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256 verseId, uint256 amountInUAsset, address user) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert MockGenesisLauncher.GenesisTransferFailed();
        }
        lastVerseId = verseId;
        lastAmountInUAsset = amountInUAsset;
        lastUser = user;
    }

    function preorder(uint256, uint256, address) external pure override {
        revert PreorderLauncherReverted();
    }

    function getUAssetByVerseId(uint256) external view override returns (address) {
        return address(uAsset);
    }

    function snapshot() external view returns (uint256 verseId, uint256 amountInUAsset, address user) {
        return (lastVerseId, lastAmountInUAsset, lastUser);
    }
}

/**
 * @title MockPOLend
 * @notice Mock POLend leveraged-genesis market: quotes borrowed debt at a fixed rate and pulls
 *         the interest from the payer.
 * @dev Partial mock: models only the POLend seams the router's leveraged-genesis entries depend
 *      on — the marketUAsset binding read, the exact interest pull via transferFrom, the
 *      user-keyed interest ledger, the last-call interest record (interestSnapshot), the
 *      borrowedAmount quote at a fixed rate, and the credit-funded leg's cached-token pull.
 *      Does not model market states, debt caps, launcher reads, or settlement.
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
    // Last-call record of the uAsset interest leg, mirroring the credit face's snapshot seam.
    uint256 internal lastInterestVerseId;
    uint256 internal lastInterestAmount;
    address internal lastInterestUser;

    address internal creditFactory_;
    address internal creditToken_;
    uint256 internal lastCreditVerseId;
    uint256 internal lastCreditAmount;
    address internal lastCreditUser;

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

    function setCreditWiring(address factory_, address cachedCreditToken_) external {
        creditFactory_ = factory_;
        creditToken_ = cachedCreditToken_;
    }

    function creditFactory() external view returns (address) {
        return creditFactory_;
    }

    function leveragedGenesis(uint256 verseId, uint256 interestAmount, address user)
        external
        returns (uint256 borrowedAmount)
    {
        require(interestAmount != 0 && user != address(0), "zero input");
        borrowedAmount = interestAmount.mulDiv(1e18, interestRate);
        leveragedInterestPaid[verseId][user] += interestAmount;
        (lastPayer, lastUser) = (msg.sender, user);
        lastInterestVerseId = verseId;
        lastInterestAmount = interestAmount;
        lastInterestUser = user;
        IERC20(uAsset).transferFrom(msg.sender, address(this), pullHalf ? interestAmount / 2 : interestAmount);
    }

    function interestSnapshot() external view returns (uint256, uint256, address) {
        return (lastInterestVerseId, lastInterestAmount, lastInterestUser);
    }

    function leveragedGenesisWithCredit(uint256 verseId, uint256 creditAmount, address user)
        external
        returns (uint256 borrowedAmount)
    {
        // The hot path pulls the cached token, mirroring real POLend's market.creditToken cache semantics.
        IERC20(creditToken_).transferFrom(msg.sender, address(this), creditAmount);
        lastCreditVerseId = verseId;
        lastCreditAmount = creditAmount;
        lastCreditUser = user;
        borrowedAmount = creditAmount;
    }

    function creditSnapshot() external view returns (uint256, uint256, address) {
        return (lastCreditVerseId, lastCreditAmount, lastCreditUser);
    }
}

/**
 * @title MockCreditRegistry
 * @notice Mock GenesisCreditRegistry returning one fixed credit token for every uAsset family.
 * @dev Minimal stand-in for the router's credit-token resolution leg (`creditOf`); no CREATE3
 *      derivation is modeled.
 */
contract MockCreditRegistry {
    address internal credit;

    constructor(address c) {
        credit = c;
    }

    function creditOf(address) external view returns (address) {
        return credit;
    }
}
