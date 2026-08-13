// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ArrayLib} from "../../../src/libraries/ArrayLib.sol";
import {IExchangeRateOracle} from "../../../src/libraries/oracle/interfaces/IExchangeRateOracle.sol";
import {SYUtils} from "../../../src/libraries/SYUtils.sol";
import {SYBaseUpgradeable} from "../../../src/yield/SYBaseUpgradeable.sol";

/**
 * @dev Shared behavior for the Memeverse Genesis Test SY mocks that wrap an ERC20
 * (aUSDC / sUSDS) at a 1:1 rate. The concrete mocks differ only in the wrapped token
 * interface they cast to and in their ERC20 name/symbol strings.
 */
abstract contract MockOutrunERC20SYUpgradeableBase is SYBaseUpgradeable {
    /// @custom:storage-location erc7201:outrun.storage.MockOutrunERC20SY
    // forge-lint: disable-next-line(pascal-case-struct)
    struct MockOutrunERC20SYStorage {
        address mockUSDC;
        address oracle;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.MockOutrunERC20SY")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MOCK_OUTRUN_ERC20_SY_STORAGE_LOCATION =
        0xb8c045ff28d8e586a70644dbc8a9d109576a40ef643afb89a77ddc5876c9fe00;

    /// @notice Initializes the shared mock SY state. Called from each concrete mock's initialize.
    function __MockOutrunERC20SY_init(
        address owner_,
        address mockUSDC_,
        address yieldBearingToken_,
        address oracle_,
        string memory name_,
        string memory symbol_
    ) internal onlyInitializing {
        require(mockUSDC_ != address(0) && oracle_ != address(0), SYZeroAddress());
        __SYBase_init(name_, symbol_, yieldBearingToken_, owner_);

        MockOutrunERC20SYStorage storage $ = _getMockOutrunERC20SYStorage();
        $.mockUSDC = mockUSDC_;
        $.oracle = oracle_;
    }

    function _getMockOutrunERC20SYStorage() private pure returns (MockOutrunERC20SYStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := MOCK_OUTRUN_ERC20_SY_STORAGE_LOCATION
        }
    }

    function mockUSDC() public view returns (address) {
        return _getMockOutrunERC20SYStorage().mockUSDC;
    }

    function oracle() public view returns (address) {
        return _getMockOutrunERC20SYStorage().oracle;
    }

    // The concrete mocks are identical except for the ERC20 they wrap, so deposit and redeem
    // share one implementation here and delegate only the wrap/unwrap call to the concrete.
    function _deposit(address tokenIn, uint256 amountDeposited) internal override returns (uint256 amountSharesOut) {
        if (tokenIn == mockUSDC()) {
            address ybt = yieldBearingToken();
            _safeApproveInf(tokenIn, ybt);
            return _wrap(ybt, amountDeposited);
        }

        return amountDeposited;
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256 amountTokenOut)
    {
        if (tokenOut == mockUSDC()) {
            amountTokenOut = _unwrap(yieldBearingToken(), amountSharesToRedeem);
            _transferOut(tokenOut, receiver, amountTokenOut);
            return amountTokenOut;
        }

        _transferOut(tokenOut, receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    /// @notice Concrete mock's wrapped-token wrap call (IMockAUSDC.wrap / IMockSUSDS.wrap).
    function _wrap(address ybt, uint256 amount) internal virtual returns (uint256);

    /// @notice Concrete mock's wrapped-token unwrap call (IMockAUSDC.unwrap / IMockSUSDS.unwrap).
    function _unwrap(address ybt, uint256 amount) internal virtual returns (uint256);

    // The rate falls back to 1e18 when the wired oracle reverts or answers zero, so a broken
    // oracle wiring surfaces as a flat rate instead of a revert.
    function exchangeRate() public view override returns (uint256 res) {
        try IExchangeRateOracle(oracle()).getExchangeRate() returns (uint256 rate) {
            if (rate != 0) return rate;
        } catch {}

        return SYUtils.ONE;
    }

    function _previewDeposit(address, uint256 amountTokenToDeposit) internal pure override returns (uint256) {
        return amountTokenToDeposit;
    }

    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory) {
        return ArrayLib.create(mockUSDC(), yieldBearingToken());
    }

    function getTokensOut() public view override returns (address[] memory) {
        return ArrayLib.create(mockUSDC(), yieldBearingToken());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == mockUSDC() || token == yieldBearingToken();
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == mockUSDC() || token == yieldBearingToken();
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, mockUSDC(), 18);
    }
}
