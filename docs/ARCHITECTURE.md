# OutStakeV2 架构总览

## 1. 模块地图

### 1.1 资产层

- `src/assets/base/OutrunERC20Upgradeable.sol`
- `src/assets/base/OutrunERC20PausableUpgradeable.sol`
- `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`
- `src/assets/omnichain/OutrunOFTUpgradeable.sol`
- `src/assets/omnichain/OutrunRateLimiterUpgradeable.sol`（共享 OFT outbound rate-limit 抽象基类）
- `src/assets/interfaces/IUniversalAssets.sol`
- uAsset 统一债务与流通资产层，维护按 minter 维度的 mint cap / 已铸造债务 / mint / repay 路径，并继承 ERC20 / pause / OFT 跨链铸烧能力。
- 当前 state-bearing uAsset 使用 `Upgradeable` 后缀变体并通过 `ERC1967Proxy` + UUPS 部署；旧非 upgradeable 合约已退出当前产品真源。
- `OutrunUniversalAssetsUpgradeable` 直接继承 `UUPSUpgradeable`；其自定义 `OutrunOFTUpgradeable` 基于 LayerZero 官方 `OFTCoreUpgradeable` / `OAppUpgradeable` 路径，保留自定义 ERC20 metadata/decimals，不在需要自定义 metadata/decimals 时继承默认 `OFTUpgradeable`。

### 1.2 仓位层

- `src/position/OutrunStakingPositionUpgradeable.sol`
- `src/position/interfaces/IOutrunStakeManager.sol`
- 管理锁仓仓位、可追加 uAsset 债务、到期赎回、keeper 代偿赎回、公共 wrap 池与 wrap 收益 harvest。
- `OutrunStakingPositionUpgradeable` 作为 UUPS implementation 部署在 `ERC1967Proxy` 后；`SY`、`uAsset`、keeper、revenuePool 等依赖由 initializer 写入 storage。

### 1.3 收益层

当前 yield adapter 路径以 `find src/yield -type f` 和 `.harness/policy.json` 分类为准；本节列出当前收益层 product adapter、共享 base 与 interface 源文件。

- `src/yield/SYBaseUpgradeable.sol`
- `src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol`
- `src/yield/adapters/aster/OutrunAsBNBSYUpgradeable.sol`
- `src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol`
- `src/yield/adapters/etherfi/OutrunWeETHSYUpgradeable.sol`
- `src/yield/adapters/lista/OutrunSlisBNBSYUpgradeable.sol`
- `src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol`
- `src/yield/adapters/lido/OutrunL2WstETHSYUpgradeable.sol`
- `src/yield/adapters/lido/OutrunL2WrappableWstETHSYUpgradeable.sol`
- `src/yield/adapters/sky/OutrunStakedUsdsSYUpgradeable.sol`
- `src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol`
- `src/yield/OutrunL2StakedTokenSYUpgradeable.sol`
- `src/yield/OutrunL2OracleBackedSYUpgradeable.sol`（oracle-backed L2 SY 变体抽象基类）
- `src/yield/interfaces/IStandardizedYield.sol`
- SY 份额层抽象，把外部收益资产包装为统一的 deposit / redeem / preview / exchangeRate 接口。
- 所有当前 SY adapter product surface 都通过 `ERC1967Proxy` + UUPS 部署，包括 Lido 相关 adapter。`SYBaseUpgradeable` 统一继承 `UUPSUpgradeable`，具体 SY adapter 通过该 base 取得 upgrade authority，不重复继承 UUPS。
- oracle-backed SY upgradeable variants 使用 mutable `exchangeRateOracle` storage 与 `setExchangeRateOracle(address)` onlyOwner 入口；`OutrunExchangeOracleAdapter` 自身仍是非 upgradeable、可重部署 helper。

### 1.4 路由层

- `src/router/OutrunRouter.sol`
- `src/router/interfaces/IOutrunRouter.sol`
- `src/router/interfaces/IMemeverseLauncher.sol`
- 把 token <-> SY <-> staking position/uAsset 组合为单次入口，并承载 memeverseLauncher genesis 集成。
- `OutrunRouter` 不进入 upgradeable product surface；仍保持非 upgradeable、可重部署 helper，并通过参数或配置调用 proxy-backed uAsset / SY / position。

