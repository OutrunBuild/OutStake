# OutStake State Machines

> 状态：v1 语义（genesis-only、面值铸造、0% 利率默认、无清算）已落地。本文描述 position 层 v1 的用户可见状态机：`stakeForGenesis`（唯一铸造入口）、`redeem`、参数 setter 与 pause；清算与 CollSurplus 领回生命周期随 v1 无清算决策删除（§4/§5 编号退役不复用），各入口的实际执行顺序与错误/事件交叉引用见正文。

## 1. 文档目的

本文档把 v1 position 层的用户可见主流程整理成状态机表达：`stakeForGenesis`、`redeem`、参数 setter 与 pause。完整错误参数、回滚边界与事件字段以 [accounting.md §11](./accounting.md) 为 canonical surface；本文件记录各入口的实际执行顺序与错误/事件交叉引用。

## 1.1 Upgradeable readiness

staking position 仍以 `OutrunStakingPositionUpgradeable` + `ERC1967Proxy` 部署：

- initializer 落位 owner、`SY`、`uAsset`、参数族（`duty`/`minStake`/`protocolTreasury`，边界校验同 setter，init 期无棘轮检查；默认值由部署脚本传入——v1 全族 `duty = 1e27` 零费，[accounting.md §6](./accounting.md)）。`genesisLauncher` 不是 initialize 参数：SP 部署默认零地址＝`stakeForGenesis` 入口禁用，部署后由 owner 经 `setGenesisLauncher` 布线（§6）。计息锚为 timestamp 秒（无 `SECONDS_PER_YEAR` 换算常数、无 per-chain 定值、无对应 env 键，[accounting.md §4](./accounting.md)）。
- `OutrunStakingPositionUpgradeable` 直接继承 `UUPSUpgradeable`，upgrade authorization 由 `onlyOwner` 控制（decimals 漂移守卫 `DecimalsMismatch` 保留）。
- `SY` 初始化后保持固定；不新增 `setSY()` 状态转移。
- 全部资金面状态变更入口（`OutrunStakingPositionUpgradeable.sol::stakeForGenesis` / `::redeem`）挂 `nonReentrant`（transient guard，经 `TokenHelper.sol` 继承 `ReentrancyGuardTransient`）与 `whenNotPaused`；移除该锁或重排内外部调用与状态写入顺序前必须重新论证重入安全。
- wrap 池、keeper、revenuePool、harvest、自由借贷（`stake`）与清算（`liquidate`/`claimCollSurplus`）路径全部删除，本文件不再含其状态机。

## 2. stakeForGenesis 生命周期（唯一铸造入口，SP 原生物理门）

`OutrunStakingPositionUpgradeable.sol::stakeForGenesis(amountInSY, positionOwner, verseId, minUAssetMinted)`（`nonReentrant` + `whenNotPaused`）是 v1 唯一的铸造入口（面值/价值平价铸出）；步骤 1-8 为同一流程的生命周期概述，与 [accounting.md §3.1](./accounting.md) (a)-(h) 同序；执行序冲突时以 accounting.md §3.1 为准。

