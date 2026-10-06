# PSM（Peg Stability Module）规格

> 现状：单实例单储备已落地（四实例 + (uAsset, reserveToken) 配对绑定），详见下文各节。本文各章节的行为规格与验收基准随该现状描述。

## 系统定位

PSM 是 uAsset 三条供给路径（CDP / PSM / POLend，路径定义见 `docs/spec/protocol.md`）中的锚定兑换路径：以储备资产 1:1（面值）双向兑换 uAsset，不承担借贷、清算或收益职能。兑换对为 USDC/USDT ↔ UUSD、ETH ↔ UETH、BNB ↔ UBNB。POLend 指 Memeverse 侧杠杆创世供给路径，不在本仓库实现，接线缝为 `src/router/interfaces/IPOLendGenesis.sol`。

PSM 与 SP（position 层）同族——两者都是面值铸/烧语义，差异在背书持有与需求绑定：**PSM 储备由协议持有**（锁定 reserve 背书铸烧，供非借款人换汇，锚定管道对全部 uAsset 持有人开放）；**SP 抵押为用户自有生息 SY**（面值铸造背书，铸出与 Memeverse genesis 需求严格绑定，唯一铸造入口 `stakeForGenesis`，见 `docs/spec/position/accounting.md`）。uAsset 溢价时 PSM 储备放出、折价时债赎套利（SP 仓 owner 买折价 uAsset 还债赎 SY）构成回锚双管道（风险模型见 `docs/ARCHITECTURE.md` §7）。

1:1 兑换汇率是结构性常数：按面值硬编码实现、无 setter、禁接 oracle（见「零 oracle」节）。PSM 自身不设 pause，也无 owner 提取面——计费结余经无许可公开入口 `OutrunPSMUpgradeable.sol::sweepFees` 提取（对标 dss-psm `kick()`），owner 仅参数面（费率、cap 与 UUPS 升级权，见 `docs/spec/access-control.md`）。

## 合约结构与部署绑定

- 合约面：`src/psm/OutrunPSMUpgradeable.sol`（UUPS upgradeable，与产品族一致）与接口 `src/psm/interfaces/IPSM.sol`。
- 实例粒度（现状即单实例单储备，共四实例）：单个 PSM 实例绑定单一储备（对标 MakerDAO dss-psm 单实例单 gem）：UUSD 拆为 USDC-PSM 与 USDT-PSM 两实例，UETH / UBNB 各一原生实例，共四实例；部署期绑定该实例 uAsset 地址、储备 token 地址、owner 与计费结余接收方 `feeRecipient`；`OutrunPSMUpgradeable.sol::initialize` 参数为 uAsset、reserveToken、owner、feeRecipient、初始 `stockCap`/`tin`/`tout`，均按各自边界校验（cap > 0、0 ≤ fee ≤ 1%、feeRecipient 非零），`feeRecipient` 初始化后 immutable、无 setter。
- 储备绑定（现状即单实例单储备）：`reserveToken` 在 `initialize` 后 immutable，无 setter、无注册表。`address(0)` 为 NATIVE 哨兵，为 UETH / UBNB 实例的绑定储备形式；UUSD 两实例分别绑定 USDC / USDT 合约地址。已删除 `setReserveToken` / `activeReserveTokens` mapping / `UnregisteredReserveToken` / `InvalidReserveToken` / `SetReserveToken`——不存在实例内多储备切换面。该绑定域封闭为 UUSD 族 USDC/USDT、UETH 族 ETH、UBNB 族 BNB，均为标准转账语义 ERC20（非 fee-on-transfer/非 rebasing，名义转账额=实收额），与 `docs/spec/yield/yield-adapters.md` 背书对账守卫及 `docs/deployment.md` 投产前置校验同源。
- 部署布线：uAsset owner 经 `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter` 把每个 PSM 实例逐个登记为储备 minter；无 PSM 侧储备登记步骤，uAsset 侧登记完成后该实例兑换入口方可用。router 侧按 (uAsset, reserveToken) 配对逐个登记该实例（`OutrunRouter.sol::setPsmForUAsset`，现状即配对三参，见 `docs/spec/router/router-and-user-flows.md`），接线细节见 `docs/spec/router/router-and-user-flows.md` 与 `docs/deployment.md`。

