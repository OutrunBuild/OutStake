# USR 储蓄金库规格

> 状态：现行真值，随 T3 合约变更一并落地（新增 `src/usr/OutrunUSRVaultUpgradeable.sol` 与 `src/usr/interfaces/IUSRVault.sol`）。本文为该批合约的行为规格与验收基准；激活时点、注资规模、利率纪律与监控阈值不属本文范围，本文只落接口与结构性约束。

## vault 定位与三族

USR 是 uAsset 持有人的储蓄层，与 CDP（position 层）、PSM 锚定兑换路径解耦：uAsset 持有人把 uAsset 存入所属族的 ERC4626 vault 换取 suToken 份额，份额价格按治理设定的族利率按秒增长（timestamp 锚定），随存随取；vault 不承担借贷、清算或跨链职能。

- 合约面：`src/usr/OutrunUSRVaultUpgradeable.sol`（UUPS upgradeable，storage 于 ERC-7201 namespace `outrun.storage.OutrunUSRVault`，pre-deployment 允许布局重置）与接口 `src/usr/interfaces/IUSRVault.sol`（错误与事件声明面）。
- 实例粒度：每个 uAsset 族一个 vault 实例——suETH（资产 UETH）/ suUSD（资产 UUSD）/ suBNB（资产 UBNB）；share 即该族 suToken，对外为 18-dec ERC20。
- 部署绑定：部署期（`ERC1967Proxy` initialize）绑定该族 uAsset 资产地址与 suToken name/symbol——均为 immutable-style init 参数，init 后无 setter、不可变更。`initialize` 边界：asset 零地址、name/symbol 空值均 revert `ZeroInput`；非 18-dec 资产 revert `UAssetDecimalsMismatch`。计息换算常数为合约内部常数 `SECONDS_PER_YEAR = 31_536_000`（365 天口径的年秒数）——非 init 参数、无 per-chain 定值，部署面无计息参数核定项；该常数为 vault 合约内部专属，`OutrunStakingPositionUpgradeable` 合约内无此常数（其 `duty` 为 RAY 1e27 域每秒率，年化换算仅存在于治理侧链下换算式、与其共用同一 365 天口径）。锚定动机：timestamp 计息使速率语义为纯日历时间，与链出块基础设施解耦——多链部署（各链出块节奏不同且随链加速漂移）不携带任何会过期的年均块数换算假设，跨链利率口径一致；`block.timestamp` 受共识约束（单调不减、偏斜有界），对储蓄利率的偏斜攻击面可忽略（行业先例：按秒累计的利率指数自 2019 年起长期运行）。
- 部署布线：USR vault 不是 uAsset 的 minter 或储备 minter，无需任何 uAsset 侧登记；owner 计息注资唯一入口是 `OutrunUSRVaultUpgradeable.sol::fund`，利息预算由余额超出份额负债的部分支撑（成因：`fund` 注资与不可回收的误转/捐赠沉淀）。
- 继承面：OZ `ERC4626Upgradeable` + `OwnableUpgradeable` + UUPS；资金面入口一律 `nonReentrant`（transient guard，经 `TokenHelper` 的 `ReentrancyGuardTransient`，同仓库惯例）。

## 计息模型

族利率 `usrRate` 为 18-dec 年化点值（10% = `1e17`、50bp = `5e15`、`0` = 未激活），按秒记账（计息锚为 `block.timestamp`，换算常数 `SECONDS_PER_YEAR = 31_536_000`，365 天口径）：`usrRate` 为名义年化，每秒复合使有效年化 = `(1 + usrRate / SECONDS_PER_YEAR)^SECONDS_PER_YEAR − 1`，略高于名义（上限 `1e17` 时约 10.52%）。

