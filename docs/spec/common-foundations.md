# Common Foundations

## 目标

本文档只记录当前产品真源里会持续影响上层语义的基础层规则：

- `src/libraries/TokenHelper.sol`
- vendored OpenZeppelin `ReentrancyGuardTransient.sol`（EIP-1153 transient 重入保护，经 `TokenHelper.sol` 继承；外部依赖，上游语义不记为本地保证）
- `src/libraries/SYUtils.sol`
- `src/libraries/AaveAdapterLib.sol`
- `src/libraries/WadRayMath.sol`
- `src/libraries/AutoIncrementIdUpgradeable.sol`
- `src/libraries/ArrayLib.sol`（地址数组构造辅助，语义权重低，本文档只列名）
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
- `OutrunExchangeOracleAdapter` 做 raw answer 正性检查、新鲜度窗口校验（`maxStaleness`；`updatedAt == 0`、`updatedAt > block.timestamp`（feed 时钟超前）或超窗均 fail-closed，revert `StaleOracleAnswer`）、可选 L2 sequencer 状态校验（构造期 `sequencerUptimeFeed == address(0)` 关闭）后做精度归一化，并在归一化后校验结果非零（`ZeroNormalizedRate`）；不提供 bounds、fallback 或多源聚合；通过 `latestRoundData()` 读取（非 `latestAnswer()`）
- `uAsset` minter 债务由 `amountInMinted` 记录；`revokeMinter(minter)` 通过把 `mintingCap` 置零禁止后续 mint，但保留既有 `amountInMinted` 直到偿还
- `OutrunUniversalAssetsUpgradeable.sol::setMintingCap` 可把 `mintingCap` 下调至低于既有 `amountInMinted`：此后 `OutrunUniversalAssetsUpgradeable.sol::mint` 的前置 cap 校验失败、revert `ReachMintCap`，直到 `OutrunUniversalAssetsUpgradeable.sol::repay` 把 `amountInMinted` 冲减至新 cap 以下方自愈——属预期自愈语义，非故障；cap 置零时 repay 不产生自愈，mint 持续被阻断直至重新调升 cap（同 `revokeMinter`）
- `transferMinterDebt(from, to, amount)` 当前已实现为 owner-only 操作：要求 `from`、`to` 均非零、彼此不同、`amount` 非零；仅在两个 minter 地址之间迁移未偿债务，不 mint、不 burn、不 transfer，也不改变 `totalSupply` 或任一账户 `balance`
- `transferMinterDebt` 执行时减少 `from.amountInMinted`、增加 `to.amountInMinted`，并要求来源 minter 具备足额未偿债务、目标 minter 具备足够 `mintingCap` headroom；用途限定为运维修复或迁移，不用于用户债务豁免
- `transferMinterDebt` 只迁移 `uAsset` 的 minter 级债务；若该 minter 还受 position、wrap 等模块账本约束，操作方只能在这些账本保持一致的协调迁移流程中使用它，`uAsset` 本身不会同步更新 position/wrap 台账

### uAsset 错误与事件观测

- `OutrunUniversalAssetsUpgradeable.sol::setMintingCap` 与 `OutrunUniversalAssetsUpgradeable.sol::revokeMinter` 对零 minter 地址 revert `ZeroInput`；`OutrunUniversalAssetsUpgradeable.sol::mint` 对零 receiver 或零 amount、`OutrunUniversalAssetsUpgradeable.sol::repay` 对零 account 或零 amount revert `ZeroInput`
- `OutrunUniversalAssetsUpgradeable.sol::mint` 在本次铸出超过 minter 的 `mintingCap` headroom 时 revert `ReachMintCap`；`OutrunUniversalAssetsUpgradeable.sol::transferMinterDebt` 在目标 minter 无法容纳迁入债务时同样 revert `ReachMintCap`
- `OutrunUniversalAssetsUpgradeable.sol::repay`（来源为 `msg.sender` minter）或 `OutrunUniversalAssetsUpgradeable.sol::transferMinterDebt`（来源为 `from` minter）在销减量超过来源 minter 的未偿 `amountInMinted` 时 revert `ReachBurnCap`；该名称表示未偿债务余额不足，协议没有另一个可配置的独立 burn cap
- `OutrunUniversalAssetsUpgradeable.sol::transferMinterDebt` 对 `from`/`to` 任一为零地址、两者相同或 `amount == 0` revert `InvalidTransferParams`
- 五个 uAsset 事件及字段为：`MintUAsset(indexed minter, indexed receiver, amount)`、`BurnUAsset(indexed minter, amount)`、`SetMintingCap(indexed minter, oldMintingCap, newMintingCap)`、`RevokeMinter(indexed minter, oldMintingCap)`、`TransferMinterDebt(indexed from, indexed to, amount)`（声明见 `IUniversalAssets.sol`）
- `OutrunUniversalAssetsUpgradeable.sol::mint` 与 `OutrunUniversalAssetsUpgradeable.sol::repay` 分别伴随 `MintUAsset`/`BurnUAsset` 以及 ERC20 `Transfer`（铸出为零地址到 receiver，偿还为 account 到零地址）；`setMintingCap`、`revokeMinter`、`transferMinterDebt` 只改 minter 账本并发出各自 accounting event，不改变账户 `balance` 或 `totalSupply`，也不发出 ERC20 `Transfer`/`Approval`
- `OutrunOFTUpgradeable.sol::_debit` 与 `OutrunOFTUpgradeable.sol::_credit` 仅通过 ERC20 `_update` 产生 ERC20 `Transfer`：不读写 minter debt ledger，不改变 `amountInMinted`/`mintingCap`，也不发出 `MintUAsset`/`BurnUAsset`

