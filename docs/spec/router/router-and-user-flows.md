# OutStakeV2 Router And User Flows

## 1. 文档目的

本文档整理 `OutrunRouter`、`OutrunStakingPosition` 与 `SYBase` 当前已经实现的用户流程，覆盖 token / native、`SY`、locked stake、wrap stake、genesis 与 preview 语义。本文只记录本地代码和现有测试能直接证明的行为，并记录当前 router 与 proxy-backed products 的边界；涉及 mixed-decimals 双段换算与 rounding 的条目均为当前代码已完成行为，按当前实现语义直接描述。

## 1.1 Upgradeable readiness

当前 upgradeable product surface 不把 `OutrunRouter` 部署为 proxy：

- router 仍是非 upgradeable、可重部署 helper。
- router 业务入口仍通过用户传入的独立 `SY` 地址、`SP` 地址或从 `SP.SY()` 派生的 canonical `SY` 调用下游，但目标必须先由 owner 注册。
- 下游 product address 可以是 `ERC1967Proxy` 地址：uAsset proxy、SY proxy、staking position proxy。
- router 本身不持有 core accounting state；切换 router 需要用户/集成侧重新授权或改用新入口，但不迁移 position、uAsset debt 或 SY share state。
- router 不获得 upgrade admin、timelock、pause 或 oracle 管理能力；owner 只维护 router 的 SY 白名单和 SP -> SY 配对登记。

### 1.2 Router target registry

- `OutrunRouter.sol::setTrustedSY(SY, trusted)` 由 owner 管理 SY 白名单；启用时要求 `SY` 是有代码的合约，禁用会立即阻止后续 router 调用。
- `OutrunRouter.sol::setTrustedSP(SP, SY)` 由 owner 登记 SP 的 canonical SY 配对；非零 `SY` 必须已在白名单中，且必须等于 `SP.SY()`。
- `SY == address(0)` 是 NATIVE sentinel，不能作为 trusted SY；`SP == address(0)` 也不能登记。配置成功后可通过 `OutrunRouter.sol::trustedSY`、`OutrunRouter.sol::trustedSYForSP` 读取当前值，并核对 `IOutrunRouter.sol::TrustedSYUpdated` / `IOutrunRouter.sol::TrustedSPUpdated` 事件。
- 仅登记白名单 SY 的入口 `mintSYFromToken(...)`、`redeemSyToToken(...)` 可继续执行；所有从 SP 派生 SY 的 preview、locked stake、wrap stake 和 genesis 入口都要求已登记且匹配的 SP -> SY 配对。
- 校验在任何用户资产转移或精确 approve 前执行；未登记目标回退 `UntrustedRouterTarget(address)`，SP 与登记 SY 不匹配回退 `RouterTargetMismatch(address,address,address)`。
- 每次 SP 路径都会重新读取 `SP.SY()` 与登记值比较；即使 pair 曾经登记成功，canonical SY 发生漂移也会在拉取或 approve 前回退。
- `OutrunRouter.sol::setTrustedSP(SP, address(0))` 用于撤销配对；`OutrunRouter.sol::setTrustedSY(SY, false)` 只撤销 SY 信任，不会自动清零已有的 SP mapping，但后续调用会因 SY 不再 trusted 而失败，因此应显式撤销 pair 并核对 getter / event。
- 撤销 SY 或配对只影响后续 router 入口，已完成的 position、uAsset debt 和 SY share state 不受影响。
- 当前 setter 是 pre-mainnet deployment wiring：部署后先注册全部 SY，再登记匹配的 SP -> SY pair，核对 getter 与事件后才开放入口。主网发布前冻结并移除临时 owner/admin setter（包括 `OutrunRouter.sol::setTrustedSY`、`OutrunRouter.sol::setTrustedSP`、`OutrunRouter.sol::setMemeverseLauncher`），主网不依赖运行期新增或替换 target。

## 2. token / native -> SY

`mintSYFromToken(SY, tokenIn, receiver, amountInput, minSyOut)` 是 router 的 token 或 native 入金入口。

