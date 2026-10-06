# OutStake Protocol Specification

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
`uAsset` 的 minter 债务账本与流通供应分离：`revokeMinter(minter)` 只把该 minter 的 `mintingCap` 置零以禁止未来 mint，不清除既有 `amountInMinted`，未偿债务仍需后续 repay。`OutrunUniversalAssetsUpgradeable` 当前无 `sweep` 为有意设计，未来若新增 `sweep` 必须 `onlyOwner nonReentrant` 经 timelock/multisig 且阻断 `address(this)`——阻断 `address(this)` 的依据是 sweep uAsset 自身将使 owner 绕过 mint/cap 授权面获得流通代币；transfer 式 sweep 只移动余额、对 minter 债务台账与跨账本不变量零接触，不得为 rescue 回写 `amountInMinted`（完整口径见 `docs/spec/common-foundations.md`「基础规则」sweep 条）。
OFT outbound/inbound 不触碰 minter 债务台账、`_credit` 对零地址收款人重映射为 `0xdead` 的设计语义以 `docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」为准。
储备铸烧路径（`OutrunUniversalAssetsUpgradeable.sol::setReserveMinter` 登记/撤销，`OutrunUniversalAssetsUpgradeable.sol::reserveMint`/`::reserveBurn` 铸/烧，PSM 消费）同样不触碰 minter 债务台账，kill switch 为 `setReserveMinter(psm, false)`；完整豁免语义见 `docs/spec/psm/peg-stability-module.md`。
`transferMinterDebt(from, to, amount)` 是 owner-only 的 minter 级债务迁移；输入校验、账务约束与用途限定以 `docs/spec/common-foundations.md`「基础规则」为准。

另外，销债路径与 OFT 跨链之间存在本地销债边界：`OutrunStakingPositionUpgradeable.sol::redeem` 经 `OutrunUniversalAssetsUpgradeable.sol::repay`（本金腿）与 ERC20 transfer（利息腿，v1 零费下恒 0）消耗 position owner 在 position 所在链上的 uAsset 余额来偿债；OFT 跨链（`OutrunOFTUpgradeable.sol::_debit` / `::_credit`）只移动流通供应、不移动 minter 债务台账，因此被桥出到其他链的 uAsset 必须先桥回（受 `OutrunOFTUpgradeable` 的 peer / outbound rate limit 配置约束）或在本地另行获取，才能用于原链销债；出站限流与 peer 配置下的销债可达性联动与校准见下文「跨链可用性与限流」节。

OFT 跨链可用性依赖 per-eid peer 与 outbound rate limit（含 DVN/enforcedOptions 信任根）配置；语义、预览入口与告警要求见下文「跨链可用性与限流」节，此处不重复。

### position

v1 产品定义：SP（`OutrunStakingPositionUpgradeable`）= **Memeverse 专用、按面值铸造、零利息、无清算的收益背书凭证层**——uAsset 叙事为「按面值足额背书的凭证，生息敞口 100% 留在抵押方（genesis 参与者）」。

- 与 PSM 同族（面值铸/烧），差异：PSM 储备由协议持有、供非借款人换汇；SP 抵押为用户自有生息 SY、铸出与 genesis 需求严格绑定。
- 唯一铸造入口：`OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（SP 原生物理门：`genesisLauncher` kill switch、精确 approve、`GenesisGateLib` 后置断言全额消费）。自由借贷入口（`stake`）不存在。
- 面值铸造（价值平价）：`mintedUAsset = floor₂(syStaked × SY.exchangeRate())`（两段 down，无 LTV 缩放），背书不变式 `positions.principalDebt ≤ syStaked × exchangeRate(铸造时点)` 由取整方向构造成立。
- 零利息：v1 全族默认 `duty = 1e27`（零费哨兵合法）；`rate` 永不前移、债务冻结、背书率单调上升；`setDuty` 保留（接受域 `[1e27, DUTY_CAP]`，sub-RAY 全拒），未来加息需配套背书率监控口径调整（见 `docs/deployment.md`）。
- 无清算：链上不设清算、LTV 或再融资机制；铸造侧率值链上守卫按族分形：oracle-fed 族为 oracle fail-closed 栈（适配器新鲜度栈：正性/round 完整性/新鲜度/sequencer/归一化非零 + SY 基类锚点偏差熔断），Sky L2 族（`OutrunL2StakedUsdsSYUpgradeable`）由 PSM3-SSR 双源偏差守卫守率值（偏离超 `maxDeviationBps` 即 revert `RateDeviationExceeded`，fail-closed），另有族无关的 `ZeroExchangeRate` 单点守卫——语义真源 `docs/spec/yield/oracles-and-integrations.md`「边界」；`mintingCap` 是唯一供给刹车。风险按五层瀑布承接（集成准入 → 发行方自救 → 协议桥接 → 收入年金 → 终局脱钩社会化，声明见 `docs/ARCHITECTURE.md` 风险模型节）。
- `redeem` 任意时刻按比例双腿销债（利息腿转协议金库——v1 零费下恒 0、本金腿 burn 并冲销 minter 台账）；完整行为规格见 `docs/spec/position/accounting.md`（账务、计息、背书不变式与错误/事件真源）、`docs/spec/position/state-machines.md`（状态机与暂停矩阵）。

