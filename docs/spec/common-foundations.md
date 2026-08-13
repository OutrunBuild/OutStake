# Common Foundations

## 目标

本文档只记录当前产品真源里会持续影响上层语义的基础层规则：

- `src/libraries/TokenHelper.sol`
- `src/libraries/ReentrancyGuard.sol`
- `src/libraries/SYUtils.sol`
- `src/assets/base/OutrunERC20Upgradeable.sol`
- `src/assets/base/OutrunERC20PausableUpgradeable.sol`
- `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`
- `src/assets/omnichain/OutrunOFTUpgradeable.sol`
- `src/assets/omnichain/OutrunRateLimiterUpgradeable.sol`
- `src/assets/interfaces/IUniversalAssets.sol`
- `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`
- `test/upgradeable/SYUpgradeable.t.sol`
- `test/upgradeable/SYAdaptersUpgradeable.t.sol`
- `test/upgradeable/OracleSetterUpgradeable.t.sol`
- `test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol`

## 基础规则

- `address(0)` 作为 `NATIVE`
- `nonReentrant` 由 transient guard 提供
- `1e18` 是统一换算基准
- oracle-backed upgradeable adapters 通过 `exchangeRateOracle` storage 读取外部汇率
- `OutrunExchangeOracleAdapter` 做 raw answer 正性检查、新鲜度窗口校验（`maxStaleness`，含 `updatedAt == 0` fail-closed）、可选 L2 sequencer 状态校验（构造期 `sequencerUptimeFeed == address(0)` 关闭）后做精度归一化；不提供 bounds、fallback 或多源聚合；通过 `latestRoundData()` 读取（非 `latestAnswer()`）
- `uAsset` minter 债务由 `amountInMinted` 记录；`revokeMinter(minter)` 通过把 `mintingCap` 置零禁止后续 mint，但保留既有 `amountInMinted` 直到偿还
- `transferMinterDebt(from, to, amount)` 当前已实现为 owner-only 操作：要求 `from`、`to` 均非零、彼此不同、`amount` 非零；仅在两个 minter 地址之间迁移未偿债务，不 mint、不 burn、不 transfer，也不改变 `totalSupply` 或任一账户 `balance`
- `transferMinterDebt` 执行时减少 `from.amountInMinted`、增加 `to.amountInMinted`，并要求来源 minter 具备足额未偿债务、目标 minter 具备足够 `mintingCap` headroom；用途限定为运维修复或迁移，不用于用户债务豁免
- `transferMinterDebt` 只迁移 `uAsset` 的 minter 级债务；若该 minter 还受 position、wrap 等模块账本约束，操作方只能在这些账本保持一致的协调迁移流程中使用它，`uAsset` 本身不会同步更新 position/wrap 台账
- `_safeApproveInf` 的 ERC20 approval 刷新：当 allowance 低于 `LOWER_BOUND_APPROVAL`（`type(uint96).max / 2`）时先归零再设 max——USDT 型 token 拒绝非零→非零变更；NATIVE 哨兵跳过；刷新是调用点触发的惰性重检，仅在再次调用 `_safeApproveInf` 时重查 allowance，不维护「恒 max」不变量
- TokenHelper 资金转移契约：native 转出走低层 call，失败必须 revert `NativeTransferFailed`（不静默吞失败）；`_transferOut`/`_transferFrom` 零金额跳过不发起转账；`_transferIn`：native 分支自身不发起转账（资金随 `msg.value` 到达）、仅校验 `msg.value == amount`，ERC20 分支要求 `msg.value == 0` 且金额非零才执行 `safeTransferFrom`，两分支的 `msg.value` 校验均不因零金额跳过

## 单位模型（本次修复目标）

本节定义 mixed-decimals 双段换算的本次修复目标/修复后语义，不把它表述为当前代码已完成行为。

- `exchangeRate` 的单位是 `canonical asset per 1 SY`，并按 `1e18` 缩放
- `canonicalAssetDecimals = SY.assetInfo().assetDecimals`
- `uAssetDecimals = uAsset.decimals()`
- `syAmount` 表示 `SY` 数量
- `canonicalAssetValue` 表示 canonical asset 单位下的价值
- `uAssetDebtUnits` 表示 `uAsset` decimals 口径下的债务单位

记：

- `roundDownDiv(x, y) = floor(x / y)`
- `roundUpDiv(x, y) = ceil(x / y) = floor((x + y - 1) / y)`

四个基础换算公式：

- `SY -> canonical asset`
  - down: `canonicalAssetValue = roundDownDiv(syAmount * exchangeRate, 1e18)`
  - up: `canonicalAssetValue = roundUpDiv(syAmount * exchangeRate, 1e18)`
- `canonical asset -> uAsset`
  - 若 `uAssetDecimals >= canonicalAssetDecimals`，`uAssetDebtUnits = canonicalAssetValue * 10 ** (uAssetDecimals - canonicalAssetDecimals)`
  - 若 `uAssetDecimals < canonicalAssetDecimals`，down: `uAssetDebtUnits = roundDownDiv(canonicalAssetValue, 10 ** (canonicalAssetDecimals - uAssetDecimals))`
  - 若 `uAssetDecimals < canonicalAssetDecimals`，up: `uAssetDebtUnits = roundUpDiv(canonicalAssetValue, 10 ** (canonicalAssetDecimals - uAssetDecimals))`
