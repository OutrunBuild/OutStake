# OutStake Accounting

> 状态：v1 语义（genesis-only、面值铸造、0% 利率默认、无清算）已落地。本文是 position 层 v1 账务语义的唯一真源，描述现行 `OutrunStakingPositionUpgradeable` 行为：唯一铸造入口 `stakeForGenesis` 按面值（价值平价）铸出，债务按 duty 域计息（v1 全族默认零费），清算与 CollSurplus 不存在。

## 1. 文档目的

本文档说明 position 层 v1 的核心账务规则：`uAsset` minter-cap 台账、仓位债务（本金 + 应计利息）、浮动利率 virtual accrual 计息数学（duty 域、零费放行）、参数面、`redeem` 按比例双腿销债、协议金库、mixed-decimals 双段换算语义、三行对账式与背书不变式、错误/事件真源。状态机表达见 [state-machines.md](./state-machines.md)。

## 1.1 Upgradeable accounting readiness

v1 implementation 仍为 proxy-backed uAsset、SY adapter 与 staking position：

- `OutrunUniversalAssetsUpgradeable` 的 `mintingStatusTable` 继续按 minter 维度记录 `mintingCap` 与 `amountInMinted`（§2）。
- `OutrunStakingPositionUpgradeable` 按 position 记录 `owner`、`syStaked`、`principalDebt`、`accruedInterest`、`lastRate`（§3、§4）；v1 删除 `rateMultiplier` 字段（五字段化）。
- v1 重排 `OutrunStakingPositionUpgradeable.sol` 的 ERC-7201 namespace storage struct（删除 `mintLtv`/`liquidationLtv`/`liquidationPremium`/`genesisRateMultiplier` 参数字段与 `CollSurplus` mapping、`Position` 结构五字段化）；当前 pre-deployment、无存量 proxy，布局重置不需要迁移函数；若出现任何存量部署，必须先提供迁移函数再升级。
- `SY` 依赖在 initializer 中写入后保持固定，不新增 `setSY()`，避免 position 债务对应的 share token 与 exchangeRate source 被替换。
- oracle-backed SY upgradeable variants 可通过 owner-only `setExchangeRateOracle(address)` 更换 `exchangeRateOracle`，但 setter 不改变 balances、shares、position accounting 或 yield-bearing token 配置。
- `OutrunExchangeOracleAdapter` 仍是非 upgradeable adapter（raw answer 正性、round 完整性、新鲜度窗口、可选 sequencer 校验、归一化后非零校验；语义真源见 `docs/spec/yield/oracles-and-integrations.md`）；不提供 bounds/fallback/多源聚合。oracle 喂价 revert（staleness 等）传导为 position 侧 fail-closed（§5.1）。
- upgradeable variants 的 V1 storage layout 是后续升级的 canonical layout；L2 oracle-backed SY 变体的升级兼容性以基类 ERC-7201 槽 `erc7201("outrun.storage.OutrunL2OracleBackedSY")` 为准。

## 2. `uAsset` 的 minter-cap 账务

`OutrunUniversalAssetsUpgradeable` 按 minter 维护 `mintingStatusTable`（`mintingCap` / `amountInMinted`），本层不变：

- `checkMintableAmount(minter)` 返回 `mintingCap - amountInMinted`，最低到 0。
- `mint(receiver, amount)` 由调用者（position 合约）自己的 minter 额度承担，成功后增加 `amountInMinted`。
- `repay(account, amount)` 减少调用者（`msg.sender`，即 minter = position 合约）的 `amountInMinted`；`account` 是被 burn 的地址，必须持有足够 `uAsset` 且（`account != msg.sender` 时）已授权。本金腿销债一律经 `repay`（§7）。
- `revokeMinter(minter)` 只把 cap 设为 0 以禁止后续 mint，既有 `amountInMinted` 保留到后续 repay。
- `transferMinterDebt(from, to, amount)` 是 owner-only 的 minter 级债务迁移；用途限定与对账验收见 `docs/spec/common-foundations.md`「基础规则」与本文 §10.2。
- OFT 跨链铸烧豁免与 PSM 储备铸烧豁免不触碰 minter 债务台账，见 `docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」。

应计利息不进入 minter 台账：利息腿是流通 `uAsset` 的 transfer（调用者 → 协议金库），既不 mint 也不 repay（§4、§7），因此 §10.2 的对账式只含本金。v1 零费默认下利息腿恒为 0，台账语义不变。

`mintingCap` 在 v1 的定位是**唯一的供给刹车**：原「背书保护」（LTV）职责已随 LTV 族删除并入——cap 直接限总供给，背书由价值平价铸造构造保证（§3.1、§10.3）。

## 3. Position debt 账务（本金 + 应计利息）

每个 `Position` 记录：

- `owner`：仓位控制权（redeem 权）
- `syStaked`：质押的 SY 本金数量
- `principalDebt`：本金债务（uAsset decimals 口径，即铸账口径——`stakeForGenesis` 时经 `uAsset.mint` 铸出的数量；字段语义= 铸账本金）
- `accruedInterest`：已结算未支付的应计利息（uAsset decimals 口径，与本金币同单位；仅在本位结算触点写入，§4）
- `lastRate`：本仓最近一次利息结算时的 SP `rate` 快照

仓位总债务（结算后）：

> `totalDebt = principalDebt + accruedInterest + pendingInterest`

其中 `pendingInterest` 为自 `lastRate` 至当前 `rate` 的未结算增量（§4 公式）。开放期限：无 `deadline` 字段、无到期门；无增借入口（`drawUAsset` 删除），减借唯一路径是 partial `redeem`（§7）。

初始铸债规则（`OutrunStakingPositionUpgradeable.sol::stakeForGenesis`，唯一铸造入口）：

1. 抵押定价：`collateralValue = SY -> canonical asset -> uAsset`（两段均 down，沿用 `_syToAsset` 路径与 `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 单点读率）。
2. 面值铸出（价值平价）：`mintedUAsset = collateralValue`——两段 down 的直接结果，无 LTV 缩放段。注意是**价值平价不是单位平价**：汇率 1.15 时存 1 sUSDS 铸 1.15 UUSD。
3. `mintedUAsset` 写入 `principalDebt`，并经 `uAsset.mint` 铸出（消耗 SP minter 的 mintingCap headroom，`ReachMintCap` 属依赖边界）。

由此每个仓位在铸造时刻满足 `principalDebt ≤ syStaked × exchangeRate(铸造时点)`（两段 down 构造严格 ≤），这是背书不变式（§10.3）的唯一构造来源。自由借贷入口（`stake`）在 v1 不存在：uAsset 铸出量与 Memeverse genesis 需求严格绑定（§3.1）。