- router 先校验 `SY` 已登记且仍是有代码的合约；如果 `tokenIn != NATIVE`，则 `msg.value` 必须为 0，否则回退 `NativeAmountMismatch()`。
- router 总是从 `msg.sender` 拉取 `tokenIn`，不会消费 router 自己预存的同名余额。测试也证明 router 即使事先有 prefund，实际入金仍来自调用者。
- 之后 router 调用 `IStandardizedYield(SY).deposit(receiver, tokenIn, amountInput, minSyOut)`。
- `SYBase.deposit(...)` 会再次校验：
  - `tokenIn` 必须是 `isValidTokenIn(tokenIn)` 支持的资产。
  - `amountTokenToDeposit` 不能为 0。
  - 若 `tokenIn != NATIVE`，`msg.value` 也必须为 0。
- `SYBase.deposit(...)` 成功后，`SY` 份额直接 mint 给 `receiver`，不是留在 router。
- native 路径下，router 会把 `amountInput` 作为 `value` 传给 `SY.deposit(...)`；测试证明这一路径会把 `tokenIn` 记录为 `address(0)`，并把相同数额的 `msg.value` 透传给 `SY`。

## 3. SY -> token

`redeemSyToToken(SY, receiver, tokenOut, amountInSY, minTokenOut)` 是 router 的 `SY` 赎回入口。

- router 先校验 `SY` 已登记，再把 `amountInSY` 从调用者转到 `SY` 合约地址本身，而不是转到 router 自己。
- 然后 router 调用 `IStandardizedYield(SY).redeem(receiver, amountInSY, tokenOut, minTokenOut, true)`；该 `SY` 实例必须先由 owner 将当前 router 配置为 trusted router caller。
- `burnFromInternalBalance = true` 的含义是：`SYBaseUpgradeable.sol::redeem` 会从 `address(this)`，也就是 `SY` 合约自身余额里烧份额；只有 owner 配置的 trusted router caller 可使用该模式，其他 caller 传入 `true` 会回退。
- `burnFromInternalBalance = false` 仍是直兑模式，从 `msg.sender` 的余额烧份额，不要求 trusted router 配置。
- 结算顺序是 token-out-before-burn：adapter `_redeem`（含外部调用）先把 tokenOut 交付给 receiver，随后才 burn 份额；重入安全由 `SYBase.redeem` 的 `nonReentrant` 保证，不靠 burn 在前。
- `SYBase.redeem(...)` 会校验：
  - `tokenOut` 必须是 `isValidTokenOut(tokenOut)` 支持的资产。
  - `amountSharesToRedeem` 不能为 0。
  - 实际产出的 `amountTokenOut` 不能低于 `minTokenOut`。
- 测试证明这一路径也不会动用 `SY` 合约里已有的 prefund internal balance；调用者的 `SY` 仍然会被先转入，再按本次数量烧掉。

## 4. token -> locked stake

`stakeFromToken(SP, tokenIn, tokenAmount, stakeParam)` 当前实现是”从 `SP.SY()` 派生 canonical `SY`，先 mint `SY`，再创建 locked position”。

`StakeParam` 结构体包含以下字段：
- `lockupDays`：锁仓天数
- `minSyOut`：token -> SY 最小输出（滑点保护）
- `minUAssetMinted`：SY -> uAsset 最小输出（滑点保护）
- `owner`：position owner，拥有仓位控制权
- `receiver`：uAsset 接收地址；当 `receiver == address(0)` 时回退到 `owner`

当前路由行为：
- router 先校验已登记的 SP -> SY 配对，再读取 stake manager 绑定的 canonical `SY`，不接收调用者单独传入的 `SY`。
- router 先调用 `_mintSY(..., address(this), tokenAmount, stakeParam.minSyOut)`，把新 mint 的 `SY` 留在 router。
- router 解析 uAsset 接收地址：`uAssetReceiver = stakeParam.receiver == address(0) ? stakeParam.owner : stakeParam.receiver`。
- 然后 router 调用 `SP.stake(amountInSY, stakeParam.lockupDays, stakeParam.owner, uAssetReceiver)`。
- `OutrunStakingPosition.stake(...)` 的行为是：
  - `positionOwner` 和 `uAssetReceiver` 不能为零地址。
  - `amountInSY` 必须满足 `minStake`。
  - 把 `SY` 从 router 拉入 position 合约。
  - 先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `uAssetDebt = canonical asset -> uAsset`。
  - 用这个 `uAssetDebt` 作为初始 `position.UAssetMinted`（返回值/事件字段名为 `mintedUAsset`）。
  - 新建 `positionId`，写入 `owner`、`syStaked`、`UAssetMinted`、`deadline`。
  - 向 `uAssetReceiver` mint 等额 `uAsset`。
