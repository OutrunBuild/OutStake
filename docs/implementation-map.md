# OutStakeV2 Implementation Map

## 文档目的

本文档用于给出 `OutStakeV2` 当前实现面的结构化映射，说明各 surface 的职责、权限边界、本地依赖、证据来源与当前状态。

本文档只描述本仓库当前源码、测试与部署入口能够直接证明的实现事实。凡涉及外部协议、oracle、跨链消息、launcher 或 vault 行为，而本仓库无法单独证明其真实线上表现者，均作为本地依赖边界陈述，不升级为既成事实。

## Surface Map

| surface | core responsibility | authority/roles | key local dependencies | evidence source | current state |
| --- | --- | --- | --- | --- | --- |
| `OutrunUniversalAssetsUpgradeable` | 作为统一 `uAsset` 资产层，维护按 minter 维度的 mint cap、已铸造债务、`mint` 与 `repay` 路径 | `owner` 可设置或撤销 minter cap；被授权 minter 可在额度内铸造并回收自身债务 | `IUniversalAssets`、`OutrunOFTUpgradeable`、`OwnableUpgradeable`、position/router 下游对 `mint/repay` 的调用 | `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`；`test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol` | 已实现且有直接测试，覆盖 mint cap、repay 与基础 OFT 安全边界 |
| `OutrunOFTUpgradeable` | 为 `uAsset` 提供 ERC20、pause 与 OFT 跨链铸烧表面 | OFT delegate/peer 配置由上层 owner 流程控制 | `OutrunERC20PausableUpgradeable`、`OFTCoreUpgradeable`、`OutrunRateLimiterUpgradeable` | `src/assets/omnichain/OutrunOFTUpgradeable.sol`；`test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol`；`test/upgradeable/OutrunOFTUpgradeable.t.sol` | 已实现；本地证明了 token、`_toSD`、rate-limit 行为，以及 `quoteOFT()` 对当前 outbound capacity 与 shared-decimal envelope 的约束 |
| `OutrunStakingPositionUpgradeable` | 管理锁仓仓位、可追加 `uAsset` 债务、到期赎回、keeper 代偿赎回、公共 wrap 池与 wrap 收益 harvest | `owner` 可 pause、配置 `minStake/uAsset/revenuePool/keeper`；`position owner` 管理自身仓位；`keeper` 仅能执行 `keepRedeem`；普通用户可进入 wrap 池 | `IStandardizedYield.exchangeRate/redeem/previewRedeem`、`IUniversalAssets.mint/repay`、`SYUtils`、`TokenHelper` | `src/position/OutrunStakingPositionUpgradeable.sol`；`test/upgradeable/OutrunStakingPositionUpgradeable.t.sol`；`test/upgradeable/OutrunStakingPositionFuzzUpgradeable.t.sol` | 已实现且核心路径有测试，覆盖 stake、draw、redeem、keepRedeem、wrapStake、wrapRedeem、harvestWrapYield |
| `OutrunRouter` | 把 `token <-> SY <-> staking position/uAsset` 组合为单次入口，并承接 `memeverseLauncher` genesis 集成 | `owner` 可更新 `memeverseLauncher`；调用者负责提供输入资产与授权；router 本身不承担独立资金池角色 | `IStandardizedYield`、`IOutrunStakeManager`、`IMemeverseLauncher`、`TokenHelper` | `src/router/OutrunRouter.sol`；`test/upgradeable/OutrunRouterUpgradeable.t.sol`；`test/upgradeable/OutrunRouterFuzzUpgradeable.t.sol`；`test/upgradeable/RouterProxyIntegration.t.sol` | 已实现且关键路由路径有测试，已证明 caller-funded pull 模式、wrap 路径、mock `genesisBySY` 的锁仓路径、`genesisByToken` 的直接 fuzz 覆盖，以及 `minSyOut` / `minUAssetMinted` / `minTokenOut` 滑点下限 |
| `SYBaseUpgradeable` | 定义 proxy-backed SY 份额层抽象，提供 `deposit/redeem/preview/exchangeRate`、token 合法性检查、重入保护与 UUPS authority | `owner` 继承自 upgradeable pausable/ownable 资产；用户通过统一入口申赎份额 | `OutrunERC20PausableUpgradeable`、`TokenHelper`、`IStandardizedYield` | `src/yield/SYBaseUpgradeable.sol`；`test/upgradeable/SYUpgradeable.t.sol` | 当前产品真源；基础输入守卫、pause、initializer 与 UUPS 边界由 upgradeable 测试覆盖 |
| `SY adapter upgradeable families` | 将 Aave、EtherFi、Lido、Sky、Ethena、Lista、Aster 等收益资产封装为 proxy-backed SY | 用户申赎；owner 管理 pause、UUPS upgrade，oracle-backed 变体可更新 `exchangeRateOracle` | `*SYUpgradeable`、外部协议 interfaces、`AaveAdapterLib`、`IExchangeRateOracle` | `src/yield/**/*SYUpgradeable.sol`；`test/upgradeable/SYAdaptersUpgradeable.t.sol`；`test/upgradeable/OracleSetterUpgradeable.t.sol` | 当前产品真源；旧非 upgradeable SY 合约与测试后续 Solidity phase 删除，不再作为当前证据 |
| `OutrunExchangeOracleAdapter` | 通过 `latestRoundData()` 读取聚合器并标准化为 `IExchangeRateOracle.getExchangeRate()` 输出 | 无仓库内业务角色写权限；构造后参数不可变，调用方为各 L2 adapter | `AggregatorInterface`、`IExchangeRateOracle` | `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`；`test/support/MockOracleWarnings.t.sol` | 已实现；本地逻辑做 raw answer 正值检查、`maxStaleness` 新鲜度窗口校验（含 `updatedAt == 0` fail-closed）与可选构造期 L2 sequencer 校验后再做 decimals 归一化，不提供 bounds/fallback/多源聚合；底层 oracle 数据真实性属于外部依赖边界 |
| `deployment scripts` | 提供当前仓库的部署与接入入口，连接 `uAsset`、router、SY、position、mock、跨链 peer 与 CREATE3 deployer | 依赖环境变量提供 `owner/keeper/revenuePool/launcher/endpoints` 等配置；`OutrunDeployer` 为 owner-only | `OutstakeScript.s.sol`、`YieldDeployScript.s.sol`、`OutrunDeployer.sol`、测试 support 合约 | `script/deploy/OutstakeScript.s.sol`；`script/deploy/YieldDeployScript.s.sol`；`script/deploy/deployment/OutrunDeployer.sol` | 已实现；脚本表明当前仓库具备部署入口，但脚本中含注释分支，不能据此推导某链上实例已实际部署或已完成配置 |

## Test / Process Mapping Status

当前测试证据主要集中在 `test/upgradeable` 与 `test/support`。收益层当前证据以 `test/upgradeable/SYUpgradeable.t.sol`、`test/upgradeable/SYAdaptersUpgradeable.t.sol`、`test/upgradeable/OracleSetterUpgradeable.t.sol` 为准。

当前 Harness 证据来自 `README.md`、`.harness/policy.json` 与 `script/harness/gate.sh`。仓库当前统一入口为 `npm run gate:fast`、`npm run gate`、`npm run gate:ci`；它们按 policy 选择 changed files、writer/reviewer 角色、verification profile 与 run-record 输出。`docs/spec/**` 的真实性仍主要依赖源码与测试可回溯性，而不是单独文档脚本赋予的通过状态。
