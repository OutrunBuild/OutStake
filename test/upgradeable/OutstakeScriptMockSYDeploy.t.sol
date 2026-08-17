// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {MockUSDC} from "../support/mocks/MockUSDC.sol";
import {MockAUSDC} from "../support/mocks/MockAUSDC.sol";
import {MockSUSDS} from "../support/mocks/MockSUSDS.sol";
import {MockAUSDCOracle} from "../support/mocks/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "../support/mocks/MockSUSDSOracle.sol";
import {MockExchangeRateOracle} from "../support/mocks/MockExchangeRateOracle.sol";

contract OutstakeScriptHarness is OutstakeScript {
    function configure(address owner_, address deployer_, address outrunDeployer_) external {
        owner = owner_;
        deployer = deployer_;
        outrunDeployer = outrunDeployer_;
    }

    function exposedDeployMockERC20SY(uint256 nonce) external {
        _deployMockERC20SY(nonce);
    }

    function exposedSupportMockAUSDC(uint256 nonce) external {
        _supportMockAUSDC(nonce);
    }

    function exposedDeployMockERC20(uint256 nonce) external {
        _deployMockERC20(nonce);
    }

    function exposedDeployMockOracle(uint256 nonce) external {
        _deployMockOracle(nonce);
    }

    function exposedTestnetChainIds() external pure returns (uint32[] memory) {
        return _testnetChainIds();
    }
}