- router 在 stake 完成后才检查 `mintedUAsset >= stakeParam.minUAssetMinted`（即 `SP.stake` 返回值）；不足时整笔交易回退并报 `InsufficientUAssetMinted(...)`。

## 5. SY -> locked stake

`stakeFromSY(SP, amountInSY, stakeParam)` 与上一路径的差别，只在于输入资产已经是 `SP.SY()` 返回的 canonical `SY`。

- router 先校验已登记的 SP -> SY 配对，再读取 canonical `SY`，把 `amountInSY` 从调用者拉到自己地址。
- 之后走和 `token -> locked stake` 一样的 `_stakeFromSYBalance(...)` 路径。
- router 根据 `stakeParam.receiver` 决定 uAsset 接收地址：若 `receiver == address(0)` 则回退到 `stakeParam.owner`。
- locked position 创建后的核心语义不变：
  - `deadline = block.timestamp + lockupDays * 1 days`
  - 初始 debt 是先做 `SY -> canonical asset`，再做 `canonical asset -> uAsset` 归一化定价，不是固定 1:1
  - position 赎回必须等到 `deadline` 到期
- 测试证明：若实际铸出的 `uAsset` 低于 `stakeParam.minUAssetMinted`，router 会整笔回退。

## 6. token / SY -> wrap stake

当前 wrap stake 走的是共享 wrap 池，不会生成 `positionId`。

### 6.1 token -> wrap stake

`wrapStakeFromToken(SP, tokenIn, tokenAmount, minSyOut, uAssetReceiver, minUAssetMinted)` 的流程是：

- router 先校验已登记的 SP -> SY 配对，再读取 stake manager 绑定的 `SY`。
- router 调用 `_mintSY(SY, tokenIn, address(this), tokenAmount, minSyOut)`，先把 token / native 转成 `SY`，并由 `SY.deposit(...)` 校验 token -> SY 最小输出。
- router 再调用 `SP.wrapStake(amountInSY, uAssetReceiver)`。
- router 在 wrap stake 完成后校验 `mintedUAsset >= minUAssetMinted`（即 `SP.wrapStake` 返回值）；不足时整笔交易回退并报 `InsufficientUAssetMinted(...)`。

### 6.2 SY -> wrap stake

`wrapStakeFromSY(SP, amountInSY, uAssetReceiver, minUAssetMinted)` 的流程是：

- router 先校验已登记的 SP -> SY 配对，再读取 canonical `SY`，把 `SY` 从调用者拉到自己地址。
- 之后走和 `token -> wrap stake` 一样的 `OutrunRouter.sol::_wrapStakeFromSYBalance` 共享尾部：approve 精确额度给 `SP`、调用 `SP.wrapStake(amountInSY, uAssetReceiver)`，并在完成后校验 `mintedUAsset >= minUAssetMinted`；不足时整笔交易回退并报 `InsufficientUAssetMinted(...)`。

### 6.3 wrap stake 落到 position 合约后的语义

`OutrunStakingPosition.wrapStake(...)` 当前行为是：

- `amountInSY` 不能为 0，`uAssetReceiver` 不能为零地址。
- 把 `SY` 拉入 position 合约。
- 先计算 `canonicalAssetValue = SY -> canonical asset`，再计算 `uAssetDebt = canonical asset -> uAsset`。
- 更新共享账务：
  - `syTotalStaking += amountInSY`
  - `syWrapStaking += amountInSY`
  - `wrapUAssetDebt += uAssetDebt`
- 给 `uAssetReceiver` mint `uAssetDebt` 数量的 `uAsset`。

测试证明：

- wrap stake 返回值是本次 mint 的 `uAsset` 数量。
- `wrapStakeFromSY(...)` 会直接把 `uAsset` 打给 `uAssetReceiver`。
- wrap stake 不产生独立 `positionId`。

## 7. genesis flows

当前 router 提供两个 genesis 入口：`genesisByToken(...)` 和 `genesisBySY(...)`。

### 7.1 genesisByToken

