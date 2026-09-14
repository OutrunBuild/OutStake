# OutStake Testing And Evidence

## 测试布局

当前产品证据主要分布在：

- `test/upgradeable/`
- `test/psm/`
- `test/usr/`
- `test/deploy/`
- `test/support/`

`test/upgradeable/` 是当前产品测试主入口，覆盖 upgradeable assets、position、router proxy integration、SY base、proxy-backed adapters、oracle setter、SY adapter fork coverage、fuzz、invariant、adversarial cases，以及 Sky L2 SSR 偏差守卫 invariant（由 `SkyL2DeviationGuardInvariantUpgradeable.t.sol` 驱动真实 `OutrunL2StakedUsdsSYUpgradeable`）。`SYAdaptersFork.t.sol` 中已有固定 block 的 Ethereum mainnet、BSC mainnet 与 Base mainnet fork evidence；没有固定 block 的 fork 结果不得作为可审计 pinned-block evidence。

`test/psm/` 覆盖 PSM（`OutrunPSMUpgradeable` 的双向兑换 roundtrip、费率与 cap 边界、储备守恒式与 minter 台账豁免）；`test/usr/` 覆盖 USR vault（`OutrunUSRVaultUpgradeable` 的存取计息、硬预算封顶停摆与恢复、无回收入口与参数边界）。

`test/deploy/` 覆盖 upgradeable deployment scripts。

`test/support/` 保留 library 与 token helper 测试证据及 Faucet 等 helper 合约；mock 与 harness 位于 `test/support/mocks/`。

`test/{assets,integration,position,router,security,yield}/` 当前不承载 `.sol` 测试文件。

## 直接证据

