# OutStakeV2 State Machines

## 1. 文档目的

本文档把 `OutStakeV2` 当前用户可见主流程整理成状态机表达，帮助读者理解各个入口如何改变 position、wrap 池、`uAsset` debt 与 pause 状态。本文只描述当前本地代码里已经存在的流程，并记录当前 upgradeable-only implementation 的状态机边界；mixed-decimals 双段换算与 harvest coverage rounding 的条目均为当前代码已完成行为，按当前实现语义直接描述。

position manager 的完整错误参数、回滚边界和事件字段以 [accounting.md §11](./accounting.md) 为 canonical surface；本文件在每条状态机中保留入口实际执行顺序和对应错误/事件交叉引用。

## 1.1 Upgradeable readiness

当前 staking position 以 `OutrunStakingPositionUpgradeable` + `ERC1967Proxy` 部署：

- initializer 写入 `SY`、`uAsset`、`minStake`、`revenuePool`、`keeper` 与 owner（终态为 multisig；部署期 owner 取值规则见 `docs/deployment.md`「关键约束」）。
- `OutrunStakingPositionUpgradeable` 直接继承 `UUPSUpgradeable`，upgrade authorization 由 `onlyOwner` 控制。
- `SY` 初始化后保持固定；不新增 `setSY()` 状态转移。
- 下列 stake / draw / redeem / wrap / keeper / harvest 状态机的产品语义不因 proxy deployment 改变。

## 2. 直接 stake 生命周期

直接 stake 对应 `OutrunStakingPositionUpgradeable.sol::stake`，以及 router 的 `stakeFromToken` / `stakeFromSY` 在进入 position 后的同一路径。

当前生命周期如下：

1. 调用前状态：用户持有 `SY`，或先经 router 把 token 转成 `SY`。
2. 入口校验：`positionOwner`、`uAssetReceiver` 或 `amountInSY` 为零时 `ZeroInput()`；`amountInSY < minStake()` 时 `MinStakeInsufficient(minStake)`；合约 paused 时由 `whenNotPaused` 阻断。
3. uAssetDebt 定价：先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `uAssetDebt = canonical asset -> uAsset`；其中 `canonicalAssetDecimals = SY.assetInfo().assetDecimals`，`uAssetDecimals = uAsset.decimals()`。汇率读取点守卫：`exchangeRate()` 读回为 0 时先 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`），先于 dust 守卫与 `_transferIn`/一切写入；原先 rate==0 下误归 `DustRoundedToZero()`（previewStake 0-返回）收敛为具名错误。
4. dust 守卫：若向下换算得到 `uAssetDebt == 0`，则 `DustRoundedToZero()`；该检查在 SY transfer 前，不会留下零债务 position。
5. 资产进入：`SY` 被转入 `OutrunStakingPositionUpgradeable`。
6. 状态进入：SY transfer 成功后增加 `syTotalStaking`，计算 `deadline256 = block.timestamp + uint256(lockupDays) * 1 days`。若 `deadline256 > type(uint128).max`，则 `LockupDaysOutOfRange(lockupDays)`；虽然该检查位于 transfer 和总账暂增之后，revert 会原子回滚这两步以及后续全部状态。
7. 状态写入：生成新的 `positionId`，写入 position；随后调用 `uAsset.mint(uAssetReceiver, mintedUAsset)`（stake 场景 `mintedUAsset = uAssetDebt`）。uAsset mint cap 等依赖错误会使整笔 stake 回滚。
8. 完成状态：position 进入活跃状态；若 `lockupDays > 0`，锁定期内（`block.timestamp < deadline`）可 draw、未到期不可 redeem；若 `lockupDays == 0`，`deadline == block.timestamp`，创建即到期、可立即 redeem 但不可 draw（draw 于 `block.timestamp >= deadline` revert `LockTimeExpired()`，见 §3）。成功后发出 `Stake`，其字段与索引含义见 [accounting.md §11.2](./accounting.md)。

## 3. Draw 生命周期

`OutrunStakingPositionUpgradeable.sol::drawUAsset` 只作用于已存在 position，当前状态机如下：

1. 前置状态：position 不存在或 caller 不是记录 owner 时由 `onlyPositionOwner` revert `PositionAccessDenied()`；`uAssetReceiver` 为零时 `ZeroInput()`；合约不能 paused。
2. 到期守卫：`block.timestamp >= position.deadline` 时 revert `LockTimeExpired(position.deadline)`；语义：draw 仅在锁定期内可用，deadline 起该入口关闭，与 `redeem`/`keepRedeem` 的 `LockTimeNotExpired`（`< deadline`）在 deadline 时刻精确互补。该守卫位于 position 存在性/owner 校验之后、估值阶段汇率读取与一切状态写入之前。
3. 估值阶段：先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `currentValueInUAsset = canonical asset -> uAsset`。汇率读取点守卫：`exchangeRate()` 读回为 0 时先 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`），先于 NothingToDraw 判定；原先误归 `NothingToDraw()`（previewDrawUAsset 0-返回）收敛为具名错误。
4. 可追加额度计算：若 `currentValueInUAsset <= position.UAssetMinted`，则 `NothingToDraw()`；`previewDrawUAsset` 在同一条件返回 0（rate==0 时先在汇率读取点 revert `ZeroExchangeRate()`，不进入本条件）。否则差额即 `mintedUAsset`（`drawUAsset` 返回值与 `DrawUAsset` 事件字段，调用级铸出量；非 `position.UAssetMinted` 总债务）。
5. 状态更新：将 `position.UAssetMinted` 写为 `currentValueInUAsset`（不是把当前 debt 再加一遍）。
6. cap 校验与铸造：检查 `uAsset` mint cap，随后铸造新的 `uAsset` 到 `uAssetReceiver`；依赖错误会回滚第 5 步。
7. 完成状态：position 仍是活跃仓位，但未偿 debt 增大；成功后发出 `DrawUAsset`，事件只记录本次新增量，当前总 debt 要结合 `positions(positionId)` 读取，详见 [accounting.md §11.2](./accounting.md)。

