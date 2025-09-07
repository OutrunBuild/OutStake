// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { OutrunERC20 } from "../common/OutrunERC20.sol";
import { IYieldToken } from "./interfaces/IYieldToken.sol";
import { Initializable } from "../libraries/Initializable.sol";
import { ReentrancyGuard } from "../libraries/ReentrancyGuard.sol";
import { IOutrunStakeManager } from "../Position/interfaces/IOutrunStakeManager.sol";

/**
 * @dev Outrun Yield Token, non-transferable.
 */
abstract contract OutrunYieldToken is 
    IYieldToken, 
    OutrunERC20, 
    ReentrancyGuard, 
    Pausable, 
    Initializable, 
    Ownable 
{
    address public SY;
    address public SP;
    address public revenuePool;
    uint96 public protocolFeeRate;

    int256 public yieldBalance;        // Withdrawable yields balance
    
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _revenuePool,
        uint96 _protocolFeeRate
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
        int256 _totalRedeemableYields = totalRedeemableYields();
        require(
            _totalSupply > 0 && 
            _totalRedeemableYields > 0 && 
            amountInBurnedYT <= _totalSupply,
            InvalidInput()
        );
        amountYieldsOut = amountInBurnedYT * uint256(_totalRedeemableYields) / _totalSupply;
    }

    /**
     * @dev Burn YT to withdraw yields
     * @param tokenOut - The specific token type of the withdrawed yields
     * @param amountInBurnedYT - The amount of burned YT
     */
    function withdrawYields(
        address tokenOut,
        uint256 amountInBurnedYT
    ) external override nonReentrant whenNotPaused returns (uint256 amountYieldsOut) {
        require(amountInBurnedYT != 0, ZeroInput());
        uint256 _totalSupply = totalSupply;
        require(amountInBurnedYT <= _totalSupply && _totalSupply > 0, InvalidInput());
        accumulateYields();
        require(yieldBalance > 0, InsufficientYields());

        uint256 amountInSY;
        unchecked {
            amountInSY = uint256(yieldBalance) * amountInBurnedYT / _totalSupply;
            yieldBalance -= int256(amountInSY);
        }

        _burn(msg.sender, amountInBurnedYT);
        amountYieldsOut = IOutrunStakeManager(SP).transferYields(tokenOut, msg.sender, amountInSY);

        emit WithdrawYields(msg.sender, tokenOut, amountYieldsOut);
    }

    /**
     * @dev Only SP Contract can mint when the user stake native yield token
     * @param account - Address who receive YT 
     * @param amount - The amount of minted YT
     */
    function mint(address account, uint256 amount) external override whenNotPaused onlySP {
        _mint(account, amount);
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
    function setProtocolFeeRate(uint96 _protocolFeeRate) public override onlyOwner {
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

    function transfer(address /*to*/, uint256 /*value*/) external virtual override returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address /*from*/, address /*to*/, uint256 /*value*/) external virtual override returns (bool) {
        revert NonTransferable();
    }

    function _burn(address account, uint256 value) internal override {
        require(account != address(0), ERC20InvalidSender(address(0)));
        if (msg.sender != account) _spendAllowance(account, msg.sender, value);
        _update(account, address(0), value);
    }

    /**
     * @dev Total redeemable yields
     * @return realTimeYield - The real-time accumulated yield
     */
    function totalRedeemableYields() public view virtual override returns (int256) {}

    /**
     * @dev Accumulate yields
     * @return realTimeYield - The real-time accumulated yield
     * @return increasedYield - The increased yield
     */
    function accumulateYields() public virtual override returns (int256 realTimeYield, int256 increasedYield) {}
}