### 3.1 `stakeForGenesis`：唯一铸造入口（SP 原生物理门）

`OutrunStakingPositionUpgradeable.sol::stakeForGenesis(amountInSY, positionOwner, verseId, minUAssetMinted)`（`nonReentrant` + `whenNotPaused`，返回 `positionId`）是 v1 唯一的铸造入口：铸出的 uAsset 在同一交易内全额交 SP 侧 `genesisLauncher`。全原子执行序：

- (a) 前置校验：`genesisLauncher == address(0)` → `GenesisLauncherNotSet()`；`amountInSY` / `positionOwner` 为零 → `ZeroInput()`；`amountInSY < minStake()` → `MinStakeInsufficient`。
- (b) 铸出量数学：两段 down 面值换算（§3），铸出为 0 → `DustRoundedToZero()`；随后两项 genesis 专属守卫：`mintedUAsset < minUAssetMinted` → `InsufficientUAssetMinted(mintedUAsset, minMinted)`（SP 本地声明）；`mintedUAsset > type(uint128).max` → `InvalidParam()`（与 router 路径 A（`genesisByPSM`）的同名守卫同构，launcher 参数域为 uint128）。
- (c) 开仓：SY 转入 position 合约 → SP `rate` 结算到当前时刻并快照 `lastRate`（新仓不承接开仓前利息，首次结算利息按开仓时刻起算，§4.4）→ 写入五字段 `Position`（无锁定系数）；`principalDebt = mintedUAsset`。
- (d) uAsset 铸给 `address(this)`（SP 自身），绝不经过 owner、router 或任何第三方，SP 的 uAsset minter 台账正常入账——`uAsset.mint` 使 SP minter 的 `amountInMinted += mintedUAsset`，无 PSM 式豁免（§10.2 第一行显式覆盖 genesis 铸出）。
- (e) 对 `genesisLauncher` 精确 approve 恰好 `mintedUAsset`。
- (f) 调用 `IMemeverseLauncher.genesis(verseId, uint128(mintedUAsset), positionOwner)`（接口真源 `src/router/interfaces/IMemeverseLauncher.sol`，launcher 侧零改动）；`verseId` 原样转发、SP 不校验。
- (g) 后置断言：`genesis` 返回后 SP 的 uAsset 余额必须回到铸出前基线，且对 `genesisLauncher` 的 allowance 必须为 0，否则 `GenesisUAssetNotConsumed(residualBalance, residualAllowance)` 整笔回滚——部分消费、转回或任何残余都使仓位与铸出一并消失。
- (h) 事件：`Stake(positionId, positionOwner, amountInSY, mintedUAsset)` 加 `StakeForGenesis(positionId, positionOwner, verseId, mintedUAsset)`（§11.2）。

物理门控语义与边界：

- 物理门：铸出资金只能在单笔交易内到达 launcher——门是物理约束，不是身份白名单，也不是事后返还；`genesisLauncher == address(0)`（部署默认态，或 owner 置零）时入口以 `GenesisLauncherNotSet()` 拒绝（kill switch，§6）。
- 守恒断言：`stakeForGenesis` 成功后 SP 的 uAsset 余额恒等于调用前余额——mint→consume 在交易内闭环，无托管、无持久账面。
- genesis 仓在创建后即普通仓位：redeem 双腿销债（§7）、按 §4.2 计息（v1 零费默认下利息腿恒 0）——无额外状态、无锁仓。
- 报价：无 genesis 专属 preview；`previewStake` 公式同式覆盖唯一执行入口（genesis 消费量 == 铸出量，确定性，§5）。

## 4. 计息数学（virtual accrual，duty 域，零费放行）

借贷利息为浮动、治理可调、作用于存量债务；采用 per-SP 累计率单位 + per-position 按秒记账的 virtual accrual（计息锚为 `block.timestamp`），严禁 mint-as-you-accrue（计息不调用 `uAsset.mint`，`uAsset` totalSupply 不因计息变化）。timestamp 锚定使速率语义为纯日历时间、与链出块基础设施解耦：多链部署（各链出块节奏不同且随链加速漂移）不携带任何会过期的年均块数换算假设，跨链利率口径一致，无 per-chain 换算参数；`block.timestamp` 受共识约束（单调不减、偏斜有界），对借贷利率的偏斜攻击面可忽略（行业先例：按秒累计的利率指数自 2019 年起长期运行）。原块数锚定的部署误配面——年均块数 per-chain 定值与链真实出块节奏错配、链加速后名义利率与实际利率静默漂移、低率下每块增量整除归零的静默零息窗口及配套的部署后增量下限断言——随换算参数整体删除而作废，无遗留部署核对项。

### 4.1 per-SP `duty` 与累计 `rate`（Maker 式，RAY 1e27 域）