## 兑换与费率

公开兑换入口两个，均 `nonReentrant`；`mint` 为 `payable`（NATIVE 输入腿需要），`redeem` 非 `payable`（`msg.value == 0` 由函数类型结构性强制，非运行期校验）；不设 `minOut` 参数——1:1 确定性数学无滑点不确定性。去 `reserveToken` 参数已落地（`mint` 无 `reserveToken` 参数、只操作绑定储备即现状）。

- `OutrunPSMUpgradeable.sol::mint(address to, uint256 amountIn)`（reserve → uAsset 方向，只操作绑定储备；`to == address(0)` 或 `amountIn == 0` revert `ZeroInput`）：拉入绑定 reserve（native 经 `msg.value` 到账，ERC20 经 `transferFrom`），把 `amountIn` 按绑定储备 decimals 折算到 18-dec 面值后按 `× (1 − tin)` 计算铸出额，经 `OutrunUniversalAssetsUpgradeable.sol::reserveMint(to, amountOut)` 铸出 uAsset 给 `to`；事件 `SwapMintForUAsset`（字段：reserveToken, to, amountIn, amountOut, feeIn；`reserveToken` 为绑定储备地址，`feeIn` 为输入面值与铸出额之差，差额导出费额）。只读口径为 `OutrunPSMUpgradeable.sol::quoteMint(uint256 amountIn)`，与执行输出恒等（quote 非零输出且本笔铸出未超 stockCap headroom 的域内；dust 零输出域 quote 返 0 而执行 revert `ZeroInput`，超 headroom 域 quote 恒正而执行 revert `StockCapExceeded`，见「零输出守卫」与「cap」节）。
- `OutrunPSMUpgradeable.sol::redeem(address to, uint256 amountIn)`（uAsset → reserve 方向，只操作绑定储备；`to == address(0)` 或 `amountIn == 0` revert `ZeroInput`）：用户先对 PSM approve uAsset，redeem 经 `_transferFrom` 把 `amountIn` 的 uAsset 从用户拉入 PSM（任意来源的真实 uAsset，锚定属性，非仅限 PSM 铸出，见「储备侧账务与 minter 豁免」；用户侧授权由 ERC20 `transferFrom` 强制），随后以 `account == address(this)`（msg.sender 语义下即 PSM 自身）调 `OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 销毁——uAsset 侧 allowance 分支不触发（仅 `account != msg.sender` 才走），按面值 `× (1 − tout)` 向 `to` 付出绑定 reserve（native 走低层 call，失败 revert `NativeTransferFailed`，同 TokenHelper 契约；ERC20 走 transfer）；事件 `SwapRedeemForReserve`（字段与 mint 侧对称：reserveToken, to, amountIn, amountOut, feeOut；`reserveToken` 为绑定储备地址，`feeOut` 为销毁面值与付出面值之差，差额导出费额）。只读口径为 `OutrunPSMUpgradeable.sol::quoteRedeem(uint256 amountIn)`，与执行输出恒等（quote 非零输出且付出额不超本实例实际持有的绑定 reserve 余额的域内；dust 零输出域 quote 返 0 而执行 revert `ZeroInput`，超持有余额域 quote 恒正而付出失败 revert，见「零输出守卫」与「外部赎回边界」节）。

单笔规模口径：不存在单笔流量限流参数，mint 侧单笔的实际约束为 stockCap 剩余 headroom（`stockCap − netUAssetMinted`；headroom 以铸出面值计，reserve 输入按 `× (1 − tin)` 折算后落入 headroom），redeem 侧为 PSM 实际持有的 reserve 余额；无时间窗限流，拆单不受限；储备消耗的运营监控与校准要求见下文「储备消耗监控与校准」。

十进制折算：reserve 侧金额按该 token 的 decimals 折算到 18 decimals 面值（USDC 6→18 放大 1e12；native 18→18 恒等）；「1:1」指面值恒等——等面值的 reserve 与 uAsset 互换，兑换输出只由费率折减，不引入任何价格项。

零输出守卫：mint 侧当输入面值 `× (1 − tin)` floor 后铸出额为 0（极端 dust × 费率组合）revert `ZeroInput`；redeem 侧对称，付出额 floor 为 0 时 revert `ZeroInput`——防止零价值交换白收储备或白烧 uAsset。quote 侧刻意分歧：`OutrunPSMUpgradeable.sol::quoteMint` / `::quoteRedeem` 对同输入不 revert、直接返回 0（纯费率数学，无白收/白烧风险故无守卫），与执行入口的 `ZeroInput` 不复现同一失败面——`quote > 0` 是可执行的必要条件而非充分条件：执行另需 mint 侧未超 stockCap headroom（超限 revert `StockCapExceeded`，见「cap」节）、redeem 侧付出不超本实例实际持有的绑定 reserve 余额（不足时付出失败 revert，见「外部赎回边界」节），且 uAsset 未暂停、本实例储备 minter 登记在册（见「暂停联动」「储备侧账务与 minter 豁免」节）。该口径与 `docs/spec/position/accounting.md` §5/§11「quote 返 0 而执行 revert」的 preview 约定同源。「quote 与执行输出恒等」断言（见「零 oracle」节）在 quote 非零输出域且未超 mint 侧 stockCap headroom / redeem 侧本实例持有储备余额的域内成立；dust 域 quote 返 0、执行 revert，超 headroom / 持有余额域 quote 恒正而执行 revert——均不构成费率数学漂移，但非零 quote 不构成可执行性保证。

native 腿 `msg.value` 一致性（`TokenHelper.sol::_transferIn` 契约口径）：`OutrunPSMUpgradeable.sol::mint` 以 NATIVE 为 reserve 时要求 `msg.value == amountIn`，超出或不足均 revert（禁止超额 native 沉淀破坏储备守恒式）；reserve 为 ERC20 时要求 `msg.value == 0`；`OutrunPSMUpgradeable.sol::redeem` 非 `payable`，`msg.value == 0` 由函数类型结构性强制（native 只作输出腿）。

费率口径：

- `tin` 作用于 mint 侧铸出额：`amountOut = 面值(amountIn) × (1 − tin)`，输入面值与铸出面值之差为 `tin` 侧费额，沉淀 PSM。
- `tout` 作用于 redeem 侧付出额：`付出额 = 面值(amountIn) × (1 − tout)`，销毁面值与付出面值之差为 `tout` 侧费额，沉淀 PSM。
- 标度与取整：费率为 18-dec 点值（`1e18` = 100%，0.1% = `1e15`，上限 1% = `1e16`）；用户所得额（mint 侧铸出额、redeem 侧付出额）一律 mulDiv 向下取整（floor，协议有利侧）；费额 = 输入面值 − 用户所得额（差额导出，非独立计算）；redeem 付出额由 18-dec 面值折回 reserve decimals 时的非整数单位按同口径 floor 舍去（如 6-dec reserve）。
- 计费结余沉淀 PSM，唯一流出口为 `OutrunPSMUpgradeable.sol::sweepFees()`（见下文「计费结余提取」）；本金面（净铸出面值）始终不可触碰，可流出的只有经 `sweepFees` 提取的沉淀——流内即费额沉淀，饱和（混合外部赎回）域另含不再背书本实例流通 uAsset 的本金沉淀（见「计费结余提取」）。
- 计费结余提取：`OutrunPSMUpgradeable.sol::sweepFees()` 为无许可公开入口（任何人可调，无 owner 门，对标 dss-psm `kick()`），接收方为部署期 immutable 绑定的 `feeRecipient`（无参数、无 setter，接收方不能运行期变更）；可提取额 = 当前计费结余 = PSM 所持绑定 reserve 面值 − 该实例净铸出 uAsset 面值（`netUAssetMinted`），向下取整到绑定储备最小单位后以绑定储备支付（NATIVE 哨兵走低层 call，失败 revert `NativeTransferFailed`，同 TokenHelper 契约；ERC20 走 transfer）；可提取额为 0 时 revert `ZeroInput`；成功提取发出 `FeesSwept(reserveToken, to, amountOut)`；提取只减结余不减本金面（「赎回的 uAsset ⊆ 本实例铸出」流内口径），不触碰 `netUAssetMinted` 与 `stockCap` 口径；饱和（混合外部赎回）域内以「余额 − netUAssetMinted」公式为权威口径——`netUAssetMinted` 饱和到 0 后可提取额可超出历史差额口径费额，超出部分是不再背书任何本实例流通 uAsset 的本金沉淀，随费额一并可提取。只读口径为 `IPSM` `sweepableFees()` view（返回绑定储备最小单位计可提取额），与 mint/redeem 的 quote 只读口径成对。
- 参数与调整：`tin` = `tout` = 0.1% 为上线默认；`OutrunPSMUpgradeable.sol::setFees(uint256 tin_, uint256 tout_)` 为 owner-only 调整入口，边界 `0 ≤ fee ≤ 1%`，超出 revert `FeeOutOfRange`，成功发出 `SetFees`；无单次调幅限制。

## cap

cap 只约束存量，为单一参数口径（无单笔流量维度），owner 可调、恒须 > 0（setter 拒绝置零，PSM 不存在 cap 关闭态），初值部署期定：

- `stockCap`（存量 cap）：每个 (uAsset, reserve) 实例独立的净铸出（`netUAssetMinted` = 该实例累计 `reserveMint` 面值 − 累计 `reserveBurn` 面值，18-dec 口径，只覆盖本实例绑定储备）不得超过；redeem 回落净铸出即恢复 headroom（赎回量超过本地累计铸出时 `netUAssetMinted` 饱和到 0，不下溢 panic，外部 uAsset 赎回饱和语义保留，见「储备侧账务与 minter 豁免」）；stockCap 仅约束本实例净发行；在 `OutrunPSMUpgradeable.sol::mint` 侧校验（redeem 只减净铸出，不触发该约束），超限 revert `StockCapExceeded`；setter `OutrunPSMUpgradeable.sol::setStockCap` 成功发出 `SetStockCap`。

## 储备侧账务与 minter 豁免

PSM 所持储备由兑换流沉淀形成，无主动管理入口。前置条件：绑定储备为标准币（非 fee-on-transfer/非 rebasing，名义转账额=实收额），UUSD 两实例 USDC/USDT 与原生腿均满足该前提，与 `docs/spec/yield/yield-adapters.md` 背书对账守卫及 `docs/deployment.md` 投产前置校验同源；该前提下储备守恒式（spec 与测试锚点，按实例口径，绑定储备按面值折算后比较）成立：

`PSM 所持绑定 reserve 余额 × _faceValueScale（按面值折算，6-dec 储备×1e12，原生腿×1）== 该实例累计净流入面值 + 该实例未提取计费结余`

「累计净流入面值」为该实例绑定储备上净铸出 uAsset 的面值（累计 `reserveMint` 输出面值 − 累计 `reserveBurn` 面值，18-dec 口径），「未提取计费结余」为该实例上 `tin`/`tout` 沉淀费额扣除已 `sweepFees` 提取部分后的余额，按「费额 = 输入面值 − 用户所得额」的差额口径累计（含 floor 取整损耗），守恒式在向下取整口径下自洽；该等式在「赎回的 uAsset ⊆ 本实例铸出」流内精确成立（测试口径，见「外部赎回边界」）。伴随不等式：`绑定 reserve 面值 ≥ 本实例净铸出 uAsset 面值` 在标准币前提下全域成立（含混合外部赎回与饱和后状态；归纳可证：mint 输入面值 ≥ 铸出面值、redeem 付出面值 ≤ 烧毁面值且饱和不穿零、`sweepFees` 只提取「余额 − netUAssetMinted」的超出部分），提取后不等式仍成立、储备覆盖 ≥ 100% 净铸出不被破坏；流内口径下该提取即两侧之差的费额沉淀（只减结余不减本金面）。饱和（混合外部赎回）域内 `sweepFees` 的可提取额以「余额 − netUAssetMinted」公式为权威口径，可超出历史差额口径费额，超出部分是不再背书任何本实例流通 uAsset 的本金沉淀，随费额一并可提取。

minter 台账豁免：PSM 注册为 uAsset 储备 minter，铸/烧走储备背书路径，豁免 minter 债务台账——PSM 的 `mintingStatusTable` 记录保持全零，兑换不产生任何 minter 债务（参照 `OutrunOFTUpgradeable.sol::_credit`/`::_debit` 的豁免先例，豁免边界见 `docs/spec/common-foundations.md`「OFT 与 minter 债务豁免边界」）。

外部赎回边界：`OutrunPSMUpgradeable.sol::redeem` 无许可赎回任意来源的真实 uAsset（锚定属性，非仅限本实例铸出）；赎回量超过本地累计铸出时 `netUAssetMinted` 饱和到 0（不下溢 panic），stockCap 仅约束本实例净发行。储备付出的硬边界是本实例实际持有的绑定 reserve 余额，不足时 transfer 失败 revert。守恒式在「赎回的 uAsset ⊆ 本实例铸出」的流内精确成立（测试口径）；混合外部赎回流量下精确等式不再保证，退化为不等式 `绑定 reserve 面值 ≥ 本实例 netUAssetMinted`——该强式在标准币前提下全域可证（mint 输入面值 ≥ 铸出面值、redeem 付出面值 ≤ 烧毁面值且 `netUAssetMinted` 饱和不穿零、`sweepFees` 只提取超出 `netUAssetMinted` 的差额，经混合赎回与提取后均保持），加余额硬边界兜底与 `netUAssetMinted` 对账。

储备消耗监控与校准：PSM 无时间窗限流为有意设计（见「兑换与费率」单笔规模口径），绑定储备可在单块内被抽干；运营须持续监控各实例绑定 reserve 实际余额（主口径为绑定 reserve `balanceOf(psm)`，native 腿为合约 native 余额；`OutrunPSMUpgradeable.sol::sweepableFees` 为费额结余口径（非深度度量，常态近零），仅作对账辅助），深度枯竭按该实例回锚管道关闭事件告警处置。校准关系：实例初始储备规模与 `stockCap` 的设定须相对该 uAsset 的 CDP 债务存量与预期赎回/付息流评估——`OutrunPSMUpgradeable.sol::redeem` 经 `OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 收缩流通 uAsset，但储备枯竭关闭的是本实例 uAsset→reserve 面值出口（非借款人回锚管道的 redeem 腿，见「系统定位」与 `docs/ARCHITECTURE.md` §7）；借款人债赎管道（SP `redeem` SY 直出，oracle 无关）与 PSM mint 面值铸出（reserve 入账、不耗存量余额、受 stockCap headroom 约束）均不依赖储备余额，风险落在持有人面值退出关闭与折价无界加深；未来加息后付息流的容量要求见 `docs/spec/position/accounting.md` §6「加息前置校准」。