- `OutrunUniversalAssetsUpgradeable` 的 mint cap、repay、OFT shared-decimal envelope 与 rate-limit quote。
- `OutrunOFTUpgradeable` 的 OFT shared-decimal envelope 与 rate-limit quote。
- `OutrunStakingPositionUpgradeable` 的 genesis-only 面：唯一铸造入口（`stakeForGenesis`，面值铸造）、virtual accrual 计息（v1 默认零费，含利率分段变更）、任意时刻双腿销债赎回（`redeem`）与四 setter（`setDuty` / `setGenesisLauncher` / `setMinStake` / `setProtocolTreasury`）。
- `OutrunPSMUpgradeable` 的双向兑换、费率与 cap 边界、储备守恒式与 minter 台账豁免（`test/psm/OutrunPSM.t.sol`，验收清单见 `docs/spec/psm/peg-stability-module.md`）。
- `OutrunUSRVaultUpgradeable` 的存取计息 roundtrip、硬预算封顶停摆与恢复、无回收入口与参数边界（`test/usr/OutrunUSRVault.t.sol`，验收清单见 `docs/spec/usr/usr-vaults.md`）。
- `test/upgradeable/OutrunStakingPositionStorageLayout.t.sol` 验证 position ERC-7201 namespace 的 `SY` 与两个 decimals 共用 slot0。
- `SkyL2DeviationGuardInvariantUpgradeable` 的 SSR-vs-PSM 偏差守卫双侧不变量：`OutrunL2StakedUsdsSYUpgradeable.sol::exchangeRate` 要么精确返回 SSR 换算率且偏差 ≤ `maxDeviationBps`，要么以 `RateDeviationExceeded` 精确回退；严格 `>` 边界有确定性钉。
- `OutrunRouter` 的 caller-funded pull 模式、native/erc20 输入约束与 genesis 双路径（路径 A `OutrunRouter.sol::genesisByPSM` 为 router 侧 PSM 门，含 PSM registry 登记与撤销；路径 B `::genesisBySY` / `::genesisByToken` 薄转发至 SP 原生物理门 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`，router 路径 B 不触碰 uAsset、SP 侧错误透传）mock 路径。
- target registry 的 owner-only `OutrunRouter.sol::setTrustedSY` / `OutrunRouter.sol::setTrustedSP`、未登记 SP 在 pull 前回退（`OutrunRouterUpgradeable.t.sol::test_RevertWhen_GenesisByTokenTargetsUnregisteredSP`，以 `UntrustedRouterTarget` 验证 pull 前拒绝）以及登记 SY 与 `SP.SY()` 不匹配时回退（`OutrunRouterUpgradeable.t.sol::test_RevertWhen_SetTrustedSPRegisteredSYDoesNotMatchSP`），撤销后拒绝时序由同文件 `test_RevertWhen_GenesisByPSMAfterRevocation` 等撤销场景间接体现。
- `SYBaseUpgradeable` 的 initializer、pause、redeem 重入边界，以及 trusted-router 配置与权限边界：owner-only setter、零地址撤销、trusted caller 的 `redeem(..., true)`、非 trusted caller 的 `SYUnauthorizedInternalRedeemer` 回退、router 替换后旧 caller 失效、`redeem(..., false)` 的 caller 余额直兑。
- proxy-backed SY adapters 的核心 deposit / redeem / preview / exchangeRate 行为。
- oracle-backed upgradeable SY variants 的 owner-only 边界（`setExchangeRateOracle(address)` / `resetRateAnchor()` / `setRateBreakerParams(uint16,uint16,uint16)`）与 `commitRateAnchor()` 的 permissionless 边界（带内推进锚点、带外 revert `RateDeviationExceeded`）。
- `OutstakeScript` 与 `YieldDeployScript` 的 upgradeable deployment evidence。

## Harness 映射

`.harness/policy.json` 的 `test_mapping` 当前把证据归到：

- assets：`test/upgradeable/OutrunOFTUpgradeable.t.sol`、`test/upgradeable/OutrunRateLimiterStorageLayout.t.sol`、`test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol`
- position：`test/upgradeable/OutrunStakingPositionUpgradeable.t.sol`、`test/upgradeable/OutrunStakingPositionFuzzUpgradeable.t.sol`、`test/upgradeable/OutrunStakingPositionInvariantUpgradeable.t.sol`、`test/upgradeable/OutrunStakingPositionStorageLayout.t.sol`
- psm：`test/psm/OutrunPSM.t.sol`
- usr：`test/usr/OutrunUSRVault.t.sol`
- router：`test/upgradeable/OutrunRouterUpgradeable.t.sol`、`test/upgradeable/OutrunRouterFuzzUpgradeable.t.sol`、`test/upgradeable/RouterProxyIntegration.t.sol`、`test/upgradeable/RouterReentrancyGuardUpgradeable.t.sol`、`test/upgradeable/RouterEndToEndConservationUpgradeable.t.sol`
- yield：`test/upgradeable/SYUpgradeable.t.sol`、`test/upgradeable/SYAdaptersUpgradeable.t.sol`、`test/upgradeable/SYAdaptersFork.t.sol`、`test/upgradeable/OracleSetterUpgradeable.t.sol`、`test/upgradeable/SweepResidual.t.sol`、`test/upgradeable/SYPerActorConservationUpgradeable.t.sol`、`test/upgradeable/SkyL2DeviationGuardInvariantUpgradeable.t.sol`、`test/upgradeable/CrossBlockPreviewDriftUpgradeable.t.sol`、`test/upgradeable/L2OracleBackedInit.t.sol`、`test/upgradeable/L2OracleRateBreakerUpgradeable.t.sol`（oracle-backed 基类锚点偏差熔断专项套件，已同步 policy.json test_mapping）
- deployment：`test/deploy/OutstakeScriptUpgradeable.t.sol`、`test/deploy/YieldDeployScriptUpgradeable.t.sol`、`test/upgradeable/OutstakeScriptMockSYDeploy.t.sol`、`test/deploy/OutstakeRouterDriftFix.t.sol`
- libraries：`test/support/Libraries.t.sol`、`test/support/TokenHelper.t.sol`、`test/support/MockOracleWarnings.t.sol`
- security：`test/upgradeable/AdversarialTestsUpgradeable.t.sol`（该域 rule paths 当前仅覆盖 `^src/position/.*\.sol$`——文件含 `AdversarialTests`/`PositionReentrancyTest`（被测对象为 OutrunStakingPositionUpgradeable，mock SY 栈）与 `OracleFailClosedTest`（真实 `OutrunExchangeOracleAdapter` → 真实 `OutrunL2StakedTokenSYUpgradeable` proxy（含真实 `OutrunUniversalAssetsUpgradeable`）的 stale-feed fail-closed 链路））

## 仍需留意

- 外部协议真实结算、价格更新、队列、权限和可用性仍属于外部依赖。
- 当前测试更偏向统一 proxy-backed 回归，而非每个 adapter 的独立专项集。
- Target registry 的部署验收还需记录完整 target 清单、`TrustedSYUpdated` / `TrustedSPUpdated` 事件、`trustedSY` / `trustedSYForSP` 读取值，以及撤销后用户余额和 allowance 未变化；当前单元测试证明本地拒绝时序，不证明某条链上实例已经完成 registry wiring 或主网 launcher-only freeze（constructor 值 + `memeverseLauncher` getter；registry 持续 live，不冻结）。
- Launcher 轮换属于待完成的部署期验收：应记录 `OutrunRouter.sol::memeverseLauncher` 的旧、新值，并确认成功调用 `OutrunRouter.sol::setMemeverseLauncher` 发出的 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）；该事件已实现，当前以 zero/codeless 两用例的 expectEmit 断言正路径首调用的事件发射（含 indexed old/new：`OutrunRouterUpgradeable.t.sol::test_SetMemeverseLauncherAcceptsZeroAddress`、`OutrunRouterUpgradeable.t.sol::test_SetMemeverseLauncherAcceptsCodelessAddress`；`OutrunRouterUpgradeable.t.sol::test_ConstructorAcceptsZeroMemeverseLauncher` 仅 getter 断言、无事件；零地址/EOA 在配置期静默接受），部署验收证据待补；生产 release 无 setter 轮换步骤（冻结证据为 constructor 值 + getter）。SP 侧 genesis launcher 布线同属验收项：记录 `OutrunStakingPositionUpgradeable.sol::setGenesisLauncher` 发出的 `SetGenesisLauncher(oldLauncher, newLauncher)` 事件与 `OutrunStakingPositionUpgradeable.sol::genesisLauncher` 读取值，并断言与 router 侧同址（`SP.genesisLauncher() == router.memeverseLauncher()`；布线见 `docs/deployment.md`「genesis 门控布线」）。
- 主网 release evidence 需额外确认 registry 首批清单、`TrustedSYUpdated`/`TrustedSPUpdated` 事件与对应 getter 读取值已完成验收；registry 为持续 live 能力（见 `docs/spec/protocol.md`「router」），不存在冻结/移除 setter 的发布步骤，不能把当前分支的部署期 setter 暴露当作主网完成证据。`SetMemeverseLauncher` 的生产验收为 constructor 值 + `memeverseLauncher` getter（冻结证据），无 setter 轮换步骤。
- `npm run test:fork` 当前运行 `SYAdaptersFork.t.sol` 的 pinned fork coverage：Ethereum mainnet block `25_108_887`、BSC mainnet block `98_653_065` 与 Base mainnet block `46_080_598`。只有测试显式固定 block number 并记录可复现 trace 后，运行结果才可作为 pinned-block evidence；当前仓内 fork 环境变量名是 `ETHEREUM_MAINNET_RPC`、`BSC_MAINNET_RPC` 和 `BASE_MAINNET_RPC`，不得改写为 `MAINNET_RPC_URL`、`BSC_RPC_URL` 或其他别名。