因此，draw 不会改变 lock deadline，也不会改变 `syStaked`。

## 4. 普通 redeem 生命周期

`OutrunStakingPositionUpgradeable.sol::redeem` 当前只允许已到期的 position owner 发起。

生命周期如下：

1. 前置状态：position 不存在或 caller 不是 owner 时 `PositionAccessDenied()`；`block.timestamp < deadline` 时 `LockTimeNotExpired(deadline)`；合约未 paused。
2. 输入校验：`receiver == address(0)` 时 `ZeroInput()`；`syRedeemed == 0` 时 `ZeroInput()`；`syRedeemed > position.syStaked` 时 `ExceedsPositionBalance(syRedeemed, position.syStaked)`。
3. debt 计算：
   - 若 `syRedeemed == position.syStaked`，则 `UAssetBurned = position.UAssetMinted`
   - 若 `syRedeemed < position.syStaked`，则 `UAssetBurned = ceil(position.UAssetMinted * syRedeemed / position.syStaked)`
   - 若 partial redeem 算出的 `UAssetBurned >= position.UAssetMinted`，则 `PartialRedeemMustLeaveDebt()`，用户必须改走 full redeem
4. 直接 SY 的 slippage 校验：`tokenOut == SY` 且 `syRedeemed < minTokenOut` 时 `InsufficientTokenOut(syRedeemed, minTokenOut)`，发生在 position 更新前。
5. position 更新：
   - `syTotalStaking` 减少 `syRedeemed`
   - `position.syStaked` 减少 `syRedeemed`
   - `position.UAssetMinted` 减少 `UAssetBurned`
   - 若剩余 `SY` 为 0，则删除 position
   - 守恒引用：`syTotalStaking` 的减少镜像到 `Σ(active positions.syStaked) + syWrapStaking` 一侧；剩余 `SY == 0` 即 full redeem，删除 position 并从 active sum 移除，见 [accounting.md §10.1](./accounting.md)。