- `_safeApproveInf` 的 ERC20 approval 刷新：当 allowance 低于 `LOWER_BOUND_APPROVAL`（`type(uint96).max / 2`）时先归零再设 max——USDT 型 token 拒绝非零→非零变更；NATIVE 哨兵跳过；刷新是调用点触发的惰性重检，仅在再次调用 `_safeApproveInf` 时重查 allowance，不维护「恒 max」不变量
- TokenHelper 资金转移契约：native 转出走低层 call，失败必须 revert `NativeTransferFailed`（不静默吞失败）；`_transferOut`/`_transferFrom` 零金额跳过不发起转账；`_transferIn`：native 分支自身不发起转账（资金随 `msg.value` 到达）、仅校验 `msg.value == amount`，ERC20 分支要求 `msg.value == 0` 且金额非零才执行 `safeTransferFrom`，两分支的 `msg.value` 校验均不因零金额跳过
- `TokenHelper.sol::_selfBalance`：token 为 NATIVE 哨兵时读 `address(this).balance`，否则读 `balanceOf(address(this))`；`OutrunSlisBNBSYUpgradeable` 用它在外部质押存款调用（Lista StakeManager `deposit()`，效果为 mint slisBNB）前后做余额差量计量
- `TokenHelper.sol::_safeApprove`：向目标 token 透传 `forceApprove`（USDT 类非标 approve 兼容）；消费方有二：`_safeApproveInf` 的两步刷新（先归零再设 max）与 `OutrunRouter.sol::_approveExact` 的定额 approval（拒绝 `type(uint256).max`、NATIVE 跳过）——前者刷新到无限额，后者始终设置有限额的精确 allowance

## 单位模型

本节定义 mixed-decimals 双段换算语义，按当前实现直接描述。

- `exchangeRate` 的单位是 `canonical asset per 1 SY`，并按 `1e18` 缩放
- `canonicalAssetDecimals = SY.assetInfo().assetDecimals`
- `uAssetDecimals = uAsset.decimals()`
- `syAmount` 表示 `SY` 数量
- `canonicalAssetValue` 表示 canonical asset 单位下的价值
- `uAssetDebtUnits` 表示 `uAsset` decimals 口径下的债务单位
- 代码侧标识符对应：`uAssetDebt`（`OutrunStakingPositionUpgradeable.sol::stake` / `OutrunStakingPositionUpgradeable.sol::wrapStake` 局部变量与 `Stake` 事件字段，即 `uAssetDebt ≡ uAssetDebtUnits`）；**公共入口的** uAsset 输入形参统一命名 `amountInUAsset`（如 `keepWrapRedeem`/`keepRedeem`/`previewWrapRedeem`/`previewKeepRedeem` 的入参与 `_assetToSy`/`_assetToSyUp` 的换算形参；纯数值换算 helper 的通用形参（如 `_scaleUAssetToCanonicalAsset` 的 `amount`）不受此约束）。uAsset 域数量的标识符一律携带显式 uAsset 标记；该规则约束代码标识符与文档中反引号标记的标识符，规则针对**语义命名层**的债务/价值量标识符：storage 总债务域用 `UAssetMinted`（`Position` 字段/`positions()` 返回），调用级铸出量域用 `mintedUAsset`（`stake`/`drawUAsset`/`wrapStake` 返回值与对应事件字段），两域刻意异名；销债域保留 `UAssetBurned`（`redeem`/`keepRedeem` 返回值与 `Redeem`/`KeepRedeem` 事件字段），属调用级销毁量、不属铸出量域，不随本轮更名；preview 族返回值保留 `UAssetMintable` 命名——`-able` 后缀区分「可铸出量报价」与实际铸出量 `mintedUAsset`，属刻意的 quote/actual 命名区分，不随调用级更名；其他如 `uAssetDebt`、`currentValueInUAsset`；`drawUAsset`/`previewDrawUAsset` 内暂存 `position.UAssetMinted` 的局部 `positionUAssetMinted`（域前缀齐全，不属裸短名）；`_scaleUAssetToCanonicalAsset` 的 `amount` 等纯机械换算用途的短名，不视为域语义标识符，不受标记规则约束；不复用指 SY 本金的通名（如 `principal`），不约束中文散文里的『本金（principal）』一词

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