- per-SP 每秒率 `duty`（RAY 1e27 域），累计率 `rate`（init=`1e27`），单调不减（`initialize` 同时写入 `rateLastSettledAt = block.timestamp`，init 时刻即首个结算基线，此后首个触点自 init 时刻起算增量）；复利整段闭式：`rate = rmul(rpow(duty, dt), rate)`，其中 `dt = block.timestamp − rateLastSettledAt`；`rpow` 系 Maker assembly 版（内步 round-half-up），`rmul` 单次截断。无全局 base（单 `duty` per-SP）；USR 不动。
- **接受域 `[1e27, DUTY_CAP]`（v1 零费放行）**：`OutrunStakingPositionUpgradeable.sol::initialize` 与 `OutrunStakingPositionUpgradeable.sol::setDuty` 的守卫为 `duty < 1e27 → ZeroInput`（sub-RAY 即负利率、含 0，全拒——保 `rate` 单调不减），仅此拒绝对；`duty == 1e27`（零费哨兵）合法且为 v1 默认；上限 `DUTY_CAP`（年化 15% 等效每秒率），越上限 → `DutyCap`。零费从「不开放的语义」改为「v1 默认」；`BorrowRateBelowResolution` 已废除（dust 悬崖不存在）；pause 才是熔断器。
- 惰性结算：`rate` 存储值只在结算触点前移——`OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（开仓即结算，见 4.4）、`::setDuty`（分段生效，见 4.3）、`::redeem` 先把 `rate` 结算到当前时刻（`rate = rmul(rpow(duty, block.timestamp − rateLastSettledAt), rate)`）再执行本体；同秒多次结算幂等（`dt == 0` 时 `rpow(duty, 0) == 1e27`，`rate` 不变）。
- 存储配套 `rateLastSettledAt`（最近结算 timestamp）；视图族按同公式纯外推（`currentRate()`，外推至当前时刻），不写状态、与执行结算同输入同输出。

### 4.2 per-position 利息结算

position 记 `principalDebt`（= 铸账本金）+ `accruedInterest` + `lastRate`；结算增量（有效利率 = `duty` 单项，无乘数）：

> `Δint = principalDebt × (rate(t) − lastRate) / 1e27`

- `rate(t) − lastRate` 为 RAY 1e27 域复利增量，除一次 `1e27`；`rmul` 语义单次截断。
- 结算后 `accruedInterest += Δint`、`lastRate = rate(t)`。
- 复利（compound on principal via 累计 `rate`）：利息按 `principalDebt` 对累计 `rate` 复利增量计，已落账 `accruedInterest` 本身不另行复利；增借不存在故铸账本金恒定，唯一变动是 partial `redeem` 减本金后按新本金续计（§7）。
- **零费语义（v1 默认）**：`duty = 1e27` 时 `rpow(1e27, dt) = 1e27`、`rate` 永不前移、利息永不 accrue——无需任何特殊分支；债务冻结、背书率单调上升（§10.3）。`_repayTwoLegs` 保留：0 费下利息腿恒 0，既有 `interestPortion == 0 时跳过` 逻辑覆盖；`protocolTreasury` 参数保留（未来加息的利息去向不变）。mint-as-you-accrue 禁令在零费下自动满足（计息增量恒 0）。

### 4.3 利率变更分段生效

`OutrunStakingPositionUpgradeable.sol::setDuty`（§6）在写入新 `duty` 前先把 `rate` 按旧 `duty` 结算到当前时刻（复利整段闭式增量），随后新 `duty` 前瞻生效：此前未结算时间按旧 `duty` 累计、此后按新 `duty` 累计。positions 无需逐仓迁移——`lastRate` 语义是「快照时的累计 `rate`」，与率值解耦，结算公式自动分段。

### 4.4 virtual accrual 触点

- 写状态结算（`accruedInterest` 落账）：`OutrunStakingPositionUpgradeable.sol::redeem`（支付时结算）。
- 开仓结算触点：`OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 在写入新仓前先把 SP `rate` 结算到当前时刻，再快照 `lastRate = rate()`（结算后值）——新仓不承接开仓前未结算时间的利息，首次结算利息按开仓时刻起算。
- 只读外推（不写）：`pendingInterest(positionId)`、`positionDebt(positionId)`、`previewRedeem` 及 `rate` 视图族（§11.3）。
- 同秒内（同一 timestamp）preview 与执行一致（同一 `rate` 外推/结算值）。

## 5. 汇率换算

`exchangeRate()` 仍为 `asset per SY` 的统一换算基准，接口层语义不变；mixed-decimals 双段换算单位模型与四个基础公式以 `docs/spec/common-foundations.md`「单位模型」为准。`OutrunStakingPositionUpgradeable` 的换算方向：

- `SY -> canonical asset`：`collateralValue = _syToAsset(syStaked, exchangeRate)`（down + down，`OutrunStakingPositionUpgradeable.sol::_syToAsset`）
- `uAsset -> canonical asset -> SY` 的 up/up 复合（`canonical asset -> SY` up 内联公式，非 `SYUtils` 库成员）在 v1 无 SP 侧消费方（清算路径删除后 `_assetToSy` 及其唯一消费者 `_liquidationSplit` 一并删除），偏差记录见 `docs/spec/common-foundations.md` 单位模型

读率点：所有换算入口经 `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 单点读取，`exchangeRate() == 0` revert `ZeroExchangeRate()`；oracle adapter 的 stale 等喂价错误原样透传（fail-closed，依赖边界）。

rounding matrix（v1 全表）：

- `stakeForGenesis` / `previewStake(amountInSY)`：
  - `SY -> canonical asset` 用 down；`canonical asset -> uAsset` 用 down（无 LTV 缩放段）
  - 失败面：`previewStake` 的 `amountInSY == 0` → `ZeroInput()`（先于一切检查）；`amountInSY < minStake()` → `MinStakeInsufficient()`；rate==0 → `ZeroExchangeRate()`；两段换算下取整为 0 → 返回 `0`（执行入口 `stakeForGenesis` 对同输入 revert `DustRoundedToZero()`，quote/actual 刻意分歧，沿用既有约定）
  - 同一铸出量公式同式覆盖执行入口与 preview（§3.1 (b)）；genesis 专属失败面：`mintedUAsset < minUAssetMinted` → `InsufficientUAssetMinted(mintedUAsset, minMinted)`、`mintedUAsset > type(uint128).max` → `InvalidParam()`、`genesisLauncher == address(0)` → `GenesisLauncherNotSet()`、后置断言失败 → `GenesisUAssetNotConsumed(residualBalance, residualAllowance)`；无 genesis 专属 preview（genesis 消费量 == 铸出量，确定性）
- `redeem` / `previewRedeem(positionId, syRedeemed, tokenOut)`：
  - debt 按仓内比例切片，不读汇率（SY 直出路径无 oracle 依赖；tokenOut != SY 时经 `SY.redeem`/`SY.previewRedeem` 依赖换算）
  - 本金腿 partial 用 ceil：`principalPortion = ceil(principalDebt × syRedeemed / syStaked)`；full（`syRedeemed == syStaked`）精确等于 `principalDebt`
  - 利息腿 partial 用 ceil：`interestPortion = ceil(settledInterest × syRedeemed / syStaked)`；full 精确等于 `settledInterest`
  - partial 结果 `principalPortion >= principalDebt` → `PartialRedeemMustLeaveDebt()`（须改走 full redeem）

### 5.1 风险声明（oracle fail-closed、dust 接受语义与 LST 例外）

- **oracle fail-closed（率值完整性（喂价异常导致超铸）的唯一链上防线）**：铸造全路径（定价、铸出量）消费 `SY.exchangeRate()`；经 oracle-backed SY 变体时，adapter 的 raw answer 正性、round 完整性、新鲜度窗口（`maxStaleness`）、（配置时）L2 sequencer 校验、归一化后非零校验任一失败即 revert（错误面真源 `docs/spec/yield/oracles-and-integrations.md`），`stakeForGenesis` / `previewStake` 原子拒绝——fail-closed：价格源异常时铸造不可用，不降级、不 fallback。本地分支：`exchangeRate() == 0` → `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 单点守卫）。v1 无 LTV/清算，oracle 栈从「清算保护」升格为**率值完整性（喂价异常导致超铸）的唯一链上防线**——汇率虚高时面值铸造即超铸，oracle 栈是铸造侧率值维度的链上守卫（余额维度由名义 1:1 族 resident 背书对账守卫承担，见 `docs/spec/yield/yield-adapters.md`）；该栈现为两层链上防御：新鲜度栈（正性 / round 完整性 / `maxStaleness` / sequencer / 归一化非零）仍是 adapter 侧防线，oracle-backed SY 基类（`OutrunL2OracleBackedSYUpgradeable`）的锚点偏差熔断是第二层链上防御，专门拦截铸造路径的喂价数值跳变（带外读数 revert `RateDeviationExceeded`，语义真源 `docs/spec/yield/oracles-and-integrations.md`「边界」锚点偏差熔断条目）；带内缓变漂移仍属链下监控与 pause 联动职责（监控与应急操作面见 `docs/deployment.md`）。
- **互补退出通道**：`redeem` 的 SY 直出路径不读汇率——oracle 异常期间 owner 仍可按面值销债赎回（有意保留的退出通道，非守卫遗漏）；面值语义下该通道更关键：还 `principalDebt`（0 利息下 = 铸出量）拿回全部 SY，汇率涨跌只改变这组数字的外部价值，不改变结算，汇率上涨收益归抵押方。
- **dust 接受语义（Info）**：微量存款两段 down floor 归零 → `DustRoundedToZero()` 拒绝（不接受零债仓位）；已开仓的 dust 级仓位无第三方出清方（清算不存在），owner `redeem(syRedeemed == syStaked)` SY 直出全量自赎是唯一出清通道（不读汇率），波及金额 dust 级，协议零坏账（owner 自赎出口存在）。
- **LST 削罚例外**：背书不变式（§10.3）的「汇率单调不降」为收益型资产正常态假设；LST 削罚可使汇率小幅回撤（历史 ≤1% 量级，Lido/Lista 国库有自补先例）——非黑天鹅形态，风险模型可吸收，但每个 LST 集成须按准入标准单独评估（准入标准与尽调清单见 `docs/deployment.md`）。