6. debt 清偿：上述判定与减记完成后，再对调用者执行 `uAsset.repay(msg.sender, UAssetBurned)`；语义上不依赖下游 `uAsset.repay(0)` 之类的零额 repay。
7. 资产输出：
   - `tokenOut == SY` 时直接转出 `SY`
   - 否则调用 `SY.redeem(receiver, syRedeemed, tokenOut, minTokenOut, false)` 产出目标 token
8. 事件：资产输出完成后 `emit Redeem(...)`；position 删除/减记、债务和 tokenOut 字段的索引含义见 [accounting.md §11.2](./accounting.md)。非 SY 的 `SY.redeem` 错误属于依赖边界并会回滚前序 position 更新。
9. 完成状态：position 进入“部分赎回后继续存在”或“已清空删除”。

对应的 `previewRedeem(positionId, syRedeemed, tokenOut)` 必须复用同一条 full / partial 判定：full redeem 预览全部剩余 debt，partial redeem 用 ceiling rounding，且不会返回一个执行期会因“partial consume all debt”而被拒绝的报价。这里的 debt 报价语义保持为已归一化的 `uAssetDebtUnits`；若需要反推价值或 `SY` 覆盖量，则顺序是 `uAssetDebtUnits -> canonicalAssetValue -> SY`。

## 5. Wrap stake / keep wrap redeem 生命周期

### 5.1 Wrap stake

`OutrunStakingPositionUpgradeable.sol::wrapStake` 当前状态机如下：

1. 前置状态：`uAssetReceiver == address(0)` 或 `amountInSY == 0` 时 `ZeroInput()`；合约未 paused。
   其中，`minStake` 仅用于直接 `stake` / `previewStake`；共享 wrap 池的 `wrapStake` / `previewWrapStake` 不读取该阈值，分别按非零输入与 dust 守卫处理。
2. uAssetDebt 定价：先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `uAssetDebt = canonical asset -> uAsset`。汇率读取点守卫：`exchangeRate()` 读回为 0 时先 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`），先于 dust 守卫与一切写入；原先 rate==0 下误归 `DustRoundedToZero()` 收敛为具名错误。
3. dust 守卫：若 `uAssetDebt == 0` 则 `DustRoundedToZero()`，不会先转入 SY。
4. 资产进入：`SY` 转入 position 合约。
5. 聚合账务更新：
   - `syTotalStaking += amountInSY`
   - `syWrapStaking += amountInSY`
   - `wrapUAssetDebt += uAssetDebt`
   - 守恒引用：`syTotalStaking` 与 `syWrapStaking` 同增，等式保持，见 [accounting.md §10.1](./accounting.md)。
6. 铸造：向 `uAssetReceiver` 铸造 `uAssetDebt` 对应的 `uAsset`；mint cap 或其他 uAsset 依赖错误会回滚 pool 账务。
7. 事件：成功后发出 `WrapStake`；它没有 position id，字段语义见 [accounting.md §11.2](./accounting.md)。

### 5.2 Keep wrap redeem

`OutrunStakingPositionUpgradeable.sol::keepWrapRedeem` 当前状态机如下：

1. 前置状态：合约未 paused；keeper 守卫——`msg.sender != keeper()` → `PermissionDenied()`；`receiver == address(0)` 或 `amountInUAsset == 0` → `ZeroInput()`；记 `uAssetDebtUnits = amountInUAsset`。
2. 债务边界：若 `uAssetDebtUnits > wrapUAssetDebt`，则 `ExceedsWrapDebt(uAssetDebtUnits, wrapUAssetDebt)`。
3. 份额换算与 solvency：汇率读取点守卫——`exchangeRate()` 读回为 0 时先 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`），先于 pool 扣减、keeper burn 与 SY 输出；原先 rate==0 且 wrap 债务非零时该换算暴露的底层除零 Panic（Panic 0x12）收敛为该具名错误。随后用上取整检查 `_assetToSyUp(wrapUAssetDebt) > syWrapStaking`；池子不足时 `WrapPoolUndercollateralized()`，全有或全无，不按 pro-rata 支付。池子健康时再以向下口径计算 `amountInSY = uAsset -> canonical -> SY`。
4. dust 守卫：若该向下换算得到 `amountInSY == 0`，则 `DustRoundedToZero()`；不会减少 pool 或烧 keeper debt。
5. 聚合账务更新：
   - `syTotalStaking -= amountInSY`
   - `syWrapStaking -= amountInSY`
   - `wrapUAssetDebt -= uAssetDebtUnits`
   - 守恒引用：`syTotalStaking` 与 `syWrapStaking` 同减，等式保持，见 [accounting.md §10.1](./accounting.md)。
