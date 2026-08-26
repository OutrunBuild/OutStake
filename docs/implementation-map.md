# OutStakeV2 Implementation Map

## 文档目的

本文档用于给出 `OutStakeV2` 当前实现面的结构化映射，说明各 surface 的本地依赖、证据来源与当前状态。

本文档只描述本仓库当前源码、测试与部署入口能够直接证明的实现事实。凡涉及外部协议、oracle、跨链消息、launcher 或 vault 行为，而本仓库无法单独证明其真实线上表现者，均作为本地依赖边界陈述，不升级为既成事实。

Surface Map 的收录范围：产品合约 surface、`src/libraries/oracle/` 的 oracle adapter，以及部署与支撑入口。共享纯库层（`src/libraries/` 顶层共享库与 vendored OpenZeppelin `ReentrancyGuardTransient.sol`）不在本表逐行展开，其逐文件职责与契约以 `docs/spec/common-foundations.md` 为真源；各集成协议的接口层枚举见 `docs/ARCHITECTURE.md`。

## Surface Map

职责与权限边界不在此表重复：见 `docs/spec/access-control.md`（权限真源）与 `docs/ARCHITECTURE.md`（模块地图）。本表只维护 surface → 本地依赖 → 证据 → 当前状态。

| surface | key local dependencies | evidence source | current state |
| --- | --- | --- | --- |
| `OutrunUniversalAssetsUpgradeable` | `IUniversalAssets`、`OutrunOFTUpgradeable`、`OwnableUpgradeable`、position/router 下游对 `mint/repay` 的调用 | `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`；`test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol` | 已实现且有直接测试，覆盖 mint cap、repay 与基础 OFT 安全边界 |
| `OutrunOFTUpgradeable` | `OutrunERC20PausableUpgradeable`、`OFTCoreUpgradeable`、`OutrunRateLimiterUpgradeable` | `src/assets/omnichain/OutrunOFTUpgradeable.sol`；`test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol`；`test/upgradeable/OutrunOFTUpgradeable.t.sol` | 已实现；本地证明了 token、rate-limit 行为，以及 `quoteOFT()` 对当前 outbound capacity 与 shared-decimal envelope 的约束；`_toSD`、`AmountSDOverflowed`、wire encoding 与 `lzReceive` 路径尚未在本地 OFT 测试中直接覆盖 |
| `OutrunStakingPositionUpgradeable` | `IStandardizedYield.exchangeRate/redeem/previewRedeem`、`IUniversalAssets.mint/repay`、`SYUtils`、`TokenHelper` | `src/position/OutrunStakingPositionUpgradeable.sol`；`test/upgradeable/OutrunStakingPositionUpgradeable.t.sol`；`test/upgradeable/OutrunStakingPositionFuzzUpgradeable.t.sol` | 已实现且核心路径有测试，覆盖 stake、draw、redeem、keepRedeem、wrapStake、keepWrapRedeem、harvestWrapYield |
| `OutrunRouter` | `IStandardizedYield`、`IOutrunStakeManager`、`IOutrunRouter`、`IMemeverseLauncher`、`TokenHelper` | `src/router/OutrunRouter.sol`；`test/upgradeable/OutrunRouterUpgradeable.t.sol`；`test/upgradeable/OutrunRouterFuzzUpgradeable.t.sol`；`test/upgradeable/RouterProxyIntegration.t.sol` | 已实现且关键路由路径有测试；registry 校验在 pull/approve 前拒绝未登记或 canonical SY 不匹配的 target，并覆盖撤销后的后续失败；核对 launcher 轮换的 `IOutrunRouter.sol::SetMemeverseLauncher` 事件及旧、新 launcher 值作为部署验收项（事件已实现并有单元测试覆盖）；其余证据覆盖 caller-funded pull、wrap/genesis 路径与 `minSyOut` / `minUAssetMinted` 滑点下限；`minTokenOut` 的 Router mock 路径由 `test/upgradeable/OutrunRouterUpgradeable.t.sol::testRedeemSyToTokenRevertsWhenTokenOutputIsBelowMinimum`、`test/upgradeable/OutrunRouterUpgradeable.t.sol::testRedeemSyToTokenRevertsWhenRedeemAmountIsZero`、`test/upgradeable/OutrunRouterUpgradeable.t.sol::testRedeemSyToTokenRevertsWhenTokenOutIsInvalid` 覆盖；真实 proxy-backed 路径由 `test/upgradeable/RouterProxyIntegration.t.sol::testRouterRedeemSyToTokenUsesProxyBackedContracts` 与 `test/upgradeable/RouterProxyIntegration.t.sol::testRouterRedeemSyToTokenRevertsWhenMinimumIsTooHigh` 覆盖，成功路径断言 `burnFromInternalBalance=true` 的内部 SY 余额消耗与 backing 保留，minimum-too-high 路径断言 user/internal SY、SY backing、receiver token 与 allowance 的 atomic rollback |
| `SYBaseUpgradeable` | `OutrunERC20PausableUpgradeable`、`TokenHelper`、`IStandardizedYield` | `src/yield/SYBaseUpgradeable.sol`；`test/upgradeable/SYUpgradeable.t.sol` | 当前产品真源；基础输入守卫与存款零输出守卫（`SYZeroSharesOut`）、pause、initializer、trusted-router 配置与 UUPS 边界由 upgradeable 测试覆盖 |
| `SY adapter upgradeable families` | `*SYUpgradeable`、外部协议 interfaces、`AaveAdapterLib`、`IExchangeRateOracle` | `src/yield/**/*SYUpgradeable.sol`；`test/upgradeable/SYAdaptersUpgradeable.t.sol`；`test/upgradeable/OracleSetterUpgradeable.t.sol` | 当前产品真源；逐 adapter 证据见 `docs/spec/yield/yield-adapters.md` Adapter Evidence Matrix |
| `OutrunExchangeOracleAdapter` | `AggregatorInterface`、`IExchangeRateOracle` | `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`；`test/support/MockOracleWarnings.t.sol` | 校验语义与错误面见 `docs/spec/yield/oracles-and-integrations.md`；已实现并有 `test/support/MockOracleWarnings.t.sol` 覆盖 |
| `deployment scripts` | `OutstakeScript.s.sol`、`YieldDeployScript.s.sol`、`OutrunDeployer.sol`、`SYBaseUpgradeable.sol`、`IOutrunRouter.sol`、测试 support 合约 | `script/deploy/OutstakeScript.s.sol`；`script/deploy/YieldDeployScript.s.sol`；`script/deploy/deployment/OutrunDeployer.sol`；`docs/deployment.md` | 已实现；部署验收应按 SY 注册 -> SP -> SY pair 注册 -> trusted-router wiring 顺序核对 getter/event 后再开放入口；registry 与 launcher setter 为持续 live 的 owner 能力（见 `docs/spec/protocol.md`「router」）；脚本中的注释分支不能据此推导某链上实例已实际完成配置 |

## Test / Process Mapping Status

当前测试证据主要集中在 `test/upgradeable` 与 `test/support`。收益层当前证据以 `test/upgradeable/SYUpgradeable.t.sol`、`test/upgradeable/SYAdaptersUpgradeable.t.sol`、`test/upgradeable/OracleSetterUpgradeable.t.sol` 为准。

当前 Harness 证据来自 `README.md`、`.harness/policy.json` 与 `script/harness/gate.sh`。仓库当前统一入口为 `npm run gate:fast`、`npm run gate`、`npm run gate:ci`；它们按 policy 选择 changed files、writer/reviewer 角色、verification profile 与 run-record 输出。`docs/spec/**` 的真实性仍主要依赖源码与测试可回溯性，而不是单独文档脚本赋予的通过状态。
