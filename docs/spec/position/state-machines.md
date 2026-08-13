# OutStakeV2 State Machines

## 1. 文档目的

本文档把 `OutStakeV2` 当前用户可见主流程整理成状态机表达，帮助读者理解各个入口如何改变 position、wrap 池、`uAsset` debt 与 pause 状态。本文只描述当前本地代码里已经存在的流程，并记录当前 upgradeable-only implementation 的状态机边界；涉及 mixed-decimals 双段换算与 harvest coverage rounding 的条目，以下明确标成“本次修复目标/修复后语义”，不把它写成当前代码已完成行为。

## 1.1 Upgradeable readiness

当前 staking position 以 `OutrunStakingPositionUpgradeable` + `ERC1967Proxy` 部署：

- initializer 写入 `SY`、`uAsset`、`minStake`、`revenuePool`、`keeper` 与 owner（终态为 multisig；部署期 owner 取值规则见 `docs/deployment.md`「关键约束」）。
- `OutrunStakingPositionUpgradeable` 直接继承 `UUPSUpgradeable`，upgrade authorization 由 `onlyOwner` 控制。
- `SY` 初始化后保持固定；不新增 `setSY()` 状态转移。
- 下列 stake / draw / redeem / wrap / keeper / harvest 状态机的产品语义不因 proxy deployment 改变。

## 2. 直接 stake 生命周期

直接 stake 对应 `OutrunStakingPositionUpgradeable.stake(...)`，以及 router 的 `stakeFromToken` / `stakeFromSY` 在进入 position 后的同一路径。

当前生命周期如下：

1. 调用前状态：用户持有 `SY`，或先经 router 把 token 转成 `SY`。
2. 入口校验：`positionOwner` 与 `uAssetReceiver` 不能为零地址，`amountInSY` 需满足 `minStake`，合约不能处于 paused。
3. 资产进入：`SY` 被转入 `OutrunStakingPositionUpgradeable`。
4. principal 定价（本次修复目标/修复后语义）：先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `principalValue = canonical asset -> uAsset`；其中 `canonicalAssetDecimals = SY.assetInfo().assetDecimals`，`uAssetDecimals = uAsset.decimals()`。
5. debt 上限校验：检查当前 `uAsset` 给该 position 合约地址留下的 mintable cap 是否足够。
6. 状态写入：增加 `syTotalStaking`，生成新的 `positionId`，写入 position。
7. 债务铸造：调用 `uAsset.mint(uAssetReceiver, UAssetMinted)`。
8. 完成状态：position 进入“已创建、可 draw”的活跃状态；若 `lockupDays > 0`，新 position 未到期、不可 redeem；若 `lockupDays == 0`，`deadline == block.timestamp`，新 position 可立即 redeem。

## 3. Draw 生命周期

`drawUAsset(positionId, recipient)` 只作用于已存在 position，当前状态机如下：

1. 前置状态：position 存在，调用者必须是 position owner，合约不能 paused。
2. 估值阶段（本次修复目标/修复后语义）：先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `currentValueInUAsset = canonical asset -> uAsset`。
3. 可追加额度计算：若 `currentValueInUAsset` 不高于已铸 debt，则流程回退；否则差额即 `amountInUAsset`。
4. 状态更新：增加 `position.UAssetMinted`。
5. cap 校验与铸造：检查 `uAsset` mint cap，随后铸造新的 `uAsset` 到 `recipient`。
6. 完成状态：position 仍是活跃仓位，但未偿 debt 增大。

因此，draw 不会改变 lock deadline，也不会改变 `syStaked`。

## 4. 普通 redeem 生命周期

`redeem(positionId, syRedeemed, receiver, tokenOut, minTokenOut)` 当前只允许已到期的 position owner 发起。

生命周期如下：