6. debt 清偿：对 keeper 执行 `uAsset.repay(msg.sender, uAssetDebtUnits)`，烧掉 keeper 自己提供的 `uAsset`；依赖错误会回滚聚合账务。
7. 资产输出：直接将 `amountInSY` 的 SY 转给 `receiver`（keepWrapRedeem 只直付 SY，不经过 `SY.redeem`，无 tokenOut/minTokenOut 参数）。
8. 事件：成功后发出 `KeepWrapRedeem`；共享池增量和 keeper/receiver 索引见 [accounting.md §11.2](./accounting.md)。`previewWrapRedeem` 镜像债务、solvency 和 dust 分支，也镜像汇率读取点 rate==0 → `ZeroExchangeRate()`，但不检查 keeper 权限。

当前 wrap 流程始终作用于共享池，不会生成或消费独立 `positionId`。

## 6. Keeper redeem 生命周期

`OutrunStakingPositionUpgradeable.sol::keepRedeem` 对应一个特权状态机：

1. 前置状态：调用者不是 `keeper` 时 `PermissionDenied()`；`receiver == address(0)` 时 `ZeroInput()`；position 缺失时 `PositionAccessDenied()`；`block.timestamp < deadline` 时 `LockTimeNotExpired(deadline)`；合约未 paused。
2. 输入校验：记 `uAssetDebtUnits = amountInUAsset`；`amountInUAsset == 0` → `ZeroInput()`；`amountInUAsset > position.UAssetMinted` → `ExceedsPositionDebt(amountInUAsset, position.UAssetMinted)`。
3. 全仓位守卫（前置判定）：按上取整口径判断仓位整体是否不足额——`if (_assetToSyUp(positionUAssetMinted, exchangeRate) > syStaked) revert InsufficientSyCollateral();`。仓位整体不足额（按 `OutrunStakingPositionUpgradeable.sol::_assetToSyUp` 上取整守卫口径判定，带内偏差见下方「方向性说明」限定）时，任何 `amountInUAsset > 0` 的 keepRedeem 一律 revert，原子回滚——keeper 的 `uAsset` 不被烧、仓位不变；不存在 amount 依赖的残余暴露。汇率读取点守卫：`exchangeRate()` 读回为 0 时先于本守卫与第 5 步 keeperPrincipalSY 换算 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`），仍在 keeper burn 与一切 position 写入之前；原先 rate==0 且仓位债务非零时该换算暴露的底层除零 Panic（Panic 0x12）收敛为该具名错误。
4. `SY` 分解：
   - 按显式 down rounding 公式计算本次从仓位释放的 `syRedeemed = roundDownDiv(syStaked * uAssetDebtUnits, positionUAssetMinted)`
   - dust 守卫（保留）：`syRedeemed == 0` → revert `DustRoundedToZero()`，与现有实现一致
5. per-amount 防御判定（仍在 burn 前）：
   - 按 `uAssetDebtUnits -> canonicalAssetValue -> SY` 的反向顺序计算 keeper 对应本金 `keeperPrincipalSY`，即 `_assetToSy(amountInUAsset, exchangeRate)`
   - keeper 侧 dust 守卫：`keeperPrincipalSY == 0` → revert `DustRoundedToZero()`——keeper 不得为零 SY 支付燃烧非零 uAsset 债（尘额输入在汇率上行后本金腿 floor 为 0 时，分账会把全部 `syRedeemed` 静默划归 owner）；与 `keepWrapRedeem` 的 `amountInSY == 0` 守卫对称
   - 若 `keeperPrincipalSY > syRedeemed`，则同样 revert `InsufficientSyCollateral()`（替代对 `keeperPrincipalSY` 的上限收敛写法）；该防御不重复全仓位判断、正常路径不触发，仅作防御性不变量检查保留
   - 否则分账不变：`ownerExcessSY = syRedeemed - keeperPrincipalSY`
6. debt 清偿：上述全部本地分支通过后，keeper 才烧掉自己提供的 `uAsset`。
7. position 更新：与普通 redeem 一样减少 `syTotalStaking`、position principal 和 position debt。
   - 守恒引用：`syTotalStaking` 的减少镜像到 `Σ(active positions.syStaked) + syWrapStaking` 一侧，见 [accounting.md §10.1](./accounting.md)。
8. 分账输出：
   - `receiver` 接 keeper principal
   - position owner 接剩余 excess `SY`
9. 事件：两方转账完成后发出 `KeepRedeem`；keeper、owner、receiver、两类 SY split 字段的含义见 [accounting.md §11.2](./accounting.md)。

不足额判定说明：

- 全仓位守卫与 per-amount 防御都 revert `InsufficientSyCollateral()`，但判定口径不同：前者在仓位整体不足额时一刀切拒绝任何 `amountInUAsset > 0` 的调用，且在全仓位守卫前置下已严格覆盖所有 per-amount 情形；后者不重复全仓位判断、正常路径不触发，仅作为**防御性不变量检查**保留，防止未来重构在成功分账时 `ownerExcessSY = syRedeemed - keeperPrincipalSY` 下溢
- 方向性说明：不足额仓位上任何 `amountInUAsset > 0` 的 keepRedeem，keeper 拿回 SY 的市值不大于所烧 uAsset 面值（当前汇率下至多盈亏平衡，整除边界存在平衡例外），故全仓位一刀切拒绝不会放行任何“实值亏损”的 redeem，只可能误拒（量化偏差带见下述限定）；`revert 触发 ⟺ 仓位整体不足额` 在全仓位守卫口径下成立；限定：在 `uAssetDecimals > canonicalAssetDecimals` 且债务非 f 整除（`f = 10 ** (uAssetDecimals - canonicalAssetDecimals)`）时，up/up 双段复合守卫相对精确紧界存在量化偏差带——至多 `1e18 / exchangeRate + 1` SY wei（exchangeRate ≥ 1e18 时 1 wei），偿付裕度落入该带的“实值不亏”仓位会被误拒（前述「整除边界存在平衡例外」carve-out 只覆盖盈亏平衡，不覆盖带内严格充足）；偏差方向保守——守卫值恒不低于债务精确面值，绝不放行不足额仓位，owner 可经 `OutrunStakingPositionUpgradeable.sol::redeem` 自赎（redeem 无该守卫）；量化与推导以 `docs/spec/common-foundations.md` 的「mixed-decimals up/up 双段复合取整偏差」条目为准

只读查询 `previewKeepRedeem(positionId, amountInUAsset)`，返回 `(keeperPrincipalSY, ownerExcessSY)`：

- mirror keepRedeem 的 `SY` 分账计算（同一个 `_assetToSy` 与 `roundDownDiv` 公式），并镜像以下失败路径，使”preview 与执行一致”成立：
  - **镜像 amount 相关失败路径**：
    - `amountInUAsset == 0` → `ZeroInput()`
    - `amountInUAsset > position.UAssetMinted` → `ExceedsPositionDebt()`
    - `syRedeemed == 0` → `DustRoundedToZero()`
    - `keeperPrincipalSY == 0` → `DustRoundedToZero()`
    - 全仓位守卫不足额 → `InsufficientSyCollateral()`
  - **镜像汇率读取点守卫**：`exchangeRate()` 读回为 0 → `ZeroExchangeRate()`，与执行路径在同一读取点触发
  - **镜像 position 存在与 lockup（与 `previewRedeem` 一致）**：仓位不存在 → `PositionAccessDenied()`；未到期 → `LockTimeNotExpired()`（目的：优先保留缺失仓位的明确错误语义，避免被零 amount 或超 debt 校验误报为金额错误）
  - **不镜像 permission**：非 keeper 属执行期调用者身份校验，quote 公开不校验
- preview 是 keeper 事前决策入口；补上 keepRedeem 无 preview 的缺口，与 `previewStake` / `previewRedeem` / `previewWrapRedeem` 系列一致

因此，keeper redeem 当前是“keeper 帮 position 结清一部分 debt，并取回相应本金”的状态机，而不是 owner 赎回的别名。keepRedeem 对调用者（keeper）的 `uAsset` 零暴露——不足额时调用失败且不烧 `uAsset`，汇率下跌风险由仓位/owner 承担，不内化到 keeper 调用者。

## 7. Harvest wrap yield 生命周期

`OutrunStakingPositionUpgradeable.sol::harvestWrapYield` 只提取 wrap 池中超过当前 exchangeRate 下 wrap debt 最低覆盖需求的那部分 `SY` 超额收益。对应状态机应为：

1. 前置状态：
   - 调用者必须是 position 合约的 `owner`
   - 合约未 paused

2. 盈余计算：
   - 读取 `wrapPoolSY = syWrapStaking`
   - 汇率读取点守卫：`exchangeRate()` 读回为 0 时先 revert `ZeroExchangeRate()`（`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`），先于 pool 扣减与收益输出；原先该 up/up 换算在 rate==0 下会暴露底层 Panic——wrap 债务非零时除零（Panic 0x12）、空池（`wrapUAssetDebt == 0`）时 `assetToSyUp` 分子下溢（Panic 0x11）——现为具名 revert，仍原子、先于一切写入
   - 先按 up 版本计算 `wrapDebtInCanonicalAsset = uAsset -> canonical asset`，再按 up 版本计算 `wrapDebtInSY = canonical asset -> SY`，保留足够的 `SY` 覆盖 wrap debt
   - 若 `wrapPoolSY <= wrapDebtInSY`，则返回 0，状态不变且不发出 `HarvestWrapYield`
   - 否则 `harvestAmount = wrapPoolSY - wrapDebtInSY`

3. 状态变化：
   - `syTotalStaking -= harvestAmount`
   - `syWrapStaking -= harvestAmount`
   - `wrapUAssetDebt` 不变（用户债务不受影响）
   - 守恒引用：`syTotalStaking` 与 `syWrapStaking` 同减，等式保持，见 [accounting.md §10.1](./accounting.md)。

4. 收益输出：
   - 若 `tokenOut == SY`，在 pool 暂扣后检查 `harvestAmount < minTokenOut`；此时 `InsufficientTokenOut(harvestAmount, minTokenOut)`，revert 会回滚两项 pool 扣减；通过后直接将 `harvestAmount` 的 SY 转给 `revenuePool`
   - 否则调用 `SY.redeem(revenuePool, harvestAmount, tokenOut, minTokenOut, false)` 将收益兑换为 tokenOut

5. 后置条件：
   - wrap 池仍有足够的 SY 覆盖 `wrapUAssetDebt`（即 `syWrapStaking >= wrapDebtInSY`）
   - `revenuePool` 收到超额收益；成功后发出 `HarvestWrapYield`，其 `receiver` 是当前 revenuePool，字段和索引见 [accounting.md §11.2](./accounting.md)
   - 用户 `uAsset` 债务不变

### 7.1 管理配置事件

- `OutrunStakingPositionUpgradeable.sol::setMinStake` 由 owner 调用并更新 SY 最小 stake；允许设置为 0，成功后发出 `SetMinStake(minStake)`。
- `OutrunStakingPositionUpgradeable.sol::setRevenuePool` 由 owner 调用；新地址为零时 `ZeroInput()`，否则更新 harvest 收款目的地并发出 indexed `SetRevenuePool(revenuePool)`。
- `OutrunStakingPositionUpgradeable.sol::setKeeper` 由 owner 调用；新地址为零时 `ZeroInput()`，否则更新 keeper 权限并发出 indexed `SetKeeper(keeper)`。
- 三个配置事件只记录新值/新地址，不记录旧值；字段、索引和依赖边界见 [accounting.md §11.2](./accounting.md)。owner 权限失败由 OpenZeppelin Ownable 依赖错误表示，不属于 17 个 manager errors。

## 8. Pause / unpause 的影响

当前仓库存在三类 pause 语义：

### 8.1 Position 级 pause

`OutrunStakingPositionUpgradeable.pause()` / `unpause()` 由 owner 控制，并直接影响带 `whenNotPaused` 的业务入口：

- `stake`
- `drawUAsset`
- `wrapStake`
- `redeem`
- `keepWrapRedeem`
- `keepRedeem`
- `harvestWrapYield`

对应的 preview / view 函数不受该 pause 影响。

### 8.2 SY token 级 pause

`SYBase` 继承 `OutrunERC20PausableUpgradeable`，因此 `SY` token 在 owner pause 时会被阻断。阻断分两层：`SY.deposit` / `SY.redeem` 自带函数级 `whenNotPaused`，pause 时在函数入口直接 revert；常规 `SY` transfer 没有函数级 modifier，由 `_update` 的 `whenNotPaused` 兜底拦截。当前这会影响：

- `SY.deposit`（函数级 `whenNotPaused`）
- `SY.redeem`（函数级 `whenNotPaused`）
- 常规 `SY` transfer 行为（经 `_update` 的 `whenNotPaused`）

因此，在 position 未 paused 且 uAsset 未 paused 时，SY pause 会阻断 `stake`、`wrapStake`、`redeem`、`keepWrapRedeem`、`keepRedeem`，以及存在可提取盈余时的 `harvestWrapYield`（均经 SY transfer 或 `SY.redeem`）；`drawUAsset` 只读取 `exchangeRate` 并调用 `uAsset.mint`，在未到期（`block.timestamp < position.deadline`）且有可追加额度时仍可运行。`harvestWrapYield` 无盈余时会在覆盖计算后直接返回 0，不触发 SY 写路径。

### 8.3 uAsset 级 pause

`OutrunUniversalAssetsUpgradeable` 经 `OutrunOFTUpgradeable` → `OutrunERC20PausableUpgradeable` 继承 pause 家族，可被其自身 owner 独立 pause（与 position owner 是不同合约的独立角色，部署配置可指向同一地址）。阻断分两层：`OutrunUniversalAssetsUpgradeable.sol::mint` / `OutrunUniversalAssetsUpgradeable.sol::repay` 自带函数级 `whenNotPaused`；常规 uAsset transfer 与 OFT outbound send 没有函数级 modifier，由 `_update` 的 `whenNotPaused` 兜底拦截（跨链 inbound `_credit` 豁免，见 `docs/spec/common-foundations.md` 的「Pause 与跨链 OFT 执行边界」）。当前这会影响 position 的六个业务入口：

- `stake` / `drawUAsset` / `wrapStake`（经 `uAsset.mint`）
- `redeem` / `keepRedeem` / `keepWrapRedeem`（经 `uAsset.repay`）

`harvestWrapYield` 不调用 uAsset 的 mint / repay，不受该级 pause 阻断（仅受 8.1 与 8.2 两级影响）；对应的 preview / view 函数同样不受该级 pause 影响。

因此，在当前实现里，用户流程既可能被 position 级 pause 阻断，也可能被底层 `SY` token pause 阻断，还可能被 uAsset 级 pause 阻断。