### 1.5 集成与 Oracle 层

- `src/integrations/aave/interfaces/IAToken.sol`
- `src/integrations/aave/interfaces/IAaveV3Pool.sol`
- `src/integrations/aster/interfaces/IAsBnbMinter.sol`
- `src/integrations/aster/interfaces/IYieldProxy.sol`
- `src/integrations/etherfi/interfaces/IDepositAdapter.sol`
- `src/integrations/etherfi/interfaces/ILiquidityPool.sol`
- `src/integrations/etherfi/interfaces/IWeETH.sol`
- `src/integrations/lido/interfaces/IL2StETH.sol`
- `src/integrations/lido/interfaces/IStETH.sol`
- `src/integrations/lido/interfaces/IWstETH.sol`
- `src/integrations/lista/interfaces/IListaStakeManager.sol`
- `src/integrations/sky/interfaces/IPSM3.sol`
- `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`
- 外部协议最小 interface 与 adapter 调用封装；oracle adapter 做精度归一化前校验 raw answer 正性、新鲜度（含 feed 时钟超前的未来时间戳 fail-closed）与可选 sequencer，并在归一化后校验结果非零。
- `OutrunExchangeOracleAdapter` 不部署在 proxy 后；需要更换 oracle normalization 规则时部署新 adapter，再由 oracle-backed SY proxy 的 owner 更新 `exchangeRateOracle`。
- 后续执行 adapter / integration 相关任务时，以 `find src -type f` 得到的当前文件树和 `.harness/policy.json` 分类为准；本文件提供架构背景，不覆盖实际文件存在性与 harness surface 分类。

### 1.6 底层库

- `src/libraries/TokenHelper.sol`
- `src/libraries/SYUtils.sol`
- `src/libraries/AaveAdapterLib.sol`
- `src/libraries/ArrayLib.sol`
- `src/libraries/AutoIncrementIdUpgradeable.sol`
- `src/libraries/WadRayMath.sol`
- 跨业务域共享的 token 传输、汇率换算、重入保护、数组操作、ID 生成、错误定义等基础工具。
- 当前 helper 中 `TokenHelper.sol` 继承 vendored OpenZeppelin `ReentrancyGuardTransient.sol`（`@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol`），该 guard 使用 EIP-1153 transient storage；部署目标链必须支持 EIP-1153。

### 1.7 Upgradeable deployment model

当前 state-bearing product 使用 UUPS + `ERC1967Proxy`：

- proxy-backed：`OutrunUniversalAssetsUpgradeable`、`OutrunStakingPositionUpgradeable`、全部 SY adapter upgradeable variants。
- non-upgradeable / redeployable：`OutrunRouter`、`OutrunExchangeOracleAdapter`、interfaces、pure libraries、外部协议 interface。
- deployment flow：部署 implementation，编码 initializer calldata，部署 `ERC1967Proxy(implementation, initData)`，把 proxy address 作为产品地址写入后续 wiring。
- owner：单一 protocol owner 为 multisig（部署期 owner 约束按脚本区分：`OutstakeScript.s.sol` 系强制 `OWNER` 等于广播者 EOA、部署完成后 `transferOwnership` 转交 multisig；`YieldDeployScript.s.sol` 系无此 `OWNER == 广播者` 约束、`OWNER` 可直接设为终态 multisig；详见 `docs/deployment.md`「关键约束」）；无 timelock、无新增 governance module。
- upgrade authority：每个 UUPS product 的 `_authorizeUpgrade(address)` 由 `onlyOwner` 保护，只暴露 UUPS base 的 `upgradeToAndCall`。
- initializer boundary：构造参数迁移到 `initialize(...)` / `__..._init(...)`，implementation constructor 禁用 initializers。LayerZero endpoint 与 local decimals 是 `OutrunOFTUpgradeable` 继承官方 upgradeable OFT/OApp 路径所需的 implementation-level constructor 参数，每个 endpoint / local-decimal 配置部署一个 implementation。
- legacy boundary：旧非 upgradeable SY 合约、测试与部署 helper 已退出当前产品真源；当前清理任务会删除对应源码与测试表面。