- `genesisByToken(SP, tokenIn, tokenAmount, minSyOut, lockupDays, verseId, genesisUser, minUAssetMinted)` 会先校验已登记的 SP -> SY 配对，再读取 `SP.SY()`，把 `tokenIn` 转成 `SY`，并把 `minSyOut` 传给 token -> SY deposit。
- 然后调用 `SP.stake(amountInSY, lockupDays, genesisUser, address(this))`。
- 这里走的是 locked stake，不是 wrap stake。
- stake 产出的 `uAsset` 先 mint 给 router 自己。
- router 在 stake 后校验 `mintedUAsset >= minUAssetMinted`；不足时整笔交易回退并报 `InsufficientUAssetMinted(...)`。
- router 校验 `mintedUAsset <= type(uint128).max`。
- 之后 router 授权 `memeverseLauncher`，再调用 `memeverseLauncher.genesis(verseId, uint128(mintedUAsset), genesisUser)`。
- router 当前不会在 `genesis(...)` 返回后再检查 launcher 是否把本次 allowance 全部消费；这一步依赖当前 launcher 实现按传入的 `mintedUAsset` 精确拉取 `uAsset`。

### 7.2 genesisBySY

- `genesisBySY(SP, amountInSY, lockupDays, verseId, genesisUser, minUAssetMinted)` 会先校验已登记的 SP -> SY 配对，再从 `SP.SY()` 读取 canonical `SY`，从调用者拉取 `SY`。
- 后续和 `genesisByToken(...)` 一样，仍然调用 `SP.stake(...)` 创建 locked position。
- router 在 stake 后校验 `mintedUAsset >= minUAssetMinted`；不足时整笔交易回退并报 `InsufficientUAssetMinted(...)`。
- 最终也是由 launcher 拉走本次 stake 产出的 `uAsset`。
- router 当前不会对 launcher 的 allowance 消费结果做额外断言；精确消费由当前 launcher 实现负责。

### 7.3 当前实现可确认的 genesis 语义

- genesis 当前一定会生成 locked position，并写入 `deadline`。
- genesis 当前不会走 wrap 池，所以不会增加 `syWrapStaking`。
- 测试明确证明：`genesisBySY(...)` 成功后 `syWrapStaking == 0`，`syTotalStaking` 增加；在当前受信任的 launcher 实现下，本次 stake 产出的 `uAsset` 会被 launcher 拉走，而不是留在用户或 router。
- genesis 入口没有 preview 参数；`genesisByToken(...)` 有 `minSyOut` 和 `minUAssetMinted`，`genesisBySY(...)` 有 `minUAssetMinted`。

### 7.4 launcher 配置校验

- `OutrunRouter` 的 constructor 与 `setMemeverseLauncher(...)` 会在配置期 fail fast，拒绝 `address(0)` 和 `code.length == 0` 的 launcher 地址。
- `OutrunRouter.sol::setMemeverseLauncher` 成功轮换时发出 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）；该事件已落地（`IOutrunRouter.sol` 声明、`OutrunRouter.sol::_setMemeverseLauncher` emit）。部署验收时注意 constructor 部署期同样经 `_setMemeverseLauncher` 首发 `SetMemeverseLauncher(address(0), launcher)`（`oldLauncher` 为零初值），并核对 `OutrunRouter.sol::memeverseLauncher` 读取值。
- genesis 流程可把 `memeverseLauncher` 已通过配置期 code-size 校验视为前置条件。
- router 对 launcher 的运行期信任边界目前只到“地址存在代码、当前实现按参数执行 `genesis(...)`”；router 不额外校验 launcher 是否把本次 allowance 精确消费完。
- 这属于运行/测试可观测性加固，不改变 launcher 内部仍是外部信任边界这一语义。

### 7.5 target registry 与撤销

- Router owner 应先调用 `setTrustedSY(...)` 登记官方 SY，再调用 `setTrustedSP(...)` 登记每个官方 SP 的配对；部署脚本或集成层应记录 `TrustedSYUpdated` 与 `TrustedSPUpdated` 事件并核对 `SP.SY()`。
- `redeemSyToToken` 入口还要完成 trusted-router wiring：每个官方 SY 由该实例 owner 调用 `SYBaseUpgradeable.sol::setTrustedRouter(OUTRUN_ROUTER)`（当前 router 地址），使 `SYBaseUpgradeable.sol::trustedRouter()` 等于 router，并核对 `SetTrustedRouter` 事件后再开放该入口；遗漏该步时入口在 `SYBaseUpgradeable.sol::redeem` 以 `SYUnauthorizedInternalRedeemer(address caller)` 回退（见 §3）。轮换 router 时先对每个 SY 设置新 router 并核对读取值与事件，再停用旧入口或撤销（`SYBaseUpgradeable.sol::setTrustedRouter(address(0))`）。
- `setTrustedSY(SY, false)` 或 `setTrustedSP(SP, address(0))` 只影响后续 router 入口，不回滚已完成的资产流或 position 状态。