- 价格指数：`accrualIndex` 为 1e18 域的每份额价格指数，初始 `1e18`（面值 1:1）；每秒增长因子 `f = 1e18 + usrRate / SECONDS_PER_YEAR`（整数除法向下取整）。`usrRate == 0` 时 `f == 1e18`，指数不动（未激活态）。
- 外推算法：外推 = 平方求幂——对每秒因子 `f`，以 exponentiation-by-squaring 计算 `f^Δseconds`，每次乘法经 `mulDiv(x, y, 1e18)` 即时约减；确定性、O(log Δ)、无全精度中间值。取整只发生在两处：每秒因子计算的整除向下取整、每步幂乘法的即时约减，此外无其他取整来源。遍历序与合成式钉死：自 Δseconds 的最高有效位起：r = f；逐位 r = mulDiv(r, r, 1e18)，该位为 1 时再 r = mulDiv(r, f, 1e18)；Δseconds == 0 时 r = 1e18；f == 1e18（仅未激活零率；非零低于分辨率值已被 `setUsrRate` 拒绝）时 r = 1e18——恒等因子短路，不进入幂循环；最终外推值 = mulDiv(accrualIndex, r, 1e18)（该次乘法同属每步约减口径）；测试以该算式为独立参考实现（时间经 warp 推进）。外推因子有确定性饱和上界 `MAX_INDEX_FACTOR = 1e36`（指数至多 1e18 倍增长）：平方求幂中间值 r 超过该值时取该值；饱和点远超任何真实预算域（封顶 = 余额 × 1e18 / totalSupply 才是实际约束），该上界仅消除 uint256 溢出 revert 路径（长期零结算 + 速率接近上限段的大 Δseconds 外推下 mulDiv 溢出将导致六入口与 preview 永久 revert 的不可逆锁仓），保持确定性与单调性。preview 与状态结算共用同一外推投影（同状态同输出——状态含当期余额与真实供给，含下节封顶钳制），preview 只读不写、不推进结算账。
- 惰性结算：指数与结算基线只在状态变更入口推进——`OutrunUSRVaultUpgradeable.sol::deposit` / `::mint` / `::withdraw` / `::redeem` / `::fund` / `::setUsrRate` 均先把 `accrualIndex` 按当前 `usrRate` 结算到当前 `block.timestamp`（并前移 `lastSettledAt`）、再执行本体变更；`setUsrRate` 因此只能前瞻生效（此前未结算时间按旧率结算）。同秒内多次结算幂等（`Δseconds == 0`，指数不变）。
- 换算口径：`OutrunUSRVaultUpgradeable.sol::_convertToShares` 覆写为 `shares = assets × 1e18 / accrualIndex`、`OutrunUSRVaultUpgradeable.sol::_convertToAssets` 覆写为 `assets = shares × accrualIndex / 1e18`（两式中的 `accrualIndex` 均为当期有效指数（外推投影）口径，非 `accrualIndex()` 已结算存储值）——换算公式本身不引用 `totalAssets()` / `totalSupply()`（分母为当期有效指数（外推投影），封顶钳制时经投影消费当期余额与真实供给，见「捐赠攻击缓解」）；基础方向向下取整（floor），各入口取整方向沿用 ERC4626/OZ 标准（previewDeposit/previewRedeem 向下、previewMint/previewWithdraw 向上）。`OutrunUSRVaultUpgradeable.sol::totalAssets` 沿用 OZ 默认语义（实际 uAsset 余额，含注资与捐赠沉淀），仅作信息视图，换算与 preview 不消费。
- 视图口径：`OutrunUSRVaultUpgradeable.sol::convertToAssets` / `::convertToShares` / preview 族视图对当前 `block.timestamp` 外推（同一外推投影，受同一封顶钳制）；同秒内（同一 timestamp）且 vault 状态无变更时 preview 与执行一致；封顶钳制域内同秒插入对 vault 的直接转入即时改变 preview 有效价（抬升以未结算外推差幅为限，Δ=0 即已结算于本秒时为零）；`fund` 注资因结算前置同秒投影值不变、注入自下一秒起进入有效价（见「捐赠攻击缓解」）。计息结算账视图族仅两项：`accrualIndex()`（已结算存储值）与 `lastSettledAt()`（最近结算 timestamp）；另有 `usrRate()` 利率参数视图（返回当期族利率，18-dec 点值，`0` = 未激活）；`SECONDS_PER_YEAR` 为内部常数，无换算常数视图。

## 硬预算 fail-safe（余额封顶）

计息预算的硬约束：vault 仅以实际持有的 uAsset 余额计息，禁止任何 mint 计息。

