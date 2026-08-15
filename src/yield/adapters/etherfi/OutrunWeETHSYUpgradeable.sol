// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {IWeETH} from "../../../integrations/etherfi/interfaces/IWeETH.sol";
import {ILiquidityPool} from "../../../integrations/etherfi/interfaces/ILiquidityPool.sol";
import {IDepositAdapter} from "../../../integrations/etherfi/interfaces/IDepositAdapter.sol";

/// @title Outrun EtherFi weETH SY adapter
/// @notice SY adapter for EtherFi weETH. The yield-bearing token is weETH (wrapped eETH). Deposit paths:
///      (a) native ETH → DepositAdapter → weETH,
///      (b) eETH → wrap to weETH,
///      (c) existing weETH directly.
///      Exchange rate comes from LiquidityPool.amountForShare.
contract OutrunWeETHSYUpgradeable layout at erc7201("outrun.storage.OutrunWeETHSY") is SYBaseUpgradeable {
    struct OutrunWeETHSYStorage {
        address EETH;
        address DEPOSIT_ADAPTER;
        address LIQUIDITY_POOL;
    }
    OutrunWeETHSYStorage private outrunWeETHSYStorage;

    /// @param owner_ initial owner of the SY contract
    /// @param eETH_ EtherFi eETH token address
    /// @param weETH_ EtherFi weETH token address (yield-bearing token for this SY)
    /// @param depositAdapter_ EtherFi DepositAdapter for ETH to weETH conversion
    /// @param liquidityPool_ EtherFi LiquidityPool address
    function initialize(address owner_, address eETH_, address weETH_, address depositAdapter_, address liquidityPool_)
        external
        initializer
    {
        if (eETH_ == address(0) || depositAdapter_ == address(0) || liquidityPool_ == address(0)) {
            revert SYZeroAddress();
        }
        __SYBase_init("SY Etherfi weETH", "SY weETH", weETH_, owner_);
        outrunWeETHSYStorage.EETH = eETH_;
        outrunWeETHSYStorage.DEPOSIT_ADAPTER = depositAdapter_;
        outrunWeETHSYStorage.LIQUIDITY_POOL = liquidityPool_;
    }

    /// @notice The EtherFi eETH token address
    /// @return address of the eETH ERC20 token
    function EETH() public view returns (address) {
        return outrunWeETHSYStorage.EETH;
    }

    /// @notice EtherFi DepositAdapter for ETH to weETH conversion
    /// @return address of the DepositAdapter contract
    function DEPOSIT_ADAPTER() public view returns (address) {
        return outrunWeETHSYStorage.DEPOSIT_ADAPTER;
    }

    /// @notice EtherFi LiquidityPool used for exchange rate queries
    /// @return address of the LiquidityPool contract
    function LIQUIDITY_POOL() public view returns (address) {
        return outrunWeETHSYStorage.LIQUIDITY_POOL;
    }

    /// @param tokenIn the asset being deposited (NATIVE, eETH, or weETH)
    /// @param amountDeposited amount of tokenIn to deposit
    /// @return amountSharesOut amount of weETH shares credited (minted 1:1 as SY shares; 1 SY = 1 weETH)
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == NATIVE) {
            // Route native ETH through EtherFi's DepositAdapter which handles staking and mints weETH.
            amountSharesOut = IDepositAdapter(DEPOSIT_ADAPTER()).depositETHForWeETH{value: amountDeposited}(address(0));
        } else if (tokenIn == EETH()) {
            // Wrap existing eETH into weETH via the weETH contract.
            address _yieldBearingToken = yieldBearingToken();
            _safeApproveInf(EETH(), _yieldBearingToken);
            amountSharesOut = IWeETH(_yieldBearingToken).wrap(amountDeposited);
        } else {
            // Already in weETH form, 1:1 deposit.
            amountSharesOut = amountDeposited;
        }
    }

    /// @param receiver address to receive the redeemed tokens
    /// @param tokenOut the asset to redeem (eETH or weETH)
    /// @param amountSharesToRedeem amount of weETH shares to redeem (1 SY = 1 weETH)
    /// @return amountTokenOut amount of tokenOut received
    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        // Redeem to eETH (unwrap weETH) or transfer weETH directly.
        address _EETH = EETH();
        address _yieldBearingToken = yieldBearingToken();
        if (tokenOut == _EETH) {
            amountTokenOut = IWeETH(_yieldBearingToken).unwrap(amountSharesToRedeem);
            _transferOut(_EETH, receiver, amountTokenOut);
        } else {
            amountTokenOut = amountSharesToRedeem;
            _transferOut(_yieldBearingToken, receiver, amountSharesToRedeem);
        }
    }

    /// @notice EtherFi LiquidityPool.amountForShare — the ETH value of one weETH share.
    /// @return res exchange rate in 1e18 precision
    function exchangeRate() public view override returns (uint256 res) {
        return ILiquidityPool(LIQUIDITY_POOL()).amountForShare(1 ether);
    }

    /// @param tokenIn the token being deposited (NATIVE, eETH, or weETH)
    /// @param amountTokenToDeposit amount of tokenIn to deposit
    /// @return amountSharesOut expected weETH shares
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        internal
        view
        override
        returns (uint256 amountSharesOut)
    {
        address _pool = LIQUIDITY_POOL();
        if (tokenIn == NATIVE) {
            // ETH → eETH → weETH conversion.
            // First compute how much eETH the ETH buys, then how much weETH that eETH represents.
            uint256 eETHAmount =
                ILiquidityPool(_pool).amountForShare(ILiquidityPool(_pool).sharesForAmount(amountTokenToDeposit));
            amountSharesOut = ILiquidityPool(_pool).sharesForAmount(eETHAmount);
        } else if (tokenIn == EETH()) {
            amountSharesOut = ILiquidityPool(_pool).sharesForAmount(amountTokenToDeposit);
        } else {
            amountSharesOut = amountTokenToDeposit;
        }
    }

    /// @notice Preview the amount received for a given share redemption.
    /// @param tokenOut the token to redeem to (eETH or weETH)
    /// @param amountSharesToRedeem amount of weETH shares to redeem
    /// @return amountTokenOut expected amount of tokenOut
    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        internal
        view
        override
        returns (uint256 amountTokenOut)
    {
        if (tokenOut == EETH()) {
            amountTokenOut = ILiquidityPool(LIQUIDITY_POOL()).amountForShare(amountSharesToRedeem);
        } else {
            amountTokenOut = amountSharesToRedeem;
        }
    }

    /// @notice Returns the list of tokens accepted for deposit.
    /// @return res array containing NATIVE, eETH, and weETH
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(NATIVE, EETH(), yieldBearingToken());
    }

    /// @notice Returns the list of tokens accepted for redemption.
    /// @return res array containing eETH and weETH
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(EETH(), yieldBearingToken());
    }

    /// @notice Checks whether a given token is a valid input for deposit.
    /// @param token address of the token to check
    /// @return true if token is NATIVE, eETH, or weETH
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == NATIVE || token == EETH() || token == yieldBearingToken();
    }

    /// @notice Checks whether a given token is a valid output for redemption.
    /// @param token address of the token to check
    /// @return true if token is eETH or weETH
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == EETH() || token == yieldBearingToken();
    }

    /// @notice Returns asset metadata: canonical asset is native ETH (NATIVE = address(0) sentinel).
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress NATIVE sentinel (address(0)) — canonical asset is native ETH
    /// @return assetDecimals always 18
    function assetInfo() external pure returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, NATIVE, 18);
    }
}