1. 前置状态：position 存在；调用者是 owner；`block.timestamp >= deadline`；合约未 paused。
2. 输入校验：`syRedeemed` 不能为 0，且不能超过当前 `position.syStaked`。
3. debt 计算：
   - 若 `syRedeemed == position.syStaked`，则 `UAssetBurned = position.UAssetMinted`
   - 若 `syRedeemed < position.syStaked`，则 `UAssetBurned = ceil(position.UAssetMinted * syRedeemed / position.syStaked)`
   - 若 partial redeem 算出的 `UAssetBurned` 会等于或超过 `position.UAssetMinted`，则该路径回退，用户必须改走 full redeem
4. debt 清偿：position 层先完成上述判定，再对调用者执行 `uAsset.repay(msg.sender, UAssetBurned)`；语义上不依赖下游 `uAsset.repay(0)` 之类的零额 repay。
5. position 更新：
   - `syTotalStaking` 减少 `syRedeemed`
   - `position.syStaked` 减少 `syRedeemed`
   - `position.UAssetMinted` 减少 `UAssetBurned`
   - 若剩余 `SY` 为 0，则删除 position
6. 资产输出：
   - `tokenOut == SY` 时先检查 `syRedeemed >= minTokenOut`，再直接转出 `SY`
   - 否则调用 `SY.redeem(receiver, syRedeemed, tokenOut, minTokenOut, false)` 产出目标 token
7. 完成状态：position 进入“部分赎回后继续存在”或“已清空删除”。

对应的 `previewRedeem(positionId, syRedeemed, tokenOut)` 必须复用同一条 full / partial 判定：full redeem 预览全部剩余 debt，partial redeem 用 ceiling rounding，且不会返回一个执行期会因“partial consume all debt”而被拒绝的报价。这里的 debt 报价语义保持为已归一化的 `uAssetDebtUnits`；若需要反推价值或 `SY` 覆盖量，则顺序是 `uAssetDebtUnits -> canonicalAssetValue -> SY`。

## 5. Wrap stake / wrap redeem 生命周期

### 5.1 Wrap stake

`wrapStake(amountInSY, uAssetRecipient)` 当前状态机如下：

1. 前置状态：合约未 paused；输入数量和 recipient 有效。
2. 资产进入：`SY` 转入 position 合约。
3. principal 定价（本次修复目标/修复后语义）：先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `principalValue = canonical asset -> uAsset`。
4. cap 校验：检查当前 `uAsset` mint cap。
5. 聚合账务更新：
   - `syTotalStaking += amountInSY`
   - `syWrapStaking += amountInSY`
   - `wrapUAssetDebt += principalValue`
6. 铸造：向 `uAssetRecipient` 铸造 `principalValue` 对应的 `uAsset`。

### 5.2 Wrap redeem

`wrapRedeem(amountInUAsset, receiver, tokenOut, minTokenOut)` 当前状态机如下：

1. 前置状态：合约未 paused；输入合法；记 `uAssetDebtUnits = amountInUAsset`，且 `uAssetDebtUnits <= wrapUAssetDebt`。
2. 份额换算（本次修复目标/修复后语义）：先计算 `canonicalAssetValue = uAsset -> canonical asset`，再计算 `amountInSY = canonical asset -> SY`。
3. 分支换算：池子健康（债务等值 SY ≤ 池子 SY）时 `amountInSY = uAsset -> canonical -> SY`（down，面值兑付）；池子不足时 `amountInSY = amountInUAsset × syWrapStaking / wrapUAssetDebt`（按池子份额比例，down，不因池子不足回退）。
4. debt 清偿：对调用者执行 `uAsset.repay(msg.sender, uAssetDebtUnits)`。
5. 聚合账务更新：
   - `syTotalStaking -= amountInSY`
   - `syWrapStaking -= amountInSY`
   - `wrapUAssetDebt -= uAssetDebtUnits`
