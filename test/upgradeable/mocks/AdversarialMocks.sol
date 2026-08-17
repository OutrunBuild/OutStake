// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OutrunStakingPositionUpgradeable} from "../../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../../src/position/interfaces/IOutrunStakeManager.sol";
import {IStandardizedYield} from "../../../src/yield/interfaces/IStandardizedYield.sol";
import {IUniversalAssets} from "../../../src/assets/interfaces/IUniversalAssets.sol";

/**
 * @title MockSYWithRateControl
 * @notice Mock SY that allows rate manipulation for adversarial testing
 * @dev Partial mock: models deposit/redeem around the underlying token for adversarial consumer tests.
 *      Does not model exchange-rate-based redeem conversion or a production token surface;
 *      token surfaces are aligned to the underlying token only.
 */
contract MockSYWithRateControl is ERC20, IStandardizedYield {
    address internal immutable underlying;
    uint256 internal rate;

    constructor(address underlying_) ERC20("Mock SY", "mSY") {
        underlying = underlying_;
        rate = 1e18;
    }

    function setExchangeRate(uint256 newRate) external {
        rate = newRate;
    }

    function mintShares(address receiver, uint256 amount) external {
        _mint(receiver, amount);
        // Minted test shares need matching backing so redeem exercises a real transfer path.
        MockERC20ForAdversarial(underlying).mint(address(this), amount);
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
        MockERC20ForAdversarial(tokenOut).transfer(receiver, amountTokenOut);
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
        assetDecimals = 18;
    }
}

/**
 * @title MockERC20ForAdversarial
 * @notice Simple mock ERC20 for adversarial tests
 */
contract MockERC20ForAdversarial is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/**
 * @title MockUAssetForAdversarial
 * @notice Mock uAsset with mint cap tracking for adversarial tests
 */
contract MockUAssetForAdversarial is ERC20, IUniversalAssets {
    address public immutable owner;

    mapping(address minter => MintingStatus) public mintingStatusTable;

    error OwnableUnauthorizedAccount(address account);

    modifier onlyOwner() {
        require(msg.sender == owner, OwnableUnauthorizedAccount(msg.sender));
        _;
    }

    constructor() ERC20("Mock UAsset", "mUAsset") {
        owner = msg.sender;
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
}

/**
 * @title MaliciousSY
 * @notice Malicious SY that attempts reentrancy attacks on position
 * @dev Partial mock: models deposit/redeem around the underlying token for adversarial consumer tests.
 *      Does not model exchange-rate-based redeem conversion or a production token surface;
 *      token surfaces are aligned to the underlying token only.
 */
contract MaliciousSY is ERC20, IStandardizedYield {
    address internal immutable underlying;
    uint256 internal rate;
    OutrunStakingPositionUpgradeable internal targetPosition;
    bytes4 internal attackSelector;
    bool private lastAttackSuccess;
    bytes private lastAttackRevertData;

    constructor(address underlying_) ERC20("Malicious SY", "malSY") {
        underlying = underlying_;
        rate = 1e18;
    }

    function setExchangeRate(uint256 newRate) external {
        rate = newRate;
    }

    function setAttackTarget(OutrunStakingPositionUpgradeable position, bytes4 selector) external {
        targetPosition = position;
        attackSelector = selector;
    }

    function attackResult() external view returns (bool success, bytes memory revertData) {
        return (lastAttackSuccess, lastAttackRevertData);
    }

    function mintShares(address receiver, uint256 amount) external {
        _mint(receiver, amount);
        // Minted test shares need matching backing so redeem exercises a real transfer path.
        MockERC20ForAdversarial(underlying).mint(address(this), amount);
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
        MockERC20ForAdversarial(tokenOut).transfer(receiver, amountTokenOut);

        // Attempt malicious reentrancy
        if (address(targetPosition) != address(0) && attackSelector != bytes4(0)) {
            // Try to call stake during redeem callback
            if (attackSelector == IOutrunStakeManager.stake.selector) {
                // solhint-disable-next-line avoid-low-level-calls
                // Record the result so the test can distinguish the guard from downstream failures.
                (bool success, bytes memory revertData) = address(targetPosition)
                    .call(abi.encodeWithSelector(attackSelector, 1e18, uint128(30), receiver, receiver));
                lastAttackSuccess = success;
                lastAttackRevertData = revertData;
            }
            // Try to call drawUAsset during redeem callback
            else if (attackSelector == IOutrunStakeManager.drawUAsset.selector) {
                // Need a valid positionId - try with 1
                // Record the result so adversarial tests can inspect the callback outcome.
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, bytes memory revertData) =
                    address(targetPosition).call(abi.encodeWithSelector(attackSelector, uint256(1), receiver));
                lastAttackSuccess = success;
                lastAttackRevertData = revertData;
            }
        }
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
        assetDecimals = 18;
    }
}