1. 调用前状态：用户持有 `SY`（或先经 router 换成 `SY`；任意 EOA/合约可直接调用本入口，router 非必经）。
2. 前置守卫：合约未 paused；`genesisLauncher == address(0)` → `GenesisLauncherNotSet()`（入口禁用态/kill switch，先于一切资金移动）；`amountInSY` 或 `positionOwner` 为零 → `ZeroInput()`；`amountInSY < minStake()` → `MinStakeInsufficient(minStake)`。
3. 抵押定价与 dust 守卫：读率点守卫——`exchangeRate()` 读回 0 先 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 单点读取）；`collateralValue = SY -> canonical asset -> uAsset`（两段 down，无 LTV 缩放段）；`mintedUAsset == 0` → `DustRoundedToZero()`，先于 SY transfer，不创建零债仓位。
4. genesis 专属量守卫：`mintedUAsset < minUAssetMinted` → `InsufficientUAssetMinted(mintedUAsset, minMinted)`；`mintedUAsset > type(uint128).max` → `InvalidParam()`。
5. 资产进入与状态写入：`SY` 转入 position 合约；先把 SP `rate` 结算到当前时刻，再生成新 `positionId`，写入五字段 `Position{owner = positionOwner, syStaked = amountInSY, principalDebt = mintedUAsset, accruedInterest = 0, lastRate = rate()（结算后快照）}`——不承接开仓前未结算时间的利息（首次结算利息按开仓时刻起算）。
6. 铸造与原子交款：`uAsset.mint(address(this), mintedUAsset)`（铸给 SP 自身，SP minter 台账正常入账）→ 对 `genesisLauncher` 精确 approve 恰好 `mintedUAsset` → `IMemeverseLauncher.genesis(verseId, uint128(mintedUAsset), positionOwner)`（`verseId` 原样转发不校验；launcher 自身 revert 属依赖边界整笔回滚）。
7. 后置断言：`genesis` 返回后 SP 的 uAsset 余额必须回到铸出前基线且对 `genesisLauncher` 的 allowance 为 0，否则 `GenesisUAssetNotConsumed(residualBalance, residualAllowance)` 整笔回滚——部分消费、转回或任何残余都使仓位与铸出一并消失（物理门：铸出资金只能在单笔交易内到达 launcher）。
8. 完成状态：仓位进入活跃态，即普通仓位（redeem 双腿销债、按 [accounting.md §4](./accounting.md) 计息——v1 零费默认下利息腿恒 0；无额外状态、无锁仓）；成功后双事件 `Stake(positionId, positionOwner, amountInSY, mintedUAsset)` + `StakeForGenesis(positionId, positionOwner, verseId, mintedUAsset)`（[accounting.md §11.2](./accounting.md)）。

## 3. redeem 生命周期（任意时刻按比例双腿销债）

`OutrunStakingPositionUpgradeable.sol::redeem(positionId, syRedeemed, receiver, tokenOut, minTokenOut)` 为 position owner 专属（`onlyPositionOwner`），无时间门。

1. 前置守卫：合约未 paused；仓位不存在或 caller 非记录 owner → `PositionAccessDenied()`；`receiver == address(0)` 或 `syRedeemed == 0` → `ZeroInput()`；`syRedeemed > syStaked` → `ExceedsPositionBalance(syRedeemed, syStaked)`。
2. 利息结算（写状态触点）：SP `rate` 结算到当前时刻，本仓 `accruedInterest += Δint`、`lastRate = rate()`（公式与取整见 [accounting.md §4](./accounting.md)；v1 零费默认下 `Δint == 0`）。
3. 两腿份额计算（不读汇率）：full（`syRedeemed == syStaked`）→ `principalPortion = principalDebt`、`interestPortion = accruedInterest`；partial → 两腿按 `syRedeemed / syStaked` 比例 ceil；partial 耗尽本金（`principalPortion >= principalDebt`）→ `PartialRedeemMustLeaveDebt()`。
4. 直接 SY 输出 slippage：`tokenOut == SY` 且 `syRedeemed < minTokenOut` → `InsufficientTokenOut`（position 减记前）。
5. 仓位更新（CEI：状态先于外部调用）：`syStaked -= syRedeemed`、`principalDebt -= principalPortion`、`accruedInterest -= interestPortion`；剩余 `syStaked == 0` 删除仓位（id 空洞）；守恒引用见 [accounting.md §10.1](./accounting.md)。
6. 两腿偿还（利息腿先行）：
   - 利息腿：`interestPortion > 0` 时从调用者 transfer 等值 `uAsset` 至 `protocolTreasury`（不 burn、不冲销台账）。
   - 本金腿：`uAsset.repay(msg.sender, principalPortion)`——burn 调用者余额并等额冲减 SP minter `amountInMinted`。
   - 调用前提：owner 需持有并 approve SP 合约不少于 `principalPortion + interestPortion` 的 `uAsset`；不足时依赖边界错误整笔原子回退。