## 2. 关键资金流

### 2.1 Token / Native -> SY

用户授权 router -> router 从调用者拉取 tokenIn -> 调用 SY.deposit() -> SY 份额 mint 给 receiver。

### 2.2 SY -> Token

router 路径先把 SY 转入 SY 合约地址（直调路径份额留在调用者账户、不转入）-> 调用 `SYBaseUpgradeable.sol::redeem`（该 SY 实例须由 owner 将当前 router 配置为 trusted router caller）-> adapter `_redeem` 先把目标 token 交付给 receiver -> 随后 burn SY 份额（router 路径从 `address(this)` 烧、直调路径从 `msg.sender` 烧）。非 trusted caller 传入 `burnFromInternalBalance=true` 会回退；`false` 直兑路径保持 caller 余额扣除。重入安全由 `redeem` 的 `nonReentrant` 保证。

### 2.3 Token / SY -> Locked Stake

用户授权 -> router 调用 SY 转换 -> position.stake() -> 拉取 SY -> 按 exchangeRate 折算 uAssetDebt -> 写入 position -> uAsset.mint(uAssetReceiver, uAssetDebt)。

### 2.4 Token / SY -> Wrap Stake

用户授权 -> SY 转换 -> position.wrapStake() -> 拉取 SY -> 按 exchangeRate 折算 -> 增加 syTotalStaking / syWrapStaking / wrapUAssetDebt -> uAsset.mint(uAssetReceiver, uAssetDebt)。

### 2.5 Wrap Redeem

keeper 授权自有 uAsset -> position.keepWrapRedeem() -> uAsset.repay() 烧掉 keeper 的 uAsset -> 换算 SY（健康池按 exchangeRate 面值；不足池 revert WrapPoolUndercollateralized）-> 减少池账务 -> 直付 SY 给 receiver（keeper-only，不经 SY.redeem）。

### 2.6 Position Redeem (到期)

position owner 授权 uAsset -> position.redeem() -> 按比例计算 UAssetBurned -> 减少 syTotalStaking、position.syStaked 与 position.UAssetMinted -> uAsset.repay() burn -> 输出 SY 或目标 token。

### 2.7 Keeper Redeem

keeper 授权 uAsset -> position.keepRedeem() -> keeper 的 uAsset burnt -> 按 keeperPrincipalSY 与 syRedeemed 分账 -> keeper 收 principal，owner 收 excess。

### 2.8 Harvest Wrap Yield

owner 调用 harvestWrapYield -> 计算 wrap 池盈余（syWrapStaking > OutrunStakingPositionUpgradeable.sol::_assetToSyUp(wrapUAssetDebt)，uAsset -> canonical asset 与 canonical asset -> SY 两段均向上取整，口径见 docs/spec/position/accounting.md §9）-> 减少 syTotalStaking / syWrapStaking -> 盈余转 revenuePool。

### 2.9 Genesis

用户入金 -> router 创建 locked position -> uAsset mint 给 router -> router 授权并调用 memeverseLauncher.genesis() -> launcher 拉走 uAsset。

## 3. 系统架构图

### 3.1 合约依赖树

方向: `→` 表示"依赖 / 调用"，`⟶` 表示"extends(继承)"。

#### uAsset 继承链

```
OutrunUniversalAssetsUpgradeable (concrete)
  ⟶ Initializable                       ← openzeppelin-upgradeable
  ⟶ IUniversalAssets (interface)
  ⟶ OutrunOFTUpgradeable (abstract)
    ⟶ OFTCoreUpgradeable                ← @layerzerolabs/oft-evm-upgradeable
    ⟶ OutrunRateLimiterUpgradeable
    ⟶ OutrunERC20PausableUpgradeable
      ⟶ OutrunERC20Upgradeable
      ⟶ PausableUpgradeable             ← openzeppelin-upgradeable
      ⟶ OwnableUpgradeable              ← openzeppelin-upgradeable
  ⟶ UUPSUpgradeable                     ← openzeppelin-upgradeable
```

#### Position 继承链

