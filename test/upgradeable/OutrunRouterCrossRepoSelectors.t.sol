// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {IMemeverseLauncher} from "../../src/router/interfaces/IMemeverseLauncher.sol";
import {IPOLendGenesis} from "../../src/router/interfaces/IPOLendGenesis.sol";
import {IGenesisCreditFactory} from "../../src/router/interfaces/IGenesisCreditFactory.sol";

// 跨仓真实接口（`memeverse/` remapping 指向同级 Memeverse 仓的 src/；foundry 拒绝项目根之外的
// 相对路径 import，故经 remappings.txt + foundry.toml allow_paths 引入。其 IMemeverseLauncher 只依赖
// 两个无依赖类型文件，IPOLend/IGenesisCreditFactory 无 import，pragma 均为 ^0.8.35）。
import {IMemeverseLauncher as RealLauncher} from "memeverse/verse/interfaces/IMemeverseLauncher.sol";
import {IPOLend as RealPOLend} from "memeverse/polend/interfaces/IPOLend.sol";
import {IGenesisCreditFactory as RealCreditFactory} from "memeverse/credit/interfaces/IGenesisCreditFactory.sol";

/**
 * @title OutrunRouterCrossRepoSelectorsTest
 * @notice 锁定 OutStake 侧最小接口与 Memeverse 真实接口的 selector 一致性：两侧仓库各自以
 *     mock/最小接口独立测试，selector 漂移无法被任一侧单独发现（uint128/uint256 历史漂移即由此
 *     产生），本文件以真实接口为锚把漂移变成编译期/测试期失败。
 */
contract OutrunRouterCrossRepoSelectorsTest is Test {
    function test_LauncherSelectorsMatchMemeverseInterfaces() external pure {
        assertEq(IMemeverseLauncher.genesis.selector, RealLauncher.genesis.selector, "genesis selector drift");
        assertEq(IMemeverseLauncher.preorder.selector, RealLauncher.preorder.selector, "preorder selector drift");
        assertEq(
            IMemeverseLauncher.getUAssetByVerseId.selector,
            RealLauncher.getUAssetByVerseId.selector,
            "getUAssetByVerseId selector drift"
        );
    }

    function test_PolendSelectorsMatchMemeverseInterfaces() external pure {
        assertEq(
            IPOLendGenesis.leveragedGenesis.selector,
            RealPOLend.leveragedGenesis.selector,
            "leveragedGenesis selector drift"
        );
        assertEq(
            IPOLendGenesis.leveragedGenesisWithCredit.selector,
            RealPOLend.leveragedGenesisWithCredit.selector,
            "leveragedGenesisWithCredit selector drift"
        );
        assertEq(IPOLendGenesis.marketUAsset.selector, RealPOLend.marketUAsset.selector, "marketUAsset selector drift");
        // Memeverse declares `creditFactory()` only on the concrete POLendUpgradeable
        // (POLendUpgradeable.sol:655), not on IPOLend, so this one selector anchors to the canonical
        // signature hash instead of an interface member.
        assertEq(
            IPOLendGenesis.creditFactory.selector, bytes4(keccak256("creditFactory()")), "creditFactory selector drift"
        );
        assertEq(
            IGenesisCreditFactory.creditOf.selector, RealCreditFactory.creditOf.selector, "creditOf selector drift"
        );
    }
}