6. 资产输出：
   - `tokenOut == SY` 时先检查 `amountInSY >= minTokenOut`，再直接输出 `SY`
   - 否则通过 `SY.redeem(receiver, amountInSY, tokenOut, minTokenOut, false)` 输出目标 token

当前 wrap 流程始终作用于共享池，不会生成或消费独立 `positionId`。

## 6. Keeper redeem 生命周期

`keepRedeem(positionId, amountInUAsset, receiver)` 对应一个特权状态机，本次修复目标/修复后语义如下：

1. 前置状态：调用者必须是 `keeper`；position 存在；position 已到期；合约未 paused。
2. 输入校验：记 `uAssetDebtUnits = amountInUAsset`；`amountInUAsset == 0` → revert `ZeroInput()`；`amountInUAsset > position.UAssetMinted` → revert `ExceedsPositionDebt()`。
3. 全仓位守卫（前置判定）：按上取整口径判断仓位整体是否不足额——`if (_assetToSyUp(positionUAssetMinted, exchangeRate) > syStaked) revert InsufficientSyCollateral();`。仓位整体不足额（当前 `SY` 市值低于债务面值）时，任何 `amountInUAsset > 0` 的 keepRedeem 一律 revert，原子回滚——keeper 的 `uAsset` 不被烧、仓位不变；不存在 amount 依赖的残余暴露。
4. `SY` 分解：
   - 按显式 down rounding 公式计算本次从仓位释放的 `syRedeemed = roundDownDiv(syStaked * uAssetDebtUnits, positionUAssetMinted)`
   - dust 守卫（保留）：`syRedeemed == 0` → revert `DustRoundedToZero()`，与现有实现一致
5. debt 清偿：keeper 先烧掉自己提供的 `uAsset`。
6. per-amount 防御判定：
   - 按 `uAssetDebtUnits -> canonicalAssetValue -> SY` 的反向顺序计算 keeper 对应本金 `keeperPrincipalSY`，即 `_assetToSy(UAssetBurned, exchangeRate)`
   - 若 `keeperPrincipalSY > syRedeemed`，则同样 revert `InsufficientSyCollateral()`（替代对 `keeperPrincipalSY` 的上限收敛写法）；该防御不重复全仓位判断、正常路径不触发，仅作防御性不变量检查保留
   - 否则分账不变：`ownerExcessSY = syRedeemed - keeperPrincipalSY`
7. position 更新：与普通 redeem 一样减少 `syTotalStaking`、position principal 和 position debt。
8. 分账输出：
   - `receiver` 接 keeper principal
   - position owner 接剩余 excess `SY`

不足额判定说明：

- 全仓位守卫与 per-amount 防御都 revert `InsufficientSyCollateral()`，但判定口径不同：前者在仓位整体不足额时一刀切拒绝任何 `amountInUAsset > 0` 的调用，且在全仓位守卫前置下已严格覆盖所有 per-amount 情形；后者不重复全仓位判断、正常路径不触发，仅作为**防御性不变量检查**保留，防止未来重构在成功分账时 `ownerExcessSY = syRedeemed - keeperPrincipalSY` 下溢
- 方向性说明：不足额仓位上任何 `amountInUAsset > 0` 的 keepRedeem，keeper 拿回 SY 的市值不大于所烧 uAsset 面值（当前汇率下至多盈亏平衡，整除边界存在平衡例外），故全仓位一刀切拒绝不会误伤任何“实值不亏”的 redeem；`revert 触发 ⟺ 仓位整体不足额` 在全仓位守卫口径下成立

本次修复目标/修复后语义新增只读查询 `previewKeepRedeem(positionId, amountInUAsset)`，返回 `(keeperPrincipalSY, ownerExcessSY)`：