contract OutstakeScriptMockSYDeployTest is Test {
    address internal user = address(0xB0B);

    OutstakeScriptHarness internal script;
    OutrunDeployer internal outrunDeployer;
    MockUSDC internal mockUSDC;
    MockAUSDC internal mockAUSDC;
    MockSUSDS internal mockSUSDS;
    // Held so the deploy test can pin SHIFTED, distinct oracle rates before asserting on
    // sy.exchangeRate(). The assertion then proves each SY reads its OWN wired oracle, so a
    // cross-wiring or a broken/reverting oracle is detectable.
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

        // Pin each oracle to a DISTINCT normalized rate. The mock SY now PROPAGATES the wired
        // oracle's rate/revert (fail-closed, mirroring the production oracle-backed family), so
        // _assertUsableSY proves each SY reads its OWN wired oracle: a broken/reverting oracle
        // makes exchangeRate() revert and the test fails; a cross-wiring (SY wired to the other
        // oracle) returns the other oracle's rate and also fails, because the two expected rates
        // differ.
        // aUSDC oracle: RAW_DECIMALS=6, so raw 1_100_000 normalizes to 1.1e18.
        // sUSDS oracle: RAW_DECIMALS=18, so raw 1.2e18 normalizes to 1.2e18.
        mockAUSDCOracle.setLatestAnswer(1_100_000);
        mockSUSDSOracle.setLatestAnswer(1.2e18);

        _assertUsableSY(aUSDCSY, address(mockAUSDC), 1.1e18);
        _assertUsableSY(sUSDSSY, address(mockSUSDS), 1.2e18);
    }

    // Regression: previously the mock swallowed a broken oracle into a 1e18 fallback; now the
    // revert propagates (fail-closed), which is what the deploy-script _validateMockSupportConfig
    // catch branch depends on.
    function testDeployMockERC20SYBrokenOracleFailsClosed() external {
        uint256 nonce = 1;

        script.exposedDeployMockERC20SY(nonce);

        IStandardizedYield aUSDCSY = IStandardizedYield(
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("MockAUSDCSY", nonce)))
        );

        // Zeroing the oracle makes getExchangeRate() revert InvalidOracleAnswer; the mock SY must
        // propagate that revert instead of falling back to 1e18.
        mockAUSDCOracle.setLatestAnswer(0);

        vm.expectRevert(MockExchangeRateOracle.InvalidOracleAnswer.selector);
        aUSDCSY.exchangeRate();
    }

    // The default forge chainid 31337 is inside the allowlist, so the deploy tests above are
    // unaffected; mainnet (1) is not, and the mock gate must fail closed there.
    function test_RevertWhen_ChainIsNotTestnet() external {
        vm.chainId(1);

        vm.expectRevert(OutstakeScript.NotTestnetChain.selector);
        script.exposedDeployMockERC20SY(1);
    }

    // _supportMockAUSDC is the only call chain to the setMintingCap(SP_DEFAULT_MINTING_CAP) fund
    // surface, so its mock gate must fail closed on mainnet exactly like the deploy path.
    // Pre-seeding the support env vars pins guard-BEFORE-env-read order: if the guard moved after
    // the reads, the revert would become InvalidKeeper/InvalidAddress, not NotTestnetChain.
    function test_RevertWhen_ChainIsNotTestnetOnMockSupportPath() external {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MOCK_AUSDC_SY", vm.toString(address(0xA11CE)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("UUSD", vm.toString(address(0xB0B)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("REVENUE_POOL", vm.toString(address(0xCAFE)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("KEEPER", vm.toString(address(0xD00D)));

        vm.chainId(1);

        vm.expectRevert(OutstakeScript.NotTestnetChain.selector);
        script.exposedSupportMockAUSDC(13);
    }

    // Locks the chain guard on the _deployMockERC20 entry (guard is the function's first line, before any env read or deploy effect, so no env setup is needed).
    function test_RevertWhen_ChainIsNotTestnetOnMockTokenEntry() external {
        vm.chainId(1);

        vm.expectRevert(OutstakeScript.NotTestnetChain.selector);
        script.exposedDeployMockERC20(1);
    }

    // Locks the chain guard on the _deployMockOracle entry (guard is the function's first line, before any env read or deploy effect, so no env setup is needed).
    function test_RevertWhen_ChainIsNotTestnetOnMockOracleEntry() external {
        vm.chainId(1);

        vm.expectRevert(OutstakeScript.NotTestnetChain.selector);
        script.exposedDeployMockOracle(1);
    }

    // 4_294_998_633 = 2^32 + 31337: a uint32-truncated comparison would match allowlist entry 0
    // and pass the gate, so this locks the full-width chainid comparison (SECR-001).
    function test_RevertWhen_ChainIdTruncatesIntoAllowlist() external {
        vm.chainId(4_294_998_633);

        vm.expectRevert(OutstakeScript.NotTestnetChain.selector);
        script.exposedDeployMockERC20SY(1);
    }

    // Pins the exact contents of `_testnetChainIds` as a literal allowlist: any removal, wrong
    // id, addition, or duplicate surfaces in CI. Syncing this list with the `_chainsInit` key
    // set is still manual — this test does NOT verify `_chainsInit` (a mapping cannot be
    // enumerated), so a forgotten new testnet only surfaces at runtime when that chain is
    // rejected fail-closed. Adding a new testnet requires updating two places in lockstep:
    // `_chainsInit` and `_testnetChainIds`; the literals below evolve with this test itself.
    function test_TestnetChainIdsEqualPinnedAllowlist() external {
        uint32[15] memory expected = [
            31337, // Anvil local chain
            97, // BSC Testnet
            84532, // Base Sepolia
            421614, // Arbitrum Sepolia
            43113, // Avalanche Fuji C-Chain
            80002, // Polygon Amoy
            57054, // Sonic Blaze
            11155420, // Optimistic Sepolia
            300, // ZKsync Sepolia
            59141, // Linea Sepolia
            168587773, // Blast Sepolia
            534351, // Scroll Sepolia
            10143, // Monad Testnet
            80069, // Bera Sepolia
            11155111 // Sepolia
        ];

        uint32[] memory actual = script.exposedTestnetChainIds();
        assertEq(actual.length, expected.length);

        // Every expected member must be present in the returned allowlist.
        for (uint256 i; i < expected.length; ++i) {
            bool found;
            for (uint256 j; j < actual.length; ++j) {
                if (actual[j] == expected[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "missing testnet chain id");
        }

        // Belt-and-braces: with the length and every expected member already pinned, a duplicate
        // is impossible, but this direct pairwise check keeps the multiset pinned even if the
        // length assert above is ever relaxed.
        for (uint256 i; i < actual.length; ++i) {
            for (uint256 j = i + 1; j < actual.length; ++j) {
                assertTrue(actual[i] != actual[j], "duplicate testnet chain id");
            }
        }
    }

    function _assertUsableSY(IStandardizedYield sy, address yieldToken, uint256 expectedExchangeRate) internal {
        assertGt(address(sy).code.length, 0);
        assertEq(sy.yieldBearingToken(), yieldToken);
        // Asserts the SY propagates its wired oracle's seeded rate. The mock mirrors the
        // production fail-closed family: a broken/reverting oracle makes exchangeRate() revert,
        // and a cross-wired oracle returns the other SY's rate; each SY's expected rate differs
        // from the other SY's rate, so this fails on broken OR cross-wired oracles.
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
