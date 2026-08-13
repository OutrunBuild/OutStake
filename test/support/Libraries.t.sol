// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {AaveAdapterLib} from "../../src/libraries/AaveAdapterLib.sol";
import {WadRayMath} from "../../src/libraries/WadRayMath.sol";
import {ArrayLib} from "../../src/libraries/ArrayLib.sol";
import {SYUtils} from "../../src/libraries/SYUtils.sol";
import {ReentrancyGuard} from "../../src/libraries/ReentrancyGuard.sol";
import {MockGuarded, WadRayMathHelper} from "./LibraryMocks.sol";

// ============================================================================
// WadRayMath Tests
// ============================================================================

contract WadRayMathTest is Test {
    using WadRayMath for uint256;

    // Helper contract to test reverts through external calls
    WadRayMathHelper internal helper;

    function setUp() public {
        helper = new WadRayMathHelper();
    }

    function testRayDivReturnsCorrectResult() public {
        uint256 a = 6e27;
        uint256 b = 3e27;
        uint256 result = a.rayDiv(b);
        assertEq(result, 2e27);
    }

    function testRayDivRevertsOnZeroDivisor() public {
        vm.expectRevert();
        helper.rayDivZero(1e27);
    }

    function testRayDivRevertsOnOverflow() public {
        // a > (2^256 - 1 - b / 2) / RAY silently wraps in unchecked Yul, so the guard must revert.
        vm.expectRevert();
        helper.rayDivOverflow(type(uint256).max, 1e27);
    }

    function testRayDivPassesAtOverflowBoundary() public {
        // Largest a the guard allows: (2^256 - 1 - b / 2) / RAY. Since b == RAY, a * RAY is an
        // exact multiple of b and the half-up increment does not change the quotient; the result equals a exactly.
        uint256 b = 1e27;
        uint256 a = (type(uint256).max - b / 2) / b;
        assertEq(a.rayDiv(b), a);
    }
}

// ============================================================================
// ArrayLib Tests
// ============================================================================

contract ArrayLibTest is Test {
    address internal constant A = address(0x1);
    address internal constant B = address(0x2);
    address internal constant C = address(0x3);

    function testCreateVariableCount() public {
        address[] memory result1 = ArrayLib.create(A);
        assertEq(result1.length, 1);
        assertEq(result1[0], A);

        address[] memory result2 = ArrayLib.create(A, B);
        assertEq(result2.length, 2);
        assertEq(result2[0], A);
        assertEq(result2[1], B);

        address[] memory result3 = ArrayLib.create(A, B, C);
        assertEq(result3.length, 3);
        assertEq(result3[0], A);
        assertEq(result3[1], B);
        assertEq(result3[2], C);
    }
}

// ============================================================================
// SYUtils Tests
// ============================================================================

