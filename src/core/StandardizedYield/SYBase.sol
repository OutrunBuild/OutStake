// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ArrayLib } from "../libraries/ArrayLib.sol";
import { TokenHelper } from "../libraries/TokenHelper.sol";
import { IStandardizedYield } from "./IStandardizedYield.sol";
import { OutrunERC20, IERC20Metadata } from "../common/OutrunERC20.sol";
import { OutrunERC20Pausable } from "../common/OutrunERC20Pausable.sol";

/**
 * @dev Standardized Yield Base Contract
 */
abstract contract SYBase is IStandardizedYield, OutrunERC20Pausable, TokenHelper {
    address public immutable yieldBearingToken;

    constructor(
        string memory name_,
        string memory symbol_,
        address _yieldBearingToken,
        address _owner
    ) OutrunERC20(name_, symbol_, IERC20Metadata(_yieldBearingToken).decimals()) Ownable(_owner) {
        require(_yieldBearingToken != address(0), SYZeroAddress());
        
        yieldBearingToken = _yieldBearingToken;
    }

    receive() external payable {}

    /*///////////////////////////////////////////////////////////////
                DEPOSIT/REDEEM USING NATIVE YIELD TOKENS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IStandardizedYield-deposit}
     */
    function deposit(
        address receiver,
        address tokenIn,
        uint256 amountTokenToDeposit,
        uint256 minSharesOut
    ) external payable nonReentrant whenNotPaused returns (uint256 amountSharesOut) {
        require(isValidTokenIn(tokenIn), SYInvalidTokenIn(tokenIn));
        require(amountTokenToDeposit != 0, SYZeroDeposit());

        _transferIn(tokenIn, msg.sender, amountTokenToDeposit);

        amountSharesOut = _deposit(tokenIn, amountTokenToDeposit);
        require(amountSharesOut >= minSharesOut, SYInsufficientSharesOut(amountSharesOut, minSharesOut));

        _mint(receiver, amountSharesOut);
        emit Deposit(msg.sender, receiver, tokenIn, amountTokenToDeposit, amountSharesOut);
    }

    /**
     * @dev See {IStandardizedYield-redeem}
     */
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external nonReentrant whenNotPaused returns (uint256 amountTokenOut) {
        require(isValidTokenOut(tokenOut), SYInvalidTokenOut(tokenOut));
        require(amountSharesToRedeem != 0, SYZeroRedeem());
        amountTokenOut = _redeem(receiver, tokenOut, amountSharesToRedeem);

        if (burnFromInternalBalance) {
            _burn(address(this), amountSharesToRedeem);
        } else {
            _burn(msg.sender, amountSharesToRedeem);
        }
        
        require(amountTokenOut >= minTokenOut, SYInsufficientTokenOut(amountTokenOut, minTokenOut));

        emit Redeem(msg.sender, receiver, tokenOut, amountSharesToRedeem, amountTokenOut);
    }

    /**
     * @notice mint shares based on the deposited base tokens
     * @param tokenIn base token address used to mint shares
     * @param amountDeposited amount of base tokens deposited
     * @return amountSharesOut amount of shares minted
     */
    function _deposit(address tokenIn, uint256 amountDeposited) internal virtual returns (uint256 amountSharesOut);

    /**
     * @notice redeems base tokens based on amount of shares to be burned
     * @param tokenOut address of the base token to be redeemed
     * @param amountSharesToRedeem amount of shares to be burned
     * @return amountTokenOut amount of base tokens redeemed
     */
    function _redeem(
        address receiver,
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal virtual returns (uint256 amountTokenOut);

    /*///////////////////////////////////////////////////////////////
                               EXCHANGE-RATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IStandardizedYield-exchangeRate}
     */
    function exchangeRate() external view virtual override returns (uint256 res);

    /*///////////////////////////////////////////////////////////////
                            REWARDS-RELATED
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IStandardizedYield-claimRewards}
     */
    function claimRewards(address /*user*/) external virtual override returns (uint256[] memory rewardAmounts) {
        rewardAmounts = new uint256[](0);
    }

    /**
     * @dev See {IStandardizedYield-getRewardTokens}
     */
    function getRewardTokens() external view virtual override returns (address[] memory rewardTokens) {
        rewardTokens = new address[](0);
    }

    /**
     * @dev See {IStandardizedYield-accruedRewards}
     */
    function accruedRewards(address /*user*/) external view virtual override returns (uint256[] memory rewardAmounts) {
        rewardAmounts = new uint256[](0);
    }

    function rewardIndexesCurrent() external virtual override returns (uint256[] memory indexes) {
        indexes = new uint256[](0);
    }

    function rewardIndexesStored() external view virtual override returns (uint256[] memory indexes) {
        indexes = new uint256[](0);
    }

    /*///////////////////////////////////////////////////////////////
                MISC METADATA FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) external view virtual returns (uint256 amountSharesOut) {
        require(isValidTokenIn(tokenIn), SYInvalidTokenIn(tokenIn));
        return _previewDeposit(tokenIn, amountTokenToDeposit);
    }

    function previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) external view virtual returns (uint256 amountTokenOut) {
        require(isValidTokenOut(tokenOut), SYInvalidTokenOut(tokenOut));
        return _previewRedeem(tokenOut, amountSharesToRedeem);
    }

    function _beforeTokenTransfer(address from, address to, uint256 value) internal virtual override {}

    function _previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) internal view virtual returns (uint256 amountSharesOut);

    function _previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) internal view virtual returns (uint256 amountTokenOut);

    function getTokensIn() public view virtual returns (address[] memory res);

    function getTokensOut() public view virtual returns (address[] memory res);

    function isValidTokenIn(address token) public view virtual returns (bool);

    function isValidTokenOut(address token) public view virtual returns (bool);
}