## 6. 参数面

以下参数全部为 owner-governed 变量（setter + `Set*` 事件 + 合约内边界校验），存储于 SP 合约（per-SP 实例参数；家族一致性由部署与治理保证）：

| 参数 | 默认值（部署期落位） | 边界 |
| --- | --- | --- |
| `duty`（per-SP，每秒率，RAY 1e27 域） | 全族 `1e27`（零费，v1 默认；0 率 + 抵押生息 → 债务冻结、背书率单调上升） | 接受域 `[1e27, DUTY_CAP]`（`DUTY_CAP = 1000000004431822129783699001`，年化 15% 等效每秒率）：`duty < 1e27`（含 0，sub-RAY 即负利率）→ `ZeroInput`（保 `rate` 单调不减）；`duty == 1e27` 合法（零费哨兵）；越上限 → `DutyCap`。未来加息换算式 `duty = 1e27*(1+年化)^(1/31536000)` 向下取整（python3 decimal 高精度）；变更分段生效（§4.3）；加息前置校准清单见本节「加息前置校准」 |
| `genesisLauncher`（per-SP 地址参数，依赖级别同 `protocolTreasury`） | 零地址（部署默认＝`stakeForGenesis` 入口禁用；非 initialize 参数，部署后 owner setter 布线） | owner-settable；接受任意地址含零；零地址＝入口禁用（kill switch）；emit `SetGenesisLauncher`（§11.2） |
| `minStake`（per-SP） | 部署期定（genesis 门票最小规模 + 反垃圾） | 双向可调，恒 > 0 |
| `protocolTreasury`（per-SP 地址参数） | V1 = 部署期金库地址 | owner-settable；零地址拒绝；利息腿唯一去向（v1 零费下恒 0 腿，参数保留供未来加息）；禁止为改去向升级合约（§9） |

**加息前置校准**：任何把 `duty` 提过 `1e27` 的 `OutrunStakingPositionUpgradeable.sol::setDuty` 治理决策，执行前须完成并留痕三项前置：

1. 利息腿流通供应依赖确认——利息为 virtual accrual、永不铸出（§4），付息 uAsset 须来自流通供应或 PSM 面值铸出（本金经 genesis 全额交付 launcher，owner 偿还本金同样依赖流通供应）；
2. 各 (uAsset, reserve) PSM 实例的 stockCap headroom 与绑定储备规模相对该 SP 家族债务存量及预期付息流的容量评估（`docs/spec/psm/peg-stability-module.md`「储备消耗监控与校准」）；
3. 跨链持币分布下 OFT 出站限额对回桥付息可达性的影响评估——等待期间债务按新 duty 继续计息，限流延迟具直接利息成本（`docs/spec/protocol.md`「跨链可用性与限流」）。

v1 `duty = 1e27` 下本清单不触发；本清单为治理前置程序而非链上强制——`OutrunStakingPositionUpgradeable.sol::setDuty` 不做链上前置校验为有意设计，此处记录治理程序，不引入运行时门。

v1 参数族收缩说明：`mintLtv` / `liquidationLtv` / `liquidationPremium`（三 LTV/premium 族）与 `genesisRateMultiplier` 随无 LTV/无清算/零折扣决策整体删除，无存量迁移面。

- setter 边界校验错误全表见 §11.1；状态机级转移条件表见 [state-machines.md](./state-machines.md) §6。
- `initialize` 落位同一套参数：init 期零地址/零值 → `ZeroInput()`，`duty` sub-RAY 或越上限 → `ZeroInput` / `DutyCap`；init 期无旧值，无棘轮检查；默认值由部署脚本传入，合约内不硬编码。

## 7. `redeem` 的按比例双腿销债

`OutrunStakingPositionUpgradeable.sol::redeem(positionId, syRedeemed, receiver, tokenOut, minTokenOut)` 为 position owner 专属入口（`onlyPositionOwner`），任意时刻可用（无到期门），沿用 full/partial 语义：

- `syRedeemed == 0` → `ZeroInput()`；`syRedeemed > syStaked` → `ExceedsPositionBalance(syRedeemed, syStaked)`。
- 进门后先做利息结算（§4.4 写状态触点）：SP `rate` 结算到当前时刻，本仓 `accruedInterest += Δint`、`lastRate` 更新（v1 零费下 `Δint == 0`，利息腿跳过）。
- 两腿份额（§5 rounding matrix）：
  - full（`syRedeemed == syStaked`）：`principalPortion = principalDebt`、`interestPortion = accruedInterest`。
  - partial：两腿均按 `syRedeemed / syStaked` 比例 ceil；partial 耗尽本金（`principalPortion >= principalDebt`）→ `PartialRedeemMustLeaveDebt()`，须改走 full redeem。