uAsset 供给侧三行对账式（CDP 行 `amountInMinted(SPx) == Σ 活动仓位 principalDebt`、PSM 行豁免、POLend 行接口预留）、position minter 部署 wiring 与升级 / 迁移验收步骤以 `docs/spec/position/accounting.md`「Position minter 对账式（三行对账式，升级 / 迁移 / 运营对账验收标准）」为准。

### psm（现状：单实例单储备已落地（四实例 + (uAsset, reserveToken) 配对绑定））

PSM 是 uAsset 的储备兑换供给路径（现状即四个 `OutrunPSMUpgradeable` 实例各绑定单一储备——UUSD 拆为 USDC-PSM 与 USDT-PSM 两实例，UETH / UBNB 各一原生实例）：每实例以其绑定储备与对应 uAsset（UUSD/UETH/UBNB）按固定 1:1 面值双向兑换（`OutrunPSMUpgradeable.sol::mint`/`::redeem`，只操作绑定储备），为 uAsset 提供独立于 CDP 的锚定供给来源。uAsset 共三条供给路径：CDP（position 层）+ PSM + POLend；POLend 指 Memeverse 侧杠杆创世供给路径，不在本仓库实现，接线缝为 `src/router/interfaces/IPOLendGenesis.sol`。费率 `tin`/`tout` 上线默认各 0.1%、owner 可调（0 ≤ fee ≤ 1%），`stockCap` 约束各实例净铸出存量（恒 > 0，无单笔流量维度，每个 (uAsset, reserve) 实例独立）；PSM 经 uAsset 储备铸烧路径铸/烧、豁免 minter 债务台账，储备守恒式按实例口径为「PSM 所持绑定 reserve 余额 × _faceValueScale（按面值折算，6-dec 储备×1e12，原生腿×1）== 该实例累计净流入面值 + 该实例未提取计费结余」（费额沉淀经无许可 `OutrunPSMUpgradeable.sol::sweepFees` 提取至部署期 initialize 绑定后 immutable 的 `feeRecipient`，流内口径下提取只减结余不减本金面；饱和即混合外部赎回域内以「余额 − netUAssetMinted」公式为权威口径，超出历史差额口径费额的部分为不再背书本实例流通 uAsset 的本金沉淀，随费额一并可提取），该等式以标准币前提（非 fee-on-transfer/非 rebasing，名义转账额=实收额）为成立条件且在「赎回的 uAsset ⊆ PSM 铸出」流内精确成立；混合外部赎回流量下精确等式不再保证，退化为 `绑定 reserve 面值 ≥ 本实例 netUAssetMinted` + 余额硬边界与 `netUAssetMinted` 对账。已实现的是配对版 registry；完整行为规格见 `docs/spec/psm/peg-stability-module.md`，配对接线见 `docs/spec/router/router-and-user-flows.md`。

### usr

USR 是 uAsset 的储蓄层：每个 uAsset 族一个 `OutrunUSRVaultUpgradeable` 实例（UUPS upgradeable，suETH/suUSD/suBNB，share 为对应 suToken），存入对应 uAsset、随存随取，share 价格按治理设定的族利率（18-dec 年化点值，绝对上限 10%、上限内直接指定、上线默认 0）按秒增长（timestamp 锚定）。硬预算 fail-safe：禁 mint 计息，owner 计息注资唯一入口是 `OutrunUSRVaultUpgradeable.sol::fund`，利息预算由余额超出份额负债的部分支撑（成因：`fund` 注资与不可回收的误转/捐赠沉淀），余额不足时计息自动暂停、注资后恢复。owner 面仅注资 `OutrunUSRVaultUpgradeable.sol::fund`、设族利率 `OutrunUSRVaultUpgradeable.sol::setUsrRate` 与 UUPS 升级，无 sweep、无回收函数，入池资金仅存款人可经 ERC4626 提款取出。完整行为规格见 `docs/spec/usr/usr-vaults.md`。

