// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUAssetReserveBase} from "./MockUAssetReserveBase.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IStandardizedYield} from "../../../src/yield/interfaces/IStandardizedYield.sol";
import {IOutrunStakeManager} from "../../../src/position/interfaces/IOutrunStakeManager.sol";

/**
 * @title MockSY
 * @notice Partial mock SY used in position tests.
 * @dev Partial mock: models deposit/redeem around the underlying token for consumer-level tests.
 *      Does not model exchange-rate-based redeem conversion or a production token surface;
 *      token surfaces are aligned to the underlying token only.
 */
contract MockSY is ERC20, IStandardizedYield {
    address internal immutable underlying;
    uint256 internal rate;
    uint8 internal syDecimals;
    uint8 internal canonicalAssetDecimals;

    constructor(address underlying_) ERC20("Mock SY", "mSY") {
        underlying = underlying_;
        rate = 1e18;
        syDecimals = 18;
        canonicalAssetDecimals = 18;
    }

    function setExchangeRate(uint256 newRate) external {
        rate = newRate;
    }

    function setDecimals(uint8 syDecimals_, uint8 canonicalAssetDecimals_) external {
        syDecimals = syDecimals_;
        canonicalAssetDecimals = canonicalAssetDecimals_;
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return syDecimals;
    }

    function mintShares(address receiver, uint256 amount) external {
        _mint(receiver, amount);
        // Minted test shares need matching backing so redeem exercises a real transfer path.
        MockERC20(underlying).mint(address(this), amount);
    }

    function deposit(address receiver, address, uint256 amountTokenToDeposit, uint256)
        external
        payable
        returns (uint256 amountSharesOut)
    {
        amountSharesOut = amountTokenToDeposit;
        _mint(receiver, amountSharesOut);
    }

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut) {
        if (tokenOut != underlying) {
            revert IStandardizedYield.SYInvalidTokenOut(tokenOut);
        }
        if (amountSharesToRedeem == 0) revert IStandardizedYield.SYZeroRedeem();

        if (burnFromInternalBalance) {
            _burn(address(this), amountSharesToRedeem);
        } else {
            _burn(msg.sender, amountSharesToRedeem);
        }

        amountTokenOut = amountSharesToRedeem;
        MockERC20(tokenOut).transfer(receiver, amountTokenOut);
        if (amountTokenOut < minTokenOut) {
            revert IStandardizedYield.SYInsufficientTokenOut(amountTokenOut, minTokenOut);
        }
    }

    function exchangeRate() external view returns (uint256 res) {
        res = rate;
    }

    function yieldBearingToken() external view returns (address) {
        return underlying;
    }

    function getTokensIn() external view returns (address[] memory res) {
        res = new address[](1);
        res[0] = underlying;
    }

    function getTokensOut() external view returns (address[] memory res) {
        res = new address[](1);
        res[0] = underlying;
    }

    function isValidTokenIn(address token) external view returns (bool) {
        return token == underlying;
    }

    function isValidTokenOut(address token) external view returns (bool) {
        return token == underlying;
    }

    function previewDeposit(address, uint256 amountTokenToDeposit) external pure returns (uint256 amountSharesOut) {
        amountSharesOut = amountTokenToDeposit;
    }

    function previewRedeem(address, uint256 amountSharesToRedeem) external pure returns (uint256 amountTokenOut) {
        amountTokenOut = amountSharesToRedeem;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        assetType = AssetType.TOKEN;
        assetAddress = underlying;
        assetDecimals = canonicalAssetDecimals;
    }
}

/**
 * @title MockERC20
 * @notice Mock ERC20 with a test-only faucet mint, used in position tests.
 * @dev Decimals model: fixed 18 (no decimals override; OpenZeppelin default).
 */
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract MockUAsset is MockUAssetReserveBase {
    // Configurable uAsset decimals so cross-decimals test runs can exercise non-default scaling.
    // Default 18 keeps every existing test unchanged.
    uint8 internal uAssetDecimals = 18;

    IOutrunStakeManager internal positionProbe;
    uint256 internal positionIdProbe;
    uint256 public principalDebtDuringRepay;

    /// @notice Sets the uAsset decimals (cross-decimals invariant runs configure this BEFORE position
    ///         initialization, which freezes the value; default 18 keeps existing tests unchanged).
    function setUAssetDecimals(uint8 decimals_) external {
        uAssetDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return uAssetDecimals;
    }

    function probePositionDuringRepay(IOutrunStakeManager positionProbe_, uint256 positionIdProbe_) external {
        positionProbe = positionProbe_;
        positionIdProbe = positionIdProbe_;
    }

    function _afterRepay(address, uint256) internal override {
        IOutrunStakeManager _positionProbe = positionProbe;
        if (address(_positionProbe) != address(0)) {
            (,, principalDebtDuringRepay,,) = _positionProbe.positions(positionIdProbe);
        }
    }
}

