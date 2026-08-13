// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {MockUSDC} from "../support/MockUSDC.sol";
import {MockAUSDC} from "../support/MockAUSDC.sol";
import {MockSUSDS} from "../support/MockSUSDS.sol";
import {MockAUSDCOracle} from "../support/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "../support/MockSUSDSOracle.sol";

contract OutstakeScriptHarness is OutstakeScript {
    function configure(address owner_, address deployer_, address outrunDeployer_) external {
        owner = owner_;
        deployer = deployer_;
        outrunDeployer = outrunDeployer_;
    }

    function exposedDeployMockERC20SY(uint256 nonce) external {
        _deployMockERC20SY(nonce);
    }
}

contract OutstakeScriptMockSYDeployTest is Test {
    address internal user = address(0xB0B);

    OutstakeScriptHarness internal script;
    OutrunDeployer internal outrunDeployer;
    MockUSDC internal mockUSDC;
    MockAUSDC internal mockAUSDC;
    MockSUSDS internal mockSUSDS;
    // Held so the deploy test can pin a recognizable oracle answer before asserting on
    // sy.exchangeRate(). Without this, the mock SY swallows oracle failures into a 1e18
    // fallback and an exchangeRate assertion cannot detect a broken wiring.
    MockAUSDCOracle internal mockAUSDCOracle;
    MockSUSDSOracle internal mockSUSDSOracle;

    function setUp() external {
        script = new OutstakeScriptHarness();
        outrunDeployer = new OutrunDeployer(address(script));
        script.configure(address(script), address(script), address(outrunDeployer));

        mockUSDC = new MockUSDC("Mock USDC", "USDC", 18, address(this));
        mockAUSDC = new MockAUSDC("Mock aUSDC", "aUSDC", 18, address(mockUSDC), address(this));
        mockSUSDS = new MockSUSDS("Mock sUSDS", "sUSDS", 18, address(mockUSDC), address(this));

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MOCK_USDC", vm.toString(address(mockUSDC)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MOCK_AUSDC", vm.toString(address(mockAUSDC)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MOCK_SUSDS", vm.toString(address(mockSUSDS)));
        mockAUSDCOracle = new MockAUSDCOracle(address(this));
        mockSUSDSOracle = new MockSUSDSOracle(address(this));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MOCK_AUSDC_ORACLE", vm.toString(address(mockAUSDCOracle)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MOCK_SUSDS_ORACLE", vm.toString(address(mockSUSDSOracle)));
    }

    function testDeployMockERC20SYCreatesUsableAUSDCAndSUSDSSYProxies() external {
        uint256 nonce = 1;

        script.exposedDeployMockERC20SY(nonce);

        IStandardizedYield aUSDCSY = IStandardizedYield(
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("MockAUSDCSY", nonce)))
        );
        IStandardizedYield sUSDSSY = IStandardizedYield(
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("MockSUSDSSY", nonce)))
        );

        // Pin each oracle to a DISTINCT normalized rate that also differs from the mock SY's
        // 1e18 fallback. _assertUsableSY then proves each SY reads its OWN wired oracle: a
        // broken wiring (mis-wired address / reverting / zero oracle) falls back to 1e18 and
        // fails; a cross-wiring (SY wired to the other oracle) returns the other oracle's
        // rate and also fails, because the two expected rates differ.
        // aUSDC oracle: RAW_DECIMALS=6, so raw 1_100_000 normalizes to 1.1e18.
        // sUSDS oracle: RAW_DECIMALS=18, so raw 1.2e18 normalizes to 1.2e18.
        mockAUSDCOracle.setLatestAnswer(1_100_000);
        mockSUSDSOracle.setLatestAnswer(1.2e18);

        _assertUsableSY(aUSDCSY, address(mockAUSDC), 1.1e18);
        _assertUsableSY(sUSDSSY, address(mockSUSDS), 1.2e18);
    }

    function _assertUsableSY(IStandardizedYield sy, address yieldToken, uint256 expectedExchangeRate) internal {
        assertGt(address(sy).code.length, 0);
        assertEq(sy.yieldBearingToken(), yieldToken);
        // Asserts the SY propagates its wired oracle's seeded rate. The mock SY falls back to
        // 1e18 when the oracle reverts or answers 0, and each SY's expected rate differs from
        // both the 1e18 fallback and the other SY's rate, so this fails on broken OR
        // cross-wired oracles.
        assertEq(sy.exchangeRate(), expectedExchangeRate);
        assertTrue(sy.isValidTokenIn(address(mockUSDC)));
        assertTrue(sy.isValidTokenIn(yieldToken));
        assertTrue(sy.isValidTokenOut(address(mockUSDC)));
        assertTrue(sy.isValidTokenOut(yieldToken));

        (IStandardizedYield.AssetType assetType, address assetAddress, uint8 assetDecimals) = sy.assetInfo();
        assertEq(uint8(assetType), uint8(IStandardizedYield.AssetType.TOKEN));
        assertEq(assetAddress, address(mockUSDC));
        assertEq(assetDecimals, 18);

        uint256 amount = 100e18;
        uint256 balanceBefore = mockUSDC.balanceOf(user);
        mockUSDC.mint(user, amount);

        vm.startPrank(user);
        IERC20(address(mockUSDC)).approve(address(sy), amount);
        uint256 shares = sy.deposit(user, address(mockUSDC), amount, amount);
        assertEq(shares, amount);
        assertEq(sy.balanceOf(user), amount);

        uint256 redeemed = sy.redeem(user, amount, address(mockUSDC), amount, false);
        vm.stopPrank();

        assertEq(redeemed, amount);
        assertEq(sy.balanceOf(user), 0);
        assertEq(mockUSDC.balanceOf(user), balanceBefore + amount);
    }
}