- 封顶规则（结算钳制）：每份额价格 `accrualIndex` 的增长不得越过封顶——`实际 uAsset 余额 × 1e18 / totalSupply()`（真实流通份额）。结算取 `accrualIndex ← max(当前值, min(外推值, 封顶))`，指数单调不降。
- 两种停摆态：
  - 零余额（未注资态）：实际 uAsset 余额为 0 时封顶为 0，指数维持当前值（未注资未增长即初始 `1e18`）。
  - 零供给（挂起态）：`totalSupply() == 0`（无真实份额在外）时计息挂起——结算仅前移 `lastSettledAt`、指数不增长；首笔存款按当前指数定价（未增长即 `1e18`），挂起期间推进的时间不追溯补记，`fund` 已注入的预算不受消耗。该挂起同时消除封顶分母的除零边沿。preview 同口径。
- 暂停语义：外推超封顶时指数停在封顶值（当期计息部分兑现），其后外推持续超封顶、计息自动暂停；暂停只停计息，不关存取——`deposit`/`mint`/`withdraw`/`redeem` 在暂停态仍按当前指数可用。
- 恢复：封顶在每次结算时以当期余额与真实份额重算，注资（`fund`，余额升、份额不变）或份额变动后按新封顶重估、恢复增长；真实负债已等于余额的耗尽态下，恢复计息的实质路径是 `fund` 注资。
- 偿付不变量（跨全路径、测试锚点）：真实份额负债 `totalSupply() × accrualIndex / 1e18 ≤ 实际 uAsset 余额`——任何路径不得铸造资产、不得使负债超过实际持有余额；owner 计息注资唯一入口是 `OutrunUSRVaultUpgradeable.sol::fund`，利息预算由余额超出份额负债的部分支撑（成因：`fund` 注资与不可回收的误转/捐赠沉淀）。

## 无回收保证

- 无 admin sweep、无 rescue、无提取面：owner 资金面入口只有 `fund`，且只进不出。
- 入池资金仅存款人可经 ERC4626 提款取出：`withdraw`/`redeem` 按份额与当前指数结算付出额，付出额以实际持有余额为硬边界。
- 误转入 vault 的 uAsset（直接 transfer 的捐赠/误转）不产生任何份额、无救援路径，只能沉淀为余额超出份额负债的部分、抬高封顶余量，经后续计息（外推不超封顶域）或下一次结算即时（封顶钳制域）按份额比例社会化给既有份额持有人——属捐赠人向持有人的单向财富转移、无受害方，接受（价值口径见「捐赠攻击缓解」：存后每份额背书不低于成交指数）。

## 激活接口与参数边界

owner 入口白名单仅两项（加 UUPS 授权），除此之外无任何 owner 资金面或参数面入口：

- `OutrunUSRVaultUpgradeable.sol::fund(uint256 amount)`：owner-only，经 owner 对 vault 的 uAsset approve 拉入 `amount` 真实 uAsset，无份额铸造（只进不出）；`amount == 0` revert `ZeroInput`；成功发出 `UsrFunded(uint256 amount)`；结算前置（先结算指数再入账）。
- `OutrunUSRVaultUpgradeable.sol::setUsrRate(uint256 newRate)`：owner-only，校验 `newRate ≤ 1e17`（绝对上限 10%，上限内任意值一笔可达）；违反 revert `UsrRateTooHigh`；非零值另设分辨率下限：`newRate == 0` 合法（关闭 accrual）；`0 < newRate < SECONDS_PER_YEAR`（`SECONDS_PER_YEAR = 31_536_000`）revert `UsrRateBelowResolution`；`newRate ≥ SECONDS_PER_YEAR` 正常；上限 `1e17` 不变。下限理由：低于该值每秒增量 `newRate / SECONDS_PER_YEAR` 截断为 0，每秒因子恒 `1e18`，指数不动，存款零收益但费率读数非零——下限防此类静默冻指。成功发出 `UsrRateSet(uint256 oldRate, uint256 newRate)`；结算前置（未结算时间段按旧率结算，新率前瞻生效）。上线默认 `usrRate = 0`（未激活）。
- `OutrunUSRVaultUpgradeable.sol::_authorizeUpgrade`：owner-only UUPS 授权。

