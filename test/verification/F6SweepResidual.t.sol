// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OutrunAsBNBSYUpgradeable} from "../../src/yield/adapters/aster/OutrunAsBNBSYUpgradeable.sol";
import {OutrunL2StakedUsdsSYUpgradeable} from "../../src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol";
import {SYBaseUpgradeable} from "../../src/yield/SYBaseUpgradeable.sol";
import {ProxyTestHelper} from "../upgradeable/helpers/ProxyTestHelper.sol";
import {
    MockToken,
    MockListaStakeManager,
    MockYieldProxy,
    MockAsBnbMinter,
    MockPSM3
} from "../upgradeable/mocks/SYAdapterMocks.sol";
import {IYieldProxy} from "../../src/integrations/aster/interfaces/IYieldProxy.sol";

/// @dev Partial mock: Aster minter that only consumes half of the slisBNB input.
///      Models a future partial-fill upgrade where the external contract keeps part of the input.
contract MockPartialAsBnbMinter {
    address public immutable asBnb;
    address public immutable token;
    address public immutable yieldProxy;
    uint256 public rate = 1e18;

    constructor(address asBnb_, address token_, address yieldProxy_) {
        asBnb = asBnb_;
        token = token_;
        yieldProxy = yieldProxy_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function mintAsBnb() external payable returns (uint256) {
        if (IYieldProxy(yieldProxy).activitiesOnGoing()) return 0;
        // native branch not partial for this test - consume full value
        uint256 out = msg.value * 1e18 / rate;
        MockToken(asBnb).mint(msg.sender, out);
        return out;
    }

    function mintAsBnb(uint256 amount) external returns (uint256) {
        if (IYieldProxy(yieldProxy).activitiesOnGoing()) return 0;
        // only pull half of the slisBNB - leave residue in SY
        uint256 half = amount / 2;
        // pull half via transferFrom (SY is msg.sender)
        MockToken(token).transferFrom(msg.sender, address(this), half);
        uint256 out = half * 1e18 / rate;
        MockToken(asBnb).mint(msg.sender, out);
        return out;
    }

    function convertToTokens(uint256 asBnbAmount) external view returns (uint256) {
        return asBnbAmount * rate / 1e18;
    }

    function convertToAsBnb(uint256 tokenAmount) external view returns (uint256) {
        return tokenAmount * 1e18 / rate;
    }
}

/// @dev Partial mock: PSM3 that only consumes half of tokenIn.
contract MockPartialPSM3 {
    address public shareToken;
    uint256 public rate = 1e18;

    function setRate(address shareToken_, uint256 rate_) external {
        shareToken = shareToken_;
        rate = rate_;
    }

    function _convert(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenOut == shareToken) return amountIn * 1e18 / rate;
        if (tokenIn == shareToken) return amountIn * rate / 1e18;
        return amountIn;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address receiver, uint256)
        external
        returns (uint256)
    {
        uint256 half = amountIn / 2;
        // pull only half
        MockToken(tokenIn).transferFrom(msg.sender, address(this), half);
        uint256 amountOut = _convert(tokenIn, tokenOut, half);
        MockToken(tokenOut).mint(receiver, amountOut);
        return amountOut;
    }

    function previewSwapExactIn(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        return _convert(tokenIn, tokenOut, amountIn);
    }
}

