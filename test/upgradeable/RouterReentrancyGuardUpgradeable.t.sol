// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {OutrunRouter} from "../../src/router/OutrunRouter.sol";
import {IOutrunRouter} from "../../src/router/interfaces/IOutrunRouter.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {RouterMockSY, RouterMockUAsset, RouterMockLauncher} from "./mocks/RouterMocks.sol";
import {ReentrantTokenMock} from "./mocks/ReentrantTokenMock.sol";

/**
 * @title ReenteringAttacker
 * @notice Helper contract that, from inside the malicious token's transferFrom callback
 *      window, attempts a nested call into every state-changing router entry point and
 *      records any entry that was not blocked by the reentrancy guard.
 */
contract ReenteringAttacker {
    bytes4 internal constant GUARD_SELECTOR = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
    uint256 public constant NO_FAILURE = type(uint256).max;

    OutrunRouter internal immutable router;
    RouterMockSY internal immutable sy;
    ReentrantTokenMock internal immutable token;
    address internal immutable position;
    uint256 internal attackAmount;

    /// @notice Index of the first router entry whose nested call was not blocked; NO_FAILURE when all were blocked.
    uint256 public firstFailure = NO_FAILURE;
    /// @notice Revert selector observed for the entry at `firstFailure` (diagnostic only).
    bytes4 public capturedSelector;

    constructor(OutrunRouter router_, RouterMockSY sy_, ReentrantTokenMock token_, address position_) {
        router = router_;
        sy = sy_;
        token = token_;
        position = position_;
    }

    /**
     * @notice Calls mintSYFromToken while the input token is armed to reenter from transferFrom.
     * @dev The router flow is caller-funded (tokens are pulled from this contract), so the
     *      reentrant attempts can only try to spend this contract's own funds; the guard is
     *      what must stop every nested call from running at all.
     */
    function attack(uint256 amount) external {
        attackAmount = amount;
        // Cover the outer pull and every nested attempt (each consumes allowance if reached).
        token.approve(address(router), 9 * amount);
        token.arm(address(this));
        uint256 syOut = router.mintSYFromToken(address(sy), address(token), address(this), amount, 0);
        require(syOut == amount, "outer mint returned unexpected amount");
    }

    /**
     * @notice Reentry attempts fired from the armed token's transferFrom callback.
     * @dev Guard invariant: nonReentrant is the outermost modifier on every user entry, so each
     *      nested call must revert with the guard's custom error before any body logic or input
     *      validation runs. Arguments therefore only need to ABI-encode against valid addresses;
     *      they are never evaluated. A nested call that succeeds or reverts with anything else
     *      breaks the invariant and is recorded as a failure.
     */
    // The fallback is the attack payload entry: it encodes a nested call per router entry
    // point and inspects each revert data, so the complexity is inherent to the matrix.
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address self = address(this);
        IOutrunRouter.StakeParam memory stakeParam =
            IOutrunRouter.StakeParam({lockupDays: 1, minSyOut: 0, minUAssetMinted: 0, owner: self, receiver: self});

        bytes[] memory attempts = new bytes[](8);
        attempts[0] = abi.encodeCall(router.mintSYFromToken, (address(sy), address(token), self, attackAmount, 0));
        attempts[1] = abi.encodeCall(router.redeemSyToToken, (address(sy), self, address(token), 1, 0));
        attempts[2] = abi.encodeCall(router.stakeFromToken, (position, address(token), 1, stakeParam));
        attempts[3] = abi.encodeCall(router.stakeFromSY, (position, 1, stakeParam));
        attempts[4] = abi.encodeCall(router.wrapStakeFromToken, (position, address(token), 1, 0, self, 0));
        attempts[5] = abi.encodeCall(router.wrapStakeFromSY, (position, 1, self, 0));
        attempts[6] = abi.encodeCall(router.genesisByToken, (position, address(token), 1, 0, 1, 1, self, 0));
        attempts[7] = abi.encodeCall(router.genesisBySY, (position, 1, 1, 1, self, 0));

        for (uint256 i = 0; i < attempts.length; ++i) {
            (bool ok, bytes memory ret) = address(router).call(attempts[i]);
            if (ok || ret.length < 4) {
                firstFailure = i;
                return;
            }
            // Casting to bytes4 is safe: a Solidity custom error's selector is exactly the first 4 bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 selector = bytes4(ret);
            if (selector != GUARD_SELECTOR) {
                firstFailure = i;
                capturedSelector = selector;
                return;
            }
        }
    }
}

/**
 * @title RouterReentrancyGuardUpgradeableTest
 * @notice Regression tests proving the router's user entry points block reentrant calls.
 * @dev Invariant: every state-changing router entry point is guarded by nonReentrant, so a
 *      malicious input token that calls back mid-transferFrom cannot nest a second router
 *      call. The outer call stays caller-funded and completes normally afterwards.
 */
contract RouterReentrancyGuardUpgradeableTest is Test {
    ReentrantTokenMock internal token;
    RouterMockSY internal sy;
    RouterMockUAsset internal uAsset;
    OutrunStakingPositionUpgradeable internal position;
    OutrunRouter internal router;

    address internal owner = address(0xA11CE);
    address internal revenuePool = address(0xFEE);

    function setUp() external {
        token = new ReentrantTokenMock();
        sy = new RouterMockSY(address(token));
        uAsset = new RouterMockUAsset();
        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), address(0xC0FFEE))
                )
            )
        );
        router = new OutrunRouter(owner, address(new RouterMockLauncher(address(uAsset))));

        vm.prank(owner);
        router.setTrustedSY(address(sy), true);
        vm.prank(owner);
        router.setTrustedSP(address(position), address(sy));
    }

    /// @notice Reentry from the input token's transferFrom callback must revert with the
    ///      guard's custom error on every user entry point, while the outer mint still
    ///      delivers SY to the caller.
    function test_MintSYFromTokenBlocksReentrantCall() external {
        uint256 amount = 10 ether;
        ReenteringAttacker attacker = new ReenteringAttacker(router, sy, token, address(position));
        token.mint(address(attacker), amount);

        // Outer call must complete despite the malicious callback firing mid-transfer.
        attacker.attack(amount);

        // Every nested router call must have been stopped by the guard (NO_FAILURE sentinel).
        assertEq(attacker.firstFailure(), attacker.NO_FAILURE(), "reentrant call was not blocked by the guard");
        // Victim (attacker contract as the honest outer caller) still receives its SY.
        assertEq(sy.balanceOf(address(attacker)), amount, "outer mint did not deliver SY");
        // Router keeps no residual token balance or allowance after the guarded flow.
        assertEq(token.balanceOf(address(router)), 0, "router kept residual token balance");
        assertEq(token.allowance(address(router), address(sy)), 0, "router kept residual token allowance");
    }
}