公开面：标准 ERC4626 无许可入口 `deposit`/`mint`/`withdraw`/`redeem` 与 `preview*`/`max*`/`convertTo*`/`totalAssets`/`asset` 视图，均按当前 `block.timestamp` 外推（受同一封顶钳制），入口 `nonReentrant`。

## 捐赠攻击缓解

结构性免疫（限于外推不超封顶域）：份额计数只依赖 `accrualIndex`——换算公式本身不调用 `totalAssets()` / `totalSupply()`，但计息指数投影在封顶钳制时消费实际余额与真实供给（`OutrunUSRVaultUpgradeable.sol::_projectedIndex`），价格输入面在封顶钳制域经封顶存在。外推值不超封顶（`projected ≤ cap`，funded 域）时 `min(外推值, 封顶)` 恒取外推值、与实际余额无关——该域内攻击者向 vault 直接转入 uAsset 不改变指数，后续存款人定价不受 `totalAssets` 操纵影响，经典捐赠/通胀攻击（先捐后存使受害者铸份额取整受损）在该域内无价格输入面。残余路径：捐赠抬高实际余额 → 抬高封顶 → 抬高计息预算，其价值在外推不超封顶域经后续计息、在封顶钳制域于下一次结算即时，按份额比例社会化给既有持有人——属捐赠人向持有人的单向财富转移、无受害方，写明接受。cap-binding 耦合（外推超封顶域，含预算耗尽钉死稳态与瞬态）：封顶即有效价格约束，直接转入即时抬高封顶、从而抬高下一次结算与 preview 族视图的有效价格，抬升上限为未结算外推差幅；以转入前 preview 报价的存款人存在报价-执行份额偏差——`deposit` 少收份额、`mint` 同份额多付资产；偏差由转入本身全额背书：存后每份额背书不低于成交指数，即时赎回按成交指数取回存入资产，至多差两次换算 floor（铸份额侧 + 赎回侧，< 成交指数/1e18 + 1 wei 资产，dust 级存款份额可 floor 为 0）——价值中性、无价值抽取方（转入价值按份额比例社会化给既有持有人，转入方承担全部成本）；`withdraw`/`redeem` 侧指数单调不降、赎回人单边受益。集成指引：标准 ERC4626 入口无滑点参数，任何对外暴露 USR 存款的入口（router/前端/聚合器）应以执行时份额/资产下限复核为接入前置。vault 不使用 `_decimalsOffset` 虚拟份额（换算已整体覆写，offset 无消费方）；`decimals()` 由 OZ 默认派生（资产 18-dec + offset 0 = 18），suToken 对外即 18-dec ERC20。

## 暂停联动（无自有 pause）

vault 自身不设 pause（owner 面无 `pause`/`unpause`）；uAsset 自身暂停（`OutrunUniversalAssetsUpgradeable` owner `pause`）经资产转账传导为 fail-closed：`deposit`/`mint` 在资产转入步 revert、`withdraw`/`redeem` 在资产付出步 revert、`fund` 在拉入步 revert，整笔原子回滚，无部分执行态。计息指数无另设暂停需求：封顶 fail-safe 已是计息侧的自动停摆机制。

## 错误与事件

错误（声明见 `IUSRVault.sol`，沿用仓库具名错误惯例）：

- `OutrunUSRVaultUpgradeable.sol::initialize`（经 `ERC1967Proxy`）对 asset 零地址、name/symbol 空值 revert `ZeroInput`；对非 18-dec 资产 revert `UAssetDecimalsMismatch`
- `OutrunUSRVaultUpgradeable.sol::setUsrRate` 在 `newRate > 1e17` 时 revert `UsrRateTooHigh`；在 `0 < newRate < SECONDS_PER_YEAR` 时 revert `UsrRateBelowResolution`
- `OutrunUSRVaultUpgradeable.sol::fund` 对 `amount == 0` revert `ZeroInput`
- ERC4626/ERC20 标准校验（零地址、余额与 allowance 不足等）沿用 OZ 语义