- 偿还顺序（两腿，利息腿先行）：
  1. **利息腿**：`interestPortion` 等值 `uAsset` 从调用者 transfer 至 `protocolTreasury`（`OutrunUniversalAssetsUpgradeable` ERC20 transfer，经 SP 合约拉取调用者余额）；`interestPortion == 0` 时跳过。利息腿不 burn、不冲销 minter 台账（§2）。
  2. **本金腿**：`OutrunUniversalAssetsUpgradeable.sol::repay(msg.sender, principalPortion)`——burn 调用者的 `uAsset` 并等额冲销 SP minter 的 `amountInMinted`。
  - 调用前提：owner 须先向 SP 合约 approve 不少于 `principalPortion + interestPortion` 的 `uAsset`（repay 与 transfer 拉取共用该 allowance）；余额/授权不足时以依赖边界错误（如 `ERC20InsufficientAllowance`）整笔原子回退。
- 仓位更新（CEI：先减记仓位，后外部调用）：`syStaked -= syRedeemed`、`principalDebt -= principalPortion`、`accruedInterest -= interestPortion`；剩余 `syStaked == 0`（full redeem）删除仓位（id 空洞，§11.3）；`PartialRedeemMustLeaveDebt` 保证 partial 后 `principalDebt > 0` 且 `syStaked > 0`。partial 减本金后利息按新本金续计（§4.2）。
- 资产输出（沿用既有语义）：`tokenOut == SY` 时直接转出 `syRedeemed`（执行前校验 `syRedeemed < minTokenOut` → `InsufficientTokenOut`）；否则经 `SY.redeem(receiver, syRedeemed, tokenOut, minTokenOut, false)`。
- 成功后 emit `Redeem(positionId, owner, syRedeemed, principalBurned, interestPaid, receiver, tokenOut, amountTokenOut)`（§11.2）。
- `previewRedeem(positionId, syRedeemed, tokenOut)` 复用同一判定/舍入/拒绝规则，返回 `(principalPortion, interestPortion, amountTokenOut)`；SY 直出报价不读汇率（owner 退出通道不依赖 oracle，与铸造侧 fail-closed 形成互补，见 §5.1）。

被销毁/转移的 `principalDebt` 与 `interestPortion` 始终是 uAsset decimals 口径的债务单位；本金腿的语义基准仍是 `stakeForGenesis` 时的 `SY -> canonical asset -> uAsset` 铸账，执行路径不按汇率重定价。

## 9. 协议金库账务（`protocolTreasury`；原清算账务与 CollSurplus 账务随 v1 无清算决策整节删除，§8 编号退役不复用）

- per-SP 实例参数（V1 部署期统一配置为家族金库地址），owner 经 `setProtocolTreasury` 更新（零地址 → `ZeroInput()`），emit `SetProtocolTreasury(protocolTreasury)`。
- 唯一用途：`redeem` 的利息腿接收方——`uAsset` transfer 到账后即为金库自有的流通 `uAsset`（不 burn、不进 minter 台账）。v1 零费默认下利息腿恒 0，该参数为未来加息保留（加息后利息去向不变）。
- 运营约束：禁止为更改利息去向而升级合约；去向变更只走 setter（可审计事件）。

## 10. 账务边界总结

v1 的账务边界：

- `uAsset` 债务按 minter 独立记账（本金经 mint/repay；利息不进台账）
- 仓位债务按 position 独立记账（本金 + 应计利息双字段，virtual accrual；v1 默认零费冻结）
- `exchangeRate()` 与 `SYUtils` 仍是 SY 数量与资产值之间的统一换算基准
- 外部协议如何生成 `exchangeRate()` 属本地依赖边界；本仓库只证明上层账务如何消费该汇率

### 10.1 核心守恒不变量（SY 持仓分解）

`syTotalStaking` 聚合变量不保留（spec 决策：不再保留聚合变量，总量视图由链下/遍历取），守恒式为按持仓分解的对账锚点：

> `SP 合约 SY 余额 == Σ active positions.syStaked`

其中 active position 指 `positions(id).owner != address(0)` 的仓位。等式隐含前提：无第三方向 SP 合约直转 SY——正常流的唯一 SY 入口是 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 的 transferFrom；误转/捐赠的 SY 会沉淀为合约余额的额外项，使余额侧大于分解项之和（对账口径见 §13 第 1 条的两种断言模式）。各入口对等式的构造性保持：

- `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`：SY 转入 + 新仓位 `syStaked`，两侧同增（uAsset 的铸出→launcher 消费在同一交易内闭环，不影响 SY 守恒式，§3.1）。
- `OutrunStakingPositionUpgradeable.sol::redeem`：SY 转出（直转或经 `SY.redeem`）镜像 `syStaked` 减记；full redeem 删除仓位移出 active sum。

新增或升级任何 SY 资金路径时必须使上式在每次状态变更后仍成立；该式作为 invariant 测试锚点（§13）。

### 10.2 Position minter 对账式（三行对账式，升级 / 迁移 / 运营对账验收标准）

uAsset 供给侧三行对账（`uAsset` 三条供给路径：CDP（position 层）+ PSM + POLend）：

**第一行（CDP，本仓库强制）**：

> `amountInMinted(SPx) == Σ active positions.principalDebt`

- 应计利息单列、不进铸账：利息腿是流通 `uAsset` 的 transfer，不 mint、不 repay，`amountInMinted` 只随 `stakeForGenesis`（+本金）与 `redeem` 本金腿（−本金）移动（v1 清算项消失后该式更简：铸造与偿还双向对称）。
- 该恒等式由构造成立：`OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 经 `uAsset.mint` 等额增加 position minter 的 `amountInMinted`——genesis 铸出正常入账（`amountInMinted += mintedUAsset`），无 PSM 式豁免；`::redeem` 本金腿经 `uAsset.repay` 等额冲减。
- 锚定测试：逐活动仓位累加 `Position.principalDebt`，断言等于 `mintingStatusTable(address(position)).amountInMinted`（§13）。
- 口径边界：对账读 per-minter 的 `amountInMinted`，不读 `totalSupply()`——后者受其它 minter、OFT 跨链与 PSM 储备铸烧影响；OFT 跨链不触碰 minter 台账（`docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」），故跨链 supply movement 不参与本式。
- position minter wiring：position 合约经部署脚本注册为 uAsset minter 并配置 `mintingCap`；升级/迁移不得在不改该注册的情况下单独变更 position 侧台账。
- `OutrunUniversalAssetsUpgradeable.sol::transferMinterDebt` 以该 minter（position）为 from/to 时只迁移 minter 级债务、不自动同步 position 台账：仅限修复无仓位债支撑的错账；对有真实仓位支撑的债务调用即打破本恒等式，且 SP 侧无账本导出/导入入口，活 SP 退役走清偿路径（`setMintingCap(SP,0)` → 存量经 `redeem` 清偿 → `revokeMinter`）。
- 修账验收步骤：修账前记录恒等式偏离方向与量 → 执行 `transferMinterDebt` 归位 → 修账后逐项核对 `positions(id)` 的 `principalDebt` 与 position minter 的 `amountInMinted`（经 `mintingStatusTable` 直读），本式重新成立即通过。