uAsset 储备铸烧路径（`OutrunUniversalAssetsUpgradeable.sol`，storage 追加于 ERC-7201 namespace `outrun.storage.OutrunUniversalAssets`，pre-deployment 允许布局重置）：

- `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter(address minter, bool status)`：owner-only，登记/撤销储备 minter；对零地址 revert `ZeroInput`；事件 `SetReserveMinter(address indexed minter, bool status)`。
- `OutrunUniversalAssetsUpgradeable.sol::reserveMint(address receiver, uint256 amount)`：仅已登记储备 minter 可调，`whenNotPaused`；不读/不写 `mintingCap` 与 `amountInMinted`（豁免语义，同 OFT 先例）；铸出到 receiver；对零输入（零 receiver / 零 amount）revert `ZeroInput`；未登记 caller revert `NotReserveMinter`；事件 `ReserveMintUAsset(address indexed minter, address indexed receiver, uint256 amount)`。
- `OutrunUniversalAssetsUpgradeable.sol::reserveBurn(address account, uint256 amount)`：仅已登记储备 minter，`whenNotPaused`；销毁 account 余额（account != msg.sender 时走 allowance），对零 account 或零 amount revert `ZeroInput`（与 `mint`/`repay` 同款守卫）；不触碰债务台账（不读/不写 `mintingCap` 与 `amountInMinted`）；未登记 caller revert `NotReserveMinter`；事件 `ReserveBurnUAsset(address indexed minter, uint256 amount)`。

