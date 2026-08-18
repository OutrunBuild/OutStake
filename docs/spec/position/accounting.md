# OutStakeV2 Accounting

## 1. 文档目的

本文档说明 `OutStakeV2` 当前实现中的核心账务规则，并明确 mixed-decimals 双段换算语义，包括 `uAsset` minter-cap、position debt、wrap 池、汇率换算、赎回按比例销债、keeper redeem 分账与 wrap yield harvest。

## 1.1 Upgradeable accounting readiness

当前 implementation 使用 proxy-backed uAsset、SY adapter 与 staking position，并保持本文账务语义：

- `OutrunUniversalAssetsUpgradeable` 的 `mintingStatusTable` 继续按 minter 维度记录 `mintingCap` 与 `amountInMinted`。
- `OutrunStakingPositionUpgradeable` 继续按 position 记录 `syStaked` 与 `UAssetMinted`，并按公共 wrap 池记录 `syTotalStaking`、`syWrapStaking`、`wrapUAssetDebt`。
- `OutrunStakingPositionUpgradeable.sol` 的 V1 ERC-7201 namespace 将 `SY` 与两个 decimals 配置值打包在同一个 storage word；`minStake` 至 `positions` 的后续字段位置保持不变。该布局优化适用于 V1 发布前；若存在旧布局 proxy，升级前必须迁移旧 decimals 或恢复旧 struct 顺序。
- `SY` 依赖在 initializer 中写入后保持固定，不新增 `setSY()`，避免 position / wrap debt 对应的 share token 与 exchangeRate source 被替换。
- oracle-backed SY upgradeable variants 可通过 owner-only `setExchangeRateOracle(address)` 更换 `exchangeRateOracle`，但 setter 不改变 balances、shares、position accounting 或 yield-bearing token 配置。
- `OutrunExchangeOracleAdapter` 仍是非 upgradeable adapter（做 raw answer 正性、新鲜度窗口 `maxStaleness`（`updatedAt == 0`、`updatedAt > block.timestamp`（feed 时钟超前）或超窗均 fail-closed，revert `StaleOracleAnswer`）、可选构造期 sequencer 校验，并在精度归一化后校验结果非零（`ZeroNormalizedRate`）；不提供 bounds/fallback/多源聚合）；本次变更仅在归一化后追加非零校验（`ZeroNormalizedRate`），归一化前的正性/新鲜度/sequencer 校验语义不变。
- 旧 non-upgradeable contracts 已退出当前产品真源；当前 upgradeable variants 的 V1 storage layout 是后续升级的 canonical layout。L2 oracle-backed SY 变体（`OutrunL2StakedTokenSYUpgradeable` / `OutrunL2WstETHSYUpgradeable`）在共享基类中的 state（`exchangeRateOracle` 引用与 underlying asset 元数据）使用基类 ERC-7201 槽 `erc7201("outrun.storage.OutrunL2OracleBackedSY")`；原 per-subclass 命名空间 `outrun.storage.OutrunL2StakedTokenSY` / `outrun.storage.OutrunL2WstETHSY` 已并入该槽，升级兼容性以新槽为准。前提：当前无任何测试网/主网部署这两个变体（无存量旧布局 proxy），V1 发布前布局变更无需迁移函数；若出现任何存量部署，必须先提供迁移函数或恢复旧命名空间。

## 2. `uAsset` 的 minter-cap 账务

`OutrunUniversalAssetsUpgradeable` 当前按 minter 维护一张 `mintingStatusTable`：

- `mintingCap`
- `amountInMinted`

当前账务规则是：