**第二行（PSM，豁免）**：PSM 经 uAsset 储备铸烧路径（`reserveMint`/`reserveBurn`）供给，豁免 minter 债务台账（储备侧口径）；储备守恒式与豁免语义真源见 `docs/spec/psm/peg-stability-module.md`。

**第三行（POLend，接口预留）**：`POLend 行 == Σ globalDebtByUAsset + 未结 preRedeem backing`；`globalDebtByUAsset` 视图族的接口语义预留见 §12，Memeverse 侧持子账本，本仓库不实现。

### 10.3 背书不变式（v1 核心锚点）

- **仓位形态**：对任意活动仓位，`positions.principalDebt ≤ syStaked × exchangeRate(铸造时点)`——由铸造的两段 down 取整构造成立（§3），两段 floor 保证严格 ≤；这是 uAsset 足额背书的唯一链上构造来源。
- **聚合形态**：`amountInMinted(SPx) ≤ Σ collateralValue`（各仓按其铸造时点汇率计）。
- 汇率单调不降假设下（收益型资产正常态），背书率随时间单调改善——0 利息（v1 默认）下债务冻结、抵押生息，仓位自愈；LST 削罚例外声明见 §5.1。
- 铸造取整方向是构造来源：`mintedUAsset = floor₂(syStaked × exchangeRate())`，不存在任何放大杠杆段（v1 无 LTV 缩放、无乘数、无折扣）。
- 回锚双管道（脱钩不是单行道）：uAsset 折价 → genesis 借款人买折价 uAsset 还债赎 SY（债赎套利，`redeem` SY 直出保证该通道 oracle 无关）；uAsset 溢价 → PSM 储备放出。借款人与非借款人两条锚定管道并存。

## 11. Position manager 错误与事件真源

本节是 v1 `IOutrunStakeManager.sol` 声明的自定义错误与事件的 canonical surface。错误表只覆盖 position manager 自己声明并在本地分支触发的错误；OpenZeppelin、`TokenHelper`、`SY` adapter、oracle adapter 和 `uAsset` 的错误属于依赖边界。每个本地错误都使整笔交易 revert，已发生的 manager storage 写入、ERC20 transfer 或下游调用一并回滚。

### 11.1 错误全表（14 个）

下表中的 `::function` 简写均指 `OutrunStakingPositionUpgradeable.sol::function`；接口声明锚点为 `IOutrunStakeManager.sol`。

| 错误 | 入口与精确触发分支 | 参数 | 回滚 / 依赖边界 |
| --- | --- | --- | --- |
| `ZeroInput()` | `::initialize` 的 owner、SY、uAsset、protocolTreasury 零地址，或 `minStake == 0`；`duty < 1e27`（sub-RAY 即负利率，含 0；保 `rate` 单调不减）；`::stakeForGenesis` 的 `amountInSY` 或 `positionOwner` 为零；`::redeem` 的 receiver 为零或 `syRedeemed == 0`；`::setDuty` 的新率 sub-RAY；`::setProtocolTreasury` 的新地址为零；`::setMinStake` 的新值为零。`::previewStake`/`::previewRedeem` 的对应零输入同此错误。 | 无 | 各入口本地零值守卫，先于一切 transfer、写入与依赖调用。 |
| `DustRoundedToZero()` | `::stakeForGenesis` 的 `SY -> canonical asset -> uAsset` 向下换算得到 `mintedUAsset == 0`。 | 无 | 检查在 transfer、写入与 mint 之前；不创建零债仓位。rate==0 先在读取点 revert `ZeroExchangeRate()`。 |
| `ZeroExchangeRate()` | `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 读回的 SY `exchangeRate()` 为 0；`::stakeForGenesis` / `::previewStake` 在该读取点触发。 | 无 | fail-closed 单点守卫，先于一切换算与写入；`redeem` 的 SY 直出路径不读率，不受影响（owner 退出通道）。 |
| `MinStakeInsufficient(uint256 minStake)` | `::stakeForGenesis` 与 `::previewStake` 的 `amountInSY < minStake()`。 | `minStake`：当前配置的最小 SY 数量。 | stakeForGenesis 在 transfer 前触发；preview 不写状态。 |
| `PositionAccessDenied()` | `::redeem` 的 `onlyPositionOwner` 在仓位不存在或 caller 非记录 owner 时。 | 无 | owner/existence 守卫先于状态写入与外部调用。 |
| `ExceedsPositionBalance(uint256 requested, uint256 available)` | `::redeem` / `::previewRedeem` 的 `syRedeemed > position.syStaked`。 | `requested`：请求的 SY 数量；`available`：仓位当前 SY 数量。 | 输入守卫在任何写入前。 |
| `PartialRedeemMustLeaveDebt()` | `::redeem` / `::previewRedeem` 的 partial 分支在 ceil 计算后 `principalPortion >= principalDebt`。full redeem 不进入此分支。 | 无 | 在仓位减记、repay 与输出前触发；不留下 SY 仍在而本金已被清零的 partial 仓位。 |
| `InsufficientTokenOut(uint256 actual, uint256 minExpected)` | `::redeem` 直接输出 SY 时 `syRedeemed < minTokenOut`；非 SY 输出由 `SY.redeem` 依赖校验。 | `actual`：本地可交付 SY 数量；`minExpected`：调用者下限。 | 在仓位 apply 前；revert 原子回滚。 |
| `DecimalsMismatch(uint8 cachedCanonical, uint8 currentCanonical, uint8 cachedUAsset, uint8 currentUAsset)` | `OutrunStakingPositionUpgradeable.sol::_authorizeUpgrade` 在 `SY.assetInfo().assetDecimals` 或 `uAsset.decimals()` 实时值与 `initialize` 缓存值漂移时。 | 缓存与实时两组 decimals。 | UUPS 升级守卫，发生在任何存储布局迁移前；漂移须重部署 SY+position 解决。 |
| `DutyCap(uint256 newDuty)` | `::initialize` 的 `duty_ > DUTY_CAP` 及 `::setDuty` 的 `newDuty > DUTY_CAP`（上限 `DUTY_CAP = 1000000004431822129783699001`，年化 15% 等效每秒率）。 | 新值。 | setter 本地校验，无状态变化。 |
| `InsufficientUAssetMinted(uint256 mintedUAsset, uint256 minMinted)` | `::stakeForGenesis` 的 `mintedUAsset < minUAssetMinted`（SP 本地声明）。 | `mintedUAsset`：实际铸出量；`minMinted`：调用者下限。 | 铸出量计算后、仓位写入与 mint 之前；整笔回滚。零值 `minUAssetMinted` 为无保护透传。 |
| `InvalidParam()` | `::stakeForGenesis` 的 `mintedUAsset > type(uint128).max`（与 router 路径 A（`genesisByPSM`）的同名守卫同构，launcher 参数域为 uint128）。 | 无 | 铸出量计算后、对 launcher 的 approve 与 `genesis` 调用之前。 |
| `GenesisLauncherNotSet()` | `::stakeForGenesis` 的 `genesisLauncher == address(0)`（部署默认态或 owner 置零＝入口禁用，kill switch）。 | 无 | 前置守卫，先于一切资金移动与写入。 |
| `GenesisGateLib.GenesisUAssetNotConsumed(uint256 residualBalance, uint256 residualAllowance)` | `::stakeForGenesis` 后置断言（`GenesisGateLib.sol::assertFullConsumption`）：`IMemeverseLauncher.genesis` 返回后 SP 的 uAsset 余额 != 铸出前基线，或对 `genesisLauncher` 的 allowance 非零（任一成立即触发）。 | `residualBalance`：余额相对铸出前基线的残余；`residualAllowance`：对 launcher 的残余授权。 | 部分消费、转回或任何残余 → 整笔回滚（仓位与铸出一并消失，§3.1）；launcher 自身 revert 属依赖边界原样透传。 |

本地错误与下游依赖边界固定：`uAsset.mint` 的 mint cap（`ReachMintCap`）、`uAsset.repay` 的余额/授权、`uAsset` ERC20 transferFrom 的余额/授权、`SY.redeem` 的 token 校验与输出下限、oracle adapter 的 `StaleOracleAnswer` 等喂价错误、SY 侧锚点偏差熔断的 `RateDeviationExceeded`（oracle-backed SY 基类带外读数 revert，经 `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 原样透传——`stakeForGenesis` / `previewStake` fail-closed，`redeem` SY 直出不读率、不受影响，与 `ZeroExchangeRate` 消费面同口径）、initializer 的 `assetInfo()`/`decimals()` 失败，以及 `genesisLauncher.genesis` 的自身回退，不改名为 position manager 错误；revert data 原样透传并回滚本地已做写入。