与 `mintingStatusTable` 的正交性：储备铸烧路径与 minter 债务台账互不干预——`setMintingCap` 置零与 `revokeMinter` 不影响储备路径（两者只作用于债务台账口径的 mint），债务台账口径的 cap 校验（`ReachMintCap`）也不约束储备铸烧；储备路径的 kill switch 是 `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter(psm, false)`，撤销登记后 PSM 双向兑换 revert `NotReserveMinter`，fail-closed。

与 OFT 先例的对应关系：两条豁免路径同族——OFT（`OutrunOFTUpgradeable.sol::_credit`/`::_debit`）以 LayerZero 信任根背书跨链铸烧，储备铸烧路径以锁定储备 + 储备 minter 登记表背书本链铸烧；两者均不读/不写 `amountInMinted`/`mintingCap`，kill switch 各自独立（OFT 侧为 peer/信任根配置，PSM 侧为 `setReserveMinter` 撤销登记）。

## 暂停联动

PSM 自身不设 pause；uAsset 暂停（`OutrunUniversalAssetsUpgradeable` owner `pause`）经 `OutrunUniversalAssetsUpgradeable.sol::reserveMint` 与 `OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 的 `whenNotPaused` 同时阻断双向兑换：mint 在铸出步（`reserveMint`）revert、redeem 先在 uAsset 拉款步（`transferFrom` → `OutrunERC20PausableUpgradeable.sol::_update` `whenNotPaused`）revert，`reserveBurn` 为第二重 fail-closed 兜底，均无部分执行态。

## 零 oracle

PSM 全代码路径无任何 price feed / oracle 读取：兑换汇率为面值 1:1 结构性常数（硬编码、无 setter、禁接 oracle），不存在价格输入面。该性质由零 oracle 断言锁定：quote 与执行等价（dust 零输出域——quote 返 0 而执行 revert `ZeroInput`；超出 mint 侧 stockCap headroom 域——quote 恒正而执行 revert `StockCapExceeded`；超出 redeem 侧本实例实际持有的绑定 reserve 余额域——quote 恒正而付出失败 revert；见「零输出守卫」「cap」「外部赎回边界」节） + 对供给/兑换/时间的确定性，锁定执行路径无任何价格输入（见「测试与不变量」）。

## 错误与事件

PSM 侧（`OutrunPSMUpgradeable.sol`，声明见 `IPSM.sol`）：

- `OutrunPSMUpgradeable.sol::initialize` 对零 uAsset / 零 owner / 零 cap / 零 feeRecipient revert `ZeroInput`（`reserveToken == address(0)` 为合法 NATIVE 绑定，不触发该守卫；`initialize` 含 `reserveToken` 参数即现状）；绑定的 uAsset 非 18 decimals 时 revert `UAssetDecimalsMismatch(expected, actual)`；非 NATIVE 储备腿绑定时读取一次 `decimals()`，超过 18 revert `UAssetDecimalsMismatch(18, reserveDecimals)`（与 uAsset 腿共用错误名，触发条件为储备腿 decimals），非 ERC20 / 无代码储备在 `decimals()` 读取处 revert；费率超出 `0 ≤ fee ≤ 1%` 时 revert `FeeOutOfRange`
- `OutrunPSMUpgradeable.sol::mint` 在本笔后净铸出面值超过本实例 `stockCap` 时 revert `StockCapExceeded`
- `OutrunPSMUpgradeable.sol::mint` 对 `to == address(0)` 或 `amountIn == 0`、以及铸出额 floor 为 0 revert `ZeroInput`
- `OutrunPSMUpgradeable.sol::mint` 以 NATIVE 为储备时要求 `msg.value == amountIn`、储备为 ERC20 时要求 `msg.value == 0`，不一致时 revert `NativeAmountMismatch`（同 `TokenHelper.sol::_transferIn` 契约）
- `OutrunPSMUpgradeable.sol::redeem` 对 `to == address(0)` 或 `amountIn == 0`、以及付出额 floor 为 0 revert `ZeroInput`
- `OutrunPSMUpgradeable.sol::redeem` 的 native 付出低层 call 失败时 revert `NativeTransferFailed`（同 TokenHelper 契约，不静默吞失败）
- `OutrunPSMUpgradeable.sol::setFees` 在任一费率超出 `0 ≤ fee ≤ 1%` 时 revert `FeeOutOfRange`
- `OutrunPSMUpgradeable.sol::setStockCap` 拒绝置零（cap 恒 > 0），置零 revert `ZeroInput`
- `OutrunPSMUpgradeable.sol::sweepFees` 在当前计费结余（可提取额）为 0 时 revert `ZeroInput`；native 付出低层 call 失败时 revert `NativeTransferFailed`（同 TokenHelper 契约）。
- `OutrunPSMUpgradeable.sol::_authorizeUpgrade` 在绑定的 uAsset decimals 漂移时 revert `UAssetDecimalsMismatch`
- 绑定储备只读面（现状即单实例单储备）：`OutrunPSMUpgradeable.sol::reserveToken` 返回 immutable 绑定储备（`address(0)` 即 NATIVE）；兑换与 quote 失败仍 fail-closed（`decimals()` / 转账失败 revert），不设 decimals / fee-on-transfer 白名单
- 事件面：`SwapMintForUAsset(reserveToken, to, amountIn, amountOut, feeIn)` 由 `OutrunPSMUpgradeable.sol::mint` 成功时发出（`reserveToken` 为绑定储备）；`SwapRedeemForReserve(reserveToken, to, amountIn, amountOut, feeOut)` 由 `OutrunPSMUpgradeable.sol::redeem` 成功时发出；`SetFees` 由 `OutrunPSMUpgradeable.sol::setFees` 成功时发出（记录调整后费率）；`SetStockCap` 由 `OutrunPSMUpgradeable.sol::setStockCap` 成功时发出（记录调整后 cap 值）；`FeesSwept(reserveToken, to, amountOut)` 由 `OutrunPSMUpgradeable.sol::sweepFees` 成功提取时发出（`to` 为 immutable 绑定的 `feeRecipient`，`amountOut` 为绑定储备最小单位计的提取额）

uAsset 侧（储备铸烧路径，声明见 `IUniversalAssets.sol`）：

- `OutrunUniversalAssetsUpgradeable.sol::reserveMint` / `OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 对未登记储备 minter 的 caller revert `NotReserveMinter`
- `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter` 对零 minter 地址、`OutrunUniversalAssetsUpgradeable.sol::reserveMint` 对零 receiver 或零 amount、`OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 对零 account 或零 amount revert `ZeroInput`
- `OutrunUniversalAssetsUpgradeable.sol::reserveMint` / `OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 受 `whenNotPaused` 约束，uAsset 暂停期 revert（fail-closed）
- 事件面：`SetReserveMinter(address indexed minter, bool status)` 由 `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter` 登记/撤销时发出；`ReserveMintUAsset(address indexed minter, address indexed receiver, uint256 amount)` 由 `OutrunUniversalAssetsUpgradeable.sol::reserveMint` 铸出成功时发出，并伴随 ERC20 `Transfer`（零地址到 receiver）；`ReserveBurnUAsset(address indexed minter, uint256 amount)` 由 `OutrunUniversalAssetsUpgradeable.sol::reserveBurn` 销毁成功时发出，并伴随 ERC20 `Transfer`（account 到零地址）；三事件均不改 `mintingStatusTable`，也不发 `MintUAsset`/`BurnUAsset`

