// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.35;

import {UAssetHelper} from "./helpers/UAssetHelper.sol";
import {OutrunL2StakedTokenSYUpgradeable} from "../../src/yield/OutrunL2StakedTokenSYUpgradeable.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {OutrunUniversalAssetsUpgradeable} from "../../src/assets/base/OutrunUniversalAssetsUpgradeable.sol";
import {IStandardizedYield} from "../../src/yield/interfaces/IStandardizedYield.sol";
import {L2AssetValidation} from "../../script/lib/L2AssetValidation.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";
import {PositionMockToken, PositionMockOracle} from "./mocks/PositionMocks.sol";
import {SPTestDefaults} from "./helpers/SPTestDefaults.sol";

contract L2ValidationHarness {
    function validateOracleBacked(address a, uint8 d, address o) external pure {
        L2AssetValidation.validateL2OracleBackedParams(a, d, o);
    }
}

/// @title L2OracleBackedInitTest — decimals mis-scale regression
/// @notice Validates that L2 oracle-backed SY `underlyingAssetOnEthDecimals` must be cross-checked
/// off-chain against L1 truth before broadcast. L2 cannot call `IERC20Metadata.decimals()` on L1 without
/// a bridge, so a typo (e.g. 18 vs 6) is silently cached by `OutrunStakingPositionUpgradeable.initialize`
/// as `canonicalAssetDecimals` and mis-scales `principalDebt` / `syToAsset` by `10**|delta|` (1e12 for 6↔18).
/// This suite proves: (1) `L2AssetValidation` fail-fasts known-family and bounds errors at deploy time,
/// and (2) the downstream Position mis-scale is deterministic and 1e12 for the 6↔18 case.
contract L2OracleBackedInitTest is UAssetHelper {
    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE);
    PositionMockToken internal token;
    PositionMockOracle internal oracle;
    address internal L1_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // Use a non-stETH L1 address to exercise the generic 1..18 path (USDC on L1).
    address internal L1_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() external {
        token = new PositionMockToken();
        oracle = new PositionMockOracle();
    }

    // --- L2AssetValidation unit ---

    function test_RevertWhen_KnownAssetDecimalsWrong() external {
        L2ValidationHarness h = new L2ValidationHarness();
        vm.expectRevert(
            abi.encodeWithSelector(L2AssetValidation.L2InvalidDecimalsForKnownAsset.selector, L1_STETH, 18, 6)
        );
        h.validateOracleBacked(L1_STETH, 6, address(oracle));
    }

    function test_RevertWhen_DecimalsZeroOrOutOfRange() external {
        L2ValidationHarness h = new L2ValidationHarness();
        vm.expectRevert(L2AssetValidation.L2InvalidDecimalsZero.selector);
        h.validateOracleBacked(L1_USDC, 0, address(oracle));

        vm.expectRevert(abi.encodeWithSelector(L2AssetValidation.L2InvalidDecimalsOutOfRange.selector, 19));
        h.validateOracleBacked(L1_USDC, 19, address(oracle));

        vm.expectRevert(abi.encodeWithSelector(L2AssetValidation.L2InvalidDecimalsOutOfRange.selector, 255));
        h.validateOracleBacked(L1_USDC, 255, address(oracle));
    }

    function test_PassWhen_GenericAssetInRange() external {
        L2ValidationHarness h = new L2ValidationHarness();
        h.validateOracleBacked(L1_USDC, 6, address(oracle));
        h.validateOracleBacked(L1_USDC, 18, address(oracle));
    }

    function test_PassWhen_KnownAssetCorrect() external {
        L2ValidationHarness h = new L2ValidationHarness();
        h.validateOracleBacked(L1_STETH, 18, address(oracle));
    }

    // --- Integration: assetInfo -> Position canonicalAssetDecimals caching ---

    function test_PositionCachesDecimalsFromAssetInfo() external {
        OutrunL2StakedTokenSYUpgradeable sy6 = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY6", "SY6", owner, address(token), address(oracle), L1_USDC, 6)
                    )
                ))
        );
        OutrunL2StakedTokenSYUpgradeable sy18 = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY18", "SY18", owner, address(token), address(oracle), L1_USDC, 18)
                    )
                ))
        );

        (,, uint8 d6) = IStandardizedYield(address(sy6)).assetInfo();
        (,, uint8 d18) = IStandardizedYield(address(sy18)).assetInfo();
        assertEq(d6, 6, "sy6 decimals");
        assertEq(d18, 18, "sy18 decimals");

        OutrunStakingPositionUpgradeable pos6 = _deployPosition(address(sy6), 6);
        OutrunStakingPositionUpgradeable pos18 = _deployPosition(address(sy18), 18);

        // Position freezes decimals at initialize — no setter exists post-deploy
        assertEq(_canonicalDecimals(pos6), 6);
        assertEq(_canonicalDecimals(pos18), 18);
    }

    function test_MisScale_Is1e12_For6vs18() external {
        // Directly proves the mis-scale math: syToAsset / wrap debt scales by 10**|delta|
        OutrunL2StakedTokenSYUpgradeable sy6 = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY6", "SY6", owner, address(token), address(oracle), L1_USDC, 6)
                    )
                ))
        );
        OutrunL2StakedTokenSYUpgradeable sy18 = OutrunL2StakedTokenSYUpgradeable(
            payable(ProxyTestHelper.deploy(
                    address(new OutrunL2StakedTokenSYUpgradeable()),
                    abi.encodeCall(
                        OutrunL2StakedTokenSYUpgradeable.initialize,
                        ("SY18", "SY18", owner, address(token), address(oracle), L1_USDC, 18)
                    )
                ))
        );

        // uAsset with 18 decimals so canonical 6 vs 18 diverges: amount 1e6 uUnits
        OutrunStakingPositionUpgradeable pos6 = _deployPosition(address(sy6), 18);
        OutrunStakingPositionUpgradeable pos18 = _deployPosition(address(sy18), 18);

        // Exercise the production scaling path through the public preview view: at the fixture's
        // 1e18 rate both positions convert the same SY to the same canonical value, and the
        // canonical -> uAsset rescale must differ by exactly 10**12 (6 vs 18 canonical decimals
        // against an 18-decimal uAsset).
        uint256 amountInSY = 10e18;
        uint256 preview6 = pos6.previewStake(amountInSY);
        uint256 preview18 = pos18.previewStake(amountInSY);
        assertEq(preview6 / preview18, 1e12, "6 vs 18 mis-scale is 1e12");
        assertEq(preview6, preview18 * 1e12);
    }

    // --- helpers ---

    function _deployPosition(address sy, uint8 uAssetDecimals) internal returns (OutrunStakingPositionUpgradeable) {
        OutrunUniversalAssetsUpgradeable uAsset = _deployUAsset(owner, uAssetDecimals);
        OutrunStakingPositionUpgradeable pos = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                SPTestDefaults.spInitCall(owner, sy, address(uAsset), treasury)
            )
        );
        vm.prank(owner);
        uAsset.setMintingCap(address(pos), type(uint256).max);
        return pos;
    }

    function _canonicalDecimals(OutrunStakingPositionUpgradeable pos) internal view returns (uint8) {
        bytes32 base = _erc7201("outrun.storage.OutrunStakingPosition");
        bytes32 slot0 = vm.load(address(pos), base);
        // OutrunStakingPositionStorage packing: address SY (20 bytes) + uint8 canonicalAssetDecimals + uint8 uAssetDecimals
        // In Solidity packing, those two uint8 follow the address in the same slot.
        // slot0 = ... | uAssetDecimals (1 byte) | canonicalAssetDecimals (1 byte) | SY (20 bytes) with packing offset.
        // Extract canonicalAssetDecimals at byte 20 (little-endian packing: address low 20 bytes, then canonical, then u)
        // Forge vm.load returns left-padded 32 bytes; address occupies lower 20 bytes of slot.
        // So canonical is byte 20 from left? Use shift/mask via assembly-style extraction.
        uint256 s = uint256(slot0);
        // layout: slot0 = [12 zero bytes][SY 20 bytes][canonical 1][u 1][... padding? actually minStake etc are next slots]
        // Address is right-aligned in lower 160 bits of 256, but packing puts uint8 immediately after address in higher bits?
        // Solidity packs from right: first variable at lowest bytes. So SY (address) at bytes 0-19, canonical at byte 20, u at byte 21.
        uint8 canonical = uint8((s >> (20 * 8)) & 0xFF);
        return canonical;
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