### ray 域换算（Aave 流动性指数）

ray（`1e27`）是 Aave 流动性指数的数值域，区别于上文 SYUtils 公式的 `1e18` canonical 域；两族换算函数各自独立、不得互相代用（ray 域换算对见下文，SYUtils 1e18 域公式见上文）。adapter 层 `OutrunAaveV3SYUpgradeable.sol::exchangeRate` 由 1e27 域指数 ÷ 1e9 派生 1e18 域汇率，属单位重标定而非函数族混用，见 `docs/spec/yield/yield-adapters.md` 的 `OutrunAaveV3SYUpgradeable` 行。

成对换算函数与舍入方向：

- `AaveAdapterLib.sol::calcSharesFromAssetHalfUp(amountAssets, index)`：内部走 `WadRayMath.rayDiv`，half-up 舍入；存款收份额方向——`OutrunAaveV3SYUpgradeable` 在 aToken 直存路径与 `_previewDeposit` 中以它把资产额折成 scaled shares
- `AaveAdapterLib.sol::calcSharesToAssetDown(amountShares, index)`：`(amountShares * index) / 1e27`，floor 舍入；赎回付资产方向——`OutrunAaveV3SYUpgradeable` 在 `_redeem` 与 `_previewRedeem` 中以它把 scaled shares 折回资产额

舍入对照：`calcSharesFromAssetHalfUp` 的 half-up 不是 SYUtils 恒向上族（`assetToSyUp`）——后者无条件向 ceiling 进位，前者仅在商的小数部分达到 0.5 及以上时进位；两者是不同数值域上的不同舍入策略，`AaveAdapterLib` 的 NatSpec 显式区分这一点以防混淆。

`WadRayMath.sol::rayDiv` 的 half-up 定义与溢出 guard 契约：

- half-up 定义：`c = (a * 1e27 + b / 2) / b`（余数加半除数后整除）
- `b == 0` revert
- `a` 超上界 revert：要求 `a <= (type(uint256).max - b / 2) / 1e27`

`WadRayMath` 为镜像 Aave 上游 `WadRayMath` 语义的本仓库裁剪版；本节只记本仓库消费方向的契约，上游规则全集仍属外部依赖（体例同 `docs/spec/yield/oracles-and-integrations.md` 的 Evidence Rules：外部协议语义不得记为本地保证）。

## AutoIncrementId id 不变量

- `AutoIncrementIdUpgradeable` 的 counter 存于 ERC-7201 命名空间 slot（`outrun.storage.AutoIncrementId`），空槽初值 0，无初始化状态：`AutoIncrementIdUpgradeable.sol::__AutoIncrementId_init` 为空体占位（形态同 OpenZeppelin `ContextUpgradeable`），链入 init 链不写任何状态
- `AutoIncrementIdUpgradeable.sol::_nextId` 为 pre-increment：先自增再返回，首个签发 id = 1，严格单调递增，id 永不重用（自增用 `unchecked`，uint256 counter 溢出视为实际不可能）
- 消费面：`OutrunStakingPositionUpgradeable` 以 `_nextId()` 作为 positionId 来源

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
- `window == 0` 表示无限额，只存在于未配置/删除态：`setOutboundRateLimit` 拒绝 `window == 0`（revert `InvalidWindowSeconds`），`removeOutboundRateLimit` 删除配置后回到无限额；该状态下基座 `OutrunRateLimiterUpgradeable.sol::getAmountCanBeSent` 返回无限额哨兵 `(0, type(uint256).max)`，OFT 层 override（`OutrunOFTUpgradeable.sol::getAmountCanBeSent`）返回 SD 域包络 `(0, uint64.max × decimalConversionRate)`
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
- `OutrunOFTUpgradeable.sol::constructor` 拒绝 `lzEndpoint == address(0)`，revert `InvalidLayerZeroEndpoint`；标准部署脚本的 `OutstakeScript.s.sol::_validateUAssetDeploymentConfig` 可能在 implementation 创建前以 `InvalidEndpoint` 预检同一输入
- `_authorizeUpgrade`（owner-only）校验新实现与当前值三一致——endpoint、decimalConversionRate、localDecimals 任一不一致即 revert `InvalidOFTUpgradeConfig`：升级不可改变这三项

单笔发送的 SD 域 LD 上限 = `uint64.max × decimalConversionRate`；`quoteOFT().maxAmountLD` 为该值与 rate-limit 可用额度的 `min` 再去 dust（`window == 0` 时等于该值），见上文 `## OFT 与 rate limiter` 小节。

## 结论

当前上层产品语义仍然建立在：

1. 统一的 native/ERC20 资金契约
2. 统一的 allowance 语义
3. 统一的 transient reentrancy guard
4. 统一的 18-decimal 兑换规则
5. proxy-backed upgradeable deployment model