## 测试与不变量

T1 验收清单：

1. 双向兑换 roundtrip：mint → redeem 面值往返（费率按口径计入）；6-dec reserve → 18-dec 放大与 native 18→18 恒等两档折算均覆盖。
2. 费率：`tin` 作用于 mint 侧铸出额、`tout` 作用于 redeem 侧付出额的数值断言；`OutrunPSMUpgradeable.sol::setFees` 边界值 0 与 1% 可设、超界 revert `FeeOutOfRange`；费额沉淀 PSM，唯一流出口为 `sweepFees`。
3. cap 限流：`stockCap` 净铸出超限 revert `StockCapExceeded`；cap setter 拒绝置零。
4. 储备 == 净铸出面值守恒：按实例口径断言守恒式（「赎回的 uAsset ⊆ 本实例铸出」流内口径，含 sweep 后「净铸出面值 + 未提取计费结余」口径），并断言不等式 `绑定 reserve 面值 ≥ 本实例净铸出 uAsset 面值`（标准币前提下全域口径——含混合外部赎回与饱和后状态，sweep 后仍成立）。
5. PSM minter 台账豁免：兑换全程 PSM 的 `mintingStatusTable` 记录保持全零；`revokeMinter` / `setMintingCap` 置零不影响储备路径；`OutrunUniversalAssetsUpgradeable.sol::setReserveMinter(psm, false)` 后双向兑换 revert `NotReserveMinter`（kill switch fail-closed）；`transferMinterDebt` 禁止以储备 minter 为迁入目标（revert `InvalidTransferParams`），该台账永不经债务迁移写入。
6. 零 oracle 断言（quote 与执行等价 + 对供给/兑换/时间的确定性，锁定执行路径无任何价格输入）：等价面 `testFuzz_QuoteMatchesExecutionForBoundedAmounts`（quoteMint == mint 返回值、quoteRedeem == redeem 返回值，dust 零输出域除外——quote 返 0 而执行 revert `ZeroInput`，见「零输出守卫」；测试 bound 下界已排除该域，上界取 stock cap 值——mint 侧 fuzz 量恒在 headroom 域内（测试自行把 mint 侧断言域限定在 headroom 内；redeem 侧赎回量为刚铸出量、付出由同笔拉入的储备覆盖，结构性处于持有余额域内））；确定性面 `test_ZeroOracleQuoteDeterminismAgainstSupplySwapsAndTime`（totalSupply 变化、他人兑换、时间/块高漂移下 quote 恒定）。
7. 计费结余提取：费额沉淀可经无许可 `OutrunPSMUpgradeable.sol::sweepFees` 提取至 immutable `feeRecipient`（任何人可调），提取额 = 结余面值 floor 到绑定储备最小单位、发出 `FeesSwept`；提取后守恒式与新口径仍成立；结余为 0 时 revert `ZeroInput`。