### yield

当前收益层以 `SYBaseUpgradeable` 为统一抽象。所有 SY adapters 都以 upgradeable variants 作为当前产品真源。

### router

当前路由层由 `OutrunRouter` 实现，保持非 upgradeable、可重部署 helper 语义。genesis 为双路径：路径 A（PSM 门）经 `OutrunRouter.sol::genesisByPSM` 以 reserve token 经 PSM 1:1 面值铸 uAsset 后全额交 launcher（无仓位、无债务，router 侧后置断言）；路径 B（CDP 门）双计价入口——`OutrunRouter.sol::genesisByToken`（token 计价正门：token 先经 `SY.deposit` 换成 SY）/ `OutrunRouter.sol::genesisBySY`——为薄转发便利层，转发至 SP 原生物理门 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（面值/价值平价铸出，铸出 uAsset 交易内全额交 launcher，借出量与 genesis 消费量严格相等由 SP 断言；任意 EOA/合约可直接调 SP，router 非必经——组合性）。自由质押入口（`stakeFromToken`/`stakeFromSY`）随 v1 genesis-only 决策删除。双门之外另有第三入口 `OutrunRouter.sol::leveragedGenesisByPSM`（杠杆创世门）：reserve token 经 PSM 面值铸 uAsset 后全额作为利息交 Memeverse 侧 POLend 杠杆创世（借出额度记 `genesisUser`），`polend` 地址经 owner 登记测试期 setter（生产冻结 immutable）。目标登记与脱困回收为 owner-only 的持续 live 动态注册表能力（`OutrunRouter.sol::setTrustedSY`/`::setTrustedSP`/`::setPsmForUAsset`/`::trustedSY`/`::trustedSYForSP`/`::psmForUAsset`/`::sweep`，owner-only（`sweep` 另挂 `nonReentrant`），由 `Ownable` 持有、产品外经 multisig 治理，产品合约内不设 `TimelockController`），本概览仅作指针：详见 `docs/spec/router/router-and-user-flows.md` §1.2/§6/§7.5 与 `docs/spec/access-control.md`，不随主网上线冻结移除；该 live 集合不含 launcher——`OutrunRouter.sol::memeverseLauncher` 生产冻结为 immutable（仅经 constructor 布线，换 launcher 即重部署 router），`OutrunRouter.sol::setMemeverseLauncher` 在部署/测试期为 live owner-only（轮换须与每 SP 的 OutrunStakingPositionUpgradeable.sol::setGenesisLauncher 同一治理事务原子执行），生产删除。

### integrations

当前集成层只承担外部协议调用与 oracle 适配，不单独证明外部系统语义。

### deployment

当前部署层以 proxy-backed deployment flow 为准：先部署 implementation，再用 `ERC1967Proxy` 初始化并写入下游 wiring。implementation 构造期已禁用 initializer（经 `OutrunOFTUpgradeable.sol::constructor` 调 `_disableInitializers()`），implementation 本尊不可被直接 `initialize`，只能经 `ERC1967Proxy` delegatecall 初始化；详细约束与验收测试见 `docs/spec/common-foundations.md`「部署与升级一致性约束」。

## 当前实现提醒

- `SY` 现在以 upgradeable variants 为产品真源
- `OutrunStakedUSDeSYUpgradeable` 只输出 `sUSDe`
- router 不承担独立资金池
- position 层为 v1 收益背书凭证层（genesis-only、面值铸造、0% 利率默认、无清算；锁仓/wrap/keeper/revenuePool/自由借贷/清算面已删除）；规格真源为 `docs/spec/position/` 两文件（accounting.md、state-machines.md）
- router 层为 genesis 双路径（PSM 门 / CDP 门；B 门双计价入口 `genesisByToken`（token 正门）/ `genesisBySY`，薄转发至 SP 原生 `stakeForGenesis`；`genesisByPSM` 与 `psmForUAsset` registry 已实现；自由质押入口已删除）；规格真源为 `docs/spec/router/router-and-user-flows.md`

## 暂停与滑点下界

