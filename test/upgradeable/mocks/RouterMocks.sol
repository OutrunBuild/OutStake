// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUAssetReserveBase} from "./MockUAssetReserveBase.sol";
import {IStandardizedYield} from "../../../src/yield/interfaces/IStandardizedYield.sol";

/**
 * @title RouterMockSY
 * @notice Mock Standardized Yield token used in router tests.
 * @dev Partial mock: models deposit pull/minSharesOut and redeem burn/transfer/minTokenOut for
 *      consumer-level router tests. Does not model exchange-rate-based redeem conversion or a
 *      production token surface; token surfaces are aligned to the underlying token only.
 *      Decimals model: fixed 18 (assetDecimals hard-coded, no setDecimals);
 *      use MockSY in PositionTestMocks for configurable-decimals runs.
 */
contract RouterMockSY is ERC20, IStandardizedYield {
    error RouterDepositTransferFailed();
    error RouterInsufficientSharesOut(uint256 actual, uint256 minimum);

    address internal immutable underlying;
    // 1e18 identity rate for the exchangeRate() seam read by the position stack.
    uint256 internal constant RATE = 1e18;
    address internal lastDepositTokenIn;
    uint256 internal lastDepositAmount;
    uint256 internal lastDepositValue;

    constructor(address underlying_) ERC20("Mock SY", "mSY") {
        underlying = underlying_;
    }

    function mintShares(address receiver, uint256 amount) external {
        _mint(receiver, amount);
        // Minted test shares need matching backing so redeem exercises a real transfer path.
        RouterMockERC20(underlying).mint(address(this), amount);
    }

    function deposit(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        returns (uint256 amountSharesOut)
    {
        lastDepositTokenIn = tokenIn;
        lastDepositAmount = amountTokenToDeposit;
        lastDepositValue = msg.value;
        if (msg.value == 0) {
            if (!RouterMockERC20(underlying).transferFrom(msg.sender, address(this), amountTokenToDeposit)) {
                revert RouterDepositTransferFailed();
            }
        }
        amountSharesOut = _convertDepositAmount(tokenIn, amountTokenToDeposit);
        if (amountSharesOut < minSharesOut) revert RouterInsufficientSharesOut(amountSharesOut, minSharesOut);
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
        RouterMockERC20(tokenOut).transfer(receiver, amountTokenOut);
        if (amountTokenOut < minTokenOut) {
            revert IStandardizedYield.SYInsufficientTokenOut(amountTokenOut, minTokenOut);
        }
    }

    function exchangeRate() external view returns (uint256 res) {
        res = RATE;
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

    function previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        external
        view
        returns (uint256 amountSharesOut)
    {
        amountSharesOut = _convertDepositAmount(tokenIn, amountTokenToDeposit);
    }

    function previewRedeem(address, uint256 amountSharesToRedeem) external pure returns (uint256 amountTokenOut) {
        amountTokenOut = amountSharesToRedeem;
    }

    function _convertDepositAmount(address, uint256 amountTokenToDeposit)
        internal
        pure
        returns (uint256 amountSharesOut)
    {
        // Identity conversion: the mock mints SY 1:1 with the deposited token amount.
        return amountTokenToDeposit;
    }

    function lastDeposit() external view returns (address tokenIn, uint256 amount, uint256 value) {
        return (lastDepositTokenIn, lastDepositAmount, lastDepositValue);
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        assetType = AssetType.TOKEN;
        assetAddress = underlying;
        assetDecimals = 18;
    }
}

/**
 * @title RouterMockERC20
 * @notice Mock ERC20 token used in router tests.
 * @dev Full mock: standard OpenZeppelin ERC20 semantics plus a test-only faucet mint; no caps, fees,
 *      or deflation behavior.
 *      Decimals model: fixed 18 (no decimals override; OpenZeppelin default).
 */
contract RouterMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/**
 * @title RouterMockUAsset
 * @notice Mock Universal Asset token used in router tests.
 * @dev Implements minting cap and repayment logic with owner-only admin functions. Models the pausable
 *      uAsset seam of the production asset: a test-admin pause switch blocks mint/repay/reserveMint/
 *      reserveBurn and every transfer with EnforcedPause while paused (mirrors the production contract's
 *      whenNotPaused entrypoints and _update guard).
 */
contract RouterMockUAsset is MockUAssetReserveBase {
    bool public paused;

    error EnforcedPause();

    modifier whenNotPaused() {
        require(!paused, EnforcedPause());
        _;
    }

    /// @notice Test-admin pause switch mirroring the production uAsset's owner pause.
    function pause() external onlyOwner {
        paused = true;
    }

    /// @notice Test-admin unpause switch.
    function unpause() external onlyOwner {
        paused = false;
    }

    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }

    function _requireNotPaused() internal view override {
        require(!paused, EnforcedPause());
    }
}
