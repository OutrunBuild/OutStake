// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUAssetReserveBase} from "./MockUAssetReserveBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOutrunStakeManager} from "../../../src/position/interfaces/IOutrunStakeManager.sol";
import {IMemeverseLauncher} from "../../../src/router/interfaces/IMemeverseLauncher.sol";
import {IStandardizedYield} from "../../../src/yield/interfaces/IStandardizedYield.sol";

/**
 * @title MockSYWithRateControl
 * @notice Mock SY that allows rate manipulation for adversarial testing
 * @dev Partial mock: models deposit/redeem around the underlying token for adversarial consumer tests.
 *      Does not model exchange-rate-based redeem conversion or a production token surface;
 *      token surfaces are aligned to the underlying token only.
 *      Decimals model: fixed 18 (assetDecimals hard-coded, no setDecimals);
 *      use MockSY in PositionTestMocks for configurable-decimals runs.
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
 * @dev Decimals model: fixed 18 (no decimals override; OpenZeppelin default).
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
contract MockUAssetForAdversarial is MockUAssetReserveBase {}

/**
 * @title ReentrantPositionSY
 * @notice Mock SY whose ERC20 transfer/transferFrom fire a one-shot reentrancy attempt against a
 *        caller-configured position entrypoint, recording the attempt's outcome for assertions.
 * @dev Partial mock: extends the rate-controllable SY by modeling only the transfer-callback
 *      seam (the position's SY touchpoints: the stake pull via transferFrom, and the redeem /
 *      liquidate / surplus-claim payouts via transfer). Accounting is honest ERC20 — the only
 *      attack surface is the callback. One shot per `arm`: the flag clears before firing so the
 *      reentrant call itself cannot chain another callback.
 */
contract ReentrantPositionSY is MockSYWithRateControl {
    address public attackTarget;
    bytes4 public attackSelector;
    bool private armed;
    uint256 public attempts;
    bool public lastAttackSucceeded;
    bytes public lastAttackRevertData;

    constructor(address underlying_) MockSYWithRateControl(underlying_) {}

    /// @notice Arms the next transfer/transferFrom to reenter `target` on `selector`.
    function arm(address target, bytes4 selector) external {
        attackTarget = target;
        attackSelector = selector;
        armed = true;
    }

    /// @notice Outcome of the most recent reentrancy attempt.
    function attackOutcome() external view returns (bool succeeded, bytes memory revertData) {
        return (lastAttackSucceeded, lastAttackRevertData);
    }

    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        bool transferred = super.transfer(to, amount);
        _tryReenter();
        return transferred;
    }

    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        bool transferred = super.transferFrom(from, to, amount);
        _tryReenter();
        return transferred;
    }

    /// @dev Encodes a plausible calldata payload per entrypoint; the guard must revert before any
    ///      argument is evaluated, so exact values are irrelevant — only ABI shape matters.
    function _encodeAttack() private view returns (bytes memory) {
        address self = address(this);
        if (attackSelector == IOutrunStakeManager.stakeForGenesis.selector) {
            return abi.encodeCall(IOutrunStakeManager.stakeForGenesis, (1e18, self, 1, 0));
        }
        if (attackSelector == IOutrunStakeManager.redeem.selector) {
            return abi.encodeCall(IOutrunStakeManager.redeem, (1, 1e18, self, self, 0));
        }
        return abi.encodeWithSelector(attackSelector);
    }

    function _tryReenter() private {
        if (!armed || attackTarget == address(0) || attackSelector == bytes4(0)) return;
        armed = false; // one shot: the reentrant call cannot chain further callbacks
        attempts += 1;
        // Low-level call keeps the outer flow alive so the test can inspect both outcomes.
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok, bytes memory ret) = attackTarget.call(_encodeAttack());
        lastAttackSucceeded = ok;
        lastAttackRevertData = ret;
    }
}

/**
 * @title ReenteringGenesisLauncher
 * @notice Mock genesis launcher that attempts a nested call into every position entrypoint from
 *        inside the genesis window, then consumes the full approved amount.
 * @dev Partial mock: models the launcher-side reentrancy surface only (one nested attempt per
 *      position entrypoint, recorded as a first-failure index, followed by the honest full pull so
 *      an outer genesis flow with all attempts blocked can complete). Does not model verse
 *      bookkeeping, partial pulls, or transfer-backs.
 */
contract ReenteringGenesisLauncher is IMemeverseLauncher {
    error LauncherTransferFailed();

    bytes4 internal constant GUARD_SELECTOR = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
    uint256 public constant NO_FAILURE = type(uint256).max;

    IOutrunStakeManager internal immutable position;
    IERC20 internal immutable uAsset;

    /// @notice Index of the first nested entry not blocked by the transient guard; NO_FAILURE when
    ///         all were blocked.
    uint256 public firstFailure = NO_FAILURE;

    constructor(address position_, address uAsset_) {
        position = IOutrunStakeManager(position_);
        uAsset = IERC20(uAsset_);
    }

    function genesis(uint256, uint128 amountInUAsset, address) external override {
        // The guard is the outermost modifier on every position entrypoint, so each nested call
        // must revert with the guard's custom error before any body logic runs; arguments only
        // need valid ABI shape, they are never evaluated.
        address self = address(this);
        bytes[] memory attempts = new bytes[](2);
        attempts[0] = abi.encodeCall(position.stakeForGenesis, (1e18, self, 1, 0));
        attempts[1] = abi.encodeCall(position.redeem, (1, 1, self, self, 0));
        for (uint256 i = 0; i < attempts.length; ++i) {
            // forge-lint: disable-next-line(unchecked-call)
            (bool ok, bytes memory ret) = address(position).call(attempts[i]);
            if (ok || ret.length < 4) {
                firstFailure = i;
                return;
            }
            // Casting to bytes4 is safe after the length check: a custom error's selector is
            // exactly the first 4 revert-data bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 selector = bytes4(ret);
            if (selector != GUARD_SELECTOR) {
                firstFailure = i;
                return;
            }
        }
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert LauncherTransferFailed();
        }
    }
}

/**
 * @title DonatingGenesisLauncher
 * @notice Mock genesis launcher that consumes the full approved amount and additionally transfers
 *        some of its own pre-funded uAsset into the SP inside the genesis window.
 * @dev Partial mock: models the full-pull-then-extra-inflow behavior that pushes the SP's uAsset
 *      balance above its pre-mint baseline (the post-assertion's balance dimension). Does not
 *      model verse bookkeeping, partial pulls, or nested calls.
 */
contract DonatingGenesisLauncher is IMemeverseLauncher {
    error LauncherTransferFailed();

    IERC20 internal immutable uAsset;
    uint256 internal immutable donateAmount;

    constructor(address uAsset_, uint256 donateAmount_) {
        uAsset = IERC20(uAsset_);
        donateAmount = donateAmount_;
    }

    function genesis(uint256, uint128 amountInUAsset, address) external override {
        if (!uAsset.transferFrom(msg.sender, address(this), amountInUAsset)) {
            revert LauncherTransferFailed();
        }
        if (!uAsset.transfer(msg.sender, donateAmount)) {
            revert LauncherTransferFailed();
        }
    }
}