`whenNotPaused` 三级熔断与 `preview`/`minSyOut`/`minTokenOut`/`minUAssetMinted` 滑点下界已在执行层完整实现（`OutrunStakingPositionUpgradeable.sol::stakeForGenesis`/`::redeem`；`OutrunUniversalAssetsUpgradeable.sol::mint`/`::repay`、`SYBaseUpgradeable.sol::deposit`/`::redeem`），本概览仅作指针：暂停矩阵与三级影响见 `docs/spec/router/router-and-user-flows.md` §8/§10 与 `docs/spec/position/state-machines.md` §8，暂停矩阵执行真值与 `_credit` 豁免见 `docs/spec/common-foundations.md`；`preview` 与零下界=无保护语义见 `docs/spec/router/router-and-user-flows.md` §8（`min==0` 即无滑点保护，调用方须基于 `previewDeposit`/`previewRedeem` 计算非零下界）。
## 跨链可用性与限流

`OutrunOFTUpgradeable.sol::_debit` 出站前经 `OutrunRateLimiterUpgradeable.sol::_outflow` 校验 per-eid outbound rate limit，peer 未设时经 `OAppCore.sol::_getPeerOrRevert` revert `NoPeer`；本概览仅作指针：限流与 peer/DVN 语义见 `docs/spec/common-foundations.md`「OFT 与 rate limiter」、换算与校验见同文件「OFT 换算参数与发送/部署校验语义」，部署与监控见 `docs/deployment.md`「跨链信任根投产校验与应急处置」与「跨链限流（OFT Outbound Rate Limit）高危参数校验清单」；`quoteOFT().maxAmountLD`/`getAmountCanBeSent`/`isRateLimited` 为预览与可观测性入口，`RateLimitExceeded`/零 peer 需告警（fail-closed，无资金损失）。

**销债可达性联动与校准**：OFT 出站限流与 peer 配置是跨链持币用户销债可达性的组成部分——出站额度为该方向全部流量共享、无按用途的优先级或豁免；额度占满（`RateLimitExceeded`）或运行期调低限额（checkpoint 语义下已 in-flight 超新限额、可用额度瞬态为 0，机制见 `docs/spec/common-foundations.md`「OFT 与 rate limiter」）时回桥受阻，`OutrunStakingPositionUpgradeable.sol::redeem` 对跨链持币用户事实上不可达；peer 未设/撤销（`NoPeer`）同理。风险定性：fail-closed 流动性中断、无资金损失——仓位、债务、抵押不受影响，v1 无清算、无到期门，零费下等待零成本。治理校准要求：每个 live eid 的 outbound limit/window 须相对该 uAsset 的跨链流通分布与预期回桥销债流评估后配置；运行期调低限额前须评估对销债可达性的影响（含 checkpoint 瞬态全阻断窗口）；对 live eid 的持续 `RateLimitExceeded` 按「销债可达性事件」口径告警处置（本节上文告警要求的扩展）。风险接受记录：OFT 层无法区分转账用途，设计上不存在还债流量的机制级豁免；限流收紧（桥面风险遏制）与销债可用性之间的权衡属治理决策，调参时须显式接受并留痕；部署侧操作清单见 `docs/deployment.md`「跨链限流（OFT Outbound Rate Limit）高危参数校验清单」。

## 跨仓库接线约束（Memeverse/POLend）

本节固定 OutStake（本仓库）与 Memeverse/POLend（跨仓库，不在本仓库实现）之间的接线约束。POLend 指 Memeverse 侧杠杆创世供给路径（uAsset 三条供给路径的第三行，见 `docs/spec/position/accounting.md` §10.2/§12），合约侧接线缝为双门交款 `src/router/interfaces/IMemeverseLauncher.sol`、杠杆创世门 `src/router/interfaces/IPOLendGenesis.sol`，以及 uAsset minter 登记；对账视图预留 `src/position/interfaces/IPOLendGlobalDebt.sol`（语义见 `docs/spec/position/accounting.md` §12）。行为规格真源在各 spec 文件，本节只落跨仓库约束，不重复实现语义。

