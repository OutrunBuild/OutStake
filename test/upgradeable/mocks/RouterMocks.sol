// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStandardizedYield} from "../../../src/yield/interfaces/IStandardizedYield.sol";
import {IUniversalAssets} from "../../../src/assets/interfaces/IUniversalAssets.sol";

/**
 * @title RouterMockSY
 * @notice Mock Standardized Yield token used in router tests.
 * @dev Partial mock: models deposit pull/minSharesOut and redeem burn/transfer/minTokenOut for
 *      consumer-level router tests. Does not model exchange-rate-based redeem conversion or a
 *      production token surface; token surfaces are aligned to the underlying token only.
 */
contract RouterMockSY is ERC20, IStandardizedYield {
    error RouterDepositTransferFailed();
    error RouterInsufficientSharesOut(uint256 actual, uint256 minimum);

    address internal immutable underlying;
    uint256 internal rate;
    uint256 internal depositRate;
    address internal lastDepositTokenIn;
    uint256 internal lastDepositAmount;
    uint256 internal lastDepositValue;
    uint256 internal zeroApproveCount;

    constructor(address underlying_) ERC20("Mock SY", "mSY") {
        underlying = underlying_;
        rate = 1e18;
        depositRate = 1e18;
    }

    function setExchangeRate(uint256 newRate) external {
        rate = newRate;
    }

    /// @notice Sets the token-to-SY conversion used by deposit and previewDeposit.
    /// @dev Kept separate from exchangeRate, which models the SY-to-uAsset conversion in the position mock.
    function setDepositRate(uint256 newRate) external {
        depositRate = newRate;
    }

    function mintShares(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function approve(address spender, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (amount == 0) {
            zeroApproveCount += 1;
        }
        return super.approve(spender, amount);
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

    function _convertDepositAmount(address tokenIn, uint256 amountTokenToDeposit)
        internal
        view
        returns (uint256 amountSharesOut)
    {
        if (tokenIn == address(this)) return amountTokenToDeposit;
        if (depositRate == 1e18) return amountTokenToDeposit;
        amountSharesOut = amountTokenToDeposit * depositRate / 1e18;
    }

    function lastDeposit() external view returns (address tokenIn, uint256 amount, uint256 value) {
        return (lastDepositTokenIn, lastDepositAmount, lastDepositValue);
    }

    function getZeroApproveCount() external view returns (uint256 count) {
        return zeroApproveCount;
    }

    function resetZeroApproveCount() external {
        zeroApproveCount = 0;
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
 * @dev Tracks zero-approve calls for allowance-clearing verification.
 */
contract RouterMockERC20 is ERC20 {
    uint256 internal zeroApproveCount;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount == 0) {
            zeroApproveCount += 1;
        }
        return super.approve(spender, amount);
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function getZeroApproveCount() external view returns (uint256 count) {
        return zeroApproveCount;
    }

    function resetZeroApproveCount() external {
        zeroApproveCount = 0;
    }
}

/**
 * @title RouterMockUAsset
 * @notice Mock Universal Asset token used in router tests.
 * @dev Implements minting cap and repayment logic with owner-only admin functions.
 */
contract RouterMockUAsset is ERC20, IUniversalAssets {
    address public immutable owner;
    uint256 internal zeroApproveCount;

    mapping(address minter => MintingStatus) public mintingStatusTable;

    error OwnableUnauthorizedAccount(address account);

    modifier onlyOwner() {
        require(msg.sender == owner, OwnableUnauthorizedAccount(msg.sender));
        _;
    }

    constructor() ERC20("Mock UAsset", "mUAsset") {
        owner = msg.sender;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount == 0) {
            zeroApproveCount += 1;
        }
        return super.approve(spender, amount);
    }

    function checkMintableAmount(address minter) external view returns (uint256 amountInMintable) {
        MintingStatus storage status = mintingStatusTable[minter];
        amountInMintable = status.mintingCap > status.amountInMinted ? status.mintingCap - status.amountInMinted : 0;
    }

    function setMintingCap(address minter, uint256 mintingCap) public onlyOwner {
        require(minter != address(0), ZeroInput());
        mintingStatusTable[minter].mintingCap = mintingCap;
    }

    function revokeMinter(address minter) external onlyOwner {
        require(minter != address(0), ZeroInput());
        mintingStatusTable[minter].mintingCap = 0;
    }

    function transferMinterDebt(address from, address to, uint256 amount) external onlyOwner {
        require(from != address(0) && to != address(0) && from != to && amount != 0, ZeroInput());

        MintingStatus storage fromStatus = mintingStatusTable[from];
        require(fromStatus.amountInMinted >= amount, ReachBurnCap());

        MintingStatus storage toStatus = mintingStatusTable[to];
        require(toStatus.mintingCap >= toStatus.amountInMinted, ReachMintCap());
        require(amount <= toStatus.mintingCap - toStatus.amountInMinted, ReachMintCap());

        fromStatus.amountInMinted -= amount;
        toStatus.amountInMinted += amount;
    }

    function mint(address receiver, uint256 amount) external {
        MintingStatus storage status = mintingStatusTable[msg.sender];
        require(status.amountInMinted + amount <= status.mintingCap, ReachMintCap());
        status.amountInMinted += amount;
        _mint(receiver, amount);
    }

    function repay(address account, uint256 amount) external {
        MintingStatus storage status = mintingStatusTable[msg.sender];
        require(status.amountInMinted >= amount, ReachBurnCap());
        _spendAllowance(account, msg.sender, amount);
        status.amountInMinted -= amount;
        _burn(account, amount);
    }

    function getZeroApproveCount() external view returns (uint256 count) {
        return zeroApproveCount;
    }

    function resetZeroApproveCount() external {
        zeroApproveCount = 0;
    }
}

/**
 * @title RouterMockLauncher
 * @notice Mock Memeverse launcher used in router tests.
 * @dev Records the last genesis call parameters for test assertions.
 */
contract RouterMockLauncher {
    error RouterGenesisTransferFailed();

    RouterMockUAsset internal immutable uAsset;
    uint256 internal lastVerseId;
    uint128 internal lastAmountInUAsset;
    address internal lastUser;

    constructor(address uAsset_) {
        uAsset = RouterMockUAsset(uAsset_);
    }

    function genesis(uint256 verseId, uint128 amountInUAsset, address user) external {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) revert RouterGenesisTransferFailed();
        lastVerseId = verseId;
        lastAmountInUAsset = amountInUAsset;
        lastUser = user;
    }

    function snapshot() external view returns (uint256 verseId, uint128 amountInUAsset, address user) {
        return (lastVerseId, lastAmountInUAsset, lastUser);
    }
}