```
OutrunStakingPositionUpgradeable (concrete)
  ⟶ IOutrunStakeManager (interface)
  ⟶ AutoIncrementIdUpgradeable
  ⟶ TokenHelper
  ⟶ PausableUpgradeable                ← openzeppelin-upgradeable
  ⟶ OwnableUpgradeable                 ← openzeppelin-upgradeable
  ⟶ UUPSUpgradeable                    ← openzeppelin-upgradeable
  依赖:
    → IUniversalAssets (uAsset)          mint / repay
    → IStandardizedYield (SY)            exchangeRate / redeem
    → SYUtils
```

#### Router 依赖扇出

```
OutrunRouter (concrete)
  ⟶ IOutrunRouter (interface)
  ⟶ Ownable                            ← openzeppelin
  依赖:
    → IStandardizedYield               deposit / redeem / preview*
    → IOutrunStakeManager              stake / wrapStake / preview*
    → IMemeverseLauncher               genesis
    → TokenHelper
```

#### SY Adapter 统一结构

```
Concrete Adapter (e.g. OutrunAaveV3SYUpgradeable)
  ⟶ SYBaseUpgradeable (abstract)
    ⟶ IStandardizedYield (interface)
    ⟶ OutrunERC20PausableUpgradeable
      ⟶ OutrunERC20Upgradeable
      ⟶ PausableUpgradeable             ← openzeppelin-upgradeable
      ⟶ OwnableUpgradeable              ← openzeppelin-upgradeable
    ⟶ TokenHelper
    ⟶ UUPSUpgradeable                   ← openzeppelin-upgradeable
Concrete Adapter (e.g. OutrunL2StakedTokenSYUpgradeable / OutrunL2WstETHSYUpgradeable)
  ⟶ OutrunL2OracleBackedSYUpgradeable (abstract)   ← L2 oracle 接线 + 1:1 helpers + assetInfo
    ⟶ SYBaseUpgradeable (abstract)                 ← 子链同上方 Aave 条目
  依赖:
    → IExchangeRateOracle              getExchangeRate()

OutrunExchangeOracleAdapter
  → AggregatorInterface                latestRoundData()
  → IExchangeRateOracle
```

### 3.2 全局调用关系图

#### 3.2.1 合约调用关系

```
  User (EOA / ECA)
  approve(router / position / SY, ...)
       │
   ├────┬────────────┬────────────────┐
   ▼    ▼            ▼                ▼
+--------+  +--------------+  +-------------+  +------------------+
| Router |  | SYBase +     |  | Outrun      |  | IMemeverse       |
|        |  | Adapters     |  | StakingPos  |  | Launcher         |
|        |  |              |  |             |  | (external)       |
|mintSY  |  | deposit      |  | stake       |  |                  |
|redeemSy|  | redeem       |  | drawUAsset  |  | genesis          |
|stake   |  | preview*     |  | redeem      |  └──────────────────┘
|wrapStk |  | exchangeRate |  | wrapStake   |
|        |  └──────┬───────┘  │ keepWrapRdm │
|genesis │         │          │ keepRedeem  |
+───┬────┘         │          │ harvest     │
    │              │          │ preview*    │
    └──────────────┘          └─────┬─┬───┬─┘
                                    │ │   └───────┐
                 deposit/redeem mint│ │repay      │
                                    │ │     redeem│
                                    ▼ ▼           ▼
                          +----------------┐  +────────────┐
                          | OutrunUniversal|  | SY token   |
                          | Assets (uAsset)|  | ·redeem    |
                          |                |  └────────────┘
                          | ·mint          |
                          |   (minter cap) ├──────► OutrunOFT
                          | ·repay         |             │
                          └────────────────┘      _debit / _credit
                                                         │
                                               LayerZero Endpoint (external)
```

本图为调用主干摘要，非穷举：Router→Position（`stakeFromToken`/`stakeFromSY` → `stake`/`wrapStake`）与 Router→Launcher（`genesisByToken`/`genesisBySY` → `launcher.genesis`）等编排调用未画出，完整调用清单见 §3.2.2 表与 §3.1 依赖扇出。

#### 3.2.2 调用关系说明