contract SYUtilsTest is Test {
    using SYUtils for uint256;

    function testSyToAssetReturnsCorrectValue() public {
        // With rate 1:1 (1e18), 1e18 SY -> 100 asset
        uint256 exchangeRate = 1e18;
        uint256 syAmount = 100;
        uint256 result = SYUtils.syToAsset(exchangeRate, syAmount);
        assertEq(result, 100);
    }

    function testSyToAssetWithRate2x() public {
        // With rate 2e18, 2e18 SY -> 400 asset
        uint256 exchangeRate = 2e18;
        uint256 syAmount = 200;
        uint256 result = SYUtils.syToAsset(exchangeRate, syAmount);
        assertEq(result, 400);
    }

    function testSyToAssetUpRoundsUp() public {
        // rate 3, 1 wei SY: floor (1*3)/1e18 = 0, ceil (1*3 + 1e18 - 1)/1e18 = 1
        uint256 exchangeRate = 3;
        uint256 syAmount = 1;
        uint256 down = SYUtils.syToAsset(exchangeRate, syAmount);
        uint256 up = SYUtils.syToAssetUp(exchangeRate, syAmount);
        assertEq(down, 0);
        assertEq(up, 1);
    }

    function testAssetToSyReturnsCorrectValue() public {
        // With rate 1:1 (1e18), 100 asset -> 100 SY
        uint256 exchangeRate = 1e18;
        uint256 assetAmount = 100;
        uint256 result = SYUtils.assetToSy(exchangeRate, assetAmount);
        assertEq(result, 100);
    }

    function testAssetToSyWithRate2x() public {
        // With rate 2e18, 200 asset -> 100 SY
        uint256 exchangeRate = 2e18;
        uint256 assetAmount = 200;
        uint256 result = SYUtils.assetToSy(exchangeRate, assetAmount);
        assertEq(result, 100);
    }

    function testAssetToSyUpRoundsUp() public {
        // rate 3, 1 wei asset: floor 1e18/3 = 333_333_333_333_333_333, ceil rounds the remainder up by 1
        uint256 exchangeRate = 3;
        uint256 assetAmount = 1;
        uint256 down = SYUtils.assetToSy(exchangeRate, assetAmount);
        uint256 up = SYUtils.assetToSyUp(exchangeRate, assetAmount);
        assertEq(down, 333_333_333_333_333_333);
        assertEq(up, 333_333_333_333_333_334);
    }

    function testSyToAssetUpAlwaysGreaterOrEqualToSyToAsset() public {
        // rate 1e18+1, 1e18-1 SY: floor = 1e18-1, ceil = 1e18 (rounds the remainder up)
        uint256 exchangeRate = 1e18 + 1; // Non-trivial rate
        uint256 syAmount = 1e18 - 1;
        uint256 down = SYUtils.syToAsset(exchangeRate, syAmount);
        uint256 up = SYUtils.syToAssetUp(exchangeRate, syAmount);
        assertEq(down, 1e18 - 1);
        assertEq(up, 1e18);
    }

    function testAssetToSyUpAlwaysGreaterOrEqualToAssetToSy() public {
        // rate 1e18+1, 1e18-1 asset: floor = 1e18-2, ceil = 1e18-1 (rounds the remainder up)
        uint256 exchangeRate = 1e18 + 1; // Non-trivial rate
        uint256 assetAmount = 1e18 - 1;
        uint256 down = SYUtils.assetToSy(exchangeRate, assetAmount);
        uint256 up = SYUtils.assetToSyUp(exchangeRate, assetAmount);
        assertEq(down, 1e18 - 2);
        assertEq(up, 1e18 - 1);
    }

    function testRoundTripIdentity() public {
        // syToAsset(rate, assetToSy(rate, x)) == x for exact values
        uint256 exchangeRate = 1e18;
        uint256 assetAmount = 1e18;
        uint256 syAmount = SYUtils.assetToSy(exchangeRate, assetAmount);
        uint256 backToAsset = SYUtils.syToAsset(exchangeRate, syAmount);
        assertEq(backToAsset, assetAmount);
    }
}

// ============================================================================
// ReentrancyGuard Tests
// ============================================================================

contract ReentrancyGuardTest is Test {
    MockGuarded internal guarded;

    function setUp() public {
        guarded = new MockGuarded();
    }

    function testNonReentrantAllowsFirstCall() public {
        uint256 result = guarded.guardedAction();
        assertEq(result, 42);
    }

    function testNonReentrantRevertsOnReentry() public {
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        guarded.tryReenter();
    }

    function testGuardResetsAfterFunctionReturns() public {
        // First call
        uint256 result1 = guarded.guardedAction();
        assertEq(result1, 42);
        // Second call should also succeed (guard properly resets)
        uint256 result2 = guarded.guardedAction();
        assertEq(result2, 42);
    }
}

// ============================================================================
// AaveAdapterLib Tests
// ============================================================================

contract AaveAdapterLibTest is Test {
    function testCalcSharesFromAssetHalfUpRoundsHalfUpAtExactHalf() public {
        // 3 assets at index 2e27 -> quotient exactly 1.5. Half-up rounds to 2;
        // a floor rounding mode would give 1, so this pins the half-up direction.
        uint256 result = AaveAdapterLib.calcSharesFromAssetHalfUp(3, 2e27);
        assertEq(result, 2);
    }

    function testCalcSharesFromAssetHalfUpRoundsDownBelowHalf() public {
        // 1 asset at index 3e27 -> quotient 1/3, below half. Half-up rounds to 0;
        // a ceiling rounding mode would give 1, so this pins the half-up direction.
        uint256 result = AaveAdapterLib.calcSharesFromAssetHalfUp(1, 3e27);
        assertEq(result, 0);
    }

    function testCalcSharesFromAssetHalfUpRoundsHalfUpAtHalfToEvenBoundary() public {
        // 5 assets at index 2e27 -> quotient exactly 2.5. Half-up rounds to 3;
        // a round-half-even (banker's) mode would give 2, so this pins the half-up direction.
        uint256 result = AaveAdapterLib.calcSharesFromAssetHalfUp(5, 2e27);
        assertEq(result, 3);
    }

    function testCalcSharesToAssetDownRoundsDownAtExactHalf() public {
        // 1 share at index 1.5e27 -> quotient exactly 1.5. Rounds down to 1;
        // a half-up rounding mode would give 2, so this pins the down direction.
        uint256 result = AaveAdapterLib.calcSharesToAssetDown(1, 1.5e27);
        assertEq(result, 1);
    }
}