### 7.6 错误面与下游透传边界

- `NativeAmountMismatch()` 由 `OutrunRouter.sol::_mintSY` 先校验 trusted SY 后委托 `TokenHelper.sol::_transferIn` 唯一完成 router-side 的 native/ERC20 金额检查：native sentinel 要求 `msg.value == amount`，ERC20 输入要求 `msg.value == 0`。该检查先于 transfer、approve 与 SY deposit；下游 `SYBaseUpgradeable.sol::deposit` 仍有独立的 token / `msg.value` 校验。
- `InvalidParam()` 的两个 router-side 触发点分别是：`OutrunRouter.sol::_approveExact` 收到非 native token 的 `type(uint256).max`，拒绝无限 allowance；以及 `OutrunRouter.sol::_genesisFromSYBalance` 在 stake 返回的 `mintedUAsset > type(uint128).max` 时回退。后者发生在 launcher approve 与 `genesis(...)` 调用之前。
- `InvalidMemeverseLauncher(address)` 由 `OutrunRouter.sol::_setMemeverseLauncher` 在 `_memeverseLauncher.code.length == 0` 时触发；`OutrunRouter.sol::constructor` 与 `OutrunRouter.sol::setMemeverseLauncher` 都经过该检查，因此配置阶段对零地址和无代码地址 fail fast。
- `IOutrunRouter.sol::InvalidMemeverseLauncher` 是该公共 error 的 canonical 声明来源，`OutrunRouter.sol` 通过继承暴露相同 selector/revert payload；使用 Solidity 类型化 selector 的集成代码从 `OutrunRouter.InvalidMemeverseLauncher.selector` 迁移到 `IOutrunRouter.InvalidMemeverseLauncher.selector`，仅发生源码命名空间迁移，链上 ABI/runtime 保持。
- `InsufficientUAssetMinted(...)` 由 `OutrunRouter.sol::_assertMinUAssetMinted` 在实际 `mintedUAsset < minUAssetMinted` 时触发。locked stake/genesis 在 `OutrunRouter.sol::_stakeFromSYBalance` 返回后检查，wrap stake 在 `OutrunRouter.sol::_wrapStakeFromSYBalance` 完成 `SP.wrapStake(...)` 后检查；检查失败会回退整笔调用。
- 下游 `SY` 的 `deposit(...)` / `redeem(...)`、`SP` 的 `SY()` / `stake(...)` / `wrapStake(...)` 以及 launcher 的 `genesis(...)` 若自身回退，router 不捕获、不改写错误数据，原始 revert 透传给上层；router 自身的白名单、金额、精确 approve、最小铸造量和 `uint128` 边界检查可能在相应下游调用前先回退。launcher 仅在配置期做 code-size 校验，`genesis(...)` 返回后 router 不额外断言 allowance 是否已被精确消费。

## 8. preview 语义与 slippage 边界

当前 router 暴露的 preview 入口有：

- `previewStakeFromToken(SP, tokenIn, tokenAmount, stakeParam)`
- `previewStakeFromSY(...)`
- `previewWrapStakeFromToken(SP, tokenIn, tokenAmount)`

router 只暴露上述 3 个交易级 preview；SP 级共有 6 个 preview（`previewStake`、`previewWrapStake`、`previewDrawUAsset`、`previewRedeem`、`previewWrapRedeem`、`previewKeepRedeem`）是完整 quote 族。它们的失败面与 0-vs-revert 语义以 [accounting.md §5](./accounting.md) 和 [§11.1](./accounting.md) 为 canonical；其中 `previewStakeFromToken` / `previewStakeFromSY` 会透传 `SP.previewStake` 的 `MinStakeInsufficient` / `ZeroExchangeRate` / dust-返 0，而 `previewWrapStakeFromToken` 会透传 `SP.previewWrapStake` 的 `ZeroInput` / `ZeroExchangeRate` / `DustRoundedToZero`。

当前实现里，这些 preview 的语义边界很明确：