- `uAsset -> canonical asset`
  - 若 `canonicalAssetDecimals >= uAssetDecimals`，`canonicalAssetValue = uAssetDebtUnits * 10 ** (canonicalAssetDecimals - uAssetDecimals)`
  - 若 `canonicalAssetDecimals < uAssetDecimals`，down: `canonicalAssetValue = roundDownDiv(uAssetDebtUnits, 10 ** (uAssetDecimals - canonicalAssetDecimals))`
  - 若 `canonicalAssetDecimals < uAssetDecimals`，up: `canonicalAssetValue = roundUpDiv(uAssetDebtUnits, 10 ** (uAssetDecimals - canonicalAssetDecimals))`
- `canonical asset -> SY`
  - down: `syAmount = roundDownDiv(canonicalAssetValue * 1e18, exchangeRate)`
  - up: `syAmount = roundUpDiv(canonicalAssetValue * 1e18, exchangeRate)`

## Pause 与跨链 OFT 执行边界

`OutrunERC20PausableUpgradeable` 的 pause 语义用于阻断用户主动发起的本地 ERC20 transfer、mint、burn 业务入口，也阻断 pause 之后用户在源链新发起的 OFT outbound send。

`OutrunOFTUpgradeable` 的 LayerZero inbound `_credit` 执行路径是跨链消息生命周期的一部分，不能因为目标链本地 pause 阻断已经进入跨链流程的代币。因此，`_credit` 直接走基础 ERC20 `_update`，不经过 `OutrunERC20PausableUpgradeable._update whenNotPaused`。

该规则只豁免 inbound `_credit`，不扩大到用户主动发起的 outbound send、普通用户 transfer、`uAsset.mint`、`SY.deposit` 或 `SY.redeem`。

## OFT 与 minter 债务豁免边界

OFT outbound `_debit` burn 与 inbound `_credit` mint 均不触碰 minter 债务台账——不读/写任何 minter 的 `amountInMinted` 或 `mintingCap`，为设计语义。`_credit` 对零地址收款人重映射为 `0xdead`。

## OFT 与 rate limiter

`OutrunOFTUpgradeable` 继承 `OutrunRateLimiterUpgradeable`，对每个远程链的 outbound send 施加风控限额（部署不配置本地链限额）：

- outbound send 受 rate limit 约束：`_debit` burn 前先走 `_outflow` 记账，超过可用额度即 revert `RateLimitExceeded`
- 线性衰减回补模型：`decay = limit × timeSinceLastUpdate / window`；当前 in-flight = `max(0, 上次 in-flight − decay)`；可用额度 = `limit − 当前 in-flight`（距上次记账超过 `window` 后全量回补）
- `quoteOFT()` 的 `maxAmountLD` 受 rate limit 封顶：取 `min(amountCanBeSent, uint64.max × decimalConversionRate)` 再去 dust；`window == 0` 时不封顶
- `window == 0` 表示无限额，只存在于未配置/删除态：`setOutboundRateLimit` 拒绝 `window == 0`（revert `InvalidWindowSeconds`），`removeOutboundRateLimit` 删除配置后回到无限额
- checkpoint 语义：每次 `setOutboundRateLimit` 先以 0 记账结算当前 in-flight，再写入新限额；若限额被调低，已 in-flight 可瞬态超过新限额——此时可用额度为 0、outbound 暂时全部 revert，随衰减回补自愈
- 部署约束：部署脚本对每个远程链强制设置限额与窗口，限额/窗口由 env 显式配置、无生产默认值，任一为 0 即部署 revert；部署测试断言值为 1_000_000 ether / 1h（测试断言值，非生产默认值）

## OFT 换算参数与发送/部署校验语义

`OutrunOFTUpgradeable` 继承 LayerZero `OFTCoreUpgradeable`，跨链金额在 LD（local decimals）与 SD（shared decimals）两域间换算：

- decimalConversionRate（DCR）= `10 ** (localDecimals − sharedDecimals)`，immutable；`sharedDecimals` 默认 6（Outrun 代码未覆盖），18-dec 部署下 DCR = 1e12
- 发送金额经 `_removeDust` 去 dust（按 DCR 粒度截断低位）后 burn：实际 burn 与跨链到账金额均为去 dust 后金额（≤ 用户输入 `amountLD`；源/目标 localDecimals 相同时到账数值相等），dust 保留在发送方源链余额中、不被 burn、不跨链
- `_debitView` 在去 dust 后金额低于 `minAmountLD` 时 revert `SlippageExceeded`：`minAmountLD` 是发送方滑点保护下限
- LD→SD 换算结果超过 `uint64.max` 时 revert `AmountSDOverflowed`：单笔发送受 SD 域上限约束（对应 LD 上限 = `uint64.max × DCR`）
- `approvalRequired()` 返回 `false`；`token()` 返回 `address(this)`：OFT 合约本身不要求 allowance

部署与升级一致性约束（`OutrunUniversalAssetsUpgradeable`）：

- `initialize` 强制传入 `decimals_` 等于构造期固化的 `_localDecimalsForValidation()`，否则 revert `DecimalsMismatch(expected, provided)`：不可用与 localDecimals 不一致的 decimals 部署
- `_authorizeUpgrade`（owner-only）校验新实现与当前值三一致——endpoint、decimalConversionRate、localDecimals 任一不一致即 revert `InvalidOFTUpgradeConfig`：升级不可改变这三项

单笔发送的 SD 域 LD 上限 = `uint64.max × decimalConversionRate`；`quoteOFT().maxAmountLD` 为该值与 rate-limit 可用额度的 `min` 再去 dust（`window == 0` 时等于该值），见上文 `## OFT 与 rate limiter` 小节。

## 结论

当前上层产品语义仍然建立在：

1. 统一的 native/ERC20 资金契约
2. 统一的 allowance 语义
3. 统一的 transient reentrancy guard
4. 统一的 18-decimal 兑换规则
5. proxy-backed upgradeable deployment model