- `checkMintableAmount(minter)` 返回 `mintingCap - amountInMinted`，最低到 0。
- `mint(receiver, amount)` 由调用者自己的 minter 额度承担，成功后增加调用者的 `amountInMinted`。
- `repay(account, amount)` 减少调用者（`msg.sender`，即 minter）自己的 `amountInMinted`；`account` 是被 burn 的地址，必须持有足够的 `uAsset`。若 `account != msg.sender`，则还必须先授权 `msg.sender` 消耗对应 `uAsset`。
- `revokeMinter(minter)` 只把 cap 设为 0 以禁止后续 mint，不会自动清空历史已铸债务；既有 `amountInMinted` 保留到后续 repay。
- `transferMinterDebt(from, to, amount)` 是 owner-only 的 minter 级债务迁移；完整输入校验与账务约束（不 mint/burn/transfer、`mintingCap` headroom、用途限定）以 `docs/spec/common-foundations.md`「基础规则」为准。
- accounting 视角补充：`transferMinterDebt` 只迁移 `uAsset` 的 minter 级债务；若该 minter 还被 `OutrunStakingPositionUpgradeable` 的 position debt、wrap debt 或其他模块账本引用，操作方必须同步完成对应账本迁移，`uAsset` 不会单独更新这些 position/wrap 记录。
- OFT 跨链铸烧豁免（outbound `_debit`/inbound `_credit` 不触碰 minter 债务台账、`_credit` 零地址重映射 `0xdead`）以 `docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」为准。

因此，`uAsset` 当前不是”全局总债务池”，而是”按 minter 独立记账的铸造额度和未偿债务”；owner 只能迁移这笔 minter 维度债务归属，不能消灭债务或改变总供应，也不能仅靠 `uAsset` 调账就让 position/wrap 账本自动一致。

## 3. Position debt 账务

`OutrunStakingPositionUpgradeable` 中每个 `Position` 当前记录：

- `owner`
- `syStaked`
- `UAssetMinted`
- `deadline`

锁仓仓位的初始 debt 规则是：

- 用户 stake `amountInSY`
- 先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `uAssetDebt = canonical asset -> uAsset`
- `uAssetDebt` 同时成为初始 `UAssetMinted`
- position 内写入该值，并调用 `uAsset.mint(...)`

这里的关键点是：position debt 不是按固定 1:1 写入，而是按当前 `exchangeRate()` 折算后的 canonical asset value，再归一化成 `uAsset` 记账单位后写入。

## 4. Wrap 池账务

wrap 池当前使用三组聚合账务变量：

- `syTotalStaking`
- `syWrapStaking`
- `wrapUAssetDebt`

`wrapStake` 时：

- 增加 `syTotalStaking`
- 增加 `syWrapStaking`
- 先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `uAssetDebt = canonical asset -> uAsset`
- 用 `uAssetDebt` 增加 `wrapUAssetDebt`
- 铸造等额 `uAsset`

`keepWrapRedeem` 时（keeper-only，仅直付 SY）：

- keeper 守卫：`msg.sender != keeper()` → revert `PermissionDenied()`
- 先检查 `uAssetDebtUnits = amountInUAsset` 且 `uAssetDebtUnits <= wrapUAssetDebt`
- 先按完整 `wrapUAssetDebt` 的债务覆盖口径计算 `wrapDebtInSY`：`uAsset -> canonical asset` 用 up、`canonical asset -> SY` 用 up
- 池子不足（`wrapDebtInSY > syWrapStaking`）时 revert `WrapPoolUndercollateralized()`（不再按 pro-rata 部分兑付）
- 池子健康后，按本次 `amountInUAsset` 计算 `canonicalAssetValue = uAsset -> canonical asset` 与 `amountInSY = canonical asset -> SY`，两段均用 down
- 减少 `syTotalStaking`
- 减少 `syWrapStaking`
- 减少 `wrapUAssetDebt` 中对应的 `uAssetDebtUnits`
- 烧掉 keeper 自己提供的 `uAsset`（`uAsset.repay(msg.sender, uAssetDebtUnits)`）
- 直接将 `amountInSY` 的 SY 转给 `receiver`（不经 `SY.redeem`，无 tokenOut/minTokenOut）

当前测试已经说明 wrap 池按 principal accounting 运行，不会因为汇率上涨而自动增加用户的 `uAsset` debt。

## 5. 汇率换算

当前仓库把 `exchangeRate()` 视为 `asset per SY` 的统一换算基准，接口层也明确要求：

- `exchangeRate * syBalance / 1e18` 对应资产值
- 如果用户贡献的是价值 X 的资产，则铸出的 SY 或 debt 应通过同一换算关系推导
- position / wrap debt 的统一语义是：先 `SY -> canonical asset`，再 `canonical asset -> uAsset`；需要从 debt 反推 `SY` 时，则先 `uAsset -> canonical asset`，再 `canonical asset -> SY`
- `canonical asset` 在这里是 `exchangeRate()` 定义的价值单位；`canonicalAssetDecimals` 取自 `SY.assetInfo().assetDecimals`，`uAssetDecimals` 取自 `uAsset.decimals()`
- 以下 mixed-decimals 双段换算为当前代码已完成行为；具体单位模型与四个基础公式以 [docs/spec/common-foundations.md](/home/azkrale/Web3Project/OutStakeV2/docs/spec/common-foundations.md) 为准

`OutrunStakingPositionUpgradeable` 的相关账务应按四个基础方向换算：

- `SY -> canonical asset`：`canonicalAssetValue = syToAsset(exchangeRate, syAmount)`
- `canonical asset -> uAsset`：把 `canonicalAssetValue` 归一化为 `uAssetDebtUnits`
- `uAsset -> canonical asset`：把 `uAssetDebtUnits` 反归一化为 `canonicalAssetValue`
- `canonical asset -> SY`：`syAmount = assetToSy(exchangeRate, canonicalAssetValue)`，必要时使用向上版本

rounding matrix：

- mint / stake / wrap stake / `previewStake(amountInSY)` / `previewWrapStake(amountInSY)`：
  - `SY -> canonical asset` 用 down
  - `canonical asset -> uAsset` 用 down
  - 失败面 / 0-return：
    - `previewStake`：`amountInSY < minStake()` → `MinStakeInsufficient()`；rate==0 → `ZeroExchangeRate()`；dust 下取整为 0 → 返回 `0`（不触发 `DustRoundedToZero()`）
    - `previewWrapStake`：`amountInSY == 0` → `ZeroInput()`；rate==0 → `ZeroExchangeRate()`；报价为 0 → `DustRoundedToZero()`
    - 执行入口 `stake` / `wrapStake` 的对应触发见 §11.1
- draw：
  - `SY -> canonical asset` 用 down
  - `canonical asset -> uAsset` 用 down
  - `previewDrawUAsset`：仓位缺失 → `PositionAccessDenied()`；到期（`block.timestamp >= position.deadline`）→ revert `LockTimeExpired()`（不返回 0，镜像执行入口的到期失败，与 `previewRedeem` / `previewKeepRedeem` 镜像 `LockTimeNotExpired()` 的方向一致）；rate==0 → `ZeroExchangeRate()`；无新增可 draw → 返回 `0`（执行入口 `drawUAsset` 同条件 revert `NothingToDraw()`）
- wrap redeem（健康池）：
  - 健康守卫（完整 `wrapUAssetDebt` 的债务等值 SY）：`uAsset -> canonical asset` 用 up、`canonical asset -> SY` 用 up
  - 实际兑付（本次 `amountInUAsset`）：`uAsset -> canonical asset` 用 down、`canonical asset -> SY` 用 down
- wrap redeem（不足池，池值 < 债务面值）：revert `WrapPoolUndercollateralized()`（keeper-only keepWrapRedeem 不再 pro-rata）
- `previewWrapRedeem(amountInUAsset)`：镜像 `keepWrapRedeem` 的健康守卫 up/up 与实际兑付 down/down；失败面包括 `amountInUAsset == 0` → `ZeroInput()`、超 `wrapUAssetDebt()` → `ExceedsWrapDebt()`、rate==0 → `ZeroExchangeRate()`、不足池 → `WrapPoolUndercollateralized()`、兑付为 0 → `DustRoundedToZero()`
- keeper redeem：
  - `uAsset -> canonical asset` 用 down
  - `canonical asset -> SY` 用 down
  - 全仓位守卫：`uAsset -> canonical asset` 用 up、`canonical asset -> SY` 用 up（与 §8 公式 `_assetToSyUp` 对齐）
  - `previewKeepRedeem` 的失败面见 §8 与 §11.1（含 position 存在、lockup、amount 边界、solvency、rate==0、dust）
- `previewRedeem(positionId, syRedeemed, tokenOut)`：
  - full redeem 直接返回全部剩余 `position.UAssetMinted`
  - partial redeem 对 `position.UAssetMinted * syRedeemed / syStaked` 用 up
  - 若 partial 结果会耗尽剩余 debt，则 preview 必须拒绝该报价
  - 失败面包括仓位缺失 → `PositionAccessDenied()`、未到期 → `LockTimeNotExpired()`、`syRedeemed == 0` → `ZeroInput()`、超仓位 → `ExceedsPositionBalance()`、partial 耗尽 debt → `PartialRedeemMustLeaveDebt()`；非 SY 输出可能透传 `SY.previewRedeem` 依赖错误
- harvest coverage：
  - `uAsset -> canonical asset` 用 up
  - `canonical asset -> SY` 用 up

因此，position/wrap 账务都以 `SY` 数量和资产值之间的双向换算为前提，但 mixed-decimals 双段归一化按上表作为当前实现落文。

- 上表三处 up/up 守卫（wrap redeem 健康守卫、keeper redeem 全仓位守卫、harvest coverage）共享 `OutrunStakingPositionUpgradeable.sol::_assetToSyUp` 的双段复合，在 `uAssetDecimals > canonicalAssetDecimals` 且债务非 f 整除（`f = 10 ** (uAssetDecimals - canonicalAssetDecimals)`）时继承同一量化偏差带（至多 `1e18 / exchangeRate + 1` SY wei，exchangeRate ≥ 1e18 时 1 wei；wrap 债务整除性经 `OutrunStakingPositionUpgradeable.sol::keepWrapRedeem` 任意整数减债即可破坏），方向保守、只误拒不放行不足额；量化以 `docs/spec/common-foundations.md` 的「mixed-decimals up/up 双段复合取整偏差」条目为准

## 6. Draw 账务

`drawUAsset(positionId, uAssetReceiver)` 当前的账务规则是：

- position 存在与 owner 守卫通过后、估值/汇率读取之前：未到期检查——`block.timestamp >= position.deadline` 时 revert `LockTimeExpired(position.deadline)`
- 先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `currentValueInUAsset = canonical asset -> uAsset`
- 再读取已有 `position.UAssetMinted`
- 若 `currentValueInUAsset <= positionUAssetMinted`，则 `drawUAsset` 回退 `NothingToDraw()`
- 汇率读取成功且上述条件成立时，`previewDrawUAsset` 仅返回 `0` quote；`rate==0` 时先回退 `ZeroExchangeRate()`
- 否则只允许铸造差额 `currentValueInUAsset - positionUAssetMinted`

成功后：

- `position.UAssetMinted = currentValueInUAsset`（本次 draw 后总债务被重置为当前估值；返回值/事件里的 `mintedUAsset` 仅指本次新增差额 `currentValueInUAsset - positionUAssetMinted`，非新总量）
- 再次检查当前 `uAsset` mint cap 是否足够
- 最后铸造追加的 `uAsset`

因此，draw 当前只把“升值部分”转成新的 debt，不会重写原本金 principal。

## 7. `redeem` 的按比例销债

锁仓仓位赎回时，debt 销毁规则按 full redeem / partial redeem 分叉：

- 用户传入要赎回的 `syRedeemed`
- 若 `syRedeemed == syStaked`，则视为 full redeem，必须精确烧掉该 position 剩余的全部 `position.UAssetMinted`
- 若 `syRedeemed < syStaked`，则视为 partial redeem，`UAssetBurned` 按 `ceil(position.UAssetMinted * syRedeemed / syStaked)` 计算
- partial redeem 额外有一条边界：若上述 ceiling 结果会等于或超过当前剩余 debt，则该 partial 路径必须回退，用户只能改走 full redeem
- `previewRedeem(...)` 与执行期 `redeem(...)` 使用同一条 full / partial 判定与拒绝规则；preview 不能返回一个执行期会因“partial consume all debt”而失败的报价
- position 层先确定 `UAssetBurned` 和允许性，再进入 `uAsset.repay(...)`；正确性不依赖下游出现 `uAsset.repay(0)` 这种零额 repay

如果赎回后 `remainingSY == 0`，position 会被删除；否则保留剩余 principal 与剩余 debt。

这意味着 position redeem 仍然是“按当前仓位内部 debt 比例切片销债”，但 partial 路径使用 ceiling rounding，并显式禁止“剩余 SY 仍在、debt 已被全部烧空”的状态。

这里被销毁的 `position.UAssetMinted` 始终是前述 `SY -> canonical asset -> uAsset` 归一化后记下来的 debt 单位；执行路径不要求在每次 partial redeem 时重新按汇率定价，但该 debt 单位的语义基准保持不变。

## 8. Keeper redeem 分账

`keepRedeem(positionId, amountInUAsset, receiver)` 的账务路径与普通 redeem 不同，当前实现语义如下：

- 输入校验：`amountInUAsset == 0` → revert `ZeroInput()`；`amountInUAsset > position.UAssetMinted` → revert `ExceedsPositionDebt()`
- **全仓位守卫（前置判定）**：先按上取整口径判断仓位整体是否不足额——`if (_assetToSyUp(positionUAssetMinted, exchangeRate) > syStaked) revert InsufficientSyCollateral();`。仓位整体不足额（当前 `SY` 市值低于债务面值）时，任何 `amountInUAsset > 0` 的 keepRedeem 一律 revert，原子回滚——keeper 的 `uAsset` 不被烧、仓位不变，不存在 amount 依赖的残余暴露
- 再按显式 down rounding 公式 `syRedeemed = roundDownDiv(syStaked * uAssetDebtUnits, positionUAssetMinted)` 算出本次实际抽出的仓位 `SY`
- **dust 守卫（保留）**：`syRedeemed == 0` → revert `DustRoundedToZero()`，与现有实现一致；dust 输入不得在不减少 `syStaked` 的情况下烧 debt
- keeper 提供并烧掉自己持有的 `uAssetDebtUnits = amountInUAsset`，并按 `keeperPrincipalSY = _assetToSy(UAssetBurned, exchangeRate)`（即先 `uAsset -> canonical asset`，再 `canonical asset -> SY`）折算其应得本金
- **keeper 侧 dust 守卫**：`keeperPrincipalSY == 0` → revert `DustRoundedToZero()`；keeper 不得为零 SY 支付燃烧非零 uAsset 债（本金腿 floor 为 0 时，分账会把全部 `syRedeemed` 静默划归 owner），与 `keepWrapRedeem` 的 `amountInSY == 0` 守卫对称
- **per-amount 防御判定**：若 `keeperPrincipalSY > syRedeemed`，同样 revert `InsufficientSyCollateral()`（替代对 `keeperPrincipalSY` 的上限收敛写法）；该防御不重复全仓位判断、正常路径不触发，仅作防御性不变量检查保留
- 否则分账不变：剩余 `ownerExcessSY = syRedeemed - keeperPrincipalSY`

不足额判定说明：

- 全仓位守卫与 per-amount 防御都 revert `InsufficientSyCollateral()`，但判定口径不同：前者在仓位整体不足额时一刀切拒绝任何 `amountInUAsset > 0` 的调用，且在全仓位守卫前置下已严格覆盖所有 per-amount 情形；后者不重复全仓位判断、正常路径不触发，仅作为**防御性不变量检查**保留，防止未来重构在成功分账时 `ownerExcessSY = syRedeemed - keeperPrincipalSY` 下溢
- 方向性说明：不足额仓位上任何 `amountInUAsset > 0` 的 keepRedeem，keeper 拿回 SY 的市值不大于所烧 uAsset 面值（当前汇率下至多盈亏平衡，整除边界存在平衡例外），故全仓位一刀切拒绝不会放行任何“实值亏损”的 redeem，只可能误拒（量化偏差带见下述限定）；`revert 触发 ⟺ 仓位整体不足额` 在全仓位守卫口径下成立；限定：在 `uAssetDecimals > canonicalAssetDecimals` 且债务非 f 整除（`f = 10 ** (uAssetDecimals - canonicalAssetDecimals)`）时，up/up 双段复合守卫相对精确紧界存在量化偏差带——至多 `1e18 / exchangeRate + 1` SY wei（exchangeRate ≥ 1e18 时 1 wei），偿付裕度落入该带的“实值不亏”仓位会被误拒（前述「整除边界存在平衡例外」carve-out 只覆盖盈亏平衡，不覆盖带内严格充足）；偏差方向保守——守卫值恒不低于债务精确面值，绝不放行不足额仓位，owner 可经 `OutrunStakingPositionUpgradeable.sol::redeem` 自赎（redeem 无该守卫）；量化与推导以 `docs/spec/common-foundations.md` 的「mixed-decimals up/up 双段复合取整偏差」条目为准
- keepRedeem 对调用者（keeper）的 `uAsset` 零暴露：两种不足额判定触发时调用都失败且不烧 `uAsset`，汇率下跌风险由仓位/owner 承担，不内化到 keeper 调用者

只读查询：

- `previewKeepRedeem(positionId, amountInUAsset) returns (keeperPrincipalSY, ownerExcessSY)` mirror keepRedeem 的 `SY` 分账计算（同一个 `_assetToSy` 与 `roundDownDiv` 公式），并镜像以下失败路径，使”preview 与执行一致”成立：
  - **镜像 amount 相关失败路径**：
    - `amountInUAsset == 0` → `ZeroInput()`
    - `amountInUAsset > position.UAssetMinted` → `ExceedsPositionDebt()`
    - `syRedeemed == 0` → `DustRoundedToZero()`
    - `keeperPrincipalSY == 0` → `DustRoundedToZero()`
    - 全仓位守卫不足额 → `InsufficientSyCollateral()`
  - **镜像汇率读取点守卫**：`exchangeRate()` 读回为 0 → `ZeroExchangeRate()`，与执行路径在同一读取点触发（`_computeKeepRedeemShares` 共享读取点）
  - **镜像 position 存在与 lockup（与 `previewRedeem` 一致）**：仓位不存在 → `PositionAccessDenied()`；未到期 → `LockTimeNotExpired()`（目的：优先保留缺失仓位的明确错误语义，避免被零 amount 或超 debt 校验误报为金额错误）
  - **不镜像 permission**：非 keeper 属执行期调用者身份校验，quote 公开不校验
- preview 是 keeper 事前决策入口；补上 keepRedeem 无 preview 的缺口，与 `previewStake` / `previewRedeem` / `previewWrapRedeem` 系列一致

成功后：

- keeper 接收 `keeperPrincipalSY`
- position owner 接收 `ownerExcessSY`
- `revenuePool` 不参与这一路径的分成

测试也直接证明了当前 keeper redeem 没有额外 protocol fee，并且分账输入基于 keeper 烧掉的 `uAsset`，不是 keeper 自己指定的 `SY` 数量。

## 9. Harvest 账务

`harvestWrapYield(tokenOut, minTokenOut)` 只处理 wrap 池中高于当前 exchangeRate 下 wrap debt 最低覆盖需求的那部分 `SY`：

- 先读取 `wrapPoolSY = syWrapStaking`
- 先按 up 版本计算 `wrapDebtInCanonicalAsset = uAsset -> canonical asset`，再按 up 版本计算 `wrapDebtInSY = canonical asset -> SY`
- 若 `wrapPoolSY <= wrapDebtInSY`，则没有可 harvest 的额外收益
- 否则 `amountInSY = wrapPoolSY - wrapDebtInSY`

成功 harvest 后：

- `syTotalStaking -= amountInSY`
- `syWrapStaking -= amountInSY`
- `wrapUAssetDebt` 不变化
- harvest 后剩余的 `syWrapStaking` 仍满足 `syWrapStaking >= wrapDebtInSY`
- 收益转到 `revenuePool`

因此，harvest 当前抽走的是 wrap 池里“高于 debt 等价 SY 的超额部分”，而不是改变用户未偿 `uAsset` debt。

## 10. 账务边界总结

当前实现可以概括为四条账务边界：

- `uAsset` debt 按 minter 独立记账
- locked position debt 按 position 独立记账
- wrap debt 按公共池聚合记账
- `exchangeRate()` 与 `SYUtils` 是 `SY` 数量和资产值之间的统一换算基准

凡是外部协议如何生成该 `exchangeRate()` 的问题，都只属于本地依赖边界；当前本仓库能直接证明的是“上层账务如何消费这个汇率”，而不是外部汇率来源本身的真实性。

## 11. Position manager 错误与事件真源

本节是 `IOutrunStakeManager.sol` 声明的 17 个自定义错误和 10 个事件的 canonical surface。错误表只覆盖 position manager 自己声明并在本地分支触发的错误；OpenZeppelin、`TokenHelper`、`SY` adapter 和 `uAsset` 的错误属于依赖边界。每个本地错误都会使整笔交易 revert，已经发生的 manager storage 写入、ERC20 transfer 或下游调用一并回滚。

### 11.1 17 个自定义错误

下表中的 `::function` 简写均指 `OutrunStakingPositionUpgradeable.sol::function`；接口声明锚点为 `IOutrunStakeManager.sol`。

| 错误 | 入口与精确触发分支 | 参数 | 回滚 / 依赖边界 |
| --- | --- | --- | --- |
| `ZeroInput()` | `OutrunStakingPositionUpgradeable.sol::initialize` 的 owner、revenuePool、SY、uAsset 或 keeper 为零；`::stake` 的 amount、positionOwner 或 uAssetReceiver 为零；`::drawUAsset` 的 receiver 为零；`::wrapStake` 的 amount 或 receiver 为零；`::redeem` 的 receiver 为零；`::keepWrapRedeem` 的 amount 或 receiver 为零；`::keepRedeem` 的 amount 或 receiver 为零；`::setRevenuePool` / `::setKeeper` 的新地址为零。`::previewWrapStake`、`::previewWrapRedeem`、`::previewKeepRedeem` 的零数量也走此错误。 | 无 | 各入口的本地零值守卫；状态写入和 token 依赖调用均在守卫之后。`keepWrapRedeem` / `keepRedeem` 先做 keeper 守卫，非 keeper 会先得到 `PermissionDenied()`。 |
| `DustRoundedToZero()` | `::stake`、`::wrapStake` 的 `SY -> canonical asset -> uAsset` 向下换算得到 `uAssetDebt == 0`；`::previewWrapStake` 的报价为 0；`::keepWrapRedeem` / `::previewWrapRedeem` 的 `uAsset -> canonical asset -> SY` 向下换算得到 `amountInSY == 0`；`::keepRedeem` / `::previewKeepRedeem` 的按比例 `syRedeemed == 0` 或 keeper 本金 `keeperPrincipalSY == 0`。`previewStake` 对同类下取整只返回 0，不触发本错误（rate==0 除外：现于汇率读取点先 revert `ZeroExchangeRate()`）。 | 无 | 所有这些检查都在对应 transfer、burn、position/pool 写入前；`exchangeRate()` 读取若失败则由 SY 依赖错误返回，读取返回 0 时由 position 侧 `ZeroExchangeRate()` 具名失败（rate==0 下各入口先触发该错误，本错误仅覆盖非零 rate 下的取整归零）。dust 不会创建零债务 position、改变 pool 或烧 keeper debt。 |
| `ZeroExchangeRate()` | `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 读回的 SY `exchangeRate()` 为 0；所有消费汇率的换算入口（`::stake` / `::wrapStake` / `::drawUAsset` / `::keepWrapRedeem` / `::keepRedeem` / `::harvestWrapYield` 及对应 preview）都在该读取点触发。 | 无 | 所有换算路径在读取点具名失败，先于一切 transfer、burn 与 position/pool 写入；rate==0 下原先的底层除零 / 下溢 Panic 与 0-返回、误归 `DustRoundedToZero()` / `NothingToDraw()` 等表现统一收敛为该具名错误，fail-closed 原子性不变；非零 rate 的一切路径行为不变。 |
| `PermissionDenied()` | `OutrunStakingPositionUpgradeable.sol::keepWrapRedeem` 和 `::keepRedeem` 的 `msg.sender != keeper()`。 | 无 | 入口第一道 keeper 守卫；没有 manager 状态写入、uAsset repay 或 SY transfer。 |
| `LockTimeNotExpired(uint128 deadline)` | `::redeem`、`::previewRedeem`、`::keepRedeem`、`::previewKeepRedeem` 的 `block.timestamp < position.deadline`。 | `deadline`：position 中保存的 uint128 Unix 秒时间戳。 | position 存在性检查后、任何 redeem 状态变化和依赖调用前触发；只读报价同样回退。 |
| `LockTimeExpired(uint128 deadline)` | `::drawUAsset`、`::previewDrawUAsset` 的 `block.timestamp >= position.deadline`。 | `deadline`：position 中保存的 uint128 Unix 秒时间戳。 | position 存在性/owner 守卫后、汇率读取与一切状态写入前触发；只读报价同样回退。与 `LockTimeNotExpired` 的 `< deadline` 在 deadline 时刻精确互补（`>= deadline` 时 redeem 开放、draw 关闭）。 |
| `LockupDaysOutOfRange(uint128 lockupDays)` | `::stake` 先以 uint256 计算 `deadline256 = block.timestamp + uint256(lockupDays) * 1 days`，若 `deadline256 > type(uint128).max`。 | `lockupDays`：输入的天数。 | 该分支位于 SY 已转入且 `syTotalStaking` 已暂增之后，但 revert 的原子性会回滚 transfer、账本暂增和后续 position 创建；不会产生溢出后已过期的 deadline。 |
| `MinStakeInsufficient(uint256 minStake)` | `::stake` 和 `::previewStake` 的 `amountInSY < minStake()`。 | `minStake`：当前配置的最小 SY 数量。 | stake 在 transfer 前触发；preview 不写状态、不调用 token。 |
| `PositionAccessDenied()` | `::drawUAsset` / `::redeem` 的 `onlyPositionOwner` 在 position 不存在或 caller 不是记录 owner 时；`::previewDrawUAsset`、`::previewRedeem`、`::previewKeepRedeem`、`::keepRedeem` 只在 position owner 为零（缺失/已删除）时。 | 无 | owner/modifier 或存在性守卫先于各自的状态写入和依赖调用；preview 不检查 caller 权限。 |
| `ExceedsPositionBalance(uint256 requested, uint256 available)` | `::redeem` / `::previewRedeem` 的 `_validateRedeemAmount` 在 `syRedeemed > position.syStaked`；`_applyPositionRedeem` 对 redeem/keepRedeem 的共享防御分支也检查 `syRedeemed > syStaked`。 | `requested`：请求或计算的 SY 数量；`available`：position 当前 SY 数量。 | owner redeem 的输入守卫在任何写入前；共享 apply 守卫位于其 ledger subtraction 前。owner 路径在 repay 前，keeper 路径的计算值当前有上界保证；若未来防御分支在 keeper repay 后触发，原子 revert 会回滚该 repay 和全部 manager 写入。 |
| `ExceedsPositionDebt(uint256 requested, uint256 available)` | `::keepRedeem` / `::previewKeepRedeem` 的 `amountInUAsset > position.UAssetMinted`；`_applyPositionRedeem` 对 redeem/keepRedeem 的共享防御分支检查 `UAssetBurned > positionUAssetMinted`。 | `requested`：输入或计算的 uAsset 数量；`available`：position 当前 uAsset debt（uAsset decimals）。 | 输入分支在 keeper burn 前；共享 apply 分支在 debt subtraction 前。合法 full redeem 等于 available，合法 partial redeem 的 ceiling 结果严格小于 available；keeper 路径若未来触发 apply 防御分支，已发生的 repay 也随原子 revert 回滚。 |
| `InsufficientSyCollateral()` | `::keepRedeem` / `::previewKeepRedeem` 的 `_computeKeepRedeemShares`：全仓位上取整债务等值 `(_assetToSyUp(positionUAssetMinted) > syStaked)`，或防御性检查 `keeperPrincipalSY > syRedeemed`。 | 无 | 只读汇率和 position 值检查，发生在 keeper uAsset repay、position reduction 和 SY transfer 前；不通过 cap 或其他依赖来收敛金额，失败即整笔回滚。 |
| `ExceedsWrapDebt(uint256 requested, uint256 available)` | `::keepWrapRedeem` / `::previewWrapRedeem` 的 `_validateWrapRedeemAmount` 在 `amountInUAsset > wrapUAssetDebt`。 | `requested`：要烧的 uAsset 数量；`available`：共享 wrap debt（uAsset decimals）。 | 在读取汇率、pool solvency 检查和任何 pool/repay 操作前触发；无状态变化。 |
| `WrapPoolUndercollateralized()` | `::keepWrapRedeem` / `::previewWrapRedeem` 在当前汇率下 `_assetToSyUp(wrapUAssetDebt) > syWrapStaking`。 | 无 | keeper wrap redeem 采用 all-or-nothing；该只读 guard 在 pool subtraction、uAsset repay 和 SY transfer 前触发，不能以 pro-rata 方式支付。 |
| `NothingToDraw()` | `::drawUAsset` 的 `currentValueInUAsset <= position.UAssetMinted`。 | 无 | 汇率估值后、position debt 写入和 uAsset mint 前触发；`previewDrawUAsset` 在同一条件下返回 0，不触发本错误（rate==0 时先在汇率读取点 revert `ZeroExchangeRate()`，不进入本条件）。 |
| `PartialRedeemMustLeaveDebt()` | `::redeem` / `::previewRedeem` 的 partial 分支（`syRedeemed < syStaked`）在 ceiling 计算后 `UAssetBurned >= position.UAssetMinted`。full redeem 直接烧全部 debt，不进入此分支。 | 无 | `_computeRedeemPositionDebt` 在 position reduction、uAsset repay 和 output 前执行；不会留下 SY 仍存在但 debt 已被清零的 partial position。 |
| `InsufficientTokenOut(uint256 actual, uint256 minExpected)` | `::redeem` 直接输出 SY 时 `syRedeemed < minTokenOut`；`::harvestWrapYield` 直接输出 SY 时 `amountInSY < minTokenOut`（rate==0 先在读取点 revert `ZeroExchangeRate()`，不进入本检查）。非 SY 输出交由 `SY.redeem` 的依赖校验。 | `actual`：本地可交付 SY 数量；`minExpected`：调用者的最小值。 | redeem 分支在 position apply 前；harvest 分支在临时扣减 `syTotalStaking` / `syWrapStaking` 后，但 revert 原子性会回滚该扣减。非 SY 的 adapter slippage/error 不属于这 17 个错误。 |