### 11.2 事件全表（7 个）

下表按 `IOutrunStakeManager.sol` 声明与 `OutrunStakingPositionUpgradeable.sol` emit 点记录。

| 事件 | 字段（单位） | indexed 字段 | 状态 / 索引含义 |
| --- | --- | --- | --- |
| `Stake` | `positionId`；`owner`（地址）；`amountInSY`（SY units）；`mintedUAsset`（uAsset units，= 该仓初始 `principalDebt`）。 | `positionId`, `owner` | `::stakeForGenesis` 成功创建仓位、铸 uAsset 后发出（随后另发 `StakeForGenesis`）；owner 可与 caller 不同。 |
| `StakeForGenesis` | `positionId`；`positionOwner`（地址）；`verseId`（uint256，launcher opaque ID 原样转发）；`mintedUAsset`（uAsset units，= 该仓初始 `principalDebt`）。 | `positionId`, `positionOwner` | `::stakeForGenesis` 后置断言通过后紧随同 positionId 的 `Stake` 发出；两事件互为印证（§3.1 (h)）。 |
| `Redeem` | `positionId`；`owner`（通过 owner guard 的 `msg.sender`）；`syRedeemed`（SY units）；`principalBurned`（uAsset units，本金腿 burn 量）；`interestPaid`（uAsset units，利息腿转金库量）；`receiver`；`tokenOut`；`amountTokenOut`。 | `positionId`, `owner`, `receiver` | `::redeem` 完成仓位减记/删除、两腿偿还与输出后发出；两腿合计 = 本次总偿付（v1 零费下 `interestPaid == 0`）。full redeem 后 `positions(id)` owner 归零。 |
| `SetDuty` | `oldDuty`、`newDuty`（RAY 1e27 域每秒率）。 | 无 | `::setDuty` 成功；emit 前已完成旧 `duty` 分段结算（§4.3）。 |
| `SetGenesisLauncher` | `oldLauncher`、`newLauncher`（地址）。 | `oldLauncher`, `newLauncher` | `::setGenesisLauncher` 更新 genesis launcher 目标；接受任意地址含零（零＝`stakeForGenesis` 入口禁用 kill switch）。 |
| `SetMinStake` | `minStake`（SY units）。 | 无 | `::setMinStake` 更新阈值；沿用单值形态（旧值由前一事件推导）。 |
| `SetProtocolTreasury` | `protocolTreasury`（地址）。 | `protocolTreasury` | `::setProtocolTreasury` 更新利息腿收款目的地。 |

### 11.3 视图族、Position enumeration 与事件历史

- 计息状态视图族：`duty()`、`rate()`（已结算存储值）、`rateLastSettledAt()`（最近结算 timestamp）、`currentRate()`（外推至当前时刻，不写）；仓位级 `pendingInterest(positionId)`（未结算利息，外推）、`positionDebt(positionId)`（= `principalDebt + accruedInterest + pendingInterest`）。
- 参数视图：`minStake()`、`genesisLauncher()`、`protocolTreasury()`、`SY()`、`uAsset()`。
- `positions(positionId)` 返回 `(owner, syStaked, principalDebt, accruedInterest, lastRate)`。
- `idCounter()`（`AutoIncrementIdUpgradeable.sol::idCounter`）返回最后已签发的 position id；有效 id 从 1 起单调递增、永不复用。链上枚举把 `1 .. idCounter()` 作为候选范围逐项读取 `positions(id)`；`owner == address(0)` 表示从未创建或已删除（full redeem 后留下可观测 id 空洞，无 active-id 数组）。
- 事件历史与 storage 互补：`Stake` + `StakeForGenesis` 发现创建（含 `verseId`），`Redeem` 记录两腿减记/删除，`Set*` 族记录配置变更（含 `SetGenesisLauncher`）。当前余额、剩余债务以 `positions(id)` 与视图族为准。