- mirror keepRedeem 的 `SY` 分账计算（同一个 `_assetToSy` 与 `roundDownDiv` 公式），并镜像以下失败路径，使”preview 与执行一致”成立：
  - **镜像 amount 相关失败路径**：
    - `amountInUAsset == 0` → `ZeroInput()`
    - `amountInUAsset > position.UAssetMinted` → `ExceedsPositionDebt()`
    - `syRedeemed == 0` → `DustRoundedToZero()`
    - 全仓位守卫不足额 → `InsufficientSyCollateral()`
  - **镜像 position 存在与 lockup（与 `previewRedeem` 一致）**：仓位不存在 → `PositionAccessDenied()`；未到期 → `LockTimeNotExpired()`（目的：对不存在仓位读全零 state 会触发底层 DivisionByZero panic，镜像前置校验保持干净失败语义）
  - **不镜像 permission**：非 keeper 属执行期调用者身份校验，quote 公开不校验
- preview 是 keeper 事前决策入口；补上 keepRedeem 无 preview 的缺口，与 `previewStake` / `previewRedeem` / `previewWrapRedeem` 系列一致

因此，keeper redeem 当前是“keeper 帮 position 结清一部分 debt，并取回相应本金”的状态机，而不是 owner 赎回的别名。keepRedeem 对调用者（keeper）的 `uAsset` 零暴露——不足额时调用失败且不烧 `uAsset`，汇率下跌风险由仓位/owner 承担，不内化到 keeper 调用者。

## 7. Harvest wrap yield 生命周期

`harvestWrapYield(tokenOut, minTokenOut)` 的批准修复语义是：只提取 wrap 池中超过当前 exchangeRate 下 wrap debt 最低覆盖需求的那部分 `SY` 超额收益。对应状态机应为：

1. 前置状态：
   - 调用者必须是 position 合约的 `owner`
   - 合约未 paused

2. 盈余计算：
   - 读取 `wrapPoolSY = syWrapStaking`
   - 先按 up 版本计算 `wrapDebtInCanonicalAsset = uAsset -> canonical asset`，再按 up 版本计算 `wrapDebtInSY = canonical asset -> SY`，保留足够的 `SY` 覆盖 wrap debt
   - 若 `wrapPoolSY <= wrapDebtInSY`，则返回 0，状态不变
   - 否则 `harvestAmount = wrapPoolSY - wrapDebtInSY`

3. 状态变化：
   - `syTotalStaking -= harvestAmount`
   - `syWrapStaking -= harvestAmount`
   - `wrapUAssetDebt` 不变（用户债务不受影响）

4. 收益输出：
   - 若 `tokenOut == SY`，先检查 `harvestAmount >= minTokenOut`，再直接将 `harvestAmount` 的 SY 转给 `revenuePool`
   - 否则调用 `SY.redeem(revenuePool, harvestAmount, tokenOut, minTokenOut, false)` 将收益兑换为 tokenOut

5. 后置条件：
   - wrap 池仍有足够的 SY 覆盖 `wrapUAssetDebt`（即 `syWrapStaking >= wrapDebtInSY`）
   - `revenuePool` 收到超额收益
   - 用户 `uAsset` 债务不变

## 8. Pause / unpause 的影响

当前仓库存在两类 pause 语义：

### 8.1 Position 级 pause

`OutrunStakingPositionUpgradeable.pause()` / `unpause()` 由 owner 控制，并直接影响带 `whenNotPaused` 的业务入口：

- `stake`
- `drawUAsset`
- `wrapStake`
- `redeem`
- `wrapRedeem`
- `keepRedeem`
- `harvestWrapYield`

对应的 preview / view 函数不受该 pause 影响。

### 8.2 SY token 级 pause

`SYBase` 继承 `OutrunERC20Pausable`，因此 `SY` token 的转账、mint、burn 本身也受 owner pause 控制。当前这会影响：

- `SY.deposit` 中的 `_mint`
- `SY.redeem` 中的 `_burn`
- 常规 `SY` transfer 行为

因此，在当前实现里，用户流程既可能被 position 级 pause 阻断，也可能被底层 `SY` token pause 阻断。
