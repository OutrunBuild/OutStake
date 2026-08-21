// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAToken} from "../../../integrations/aave/interfaces/IAToken.sol";
import {IAaveV3Pool} from "../../../integrations/aave/interfaces/IAaveV3Pool.sol";
import {ArrayLib} from "../../../libraries/ArrayLib.sol";
import {AaveAdapterLib} from "../../../libraries/AaveAdapterLib.sol";
import {SYBaseUpgradeable} from "../../SYBaseUpgradeable.sol";

/// @title Outrun Aave V3 SY adapter
/// @notice SY adapter for Aave V3. The yield-bearing token is the aToken (e.g., aUSDC). Deposit paths:
///      (a) deposit the underlying asset into Aave to receive aToken shares,
///      (b) deposit existing aToken directly as SY.
///      Exchange rate uses Aave's liquidity index (ray-scaled) divided by 1e9 to get the 1e18-scaled rate.
contract OutrunAaveV3SYUpgradeable layout at erc7201("outrun.storage.OutrunAaveV3SY") is SYBaseUpgradeable {
    struct OutrunAaveV3SYStorage {
        address underlying;
        address aavePool;
    }
    OutrunAaveV3SYStorage private outrunAaveV3SYStorage;

    error AaveZeroShares();

    /// @param name_ SY token name
    /// @param symbol_ SY token symbol
    /// @param aToken_ Aave aToken address (yield-bearing token for this SY)
    /// @param aavePool_ Aave V3 pool address
    /// @param owner_ initial owner of the SY contract
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address aToken_,
        address aavePool_,
        address owner_
    ) external initializer {
        if (aavePool_ == address(0)) revert SYZeroAddress();
        __SYBase_init(name_, symbol_, aToken_, owner_);
        outrunAaveV3SYStorage.underlying = IAToken(aToken_).UNDERLYING_ASSET_ADDRESS();
        outrunAaveV3SYStorage.aavePool = aavePool_;
    }

    /// @notice The underlying asset that this SY represents (e.g., USDC for aUSDC)
    /// @return address of the underlying ERC20 token
    function underlying() public view returns (address) {
        return outrunAaveV3SYStorage.underlying;
    }

    /// @notice The Aave V3 pool used for supply/withdraw operations
    /// @return address of the Aave V3 pool contract
    function aavePool() public view returns (address) {
        return outrunAaveV3SYStorage.aavePool;
    }

    /// @notice Deposit: supply underlying to Aave or wrap aToken.
    /// @param tokenIn the asset being deposited (underlying or aToken)
    /// @param amountDeposited amount of tokenIn to deposit
    /// @return amountSharesOut scaled shares credited (minted 1:1 as SY shares; 1 SY = 1 scaled share)
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        address _underlying = underlying();
        address _pool = aavePool();
        if (tokenIn == _underlying) {
            // Supply the underlying asset to Aave pool.
            // Track scaled balance before/after because aToken balance changes with the liquidity index.
            IAToken aToken = IAToken(yieldBearingToken());
            uint256 scaledBefore = aToken.scaledBalanceOf(address(this));
            _safeApproveInf(_underlying, _pool);
            IAaveV3Pool(_pool).supply(_underlying, amountDeposited, address(this), 0);
            amountSharesOut = aToken.scaledBalanceOf(address(this)) - scaledBefore;
        } else {
            // Deposit aToken directly — convert to scaled shares using current liquidity index.
            amountSharesOut =
                AaveAdapterLib.calcSharesFromAssetHalfUp(amountDeposited, _getNormalizedIncome(_underlying, _pool));
        }
        if (amountSharesOut == 0) revert AaveZeroShares();
    }

    /// @notice Redeem SY shares to the requested output token.
    /// @dev F3 (P1) 流动性依赖说明: 当 `tokenOut == underlying` 时本路径经 `IAaveV3Pool.withdraw` 兑付为底层资产,
    ///      依赖 Aave 储备可用流动性; 高利用率、储备 pause/freeze 或流动性不足时会 fail-closed revert 直至恢复.
    ///      `tokenOut == yieldBearingToken()` (aToken) 分支为流动性无关的直转逃生门 (`_transferOut`), 恒可用.
    ///      上层 `OutrunStakingPositionUpgradeable.redeem` 若指定 `tokenOut==underlying` 同步继承该外部依赖;
    ///      `keepRedeem`/`keepWrapRedeem` 固定以 SY (aToken) 结算, 不经 `withdraw`, 不受该依赖影响.
    ///      运维/集成建议: 储备级登记流动性与暂停监控 (利用率阈值告警), position 兑付优先请求 YBT, 仅最终结算时经 Router 二次 `SY.redeem(..., underlying)` 退出底层.
    /// @param receiver address to receive the redeemed tokens
    /// @param tokenOut the asset being redeemed (underlying or aToken)
    /// @param amountSharesToRedeem scaled shares to redeem (1 SY = 1 scaled share)
    /// @return amountTokenOut amount of tokenOut received
    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        address _underlying = underlying();
        address _pool = aavePool();
        // Convert scaled shares back to asset amount using current liquidity index,
        // then either withdraw from Aave (if redeeming to underlying)
        // or transfer aToken directly (if redeeming to aToken).
        amountTokenOut =
            AaveAdapterLib.calcSharesToAssetDown(amountSharesToRedeem, _getNormalizedIncome(_underlying, _pool));
        if (tokenOut == _underlying) {
            amountTokenOut = IAaveV3Pool(_pool).withdraw(_underlying, amountTokenOut, receiver);
        } else {
            // SYBaseUpgradeable.redeem already validated tokenOut via isValidTokenOut, so
            // this branch implies tokenOut == yieldBearingToken().
            _transferOut(tokenOut, receiver, amountTokenOut);
        }
    }

    /// @notice Aave liquidity index / 1e9 = canonical asset per SY.
    /// Aave's liquidity index is ray-scaled (1e27).
    /// Divide by 1e9 to get the standard 1e18-scaled exchange rate.
    /// @return exchange rate in 1e18 precision
    function exchangeRate() public view override returns (uint256) {
        address _underlying = underlying();
        address _pool = aavePool();
        return _getNormalizedIncome(_underlying, _pool) / 1e9;
    }

    /// @notice Preview the scaled shares received for a given deposit.
    /// @param amountTokenToDeposit amount of token to deposit
    /// @return amountSharesOut expected scaled shares
    function _previewDeposit(address, uint256 amountTokenToDeposit) internal view override returns (uint256) {
        address _underlying = underlying();
        address _pool = aavePool();
        return AaveAdapterLib.calcSharesFromAssetHalfUp(amountTokenToDeposit, _getNormalizedIncome(_underlying, _pool));
    }

    /// @notice Preview the asset amount received for a given share redemption.
    /// @param amountSharesToRedeem scaled shares to redeem
    /// @return amountTokenOut expected asset amount
    function _previewRedeem(address, uint256 amountSharesToRedeem) internal view override returns (uint256) {
        address _underlying = underlying();
        address _pool = aavePool();
        return AaveAdapterLib.calcSharesToAssetDown(amountSharesToRedeem, _getNormalizedIncome(_underlying, _pool));
    }

    /// @notice Queries the Aave pool for the current liquidity index of the underlying reserve.
    /// @param _underlying the underlying reserve asset whose liquidity index is queried
    /// @param _pool the Aave V3 pool contract holding the reserve
    /// @return the normalized income (liquidity index) in ray (1e27) precision
    function _getNormalizedIncome(address _underlying, address _pool) internal view returns (uint256) {
        return IAaveV3Pool(_pool).getReserveNormalizedIncome(_underlying);
    }

    /// @notice Returns the list of tokens accepted for deposit.
    /// @return res array containing the underlying asset and the yield-bearing aToken
    function getTokensIn() public view override returns (address[] memory res) {
        return ArrayLib.create(underlying(), yieldBearingToken());
    }

    /// @notice Returns the list of tokens accepted for redemption.
    /// @return res array containing the underlying asset and the yield-bearing aToken
    function getTokensOut() public view override returns (address[] memory res) {
        return ArrayLib.create(underlying(), yieldBearingToken());
    }

    /// @notice Checks whether a given token is a valid input for deposit.
    /// @param token address of the token to check
    /// @return true if token is the underlying asset or the yield-bearing aToken
    function isValidTokenIn(address token) public view override returns (bool) {
        return token == underlying() || token == yieldBearingToken();
    }

    /// @notice Checks whether a given token is a valid output for redemption.
    /// @param token address of the token to check
    /// @return true if token is the underlying asset or the yield-bearing aToken
    function isValidTokenOut(address token) public view override returns (bool) {
        return token == underlying() || token == yieldBearingToken();
    }

    /// @notice Returns asset metadata: type, address, and decimals of the underlying token.
    /// @return assetType always TOKEN for this adapter
    /// @return assetAddress address of the underlying asset
    /// @return assetDecimals decimals of the underlying asset
    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        address _underlying = underlying();
        return (AssetType.TOKEN, _underlying, IERC20Metadata(_underlying).decimals());
    }
}