事件：

- `UsrFunded(uint256 amount)`：`OutrunUSRVaultUpgradeable.sol::fund` 成功时发出
- `UsrRateSet(uint256 oldRate, uint256 newRate)`：`OutrunUSRVaultUpgradeable.sol::setUsrRate` 成功时发出
- `AccrualIndexSettled(uint256 oldIndex, uint256 newIndex)`：`OutrunUSRVaultUpgradeable.sol::_settleIndex` 在指数实际变化时发出（投影值等于已结算存储值时不发（含同秒/零供给/零余额/零费率/封顶钉死））。
- ERC20 `Transfer`/`Approval` 与 ERC4626 `Deposit`/`Withdraw` 标准事件沿用 OZ 语义

## 测试与不变量验收清单

T3 验收清单：

1. 存取计息 roundtrip：多时间段存取下指数增长精确断言（时间经 warp 推进；含 `setUsrRate` 变更段前瞻生效、同秒（同一 timestamp）多次操作幂等、`usrRate == 0` 段指数不动）。
2. 停摆与恢复：外推超封顶时指数停在封顶、后续时间不再增长，期间存取仍按当前指数可用；`fund` 注资后按新封顶恢复增长。零供给挂起态：`totalSupply() == 0` 期间指数不增长、`lastSettledAt` 前移，恢复供给后不追溯补记。
3. 无回收入口断言：owner 无法经任何入口取回非份额对应资产（`fund` 只进不出，无 sweep/rescue/pause 面）；误转资产无救援路径。
4. 捐赠缓解：直接 transfer uAsset 进 vault（首笔存款前或既有持仓期）不产生份额；外推不超封顶（funded）域内不改变指数与换算价；封顶钳制（cap-binding）域断言：直接转入抬升下一次结算指数与 preview（上限为未结算外推差幅），以转入前 preview 报价的 `deposit`/`mint` 存在报价-执行份额偏差、由转入全额背书（存后每份额背书不低于成交指数，即时赎回按成交指数取回存入资产，至多差两次换算 floor（铸份额侧 + 赎回侧，< 成交指数/1e18 + 1 wei 资产，dust 级存款份额可 floor 为 0））；其价值仅抬高封顶余量、按份额比例社会化（无受害方，接受口径）；捐赠者与 owner 均无取回路径。新增测试向量（落点 `test/usr/OutrunUSRVault.t.sol`）：瞬态封顶钳制捐赠-价格耦合向量、`mint()` 报价偏差向量。
5. 参数与 init 边界：`newRate > 1e17` revert `UsrRateTooHigh`；`newRate == 0` 合法（关闭 accrual，可设）；`0 < newRate < SECONDS_PER_YEAR` revert 分辨率下限错误；`newRate == SECONDS_PER_YEAR` 为非零最小可设值；上限内任意值（含 `0↔1e17` 直接往返）一笔可设，边界值恰 `1e17` 可设；上线默认 0；`initialize` 对 asset 零地址、空 name/symbol revert `ZeroInput`；`initialize` 对非 18-dec 资产 revert `UAssetDecimalsMismatch`。
6. preview 与执行一致性：以同秒内 vault 状态无变更为前提——同秒（同一 timestamp）`previewDeposit`/`previewMint`/`previewWithdraw`/`previewRedeem` 与执行一致（含封顶钳制态与计息暂停态）；同秒内插入直接转入、`fund` 注资（状态变更：结算前置，同秒投影值不变，注入自下一秒起进入有效价）或 `setUsrRate`（状态变更：速率写入，新率自下一秒进入外推，同秒投影值不变）即例外；他人 `deposit`/`withdraw`/`mint`/`redeem` 按当期有效价 pro-rata 结算，不改变有效价、不构成例外。新增测试向量（落点 `test/usr/OutrunUSRVault.t.sol`）：同秒 `fund` 注资不动 preview 的钉死向量。
7. 不变量断言（跨全部用例）：真实份额负债 `totalSupply() × accrualIndex / 1e18 ≤ 实际 uAsset 余额`；`accrualIndex` 单调不降且增长不越封顶；`fund` 不铸份额（事件与供给断言）。