本地错误和下游依赖的边界固定如下：`uAsset.mint` 的 mint cap、`uAsset.repay` 的账户余额/授权、`SY.redeem` 的 token 校验与输出下限、`_transferIn` / `_transferOut` 的 ERC20 行为，以及 initializer 的 `assetInfo()` / `decimals()` 失败，不会改名为 position manager 错误；它们的 revert data 原样形成外部依赖边界。任何下游 revert 同样回滚本函数已做的 manager storage 写入。

### 11.2 10 个事件、单位与索引

下表按 `IOutrunStakeManager.sol` 的声明和 `OutrunStakingPositionUpgradeable.sol` 的 emit 点记录字段。`indexed` 是日志 topic 索引属性，不改变字段的数值单位。

| 事件 | 字段（单位） | indexed 字段 | 状态 / 索引含义 |
| --- | --- | --- | --- |
| `Stake` | `positionId`（position id）；`owner`（地址）；`amountInSY`（SY token units）；`mintedUAsset`（本次铸造的 uAsset units，uAsset decimals 口径，等于创建时 `Position.UAssetMinted` 即该 position 初始债务）；`deadline`（Unix 秒 timestamp，事件为 uint256，position 存储为 uint128）。 | `positionId`, `owner` | `::stake` 成功后创建 position、推进 `idCounter` 并铸 uAsset；owner 可与交易 caller 不同。事件用于发现新 position 和其初始 debt/deadline（经 `mintedUAsset`）。 |
| `DrawUAsset` | `positionId`（position id）；`uAssetReceiver`（地址）；`mintedUAsset`（本次新增 uAsset units，不是 position 总 debt）。 | `positionId`, `uAssetReceiver` | `::drawUAsset` 将 position debt 写为当前估值并成功 mint 后发出；事件字段是调用增量，当前总 debt 仍需读 `positions(positionId)`. |
| `Redeem` | `positionId`（position id）；`owner`（地址，当前为通过 owner guard 的 `msg.sender`）；`syRedeemed`（SY units）；`UAssetBurned`（uAsset units）；`receiver`（地址）；`tokenOut`（token 地址）；`amountTokenOut`（`tokenOut` units）。 | `positionId`, `owner`, `receiver` | `::redeem` 完成 position 减记/删除、uAsset repay 和 output 后发出；full redeem 后 `positions(id)` 的 owner 变为零。 |
| `WrapStake` | `amountInSY`（SY units）；`mintedUAsset`（本次新增 uAsset units）；`uAssetReceiver`（地址）。 | `uAssetReceiver` | `::wrapStake` 只改变共享 `syTotalStaking`、`syWrapStaking`、`wrapUAssetDebt`，不创建 position id；事件按交易记录聚合池的增量。 |
| `KeepWrapRedeem` | `keeper`（地址，`msg.sender`）；`receiver`（地址）；`amountInUAsset`（烧掉的 uAsset units）；`amountInSY`（释放的 SY units）。 | `keeper`, `receiver` | `::keepWrapRedeem` 成功后减少共享 pool/debt 并直付 SY；没有 position id，keeper 身份从 indexed sender 字段和交易 sender 双重确认。 |
| `KeepRedeem` | `positionId`（position id）；`owner`（position owner 地址）；`UAssetBurned`（keeper 烧掉的 uAsset units）；`receiver`（keeper principal 的地址）；`keeperPrincipalSY`（SY units）；`ownerExcessSY`（SY units）。 | `positionId`, `owner`, `receiver` | `::keepRedeem` 完成 keeper repay、position 减记/删除及两方转账后发出；keeper 本身不在字段中，`receiver` 是 keeper principal 收款地址，owner excess 收款地址由 `owner` 表示。从 position 释放的 SY 总量（内部计算量 `syRedeemed`）恒等于 `keeperPrincipalSY + ownerExcessSY`，不再单列事件字段。 |
| `HarvestWrapYield` | `receiver`（地址，当前为 `revenuePool`）；`tokenOut`（地址）；`amountInSY`（从 wrap pool 扣除的 SY units）；`amountTokenOut`（`tokenOut` units）。 | `receiver`, `tokenOut` | `::harvestWrapYield` 只移除 debt 覆盖线以上的 pool SY，`wrapUAssetDebt` 不变；有超额且 payout 成功才 emit，`wrapPoolSY <= wrapDebtInSY` 的零收益早返不 emit。 |
| `SetMinStake` | `minStake`（SY units）。 | 无 | `::setMinStake` 更新新阈值；事件只记录新值，旧值需由前一事件或链上读取推导。 |
| `SetRevenuePool` | `revenuePool`（地址）。 | `revenuePool` | `::setRevenuePool` 更新 harvest 收款目的地；indexed 字段是新地址，不包含旧地址。 |
| `SetKeeper` | `keeper`（地址）。 | `keeper` | `::setKeeper` 更新 keeper 权限边界；indexed 字段是新地址，不包含旧地址。 |

### 11.3 Position enumeration 与事件历史

- `idCounter()`（`AutoIncrementIdUpgradeable.sol::idCounter`）返回最后一次已签发的 position id；`_nextId` 预增，因此有效新 id 从 1 开始并单调递增。`wrapStake` / `keepWrapRedeem` 只操作聚合池，不签发 id。
- 链上枚举应把 `1 .. idCounter()` 作为候选范围并逐项读取 `positions(id)`（`OutrunStakingPositionUpgradeable.sol::positions`）。返回 `owner == address(0)` 表示该 id 从未创建或已被 full redeem 删除；因此删除后会留下可观测的 id 空洞，没有单独的 position length/active-id 数组。
- 事件历史与当前 storage 互补：`Stake` 发现创建，`DrawUAsset` 记录 debt 增量，`Redeem` / `KeepRedeem` 记录 position 减记或删除，`WrapStake` / `KeepWrapRedeem` / `HarvestWrapYield` 记录共享池增减，三个 `Set*` 事件记录配置变更。事件是追加式索引和审计轨迹；当前余额、owner、剩余 debt 以 `positions(id)`、`syTotalStaking`、`syWrapStaking`、`wrapUAssetDebt` 为准。