- `previewStakeFromToken(SP, tokenIn, tokenAmount, stakeParam)` 不接收调用者传入的 `SY`；它先校验已登记的 SP -> SY 配对，再从 `SP.SY()` 派生 canonical `SY`，再做两步静态组合：
  - 从 `SP.SY()` 读取 canonical `SY`
  - `SY.previewDeposit(tokenIn, tokenAmount)`
  - `SP.previewStake(amountInSY)`；其语义与执行期一致：先做 `SY -> canonical asset`，再做 `canonical asset -> uAsset`
- `previewStakeFromSY(...)` 先校验已登记的 SP -> SY 配对，再调用 `SP.previewStake(amountInSY)`；其语义同样是先 `SY -> canonical asset`，再做 `canonical asset -> uAsset`。
- `previewWrapStakeFromToken(SP, tokenIn, tokenAmount)` 不接收调用者传入的 `SY`；它先校验已登记的 SP -> SY 配对，再从 `SP.SY()` 派生 canonical `SY`，再做两步静态组合：
  - 从 `SP.SY()` 读取 canonical `SY`
  - `SY.previewDeposit(tokenIn, tokenAmount)`
  - `SP.previewWrapStake(amountInSY)`；其语义与执行期一致：先做 `SY -> canonical asset`，再做 `canonical asset -> uAsset`

当前 preview 不是完整成交保护，主要有这些边界：

- `previewStakeFromToken(...)` 和 `previewStakeFromSY(...)` 接收 `stakeParam` 参数，但只使用 `stakeParam.lockupDays` 来消除未使用变量告警；preview 结果不反映：
  - `minSyOut`
  - `minUAssetMinted`
  - `owner`
  - `receiver`
  - 不同 `lockupDays` 的差异对 exchangeRate 的影响（如果有的话）
- preview 只 quote，不锁定执行结果；执行时实际成交保护由入口参数负责：
  - `stakeFromToken(...)`、`wrapStakeFromToken(...)`、`genesisByToken(...)` 的 token -> SY 阶段使用 `minSyOut`。
  - locked stake、wrap stake 与 genesis 的 SY -> uAsset 阶段使用 `minUAssetMinted`。
  - `redeemSyToToken(...)` 的赎回阶段使用 `minTokenOut`。
  - `preview` 与执行期都以 mixed-decimals 可支持为目标，不把 `SY` canonical asset decimals 与 `uAsset` decimals 不同视为禁止配置；差异由归一化换算吸收。

## 9. 当前实现提醒

- locked stake 与 wrap stake 是两套不同表面：
  - locked stake 生成 `positionId`，受 `deadline` 约束。
  - wrap stake 不生成 position，走共享池账务；wrap 池退出由 keeper 经 `keepWrapRedeem` 托管，无协议内自助赎回。
- router 的 locked stake 路径现在通过 `StakeParam` 支持分离 position owner 和 uAsset receiver：
  - `stakeParam.owner` 是 position owner
  - `stakeParam.receiver` 是 uAsset 接收地址，当 `receiver == address(0)` 时回退到 `owner`
- genesis 当前不是”wrap 后再 launch”，而是”先建 locked position，再把 stake 产出的 `uAsset` 交给 launcher”。
- wrap 池按 principal debt 记账，不会因为汇率上涨自动给用户补发更多 `uAsset`；`harvestWrapYield(...)` 只能收走高于 `wrapDebtInSY` 的那部分 `SY`，其中 `wrapDebtInSY` 由 `wrapUAssetDebt` 先按 up 版本做 `uAsset -> canonical asset`，再按 up 版本做 `canonical asset -> SY` 得出，因此保留当前 exchangeRate 下覆盖 wrap debt 所需的最小 `SY`。
- 任何 token / native 与 tokenOut 是否可用，最终都取决于具体 `SY` 实现的 `isValidTokenIn` / `isValidTokenOut`。
- 跨链边界：`OutrunStakingPositionUpgradeable.sol::redeem` 由 position owner 用自己在 position 所在链上的 uAsset 余额经 `OutrunUniversalAssetsUpgradeable.sol::repay` 销毁销债；`::keepRedeem` / `::keepWrapRedeem` 属于 keeper 路径，烧的是 keeper 自己的同链 uAsset。
- OFT 跨链 `OutrunOFTUpgradeable.sol::_debit` / `::_credit` 只移动流通供应、不移动 minter 债务台账，因此用户把 uAsset 桥到其他链后，必须先把 uAsset 桥回（受 peer / outbound rate limit 配置约束）或在本地另行获取，才能用同一份 uAsset 走 `redeem` 销债。
- keeper 路径是独立信任角色，不与用户自有 uAsset 绑定。