| Caller | Callee | 入口 |
| --- | --- | --- |
| Router | SY | `mintSYFromToken` → `SY.deposit`；`redeemSyToToken` → `SY.redeem` |
| Router | Position | `stakeFromToken`/`stakeFromSY` → `stake`/`wrapStake` |
| Router | Launcher | `genesisByToken`/`genesisBySY` → `launcher.genesis` |
| Position | uAsset | `stake`/`wrapStake`/`drawUAsset` → `mint`；`redeem`/`keepRedeem`/`keepWrapRedeem` → `repay` |
| Position | SY | `redeem`/`harvestWrapYield` → `SY.redeem`（非 SY tokenOut 时经 adapter 兑换） |
| Adapter | External Protocol | deposit → `supply`/`wrap`/`deposit`；redeem → `withdraw`/`unwrap`/`redeem`/`swapExactIn`/`wrap`；或 1:1 直付 |
| OutrunOFT | LayerZero | `_toSD` 编码消息；`_debit` burn 本链；`_credit` mint 远端 |

Router 复合路径会透传或校验用户传入的 slippage floors：`minSyOut` 约束 token -> SY，`minUAssetMinted` 约束 stake / wrap stake 输出，`minTokenOut` 约束 redeem 输出。

### 3.3 资金流方向

方向标注: `token/token → SY` 表示资金从调用者流入 SY。

```
入金路径 (资金流向协议):

  User tokenIn  ──approve──► Router ──transferFrom──► Router
                                                         │
                                                    deposit
                                                         ▼
  User tokenIn  ──approve──► Adapter/SY ──transferFrom──► Adapter
                                                         │
                                                   deposit → external supply
                                                         │
                                                    mint SY shares
                                                         ▼
                                                   User receives SY

锁定 Stake (资金从 SY → uAsset):

  SY ──transferFrom──► Position ──exchangeRate──► uAssetDebt
                                                        │
                                                   mint uAsset
                                                        ▼
                                                 uAssetReceiver receives uAsset

Wrap Stake (资金进入共享池):

  SY ──transferFrom──► Position
    → syTotalStaking  += amountInSY
    → syWrapStaking   += amountInSY
    → wrapUAssetDebt  += uAssetDebt
    → mint uAsset to uAssetReceiver

赎回路径 (资金流出协议):

  User uAsset ──approve──► Position
    → reduce syTotalStaking / position.syStaked / position.UAssetMinted
    → repay(burn)
    → transfer SY or external redeem → token to receiver

  Keeper uAsset ──approve──► Position ──repay(burn)──► Position (keepWrapRedeem)
    → reduce syTotalStaking / syWrapStaking / wrapUAssetDebt
    → transfer SY directly to receiver (undercollateralized pool reverts WrapPoolUndercollateralized)

Keeper 代偿:

  Keeper uAsset ──approve──► Position ──repay(burn)
    → keeperPrincipalSY → keeper (receiver)
    → ownerExcessSY     → position owner

Harvest:

  Position syWrapStaking (surplus) ──► revenuePool
```

### 3.4 设计约束

- Router **不承担**独立资金池角色，所有资金来自调用者（caller-funded pull 模式）。
- 用户也**可直接调用** `SYBaseUpgradeable.sol::deposit`/`redeem` 与 Position.stake/wrapStake，无需经过 Router；直兑 `redeem(..., false)` 从调用者余额烧份额。`redeem(..., true)` 只对每个 SY 实例 owner 配置的 trusted router caller 开放；wrap 池赎回为 keeper-only `keepWrapRedeem`，不经 Router。
- uAsset.mint 是公开函数，但受 owner 配置的 mintingCap 约束，不是任何人都能铸造。
- Position 合约本身必须先在 uAsset 上被授予 mintingCap，才能继续铸造。

## 4. 文档分层（Doc Layering）

当前文档系统按四层组织：

1. Harness Contract 层
   - `AGENTS.md`
   - `CLAUDE.md`
   - `.harness/policy.json`
   - `script/harness/gate.sh`
   - `README.md`
   - `.github/workflows/test.yml`
   - `.githooks/*`
   - `.claude/settings.json`
