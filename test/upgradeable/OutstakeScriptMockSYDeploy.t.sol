// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutstakeScript} from "../../script/deploy/OutstakeScript.s.sol";
import {OutrunDeployer} from "../../script/deploy/deployment/OutrunDeployer.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {IOutrunStakeManager} from "../../src/position/interfaces/IOutrunStakeManager.sol";
import {EmptyMockLauncher} from "./mocks/EmptyMockLauncher.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {MockUSDC} from "../support/mocks/MockUSDC.sol";
import {MockAUSDC} from "../support/mocks/MockAUSDC.sol";
import {MockSUSDS} from "../support/mocks/MockSUSDS.sol";
import {MockAUSDCOracle} from "../support/mocks/MockAUSDCOracle.sol";
import {MockSUSDSOracle} from "../support/mocks/MockSUSDSOracle.sol";
import {MockExchangeRateOracle} from "../support/mocks/MockExchangeRateOracle.sol";
import {YieldDeployMockUniversalAsset} from "../deploy/mocks/YieldDeployMocks.sol";
import {SPDefaults} from "../../script/lib/SPDefaults.sol";

contract OutstakeScriptHarness is OutstakeScript {
    // --- injected config (overrides the script's env-read seams so tests never mutate process
    // --- env: forge runs tests concurrently and vm.setEnv writes race across tests) ---

    bool internal spCapSet;
    uint256 internal injectedSpCap;
    address internal injectedMockUSDC;
    address internal injectedMockAUSDC;
    address internal injectedMockSUSDS;
    address internal injectedMockAUSDCOracle;
    address internal injectedMockSUSDSOracle;
    address internal injectedSupportSy;
    address internal injectedSupportUusd;
    address internal injectedSupportTreasury;
    bool internal genesisLauncherSet;
    address internal injectedGenesisLauncher;

    function setSpMintingCap(uint256 mintingCap) external {
        spCapSet = true;
        injectedSpCap = mintingCap;
    }

    function setMockStackConfig(address usdc, address ausdc, address susds, address ausdcOracle, address susdsOracle)
        external
    {
        injectedMockUSDC = usdc;
        injectedMockAUSDC = ausdc;
        injectedMockSUSDS = susds;
        injectedMockAUSDCOracle = ausdcOracle;
        injectedMockSUSDSOracle = susdsOracle;
    }

    function setMockSupportSy(address sy) external {
        injectedSupportSy = sy;
    }

    function setMockSupportUusd(address uusd) external {
        injectedSupportUusd = uusd;
    }

    function setMockSupportTreasury(address treasury) external {
        injectedSupportTreasury = treasury;
    }

    function setGenesisLauncherConfig(address genesisLauncher) external {
        genesisLauncherSet = true;
        injectedGenesisLauncher = genesisLauncher;
    }

    function setMemeverseLauncherConfig(address launcher) external {
        memeverseLauncher = launcher;
    }

    function exposedGenesisLauncherConfig() external view returns (bool set, address genesisLauncher) {
        return _genesisLauncherConfig();
    }

    function exposedSpMintingCap() external view returns (uint256) {
        return _spMintingCap();
    }

    function _spMintingCap() internal view override returns (uint256) {
        return spCapSet ? injectedSpCap : super._spMintingCap();
    }

    function _mockStackConfig() internal view override returns (address, address, address, address, address) {
        return
            (injectedMockUSDC, injectedMockAUSDC, injectedMockSUSDS, injectedMockAUSDCOracle, injectedMockSUSDSOracle);
    }

    function _mockSupportConfig(string memory) internal view override returns (address, address, address) {
        return (injectedSupportSy, injectedSupportUusd, injectedSupportTreasury);
    }

    /// @dev Unset injection falls through to the script's env read so the absent-env path (entry
    ///      stays disabled) stays covered without env writes.
    function _genesisLauncherConfig() internal view override returns (bool, address) {
        return genesisLauncherSet ? (true, injectedGenesisLauncher) : super._genesisLauncherConfig();
    }

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

    function exposedSupportMockSUSDS(uint256 nonce) external {
        _supportMockSUSDS(nonce);
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

    // The family guard is an internal library call, so it reverts inside the caller's own frame
    // and vm.expectRevert cannot observe it; routing it through this external frame makes the
    // fail-closed legs assertable.
    function exposedAssertFamilySY(address sy, uint8 family) external view {
        SPDefaults.assertFamilySY(sy, family);
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
    YieldDeployMockUniversalAsset internal uusd;

    function setUp() external {
        // The unset-seam cap path falls through to the real process env (the production
        // default path this suite pins), so an ambient SP_MINTING_CAP export — a legitimate
        // ops override — would break every default-value assert below. Fail here with the
        // culprit named instead of an unrelated-looking red.
        assertFalse(vm.envExists("SP_MINTING_CAP"), "ambient SP_MINTING_CAP export breaks default-cap asserts");
        // Same hermeticity guard for the optional genesis-launcher config: the unset
        // injection falls through to the GENESIS_LAUNCHER env key, and an ambient export
        // (a legitimate ops override) would silently flip the "config absent" paths this
        // suite pins or revert them mid-support-deploy. Fail here with the culprit named.
        assertFalse(vm.envExists("GENESIS_LAUNCHER"), "ambient GENESIS_LAUNCHER export breaks unset-config asserts");

        script = new OutstakeScriptHarness();
        outrunDeployer = new OutrunDeployer(address(script));
        script.configure(address(script), address(script), address(outrunDeployer));

        mockUSDC = new MockUSDC("Mock USDC", "USDC", 18, address(this));
        mockAUSDC = new MockAUSDC("Mock aUSDC", "aUSDC", 18, address(mockUSDC), address(this));
        mockSUSDS = new MockSUSDS("Mock sUSDS", "sUSDS", 18, address(mockUSDC), address(this));
        mockAUSDCOracle = new MockAUSDCOracle(address(this));
        mockSUSDSOracle = new MockSUSDSOracle(address(this));
        // Mock-stack addresses are harness-injected (fresh instances per test); writing them to
        // env would race across concurrently running tests.
        script.setMockStackConfig(
            address(mockUSDC),
            address(mockAUSDC),
            address(mockSUSDS),
            address(mockAUSDCOracle),
            address(mockSUSDSOracle)
        );
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

    /// @dev Race-free seam test for the SP minting-cap config (mirrors the YieldDeploy-script
    ///      variant): the injected cap wins when set and the 1_000_000_000 ether placeholder
    ///      default applies when unset. The call site (`_supportMockSY` -> setMintingCap) is
    ///      pinned by the default-value assert in the happy-path test above.
    function testSpMintingCapFollowsInjectionOverDefault() external {
        assertEq(script.exposedSpMintingCap(), 1_000_000_000 ether);

        script.setSpMintingCap(1_234 ether);

        assertEq(script.exposedSpMintingCap(), 1_234 ether);
    }

    // --- mock-support validation matrix (the revert legs of _validateMockSupportConfig) ---

    /// @dev Baseline harness wiring that passes validation: a deployed mock SY (one of the two
    ///      instances created by a single `exposedDeployMockERC20SY`, selected by its salt word)
    ///      reading its own wired oracle, and a UUSD stand-in that is Ownable-by-script, carries
    ///      code, and answers decimals(). Injected via seams — no env writes (concurrent tests
    ///      race on env keys).
    function _setValidMockSupportConfig(string memory sySaltWord, MockExchangeRateOracle oracle, int256 answer)
        internal
        returns (address syAddress)
    {
        uusd = new YieldDeployMockUniversalAsset(address(script));
        uusd.setSymbol("UUSD");
        script.exposedDeployMockERC20SY(1);
        syAddress = outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked(sySaltWord, uint256(1))));
        oracle.setLatestAnswer(answer);
        script.setMockSupportSy(syAddress);
        script.setMockSupportUusd(address(uusd));
        script.setMockSupportTreasury(user);
    }

    function testSupportMockAUSDCPassesValidationAndDeploysThePosition() external {
        address syAddress = _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);

        script.exposedSupportMockAUSDC(2);

        address sp =
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("Mock SP aUSDC", uint256(2))));
        assertGt(sp.code.length, 0);
        // A wrapper pointed at the wrong mock SY (or a misfilled seam key) surfaces here.
        assertEq(OutrunStakingPositionUpgradeable(sp).SY(), syAddress);
        // Without SP_MINTING_CAP set, the placeholder default applies.
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
        // Pins the v1 zero-fee duty default on this family's SP.
        assertEq(OutrunStakingPositionUpgradeable(sp).duty(), SPDefaults.SP_DEFAULT_DUTY);
    }

    function testSupportMockSUSDSPassesValidationAndDeploysThePosition() external {
        address syAddress = _setValidMockSupportConfig("MockSUSDSSY", mockSUSDSOracle, 1.2e18);

        script.exposedSupportMockSUSDS(2);

        address sp =
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("Mock SP sUSDS", uint256(2))));
        assertGt(sp.code.length, 0);
        // A wrapper pointed at the wrong mock SY (or a misfilled seam key) surfaces here: the
        // sUSDS wrapper must bind the sUSDS SY instance, not the aUSDC one deployed alongside it.
        assertEq(OutrunStakingPositionUpgradeable(sp).SY(), syAddress);
        assertEq(uusd.mintingCaps(sp), 1_000_000_000 ether);
        // Pins the v1 zero-fee duty default on this family's SP.
        assertEq(OutrunStakingPositionUpgradeable(sp).duty(), SPDefaults.SP_DEFAULT_DUTY);
    }

    function test_RevertWhen_SupportMockSYFamilyMismatched() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        address ausdcsSY =
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("MockAUSDCSY", uint256(1))));
        address susdsSY =
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("MockSUSDSSY", uint256(1))));
        // The aUSDC mock SY ("SY aUSDC") bound to the sUSDS family entry must revert.
        script.setMockSupportSy(ausdcsSY);
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, ausdcsSY));
        script.exposedSupportMockSUSDS(2);
        // The sUSDS mock SY ("SY sUSDS") bound to the aUSDC family entry must revert too.
        script.setMockSupportSy(susdsSY);
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, susdsSY));
        script.exposedSupportMockAUSDC(2);
    }

    /// @dev The UBNB family is v1's only multi-adapter family: the binding check admits both
    ///      BNB-family SY symbols — Lista slisBNB and Aster asBNB — while every other family
    ///      admits exactly one. The stand-in mock models the only seam this guard reads: the
    ///      reported symbol.
    function test_AssertFamilySYAdmitsBothUBNBAdapterSymbols() external {
        YieldDeployMockUniversalAsset slisBnbSY = new YieldDeployMockUniversalAsset(address(this));
        slisBnbSY.setSymbol("SY slisBNB");
        YieldDeployMockUniversalAsset asBnbSY = new YieldDeployMockUniversalAsset(address(this));
        asBnbSY.setSymbol("SY asBNB");

        SPDefaults.assertFamilySY(address(slisBnbSY), SPDefaults.FAMILY_UBNB);
        SPDefaults.assertFamilySY(address(asBnbSY), SPDefaults.FAMILY_UBNB);
    }

    /// @dev Both fail-closed legs of the UBNB branch: a symbol outside the two admitted
    ///      BNB-family symbols, and a target whose symbol() read reverts, must each fail the
    ///      binding check with MismatchedFamilySY instead of silently passing.
    function test_RevertWhen_AssertFamilyUBNBSymbolMismatchedOrUnreadable() external {
        YieldDeployMockUniversalAsset foreignSY = new YieldDeployMockUniversalAsset(address(this));
        foreignSY.setSymbol("SY wstETH");
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, address(foreignSY)));
        script.exposedAssertFamilySY(address(foreignSY), SPDefaults.FAMILY_UBNB);

        // symbol() is stubbed to revert, modelling a broken/foreign SY whose symbol read fails;
        // the same selector the guard calls it through on IERC20Metadata.
        YieldDeployMockUniversalAsset unreadableSY = new YieldDeployMockUniversalAsset(address(this));
        unreadableSY.setSymbol("SY slisBNB");
        vm.mockCallRevert(
            address(unreadableSY), abi.encodeWithSelector(YieldDeployMockUniversalAsset.symbol.selector), bytes("")
        );
        vm.expectRevert(abi.encodeWithSelector(SPDefaults.MismatchedFamilySY.selector, address(unreadableSY)));
        script.exposedAssertFamilySY(address(unreadableSY), SPDefaults.FAMILY_UBNB);
    }

    function test_RevertWhen_SupportMockAUSDCOwnerDiffersFromDeployer() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.configure(user, address(script), address(outrunDeployer));

        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedSupportMockAUSDC(2);
    }

    function test_RevertWhen_SupportMockAUSDCTreasuryIsZeroAddress() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.setMockSupportTreasury(address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
    }

    function test_RevertWhen_SupportMockAUSDCUUSDIsZeroAddress() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.setMockSupportUusd(address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
    }

    function test_RevertWhen_SupportMockAUSDCSyIsZeroAddress() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.setMockSupportSy(address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
    }

    function test_RevertWhen_SupportMockAUSDCUUSDHasNoCode() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.setMockSupportUusd(user);

        // No code check remains: the EOA staticcall to owner() succeeds with empty
        // returndata, and the returndata decoder reverts dataless outside the try/catch.
        vm.expectRevert(bytes(""));
        script.exposedSupportMockAUSDC(2);
    }

    function test_RevertWhen_SupportMockAUSDCUUSDOwnerDiffersFromScriptOwner() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        // MockUSDC carries code but is owned by this test contract, not by the configured owner.
        script.setMockSupportUusd(address(mockUSDC));

        vm.expectRevert(SPDefaults.InvalidOwner.selector);
        script.exposedSupportMockAUSDC(2);
    }

    function test_RevertWhen_SupportMockAUSDCSyExchangeRateRevertsFailClosed() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        // A zeroed oracle makes the SY's exchangeRate() revert; validation must fail closed.
        mockAUSDCOracle.setLatestAnswer(0);

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
    }

    // --- optional genesis-launcher wiring on the mock-support SP (`_supportMockSY`) ---

    /// @dev Race-free seam test for the optional genesis-launcher config: the unset injection
    ///      falls through to the script's env read, so with GENESIS_LAUNCHER absent the config
    ///      reports "not set" and the SP stays at the zero default (entry disabled).
    function testGenesisLauncherConfigDefaultsToUnsetWithoutEnv() external {
        (bool set, address genesisLauncher) = script.exposedGenesisLauncherConfig();
        assertFalse(set, "config must be unset without GENESIS_LAUNCHER");
        assertEq(genesisLauncher, address(0), "unset config carries no address");
    }

    /// @dev Configured launcher is wired onto the freshly deployed SP via setGenesisLauncher
    ///      (event + getter).
    function testSupportMockAUSDCWiresGenesisLauncherWhenConfigured() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        EmptyMockLauncher launcher = new EmptyMockLauncher();
        script.setGenesisLauncherConfig(address(launcher));
        script.setMemeverseLauncherConfig(address(launcher));

        vm.expectEmit(true, true, false, true);
        emit IOutrunStakeManager.SetGenesisLauncher(address(0), address(launcher));
        script.exposedSupportMockAUSDC(2);

        address sp =
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("Mock SP aUSDC", uint256(2))));
        assertEq(OutrunStakingPositionUpgradeable(sp).genesisLauncher(), address(launcher), "SP launcher wired");
    }

    /// @dev The SP-side genesis gate and the router-side launcher registry must target one
    ///      address: when the configured genesis launcher differs from the memeverse launcher
    ///      the mock-support wiring fails closed instead of deploying an SP whose gate diverges
    ///      from the router entries.
    function test_RevertWhen_GenesisLauncherDiffersFromMemeverseLauncher() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        EmptyMockLauncher genesisSide = new EmptyMockLauncher();
        EmptyMockLauncher routerSide = new EmptyMockLauncher();
        script.setGenesisLauncherConfig(address(genesisSide));
        script.setMemeverseLauncherConfig(address(routerSide));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
    }

    /// @dev Absent config leaves the genesis entry disabled: the SP keeps the zero default and no
    ///      wiring call is made.
    function testSupportMockAUSDCLeavesGenesisDisabledWhenConfigAbsent() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.exposedSupportMockAUSDC(2);

        address sp =
            outrunDeployer.getDeployed(address(script), keccak256(abi.encodePacked("Mock SP aUSDC", uint256(2))));
        assertEq(OutrunStakingPositionUpgradeable(sp).genesisLauncher(), address(0), "entry stays disabled");
    }

    /// @dev A configured launcher that is the zero address fails closed (InvalidAddress) rather
    ///      than silently wiring a disabled gate or reverting inside the SP setter.
    function test_RevertWhen_GenesisLauncherConfigIsZeroAddress() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.setGenesisLauncherConfig(address(0));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
    }

    /// @dev The launcher address value is operator responsibility: a codeless address is not
    ///      rejected on its own — with only the genesis side configured, the wiring fails closed
    ///      because the configured launcher differs from the unset (zero-default) memeverse
    ///      launcher.
    function test_RevertWhen_GenesisLauncherDiffersFromUnsetMemeverseLauncher() external {
        _setValidMockSupportConfig("MockAUSDCSY", mockAUSDCOracle, 1_100_000);
        script.setGenesisLauncherConfig(address(0xC0DE));

        vm.expectRevert(OutstakeScript.InvalidAddress.selector);
        script.exposedSupportMockAUSDC(2);
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
    // Pre-seeding the harness support config pins guard-BEFORE-config-read order: if the guard
    // moved after the reads, the revert would become InvalidAddress, not NotTestnetChain.
    function test_RevertWhen_ChainIsNotTestnetOnMockSupportPath() external {
        script.setMockSupportSy(address(0xA11CE));
        script.setMockSupportUusd(address(0xB0B));
        script.setMockSupportTreasury(address(0xCAFE));

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
    // and pass the gate, so this locks the full-width chainid comparison.
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
        uint32[4] memory expected = [
            uint32(31337), // Anvil local chain
            97, // BSC Testnet
            84532, // Base Sepolia
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