1. **uAsset 全族 18 decimals**：UETH/UUSD/UBNB 统一 18 decimals（`OutrunOFTUpgradeable` 保留自定义 metadata/decimals 能力，当前部署为 18-dec 唯一形态）；POLend 侧不得按 6/8 decimals 假设做数量换算（把 `1e18` 当 `1e6`/`1e8` 口径折算会放大/缩小 1e12/1e10 倍）；单位模型真源见 `docs/spec/common-foundations.md`「单位模型」。
2. **uAsset transfer/mint/repay 无外部回调语义**：uAsset 为标准 OZ 风格 ERC20（`OutrunERC20Upgradeable.sol` 实现 `IERC20`/`IERC20Metadata`，无 ERC777 式 receiver hook），`OutrunUniversalAssetsUpgradeable.sol::mint`/`::repay`、储备铸烧路径与一切 transfer 均不会回调接收方合约；Memeverse 侧集成不得假设「转账即通知」语义，状态同步须自行轮询事件或余额。
3. **pause 联动 runbook**：OutStake 侧 uAsset / SP / SY 任一 pause 即 Memeverse 引擎对新 genesis 冻结（fail-closed）——uAsset pause 阻断 `OutrunUniversalAssetsUpgradeable.sol::mint`/`::repay`/`::reserveMint`/`::reserveBurn`，路径 A（`OutrunRouter.sol::genesisByPSM`）在 PSM 铸出步、路径 B（`OutrunRouter.sol::genesisBySY`/`::genesisByToken` 双入口）在 CDP 铸出步（SP 侧 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`）各自回退，两 genesis 门 fail-closed；SP pause 阻断路径 B（`OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 回退），路径 A 不受 SP pause 影响；SY pause 阻断路径 B（SY 计价入口的 SY 拉取步 / token 计价入口的 `SY.deposit` 步）；PSM 无自有 pause，其可用性经 uAsset 暂停传导（`docs/spec/psm/peg-stability-module.md`「暂停联动」）。逐入口映射（含 launcher 拉取步的 `_update` 兜底与非 pause 可用性边界）以 `docs/spec/router/router-and-user-flows.md` §10 矩阵与 `docs/spec/position/state-machines.md` §8.4 暂停矩阵为执行真值；Memeverse 侧应把上述三级 pause 事件纳入引擎熔断触发面（新 genesis 冻结判定依赖该矩阵，不得在引擎侧自行缓存「可用」状态跨 pause 事件）。
4. **新族上线前 POLend 侧 maxReserve 检查项**：新 uAsset 族接入 Memeverse 前，POLend 须核对其引擎侧 maxReserve 配置与该族 OutStake 侧供给上限的相对关系——该族 PSM `stockCap`（净铸出存量上限，`OutrunPSMUpgradeable.sol::stockCap`）与 CDP mintingCap（`OutrunUniversalAssetsUpgradeable.sol::setMintingCap` 为该族 SP 所设上限）。引擎侧 maxReserve 显著超出两侧供给上限可支撑的规模时，超出部分的引擎侧杠杆需求会在 OutStake 侧供给入口 fail-closed（`StockCapExceeded`/`ReachMintCap`）处无法成交；核对结果记录为该族上线验收证据。
5. **锚供给看板**：POLend minter 的 mint/burn 须纳入 uAsset 锚供给监控口径，与 PSM 储备侧（`OutrunPSMUpgradeable.sol::netUAssetMinted` 与储备守恒式）、CDP 台账侧（`OutrunUniversalAssetsUpgradeable.sol::mintingStatusTable`）做三方对账；对账式真源为 `docs/spec/position/accounting.md` §10.2 三行对账式——POLend 行 == `Σ globalDebtByUAsset + 未结 preRedeem backing`，视图族接口语义见同文件 §12（Memeverse 侧持子账本，本仓库不实现该视图）。
6. **利息收入归属边界（商务待定）**：协议金库（`OutrunStakingPositionUpgradeable.sol::protocolTreasury`，redeem 利息腿接收方——v1 零费默认下利息腿恒 0，该参数为未来加息保留，见 `docs/spec/position/accounting.md` §9）收到的利息腿 uAsset 的归属与分配规则为商务待定项。本协议层只固定收款目的地与变更审计面（`OutrunStakingPositionUpgradeable.sol::setProtocolTreasury`，事件 `SetProtocolTreasury`），不定义金库内再分配机制；定案前任何文档或实现不得预设在金库与其他方之间分配该笔收入的规则。
7. **POLend 杠杆创世两入口 ABI 契约**：Memeverse 侧 POLend 杠杆创世对 OutStake 暴露两入口 `leveragedGenesis(verseId, interestAmount, user)` / `leveragedGenesisWithCredit(verseId, creditAmount, user)`——payer 为 `msg.sender`（uAsset / GenesisCredit 从 payer 拉款）、利息记账 keyed by `user`（`user` 零地址回退 `ZeroInput`）、事件四字段 `(verseId, payer, user, amount)`，另暴露 `marketUAsset(verseId)` getter 供 verse ↔ uAsset 配对校验；两入口由 Memeverse 侧提供，OutStake 侧消费面为 router 杠杆创世门（`OutrunRouter.sol::leveragedGenesisByPSM`，行为规格见 `docs/spec/router/router-and-user-flows.md`「杠杆创世门」节）。