contract F6SweepResidualTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal constant NATIVE = address(0);

    // Aster: partial minter should revert after fix - demonstrates F6 is now protected
    // Before fix: partial minter would leave 5 ether slisBNB residue in SY, sweepable by owner (loss).
    // After fix: deposit reverts with AsBnbMintIncompleteConsumption, preventing stranded funds.
    function test_F6_Aster_PartialSlisBNB_ResidueIsSweepable() external {
        MockToken asBNB = new MockToken("asBNB", "asBNB", 18);
        MockToken slisBNB = new MockToken("slisBNB", "slisBNB", 18);
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockPartialAsBnbMinter minter =
            new MockPartialAsBnbMinter(address(asBNB), address(slisBNB), address(yieldProxy));

        OutrunAsBNBSYUpgradeable impl = new OutrunAsBNBSYUpgradeable();
        address sy = ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunAsBNBSYUpgradeable.initialize, (owner, address(asBNB), address(slisBNB), address(minter))
            )
        );

        uint256 amount = 10 ether;
        slisBNB.mint(user, amount);

        vm.startPrank(user);
        slisBNB.approve(sy, amount);
        // With fix, partial consumption must revert - no residue left for sweep
        vm.expectRevert(
            abi.encodeWithSelector(OutrunAsBNBSYUpgradeable.AsBnbMintIncompleteConsumption.selector, amount, 5 ether)
        );
        SYBaseUpgradeable(payable(sy)).deposit(user, address(slisBNB), amount, 0);
        vm.stopPrank();

        // Verify no shares minted and no sweepable residue (revert rolled back transfer)
        assertEq(SYBaseUpgradeable(payable(sy)).balanceOf(user), 0);
    }

    // Honest minter: no residue, sweep would find 0
    function test_F6_Aster_HonestMinter_NoResidue() external {
        MockToken asBNB = new MockToken("asBNB", "asBNB", 18);
        MockToken slisBNB = new MockToken("slisBNB", "slisBNB", 18);
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockAsBnbMinter minter = new MockAsBnbMinter(address(asBNB), address(slisBNB), address(yieldProxy));

        OutrunAsBNBSYUpgradeable impl = new OutrunAsBNBSYUpgradeable();
        address sy = ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunAsBNBSYUpgradeable.initialize, (owner, address(asBNB), address(slisBNB), address(minter))
            )
        );

        uint256 amount = 10 ether;
        slisBNB.mint(user, amount);
        vm.startPrank(user);
        slisBNB.approve(sy, amount);
        uint256 shares = SYBaseUpgradeable(payable(sy)).deposit(user, address(slisBNB), amount, 0);
        vm.stopPrank();

        assertEq(shares, 10 ether);
        assertEq(slisBNB.balanceOf(sy), 0, "honest minter leaves no residue");
        assertEq(asBNB.balanceOf(sy), 10 ether, "YBT backing present");
    }

    // PSM3: partial swap should revert after fix
    function test_F6_PSM3_PartialUSDC_ResidueIsSweepable() external {
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken usds = new MockToken("USDS", "USDS", 18);
        MockToken sUSDS = new MockToken("sUSDS", "sUSDS", 18);
        MockPartialPSM3 psm = new MockPartialPSM3();
        psm.setRate(address(sUSDS), 1e18);

        OutrunL2StakedUsdsSYUpgradeable impl = new OutrunL2StakedUsdsSYUpgradeable();
        address sy = ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunL2StakedUsdsSYUpgradeable.initialize,
                (owner, address(usdc), address(usds), address(sUSDS), address(psm))
            )
        );

        uint256 amount = 10 ether;
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(sy, amount);
        vm.expectRevert(
            abi.encodeWithSelector(OutrunL2StakedUsdsSYUpgradeable.PSM3IncompleteConsumption.selector, amount, 5 ether)
        );
        SYBaseUpgradeable(payable(sy)).deposit(user, address(usdc), amount, 0);
        vm.stopPrank();

        assertEq(SYBaseUpgradeable(payable(sy)).balanceOf(user), 0);
    }

    // Direct donation not backing shares is currently sweepable and harmless - control case
    function test_F6_DirectDonationNotBackingIsSweepableHarmless() external {
        MockToken asBNB = new MockToken("asBNB", "asBNB", 18);
        MockToken slisBNB = new MockToken("slisBNB", "slisBNB", 18);
        MockListaStakeManager stakeManager = new MockListaStakeManager();
        MockYieldProxy yieldProxy = new MockYieldProxy(address(stakeManager));
        MockAsBnbMinter minter = new MockAsBnbMinter(address(asBNB), address(slisBNB), address(yieldProxy));

        OutrunAsBNBSYUpgradeable impl = new OutrunAsBNBSYUpgradeable();
        address sy = ProxyTestHelper.deploy(
            address(impl),
            abi.encodeCall(
                OutrunAsBNBSYUpgradeable.initialize, (owner, address(asBNB), address(slisBNB), address(minter))
            )
        );

        // donate slisBNB directly without deposit - not backing any shares
        uint256 donation = 3 ether;
        slisBNB.mint(sy, donation);
        // totalSupply is 0, no shares minted
        assertEq(SYBaseUpgradeable(payable(sy)).totalSupply(), 0);

        // owner sweeping donation is harmless (audit says direct donation not share-backed)
        vm.prank(owner);
        SYBaseUpgradeable(payable(sy)).sweep(address(slisBNB), owner, donation);
        assertEq(slisBNB.balanceOf(owner), donation);
        assertEq(slisBNB.balanceOf(sy), 0);
    }
}