2. Product Truth 层（当前规则真源）
   - `docs/spec/protocol.md`（系统目标与模块边界）
   - `docs/spec/router/router-and-user-flows.md`（完整路由路径分析）
   - `docs/spec/position/state-machines.md`（状态机）
   - `docs/spec/position/accounting.md`（账务规则）
   - `docs/spec/access-control.md`（权限边界）
   - `docs/spec/yield/yield-adapters.md`（adapter 行为与缺口）
   - `docs/spec/yield/oracles-and-integrations.md`（外部集成边界）
   - `docs/spec/common-foundations.md`（library 基础语义）
   - `docs/deployment.md`（部署入口与环境变量）
   - `docs/implementation-map.md`（surface 表格索引）
   - `docs/testing-and-evidence.md`（测试分层与证据强度）
   - `docs/ARCHITECTURE.md`（本文件：系统级模块地图）
   - `docs/GLOSSARY.md`（术语表）
   - `docs/TRACEABILITY.md`（规则到证据追溯）
   - `docs/VERIFICATION.md`（验证入口指南）
   - `docs/SECURITY_AND_APPROVALS.md`（安全审阅规则）
3. Implementation Evidence 层（规则落地证据）
   - `src/**`
   - `test/**`
4. Topic Guides 层（设计稿与计划工件，不是当前规则真源）
   - `docs/superpowers/specs/*`
   - `docs/superpowers/plans/*`

冲突处理顺序：

- 当前规则判断以 Product Truth 层为准，并用 Implementation Evidence 层核验。
- Topic Guides 层用于补充设计历史，不单独定义当前规则。
- 若 `docs/spec/*.md` 与 `src/**` 冲突，以 `src/**` 为准。

## 5. 推荐阅读顺序

1. `CLAUDE.md`（仓库流程与角色约定，5 分钟）
2. `docs/ARCHITECTURE.md`（本文件，先建立层次与边界，5 分钟）
3. `docs/GLOSSARY.md`（术语定义基线，3 分钟）
4. `docs/spec/protocol.md`（系统目标与 8 条用户可见流程，8 分钟）
5. `docs/spec/position/state-machines.md`（7 个状态机，8 分钟）
6. `docs/spec/position/accounting.md`（4 层账务规则，8 分钟）
7. `docs/spec/access-control.md`（权限边界清单，5 分钟）
8. `docs/spec/router/router-and-user-flows.md`（完整路由路径与边界，10 分钟）
9. `docs/spec/yield/yield-adapters.md`（8 组 adapter 实现与缺口，10 分钟）
10. `docs/TRACEABILITY.md` + `docs/VERIFICATION.md`（证据追溯与验证路径）

## 6. 当前已知边界提醒

- uAsset 按 minter 独立记账，不是全局总债务池。
- Router 当前是 pull 模式，不会消费 pre-funded 余额代替调用者出资。
- Genesis 当前走的是 locked stake 路径，不是 wrap stake 路径。
- Wrap 池按 principal debt 记账，不会因为汇率上涨自动给用户补发更多 uAsset。
- 11 个 SY adapter 的 deposit/redeem 核心路径在 `test/upgradeable/SYAdaptersUpgradeable.t.sol` 均有 roundtrip 覆盖，但部分由 `SYAdaptersUpgradeable.t.sol::testVaultBackedAdaptersUseDepositRedeemAndExchangeRate`、`SYAdaptersUpgradeable.t.sol::testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate` 家族共享测试覆盖，非每 adapter 专属；残余边界：oracle-backed L2 族（`OutrunL2WstETHSYUpgradeable`、`OutrunL2StakedTokenSYUpgradeable`）无 fork/primary 证据，个别 roundtrip 分支仍用恒等 mock 汇率，详见 `docs/spec/yield/yield-adapters.md` 证据矩阵。
- Oracle adapter 是精度归一化器，做 raw answer 正性检查、`maxStaleness` 新鲜度窗口校验（`updatedAt == 0`、`updatedAt > block.timestamp`（feed 时钟超前）或超窗均 fail-closed，revert `StaleOracleAnswer`）与可选构造期 L2 sequencer 校验，并在归一化后校验结果非零（`ZeroNormalizedRate`）；不实现 deviation bounds 或 fallback。
- 跨链 OFT 消息传递的正确性依赖 LayerZero 端点与 peer 配置，不属于本地仓库可直接证明的事实。