7. 资产输出：`tokenOut == SY` 直接转出 `syRedeemed`；否则 `SY.redeem(receiver, syRedeemed, tokenOut, minTokenOut, false)`。
8. 完成状态：仓位「部分赎回后继续存在（按新本金续计息）」或「已清空删除」；发出 `Redeem(positionId, owner, syRedeemed, principalBurned, interestPaid, receiver, tokenOut, amountTokenOut)`。

`previewRedeem(positionId, syRedeemed, tokenOut)` 复用同一判定/舍入/拒绝规则，返回 `(principalPortion, interestPortion, amountTokenOut)`；SY 直出不读汇率（退出通道不依赖 oracle）。

## 4. liquidate 生命周期（已随 v1 无清算决策删除，编号退役）

## 5. claimCollSurplus 生命周期（已随 v1 无清算决策删除，编号退役）

## 6. 参数 setter 状态机

全部 setter 为 `onlyOwner`；参数语义与默认值见 [accounting.md §6](./accounting.md)，错误全表见 [accounting.md §11.1](./accounting.md)。每个 setter 成功即 emit 对应 `Set*` 事件（[accounting.md §11.2](./accounting.md)），失败无状态变化。

| setter | 接受条件（全部同时满足） | 拒绝分支（任一即 revert） | 生效范围 |
| --- | --- | --- | --- |
| `setDuty(new)` | `1e27 ≤ new ≤ DUTY_CAP`（`DUTY_CAP = 1000000004431822129783699001`，年化 15% 等效每秒率；`1e27` 零费哨兵合法且为 v1 默认） | `new < 1e27`（sub-RAY 即负利率，含 0）→ `ZeroInput`（保 `rate` 单调不减；pause 才是熔断器）；超上限 → `DutyCap`（`BorrowRateBelowResolution` 已废除） | 写入前先按旧 `duty` 把 `rate` 结算到当前时刻（复利整段闭式增量、分段生效），新 `duty` 前瞻作用于全部存量债务 |
| `setGenesisLauncher(new)` | 任意地址（含零） | 无本地拒绝分支——零是合法态（＝禁用 `stakeForGenesis` 入口，kill switch） | 后续 `stakeForGenesis` 的 launcher 目标；emit `SetGenesisLauncher(oldLauncher, newLauncher)` |
| `setMinStake(new)` | `new > 0` | 零 → `ZeroInput` | 后续 `stakeForGenesis` / `previewStake` 的下限（双向可调，不设上限） |
| `setProtocolTreasury(new)` | `new != address(0)` | 零地址 → `ZeroInput` | 后续利息腿收款目的地（v1 零费默认下恒 0 腿，参数保留供未来加息） |

setter 语义说明：`duty` 无棘轮但有接受域 `[1e27, DUTY_CAP]`（域内一笔可达，两端可设；sub-RAY 恒以 `ZeroInput` 拒绝，超上限以 `DutyCap` 拒绝）；`minStake` 双向可调；`genesisLauncher` 接受任意地址含零（零＝禁用 genesis 入口的合法 kill switch 态）。v1 删除的 `setMintLtv`/`setLiquidationLtv`/`setLiquidationPremium`/`setGenesisRateMultiplier` 无状态转移。`pause` / `unpause` 为 owner 熔断开关（§8），不属参数面。

## 7. preview / view 面边界

- preview 族：`previewStake`（quote 铸出量，dust 返 0 而执行 revert，刻意分歧）、`previewRedeem`（两腿 + tokenOut 报价）——均不写状态、不预留 cap、不校验执行期调用者身份（owner 身份属执行期守卫），但镜像执行入口的金额/存在性/读率点失败面。v1 无 genesis 专属 preview（genesis 消费量 == 铸出量，确定性）。
- 计息视图族：`duty` / `rate` / `rateLastSettledAt` / `currentRate` / `pendingInterest` / `positionDebt`（外推口径，不写状态；字段与语义见 [accounting.md §11.3](./accounting.md)）。
- preview / view 均不受 SP 级 pause 影响（§8）。