## 12. POLend 对账接口预留（`globalDebtByUAsset` 视图族）

- 语义：按 uAsset 族聚合的 Memeverse 侧杠杆债务视图——返回该族 POLend（Memeverse 杠杆创世供给）未偿本金债务总额，18-dec uAsset 单位；配套概念「未结 preRedeem backing」指 Memeverse 创世/preRedeem 流程中已铸出但对应仓位尚未完成赎回结算的背书量。
- 归属：子账本由 Memeverse 侧持有与实现，本仓库只预留接口语义，不在本仓库实现或部署该视图。
- 消费方：uAsset 供给侧第三行对账（§10.2 第三行）——`POLend 行 == Σ globalDebtByUAsset + 未结 preRedeem backing`；跨仓库对账流程在协议层文档落地，本文只固定公式与接口语义。

## 13. 测试与不变量验收清单

v1 合约变更落地时，测试/不变量以下列条目为验收基准：

1. **守恒式**：任意状态变更后 `SP 合约 SY 余额 == Σ active positions.syStaked`（§10.1；遍历 `1 .. idCounter()` 断言）；两种断言口径——handler 流（无第三方直转 SY）断言严格等式，fuzz 含捐赠流断言余额 ≥ 分解项之和且差值恰为累计捐赠沉淀。
2. **对账式（本金 + 应计 + PSM 豁免）**：`amountInMinted(SPx) == Σ active positions.principalDebt` 恒成立；应计利息结算/支付前后 minter 台账不动（利息腿只 transfer）；PSM 储备铸烧不改 minter 台账（豁免行回归，真源 `docs/spec/psm/peg-stability-module.md`）。
3. **背书不变式 fuzz（v1 核心锚点）**：任意状态下逐活动仓位断言 `positions.principalDebt ≤ syStaked × exchangeRate(铸造时点)`、聚合断言 `amountInMinted(SPx) ≤ Σ collateralValue`（各仓按其铸造时点汇率计）；fuzz 含汇率上行（背书率单调改善）与 dust 边界（两段 down 归零面）；uAsset 侧仅 SP minter 经 `mint` 铸出（PSM 走储备路径、OFT 走 `_credit`）。
4. **oracle fail-closed**：oracle adapter stale/零率 revert 时 `stakeForGenesis`/`previewStake` 原子拒绝（`ZeroExchangeRate` 本地分支 + adapter 依赖错误透传分支各自覆盖）；`redeem` SY 直出不读率、可用（owner 退出通道回归）。
5. **accrual 精度**：interest 结算对独立参考实现（`Δint = principalDebt × (rateNow − lastRate) / 1e27`，`rateNow = rmul(rpow(duty, dt), rate)` 逐步模拟，时间经 warp 推进）逐步一致；复利性质（累计 `rate` 按 `duty` 复利增长）；partial redeem 后按新本金续计；同秒（同一 timestamp）preview/执行一致；`rate` 单调不减；距上次结算触点 N 秒后开仓的仓位，首次结算利息按开仓时刻起算（开仓前 N 秒不产生本仓利息，`lastRate` 为开仓时刻结算后快照、`initialize` 后首触点自 init 时刻起算）；零费（`duty = 1e27`）下 `rate` 恒 `1e27`、`pendingInterest` 恒 0、`accruedInterest` 恒 0。
6. **调息边界**：`new < 1e27`（含 0，sub-RAY）revert `ZeroInput`，`new > DUTY_CAP` revert `DutyCap`；`new == 1e27` 合法（零费哨兵放行）；域内 `[1e27, DUTY_CAP = 1000000004431822129783699001]` 任意值一笔可设，两端可设；分段生效——变更时刻前后利息按旧/新 `duty` 各计各的。
7. **repay 双腿（本金 burn / 利息 transfer）**：redeem 的本金腿减少 SP minter `amountInMinted` 并 burn 调用者余额、利息腿等额转 `protocolTreasury` 且不改 `amountInMinted`/`totalSupply`（除 transfer 的持有人变化）；allowance 不足时依赖边界整笔回退。
8. **参数面全表回归**：§6/§11.1 每个 setter（`setDuty`/`setGenesisLauncher`/`setMinStake`/`setProtocolTreasury`）的接受/拒绝矩阵与 `Set*` 事件字段；`initialize` 同套校验与零值拒绝。
9. **暂停矩阵回归**：[state-machines.md](./state-machines.md) §8 矩阵逐行（SP/SY/uAsset 三级对 stakeForGenesis/redeem 的阻断面）；SP 暂停期计息外推继续（运维含义）。
10. **mint-as-you-accrue 禁令**：任何只触发计息结算（redeem partial、视图外推、setDuty）的路径不改变 `uAsset.totalSupply()`（零费下计息增量恒 0，禁令对 `duty > 1e27` 域保持回归）。
11. **genesis 物理门（`stakeForGenesis`，测试面见 `test/upgradeable/OutrunStakingPositionUpgradeable.t.sol`）**：成功路径后 SP 的 uAsset 余额恒等于调用前（mint→consume 交易内闭环守恒断言）；mock launcher 部分消费 / 转回 → `GenesisUAssetNotConsumed` 整笔回退（无仓位、无铸出）；launcher revert → 无仓位、无 mint；`genesisLauncher == address(0)` → `GenesisLauncherNotSet` 先于资金移动。
12. **uint128 边界与 minUAssetMinted 下限**：`mintedUAsset > type(uint128).max` → `InvalidParam()`（恰等上限可过）；`mintedUAsset < minUAssetMinted` → `InsufficientUAssetMinted(mintedUAsset, minMinted)`（零值下限为无保护透传）。
13. **router 薄转发等价**：router `genesisBySY`/`genesisByToken` 与直接调用 `SP.stakeForGenesis`（同输入同参数）铸出额、仓位字段、launcher 收额一致（等价性测试见 `test/upgradeable/RouterProxyIntegration.t.sol`）；router 路径 B 全程不持有 uAsset；部署布线验收（`GENESIS_LAUNCHER` env + `SP.genesisLauncher() == router.memeverseLauncher()` 同址断言）见 `test/upgradeable/OutstakeScriptMockSYDeploy.t.sol`。

preview 面注记：不新增 genesis 专属 preview；`previewStake` 公式同式覆盖执行入口（genesis 消费量 == 铸出量，确定性），genesis 专属守卫（`minUAssetMinted`、uint128、launcher 禁用、后置断言）只在执行入口可见。