## 10. Pause / unpause 对 router 入口的影响

router 自身没有 pause 管理能力，但 router 下游的 position、SY、uAsset 各自可被独立 pause。以下矩阵描述三级 pause 下 8 个 router 状态变更入口的可用性与回退点；组件级 pause 机制以 `docs/spec/position/state-machines.md` §8 为准，本节只落 router 入口的映射，不重复 position 面内容。

三级 pause 的生效点：

- position 级 pause：`OutrunStakingPositionUpgradeable.sol::stake`、`::wrapStake` 等 position 业务入口带 `whenNotPaused`。
- SY 级 pause：`SYBaseUpgradeable.sol::deposit`、`::redeem` 带函数级 `whenNotPaused`；常规 SY transfer 由 `OutrunERC20PausableUpgradeable.sol::_update` 的 `whenNotPaused` 兜底。
- uAsset 级 pause：`OutrunUniversalAssetsUpgradeable.sol::mint`、`::repay` 带 `whenNotPaused`；常规 uAsset transfer 与 OFT outbound send 由 `_update` 兜底（跨链 inbound `_credit` 豁免见 `docs/spec/common-foundations.md`）。

| router 入口 | position pause | SY pause | uAsset pause |
| --- | --- | --- | --- |
| `OutrunRouter.sol::mintSYFromToken` | 可用（不触 SP） | 在 `SYBaseUpgradeable.sol::deposit` 函数级 `whenNotPaused` 回退 | 可用（不触 uAsset mint） |
| `OutrunRouter.sol::redeemSyToToken` | 可用（不触 SP） | 非零额在开头 SY transferFrom 回退；零额在 `SYBaseUpgradeable.sol::redeem` 回退 | 可用（不触 uAsset mint/repay） |
| `OutrunRouter.sol::stakeFromToken` | 在 `OutrunStakingPositionUpgradeable.sol::stake` 回退 | 在 `SYBaseUpgradeable.sol::deposit` 回退 | 在 `OutrunUniversalAssetsUpgradeable.sol::mint` 回退 |
| `OutrunRouter.sol::stakeFromSY` | 同上 | 在开头 SY transferFrom 回退 | 同上 |
| `OutrunRouter.sol::wrapStakeFromToken` | 在 `OutrunStakingPositionUpgradeable.sol::wrapStake` 回退 | 在 `SYBaseUpgradeable.sol::deposit` 回退 | 同上 |
| `OutrunRouter.sol::wrapStakeFromSY` | 同上 | 在开头 SY transferFrom 回退 | 同上 |
| `OutrunRouter.sol::genesisByToken` | 在 `OutrunStakingPositionUpgradeable.sol::stake` 回退 | 在 `SYBaseUpgradeable.sol::deposit` 回退 | 同上（launcher 拉取 uAsset 的 transfer 另受 `_update` 兜底） |
| `OutrunRouter.sol::genesisBySY` | 同上 | 在开头 SY transferFrom 回退 | 同上 |

反直觉格补充说明：

- `mintSYFromToken` 与 `redeemSyToToken` 不触 position 或 uAsset，因此 position pause 与 uAsset pause 期间仍可用；「可用」指不触 uAsset 的 mint/repay 表面，若某 SY adapter 支持 `tokenOut == uAsset`，uAsset `_update` 的 `whenNotPaused` 仍会在交付侧兜底。
- `redeemSyToToken` 在 SY pause 期间（非零额）的死点在 `OutrunRouter.sol::redeemSyToToken` 开头的 SY transferFrom（经 `OutrunERC20PausableUpgradeable.sol::_update` 的 `whenNotPaused`），而非 `SYBaseUpgradeable.sol::redeem`；只有零额输入（`TokenHelper.sol::_transferFrom` 跳过零额 transfer）才会到达 `::redeem` 的函数级 `whenNotPaused`。
- 上述「可用」与退出语义不改变 preview/view 入口的处理：对应 preview 不受 position/uAsset 级 pause 阻断的规则以 `docs/spec/position/state-machines.md` §8 为准。
