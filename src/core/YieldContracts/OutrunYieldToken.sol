// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { IYieldToken } from "./interfaces/IYieldToken.sol";
import { Initializable } from "../libraries/Initializable.sol";
import { ReentrancyGuard } from "../libraries/ReentrancyGuard.sol";
import { IOutrunStakeManager } from "../Position/interfaces/IOutrunStakeManager.sol";
import { OutrunERC20, OutrunERC20DualBalance } from "../common/OutrunERC20DualBalance.sol";

abstract contract OutrunYieldToken is 
    IYieldToken, 
    OutrunERC20DualBalance, 
    ReentrancyGuard, 
    Pausable, 
    Initializable, 
    Ownable 
{
    address public SY;
    address public SP;
    address public revenuePool;
    uint256 public protocolFeeRate;

    uint256 public yieldBalance;        // Withdrawable yields balance
    
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _revenuePool,
        uint256 _protocolFeeRate
    ) OutrunERC20(_name, _symbol, _decimals) {
        revenuePool = _revenuePool;
        protocolFeeRate = _protocolFeeRate;
    }

    modifier onlySP() {
        require(msg.sender == SP, PermissionDenied());
        _;
    }

    function initialize(address _SY, address _SP) external override onlyOwner initializer {
        SY = _SY;
        SP = _SP;
    }

    /**
     * @dev Preview available yields
     * @param amountInBurnedYT - The amount of burned YT
     */
    function previewWithdrawYields(uint256 amountInBurnedYT) public view override returns (uint256 amountYieldsOut) {
        uint256 _totalSupply = totalSupply;
        require(amountInBurnedYT <= _totalSupply && _totalSupply > 0, InvalidInput());
        amountYieldsOut = amountInBurnedYT * totalRedeemableYields() / _totalSupply;
    }

    /**
     * @dev Burn YT to withdraw yields
     * @param amountInBurnedYT - The amount of burned YT
     */
    function withdrawYields(uint256 amountInBurnedYT) external override nonReentrant whenNotPaused returns (uint256 amountYieldsOut) {
        require(amountInBurnedYT != 0, ZeroInput());
        uint256 _totalSupply = totalSupply;
        require(amountInBurnedYT <= _totalSupply && _totalSupply > 0, InvalidInput());
        accumulateYields();

        unchecked {
            amountYieldsOut = yieldBalance * amountInBurnedYT / _totalSupply;
            yieldBalance -= amountYieldsOut;
        }

        address msgSender = msg.sender;
        _burn(msgSender, amountInBurnedYT);
        IOutrunStakeManager(SP).transferYields(msgSender, amountYieldsOut);

        emit WithdrawYields(msgSender, amountYieldsOut);
    }

    /**
     * @dev Only positionOptionContract can mint when the user stake native yield token
     * @param account - Address who receive YT 
     * @param amount - The amount of minted YT
     * @param transferable - Is the minted token transferable?
     */
    function mint(address account, uint256 amount, bool transferable) external override whenNotPaused onlySP {
        _mint(account, amount, transferable);
    }

    /**
     * @param _revenuePool - Address of revenue pool
     */
    function setRevenuePool(address _revenuePool) public override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());

        revenuePool = _revenuePool;
        emit SetRevenuePool(_revenuePool);
    }

    /**
     * @param _protocolFeeRate - Protocol fee rate
     */
    function setProtocolFeeRate(uint256 _protocolFeeRate) public override onlyOwner {
        require(_protocolFeeRate <= 1e18, FeeRateOverflow());

        protocolFeeRate = _protocolFeeRate;
        emit SetProtocolFeeRate(_protocolFeeRate);
    }

    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Total redeemable yields
     */
    function totalRedeemableYields() public view virtual override returns (uint256) {}

    /**
     * @dev Accumulate yields
     */
    function accumulateYields() public virtual override returns (uint256 realTimeYield, int256 increasedYield) {}
}
