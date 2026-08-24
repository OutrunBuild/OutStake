# OutStakeV2 Protocol Specification

## 系统目标

1. `uAsset` 作为统一债务与流通资产层
2. `SY` 作为标准化收益份额层
3. `OutrunStakingPositionUpgradeable` 作为仓位账本
4. `OutrunRouter` 作为用户入口
5. `script/deploy/**` 作为部署入口

## 当前范围

### assets

当前资产层以 `OutrunUniversalAssetsUpgradeable` 为中心，并通过 `OutrunOFTUpgradeable` 提供跨链扩展。
`OutrunOFTUpgradeable` 的 pause 阻断本地用户主动发起的 ERC20 路径与 pause 之后新发起的 outbound send，但 inbound `_credit` 为不阻塞已在跨链流程中的代币而不受 `whenNotPaused` 阻断；完整执行边界以 `docs/spec/common-foundations.md`「Pause 与跨链 OFT 执行边界」为准。
`uAsset` 的 minter 债务账本与流通供应分离：`revokeMinter(minter)` 只把该 minter 的 `mintingCap` 置零以禁止未来 mint，不清除既有 `amountInMinted`，未偿债务仍需后续 repay。`OutrunUniversalAssetsUpgradeable` 当前无 `sweep` 为有意设计（G-021），未来若新增 `sweep` 必须 `onlyOwner nonReentrant` 经 timelock/multisig 且阻断 `address(this)`/`SY`/`NATIVE`，否则脱钩 PA-6。
OFT outbound/inbound 不触碰 minter 债务台账、`_credit` 对零地址收款人重映射为 `0xdead` 的设计语义以 `docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」为准。
`transferMinterDebt(from, to, amount)` 是 owner-only 的 minter 级债务迁移；完整输入校验与账务约束（不 mint/burn/transfer、`mintingCap` headroom、用途限定为修复无仓位/wrap 债支撑的错账、活 SP 退役走清盘路径）以 `docs/spec/common-foundations.md`「基础规则」为准。

另外，redeem/keep 系与 OFT 跨链之间存在本地销债边界：`OutrunStakingPositionUpgradeable.sol::redeem` / `::keepRedeem` / `::keepWrapRedeem` 经 `OutrunUniversalAssetsUpgradeable.sol::repay` 销毁调用者（position owner 或 keeper）在 position 所在链上的 uAsset 余额来销债；OFT 跨链（`OutrunOFTUpgradeable.sol::_debit` / `::_credit`）只移动流通供应、不移动 minter 债务台账，因此被桥出到其他链的 uAsset 必须先桥回（受 `OutrunOFTUpgradeable` 的 peer / outbound rate limit 配置约束）或在本地另行获取，才能用于原链销债。keeper 赎回是独立的信任路径，烧的是 keeper 自己的同链 uAsset，不等同于用户自主赎回。

OFT 跨链可用性依赖 per-eid peer 与 outbound rate limit（含 DVN/enforcedOptions 信任根）配置 — 本概览仅作指针：出站可用性与限流语义详见 `docs/spec/common-foundations.md`「OFT 与 rate limiter」与「OFT 换算参数与发送/部署校验语义」，信任根与部署投产校验见 `docs/deployment.md`「跨链信任根投产校验与应急处置」与「跨链限流（OFT Outbound Rate Limit）高危参数校验清单」；`OutrunOFTUpgradeable.sol::_debit` 前经 `OutrunRateLimiterUpgradeable.sol::_outflow` 校验，额度耗尽或 peer 未设时以 `RateLimitExceeded`/`NoPeer` 静默阻断出站（`quoteOFT`/`getAmountCanBeSent` 预览，`isRateLimited` 区分未配置），运行期需对 `RateLimitExceeded` 与零 peer 告警。

### position

当前仓位层由 `OutrunStakingPositionUpgradeable` 实现，维护锁仓仓位与公共 wrap 池。

position minter 对账式（`mintingStatusTable(address(position)).amountInMinted == Σ 活动仓位 Position.UAssetMinted + wrapUAssetDebt()`）、position minter 部署 wiring 与升级 / 迁移验收步骤以 `docs/spec/position/accounting.md`「Position minter 对账式（升级 / 迁移 / 运营对账验收标准）」为准。

### yield

当前收益层以 `SYBaseUpgradeable` 为统一抽象。所有 SY adapters 都以 upgradeable variants 作为当前产品真源。

### router

当前路由层由 `OutrunRouter` 实现，保持非 upgradeable、可重部署 helper 语义。目标登记与脱困回收为 owner-only 的 pre-mainnet 临时面（`OutrunRouter.sol:38-39,52,62,517` `setTrustedSY`/`setTrustedSP`/`trustedSY`/`trustedSYForSP`/`sweep`，`onlyOwner nonReentrant`），本概览仅作指针：详见 `docs/spec/router/router-and-user-flows.md` §1.2/§7.5 与 `docs/spec/access-control.md`，主网前随 `OutrunRouter.sol:1-14` `OutrunTODO` 清单冻结移除。

### integrations

当前集成层只承担外部协议调用与 oracle 适配，不单独证明外部系统语义。

### deployment

当前部署层以 proxy-backed deployment flow 为准：先部署 implementation，再用 `ERC1967Proxy` 初始化并写入下游 wiring。implementation 构造期已禁用 initializer（经 `OutrunOFTUpgradeable.sol::constructor` 调 `_disableInitializers()`），implementation 本尊不可被直接 `initialize`，只能经 `ERC1967Proxy` delegatecall 初始化；详细约束与验收测试见 `docs/spec/common-foundations.md`「部署与升级一致性约束」。

## 当前实现提醒

- `SY` 现在以 upgradeable variants 为产品真源
- `OutrunStakedUSDeSYUpgradeable` 只输出 `sUSDe`
- router 不承担独立资金池

## 暂停与滑点下界（S-002）

`whenNotPaused` 三级熔断与 `preview`/`minSyOut`/`minTokenOut`/`minUAssetMinted` 滑点下界已在执行层完整实现（`OutrunStakingPositionUpgradeable.sol:295,354,394,442,489,537` `OutrunUniversalAssetsUpgradeable.sol:140,163` `SYBaseUpgradeable.sol:129,162`），本概览仅作指针：暂停矩阵与三级影响见 `docs/spec/router/router-and-user-flows.md` §8/§10 与 `docs/spec/position/state-machines.md` §8，PA-1 执行真值与 `_credit` 豁免见 `docs/spec/common-foundations.md`；`preview` 与零下界=无保护语义见 `docs/spec/router/router-and-user-flows.md` §8（`min==0` 即无滑点保护，调用方须基于 `previewDeposit`/`previewRedeem` 计算非零下界）。
## 跨链可用性与限流（S-003）

`OutrunOFTUpgradeable.sol::_debit` 出站前经 `OutrunRateLimiterUpgradeable.sol::_outflow` 校验 per-eid outbound rate limit，peer 未设时经 `OAppCore.sol::_getPeerOrRevert` revert `NoPeer`；本概览仅作指针：限流与 peer/DVN 语义见 `docs/spec/common-foundations.md`「OFT 与 rate limiter」、换算与校验见同文件「OFT 换算参数与发送/部署校验语义」，部署与监控见 `docs/deployment.md`「跨链信任根投产校验与应急处置」与「跨链限流（OFT Outbound Rate Limit）高危参数校验清单」；`quoteOFT().maxAmountLD`/`getAmountCanBeSent`/`isRateLimited` 为预览与可观测性入口，`RateLimitExceeded`/零 peer 需告警（fail-closed，无资金损失）。

