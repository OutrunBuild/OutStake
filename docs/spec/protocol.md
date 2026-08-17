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
`uAsset` 的 minter 债务账本与流通供应分离：`revokeMinter(minter)` 只把该 minter 的 `mintingCap` 置零以禁止未来 mint，不清除既有 `amountInMinted`，未偿债务仍需后续 repay。
OFT outbound/inbound 不触碰 minter 债务台账、`_credit` 对零地址收款人重映射为 `0xdead` 的设计语义以 `docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」为准。
`transferMinterDebt(from, to, amount)` 是 owner-only 的 minter 级债务迁移；完整输入校验与账务约束（不 mint/burn/transfer、`mintingCap` headroom、用途限定、与 position/wrap 台账的协调迁移关系）以 `docs/spec/common-foundations.md`「基础规则」为准。

另外，redeem/keep 系与 OFT 跨链之间存在本地销债边界：`OutrunStakingPositionUpgradeable.sol::redeem` / `::keepRedeem` / `::keepWrapRedeem` 经 `OutrunUniversalAssetsUpgradeable.sol::repay` 销毁调用者（position owner 或 keeper）在 position 所在链上的 uAsset 余额来销债；OFT 跨链（`OutrunOFTUpgradeable.sol::_debit` / `::_credit`）只移动流通供应、不移动 minter 债务台账，因此被桥出到其他链的 uAsset 必须先桥回（受 `OutrunOFTUpgradeable` 的 peer / outbound rate limit 配置约束）或在本地另行获取，才能用于原链销债。keeper 赎回是独立的信任路径，烧的是 keeper 自己的同链 uAsset，不等同于用户自主赎回。

### position

当前仓位层由 `OutrunStakingPositionUpgradeable` 实现，维护锁仓仓位与公共 wrap 池。

### yield

当前收益层以 `SYBaseUpgradeable` 为统一抽象。所有 SY adapters 都以 upgradeable variants 作为当前产品真源。

### router

当前路由层由 `OutrunRouter` 实现，保持非 upgradeable、可重部署 helper 语义。

### integrations

当前集成层只承担外部协议调用与 oracle 适配，不单独证明外部系统语义。

### deployment

当前部署层以 proxy-backed deployment flow 为准：先部署 implementation，再用 `ERC1967Proxy` 初始化并写入下游 wiring。

## 当前实现提醒

- `SY` 现在以 upgradeable variants 为产品真源
- `OutrunStakedUSDeSYUpgradeable` 只输出 `sUSDe`
- router 不承担独立资金池
