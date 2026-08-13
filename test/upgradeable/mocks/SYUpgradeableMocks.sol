// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SYBaseUpgradeable} from "../../../src/yield/SYBaseUpgradeable.sol";
import {ArrayLib} from "../../../src/libraries/ArrayLib.sol";

/// @dev Simple ERC20 mock for SY upgradeable tests.
contract SYUpgradeableMockToken is ERC20 {
    constructor() ERC20("Yield Token", "YBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev SYBaseUpgradeable harness that exercises deposit/redeem and reentrancy guard.
contract TestSYUpgradeable is SYBaseUpgradeable {
    bool public reentryBlocked;

    function initialize(string memory name_, string memory symbol_, address token_, address owner_)
        external
        initializer
    {
        __SYBase_init(name_, symbol_, token_, owner_);
    }

    function _deposit(address, uint256 amountDeposited) internal override returns (uint256) {
        // Probe reentrancy during deposit: the nested redeem below is blocked by redeem's own
        // nonReentrant guard, so this single probe anchors both entry points. If either guard is
        // removed, the nested call reverts with a non-guard selector (ERC20InsufficientBalance from
        // burning while the contract holds zero SY shares -- _mint runs after _deposit returns),
        // which sets reentryBlocked=false and fails the test.
        if (!reentryBlocked) {
            try this.redeem(address(this), 1, yieldBearingToken(), 0, true) {}
            catch (bytes memory reason) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 0x20))
                }
                reentryBlocked = selector == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
            }
        }
        return amountDeposited;
    }

    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        override
        returns (uint256)
    {
        IERC20(tokenOut).transfer(receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function exchangeRate() public pure override returns (uint256) {
        return 1e18;
    }

    function _previewDeposit(address, uint256 amountTokenToDeposit) internal pure override returns (uint256) {
        return amountTokenToDeposit;
    }

    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure override returns (uint256) {
        return amountSharesToRedeem;
    }

    function getTokensIn() public view override returns (address[] memory) {
        return ArrayLib.create(yieldBearingToken());
    }

    function getTokensOut() public view override returns (address[] memory) {
        return ArrayLib.create(yieldBearingToken());
    }

    function isValidTokenIn(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    function isValidTokenOut(address token) public view override returns (bool) {
        return token == yieldBearingToken();
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, yieldBearingToken(), decimals());
    }
}

/// @dev V2 harness to verify owner-only upgrade path.
contract TestSYUpgradeableV2 is TestSYUpgradeable {
    function version() external pure returns (uint256) {
        return 2;
    }
}
