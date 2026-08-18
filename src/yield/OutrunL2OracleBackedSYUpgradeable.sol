// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.35;

import {ArrayLib} from "../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "./SYBaseUpgradeable.sol";
import {IExchangeRateOracle} from "../libraries/oracle/interfaces/IExchangeRateOracle.sol";

/// @title Outrun L2 oracle-backed SY abstract base
/// @notice L2 SY abstract base where the yield-bearing token itself is the SY. Deposit and redeem are 1:1 with
///      the underlying token. The exchange rate comes from a configured oracle because yield accrues on
///      L1/Ethereum mainnet and the L2 token balance does not reflect it.
abstract contract OutrunL2OracleBackedSYUpgradeable is SYBaseUpgradeable {
    // Abstract contracts cannot use the `layout at` syntax (solc error 7587), so this base
    // sets its ERC-7201 location the classic way — same pattern as SYBaseUpgradeable.
    /// @custom:storage-location erc7201:outrun.storage.OutrunL2OracleBackedSY
    // forge-lint: disable-next-line(pascal-case-struct)
    struct OutrunL2OracleBackedSYStorage {
        // Oracle reports the current L1 exchange rate (canonical asset per SY).
        // Needed because the L2 token balance is static — the oracle makes the rate
        // visible for position accounting.
        // Production deployments should choose staleness bounds per the underlying
        // asset's rate source and, where the rate depends on L2 sequencing, enable an
        // L2 sequencer uptime feed with a post-recovery grace period.
        // Example provenance: the Lido cross-chain token guide (basis for the wstETH
        // adapter) says stETH rate data should not be outdated by more than 2 days.
        // https://docs.lido.fi/token-guides/cross-chain-tokens-guide/
        address exchangeRateOracle;
        // The canonical asset lives on Ethereum mainnet (not deployed on this L2); these
        // fields describe it for position accounting and display purposes.
        address underlyingAssetOnEthAddr;
        uint8 underlyingAssetOnEthDecimals;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunL2OracleBackedSY")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_L2_ORACLE_BACKED_SY_STORAGE_LOCATION =
        0x57aa7d79a56b64c6a75a8df5f30e533361d1c41ef1173e8a4529d9a05db56b00;

    function _getOutrunL2OracleBackedSYStorage() private pure returns (OutrunL2OracleBackedSYStorage storage $) {
        assembly {
            $.slot := OUTRUN_L2_ORACLE_BACKED_SY_STORAGE_LOCATION
        }
    }

    event SetExchangeRateOracle(address indexed oldOracle, address indexed newOracle);

    /// @notice Initializes the shared L2 oracle-backed SY state.
    /// This helper is split from the child initialize signatures because each concrete
    /// adapter exposes its own external initializer (the wstETH adapter hardcodes its name
    /// and symbol), while the oracle and underlying-asset wiring is identical for every
    /// adapter in this family, so it lives here once.
    /// @param name_ Token name for the ERC20 representation.
    /// @param symbol_ Token symbol for the ERC20 representation.
    /// @param owner_ Address that will be granted the owner role.
    /// @param token_ The yield-bearing token on L2 (IS the SY — no wrapping needed).
    /// @param exchangeRateOracle_ Oracle that reports the canonical-asset-per-SY exchange rate.
    /// @param underlyingAssetOnEthAddr_ Address of the underlying asset on Ethereum mainnet.
    /// @param underlyingAssetOnEthDecimals_ Decimals of the underlying asset on Ethereum mainnet.
    function __L2OracleBackedSY_init(
        string memory name_,
        string memory symbol_,
        address owner_,
        address token_,
        address exchangeRateOracle_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) internal onlyInitializing {
        if (exchangeRateOracle_ == address(0) || underlyingAssetOnEthAddr_ == address(0)) revert SYZeroAddress();
        __SYBase_init(name_, symbol_, token_, owner_);
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        $.exchangeRateOracle = exchangeRateOracle_;
        $.underlyingAssetOnEthAddr = underlyingAssetOnEthAddr_;
        $.underlyingAssetOnEthDecimals = underlyingAssetOnEthDecimals_;
    }

    /// @notice Returns the address of the exchange rate oracle.
    /// @return The oracle address that reports the canonical-asset-per-SY exchange rate.
    function exchangeRateOracle() public view returns (address) {
        return _getOutrunL2OracleBackedSYStorage().exchangeRateOracle;
    }

    /// @notice Updates the exchange rate oracle address. Owner-only.
    /// @param newOracle The new oracle address. Must not be zero.
    function setExchangeRateOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert SYZeroAddress();
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        address oldOracle = $.exchangeRateOracle;
        $.exchangeRateOracle = newOracle;
        emit SetExchangeRateOracle(oldOracle, newOracle);
    }

    /// @notice Adapter-specific deposit logic — 1:1, the yield-bearing token IS the SY.
    function _deposit(address, uint256 amountDeposited) internal pure virtual override returns (uint256) {
        return amountDeposited;
    }

    /// @notice Adapter-specific redeem logic — transfers the yield-bearing token 1:1 to the receiver.
    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        virtual
        override
        returns (uint256)
    {
        _transferOut(tokenOut, receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    /// @notice Returns the current exchange rate from the oracle (not from token balance).
    /// The L2 token balance does not grow with yield, so the oracle reports the canonical
    /// asset amount per SY as tracked on the source chain.
    /// @return The exchange rate, scaled by 1e18.
    function exchangeRate() public view virtual override returns (uint256) {
        return IExchangeRateOracle(exchangeRateOracle()).getExchangeRate();
    }

    /// @notice Adapter-specific preview of a deposit — returns the input amount (1:1, no wrapping).
    function _previewDeposit(address, uint256 amountTokenToDeposit) internal pure virtual override returns (uint256) {
        return amountTokenToDeposit;
    }

    /// @notice Adapter-specific preview of a redemption — returns the input amount (1:1, no unwrapping).
    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure virtual override returns (uint256) {
        return amountSharesToRedeem;
    }

    /// @notice Returns all tokens accepted for deposit — only the yield-bearing token.
    /// @return res Single-element array containing the yield-bearing token address.
    function getTokensIn() public view virtual override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @notice Returns all tokens accepted for redemption — only the yield-bearing token.
    /// @return res Single-element array containing the yield-bearing token address.
    function getTokensOut() public view virtual override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @notice Checks whether the given token is accepted for deposit.
    /// @param token The token address to check.
    /// @return True if the token equals the yield-bearing token.
    function isValidTokenIn(address token) public view virtual override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @notice Checks whether the given token is accepted for redemption.
    /// @param token The token address to check.
    /// @return True if the token equals the yield-bearing token.
    function isValidTokenOut(address token) public view virtual override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @notice Reports the underlying asset details on Ethereum mainnet (for position accounting).
    /// The canonical asset lives on Ethereum mainnet, not on this L2.
    /// @return assetType Always AssetType.TOKEN.
    /// @return assetAddress Address of the underlying asset on Ethereum mainnet.
    /// @return assetDecimals Decimals of the underlying asset on Ethereum mainnet.
    function assetInfo()
        external
        view
        virtual
        returns (AssetType assetType, address assetAddress, uint8 assetDecimals)
    {
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        return (AssetType.TOKEN, $.underlyingAssetOnEthAddr, $.underlyingAssetOnEthDecimals);
    }
}