## 8. Pause / unpause 的影响

> 暂停矩阵：三 owner 开关（SP / SY / uAsset）任一关闭即冻结 SP 全部用户面；uAsset 暂停为全协议熔断但 `_credit` 仍增供给（单边增长）。本节为执行真值，运维矩阵与告警见 `docs/deployment.md`。

### 8.1 Position 级 pause

`OutrunStakingPositionUpgradeable.pause()` / `unpause()` 由 owner 控制，直接影响带 `whenNotPaused` 的两个业务入口：

- `stakeForGenesis`
- `redeem`

对应的 preview / view 函数不受该 pause 影响。计息为纯账面外推，SP 暂停期间 `rate` 继续按秒增长（`duty > 1e27` 时债务继续累积，恢复后结算补足；v1 零费默认下 `rate` 恒 `1e27`，无此面。暂停只是入口熔断，不是计息冻结）。

### 8.2 SY token 级 pause

`SYBase` 继承 `OutrunERC20PausableUpgradeable`：`SY.deposit` / `SY.redeem` 自带函数级 `whenNotPaused`，常规 SY transfer 由 `_update` 的 `whenNotPaused` 兜底。当前影响：

- `stakeForGenesis`（SY 转入被阻）
- `redeem`：SY 直出路径被阻；`tokenOut != SY` 路径经 `SY.redeem` 亦被阻

SY pause 不阻断 uAsset 面；两腿偿还的 uAsset 操作不受该级影响（但整笔交易因 SY 输出失败而原子回滚）。

存在活跃仓位时，SY 单独暂停对用户面的效果等价于冻结全部赎回出口：`redeem` 的两条输出路径（SY 直出与 `tokenOut != SY` 的 `SY.redeem` 兑换）均经 SY，任一暂停即全断。不设操作禁令——紧急场景（SY 自身故障、底层协议事故）允许单独执行 `sy.pause()` 立即止血；运维护栏为部署侧单边态监控与时长告警，见 `docs/deployment.md`「SP v1 运行手册」暂停矩阵运维节。与 uAsset 的不对称依据：uAsset 暂停附带 `_credit` 单边供给增长与全协议熔断副作用，故计划内禁止单停（紧急场景可单独执行但须事后公告与补齐协同暂停）；SY 暂停只冻结赎回出口、无单边供给增长副作用，故不设禁令仅告警。

### 8.3 uAsset 级 pause

`OutrunUniversalAssetsUpgradeable` 经 `OutrunOFTUpgradeable` → `OutrunERC20PausableUpgradeable` 继承 pause 家族，可被其自身 owner 独立 pause。阻断分两层：`mint` / `repay` 自带函数级 `whenNotPaused`；常规 transfer（含利息腿的 transferFrom 拉取）与 OFT outbound send 由 `_update` 的 `whenNotPaused` 兜底（跨链 inbound `_credit` 豁免，见 `docs/spec/common-foundations.md`「Pause 与跨链 OFT 执行边界」）。当前影响：

- `stakeForGenesis`（经 `uAsset.mint` 铸出与 launcher `transferFrom` 拉取，两处都被阻）
- `redeem`（本金腿经 `repay`、利息腿经 transfer，两腿都被阻；v1 零费默认下利息腿恒 0，本金腿仍被阻）

协同约束：存在待赎回仓位时，uAsset 单独暂停会阻断全部销债出口；需与 `position.pause()` 同步执行或改用 `setMintingCap`/`revokeMinter` 限制 mint 面，见 `docs/deployment.md` 暂停矩阵运维节。

### 8.4 暂停矩阵（执行真值）

| 暂停方 | 触发 | SP 用户面影响 | uAsset 面 | SY 面 | 恢复 | 备注 |
|---|---|---|---|---|---:|---|
| SP `pause()` | `position.pause()` | `stakeForGenesis`/`redeem` 全部 `EnforcedPause` | 无直接影响（但 SP 的 `mint`/`repay`/transfer 依赖 uAsset 未暂停） | 无直接影响 | `unpause()` | preview/view 不受影响；计息外推继续 |
| SY `pause()` | `sy.pause()` | `stakeForGenesis`（SY 转入）、`redeem`（SY 直出与 `SY.redeem`）间接 `EnforcedPause` | 无直接影响 | `deposit`/`redeem` `EnforcedPause` | `unpause()` | 单独暂停等价冻结全部赎回出口；不设操作禁令，单边态与时长告警见 `docs/deployment.md` |
| uAsset `pause()` | `uAsset.pause()` | `stakeForGenesis`(`mint` + launcher 拉取)、`redeem`（本金腿 `repay` + 利息腿 transfer）全部 `EnforcedPause` → 全协议熔断 | `mint`/`repay`/`transfer`/`_debit`/`reserveMint`/`reserveBurn` `EnforcedPause`；`approve` 不受影响 (OZ 标准)；`_credit` 显式绕过 `whenNotPaused` 仍铸币；`reserveMint`/`reserveBurn` 阻断即 PSM 双向兑换 fail-closed | 无直接影响 | `unpause()`；恢复后 `repay` 立即恢复 | 暂停期供给单边增长需告警，见 `docs/deployment.md`；USR vault `deposit`/`mint`/`withdraw`/`redeem`/`fund` 经 uAsset transfer 传导 fail-closed，见 `docs/spec/usr/usr-vaults.md`「暂停联动」 |

- `uAsset` `_credit` 豁免：`OutrunOFTUpgradeable.sol::_credit` 直调 `OutrunERC20Upgradeable._update`，符合「桥接入账不可丢资产」实践；暂停期 `totalSupply` 仍增，见 `test/upgradeable/OutrunOFTUpgradeable.t.sol::testPausedTokenAllowsInboundCredit` 回归。`repay` 不豁免：uAsset 暂停时 `redeem` 的本金腿随之 `EnforcedPause`。
- 限流器与暂停为两级出站熔断：`setOutboundRateLimit` 的 `limit==0` 已被 `InvalidRateLimit` 拒绝，不再用作单链冻结。
- 运维：三 `owner` 主网前收敛为 timelock/multisig，暂停时长设告警（`<24h`，`_credit` 单边增长需监控）；存在待赎回仓位时计划内操作禁止单独 `uAsset.pause()`（紧急场景可单独执行但须事后公告与补齐协同暂停），见 `docs/deployment.md` 暂停矩阵运维节。SY pause 权限分层：`pause` 允许快速路径（multisig/keeper 秒级执行），`unpause` 与权限变更收敛 timelock/治理延时（错误恢复比错误暂停危害大）；「SP 未暂停而 SY 已暂停」列为单边态告警条件，SY 暂停时长告警与 uAsset 的 `<24h` 阈值对齐，见 `docs/deployment.md` 暂停矩阵运维节。

### 8.5 跨账本不变量与治理

`uAsset.mintingStatusTable[SP].amountInMinted == Σ positions[id].principalDebt`（应计利息单列不进铸账）仅由代码路径隐式维持，无链上强制；唯一可打破的是 `uAsset.transferMinterDebt`。主网前 `uAsset`/`SP` `owner` 收敛为 timelock/multisig；`transferMinterDebt` 仅限修复无仓位债支撑的错账，活 SP 退役走清偿路径（`setMintingCap`(SP,0) → 存量经 `redeem` 清偿 → `revokeMinter`），禁用于活账本迁移；`setMinStake` 可即时 DoS 新开仓，变更走公示。三行对账式与验收步骤见 [accounting.md §10.2](./accounting.md)。
