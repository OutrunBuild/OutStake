# OutStake Router And User Flows

> 状态：现行行为规格，已落地（genesis 双路径三入口：路径 A 维持 router 侧 PSM 门 `genesisByPSM` 与 `psmForUAsset` registry；路径 B（CDP 门）为薄转发便利层——`genesisByToken`（token 计价正门）/ `genesisBySY` 转发至 SP 原生物理门 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（v1 唯一铸造入口、面值/价值平价铸出），全额消费断言为 SP 侧原生）。自由质押路径（`stakeFromToken`/`stakeFromSY`）随 v1 genesis-only 决策删除（pre-deployment ABI break 免费，禁用 flag 方案否决——不留死代码）。另有双门之外的杠杆创世门 `OutrunRouter.sol::leveragedGenesisByPSM`（reserve 经 PSM 面值铸 uAsset 后全额作为利息交 Memeverse 侧 POLend 杠杆创世），独立成节见「杠杆创世门」。position 侧语义真源为 `docs/spec/position/accounting.md`，PSM 侧为 `docs/spec/psm/peg-stability-module.md`。

> 现状：单实例单储备已落地（四实例 + (uAsset, reserveToken) 配对绑定），详见下文各节。

## 1. 文档目的

本文档整理 `OutrunRouter` 与 `OutrunStakingPositionUpgradeable`、`OutrunPSMUpgradeable` 的用户流程：token / native 与 `SY` 的双向兑换、genesis 双路径（PSM 门 / CDP 门）、双门之外的杠杆创世门（`OutrunRouter.sol::leveragedGenesisByPSM`，见「杠杆创世门」节）与 preview 语义。本文只记录本地代码和现有测试能直接证明的行为（目标态部分以各模块 spec 为准），并记录 router 与 proxy-backed products 的边界；涉及 mixed-decimals 双段换算与 rounding 的条目均为既定行为，按实现语义直接描述。

## 1.1 Upgradeable readiness

当前 upgradeable product surface 不把 `OutrunRouter` 部署为 proxy：

- router 仍是非 upgradeable、可重部署 helper。
- router 业务入口经用户传入的独立 `SY` 地址、`SP` 地址（从 `SP.SY()` 派生 canonical `SY`）或按 `(uAsset, reserveToken)` 配对查表的 PSM 地址调用下游，但目标必须先由 owner 注册。
- 下游 product address 可以是 `ERC1967Proxy` 地址：uAsset proxy、SY proxy、staking position proxy、PSM proxy。
- router 本身不持有 core accounting state；切换 router 需要用户/集成侧重新授权或改用新入口，但不迁移 position、uAsset debt、SY share 或 PSM 储备状态。
- router 不获得 upgrade admin、timelock、pause 或 oracle 管理能力；owner 只维护 router 的 SY 白名单、SP -> SY 配对登记、(uAsset, reserveToken) -> PSM 配对登记以及脱困回收 `sweep`（`OutrunRouter.sol::sweep`，`onlyOwner nonReentrant`，无背书资产故无 blocklist，瞬态余额上限约单笔交易量，见 §1.2/§7.6）—— 均为持续 live 的动态注册表能力，由 `Ownable` 持有、产品外经 multisig 治理（产品合约内不设 `TimelockController`）。launcher 布线不在该 live 集合内：`OutrunRouter.sol::memeverseLauncher` 生产冻结为 immutable（仅经 constructor 布线，换 launcher 即重部署 router），`OutrunRouter.sol::setMemeverseLauncher` 仅部署/测试期可变（见 §7.4）。

### 1.2 Router target registry

- `OutrunRouter.sol::setTrustedSY(SY, trusted)` 由 owner 管理 SY 白名单；启用时不做链上代码校验（allowlisting 为 owner 治理职责，EOA 配错不再链上回退），禁用会立即阻止后续 router 调用。
- `OutrunRouter.sol::setTrustedSP(SP, SY)` 由 owner 登记 SP 的 canonical SY 配对；非零 `SY` 必须已在白名单中，且必须等于 `SP.SY()`。
- `SY == address(0)` 是 NATIVE sentinel，不能作为 trusted SY；`SP == address(0)` 也不能登记。配置成功后可通过 `OutrunRouter.sol::trustedSY`、`OutrunRouter.sol::trustedSYForSP` 读取当前值，并核对 `IOutrunRouter.sol::TrustedSYUpdated` / `IOutrunRouter.sol::TrustedSPUpdated` 事件。
- 仅登记白名单 SY 的入口 `mintSYFromToken(...)`、`redeemSyToToken(...)` 可继续执行；所有从 SP 派生 SY 的 preview 与路径 B genesis 入口都要求已登记且匹配的 SP -> SY 配对。路径 A genesis（PSM 门）不触 SY/SP，走 §1.2.1 的 PSM registry。
- 校验在任何用户资产转移或精确 approve 前执行；未登记目标回退 `UntrustedRouterTarget(address)`，SP 与登记 SY 不匹配回退 `RouterTargetMismatch(address,address,address)`。
- 每次 SP 路径都会重新读取 `SP.SY()` 与登记值比较；即使 pair 曾经登记成功，canonical SY 发生漂移也会在拉取或 approve 前回退。
- `OutrunRouter.sol::setTrustedSP(SP, address(0))` 用于撤销配对；`OutrunRouter.sol::setTrustedSY(SY, false)` 只撤销 SY 信任，不会自动清零已有的 SP mapping，但后续调用会因 SY 不再 trusted 而失败，因此应显式撤销 pair 并核对 getter / event。
- 撤销 SY 或配对只影响后续 router 入口，已完成的 position、uAsset debt 和 SY share state 不受影响。
- `OutrunRouter.sol::sweep(token,to,amount)` 为 owner-only 脱困回收，`onlyOwner nonReentrant`，零地址回退 `SweepZeroAddress`、零额回退 `SweepZeroAmount`，经 `TokenHelper._transferOut` 支持 `NATIVE` sentinel（`address(0)`）的 ERC20/native 转出并发 `Sweep(token,to,amount)` 事件；无 yield-token/SY-share blocklist 为有意设计——路由器本身不托管背书资产，除单笔交易内 `_mintSY` / SY 拉款到 `SP.stakeForGenesis` 消费之间的瞬态 SY 余额，以及 genesis 路径 A 中 `IPSM.mint` 向 router 铸 `uAsset` 到 launcher `transferFrom` 拉取之间的瞬态 `uAsset` 余额（上界约单笔交易量，非全池；路径 B 薄转发下 router 不持有瞬态 `uAsset`）外，router 还可能持有第三方直接转入的无背书 token/`uAsset` dust（ERC20 transfer 无准入限制）；此类 dust 不进入 genesis 后置断言域（断言以本次交易铸出前快照为基线，见 §7.3），由 owner 经 `OutrunRouter.sol::sweep` 回收；该能力随注册表持续 live，由 `Ownable`（产品外 multisig）管控，不随主网上线移除。
- router 的 6 个用户状态变更入口（`mintSYFromToken`/`redeemSyToToken`/`genesisByPSM`/`genesisByToken`/`genesisBySY`/`leveragedGenesisByPSM`）均挂 `nonReentrant`（transient guard，经 `TokenHelper` 继承 `ReentrancyGuardTransient`）：在 `_transferIn` 拉款回调、`SY.deposit`、`IPSM.mint`、`SP.stakeForGenesis`、`launcher.genesis`（A 门 router 直调；B 门该调用发生在 SP 内部）、`polend.leveragedGenesis`（杠杆创世门）等外部调用窗口内，对 router 任一入口的重入以 `ReentrancyGuardReentrantCall` 回退。该防护与 SY/SP/PSM 侧各自的 `nonReentrant` 相互独立（transient slot 按合约实例隔离），与 `OutrunRouter.sol::sweep` 的 guard 同源；router 入口自身的原子性仍由 EVM 同交易回滚语义保证，guard 提供的是重入隔离而非原子性。
- 当前 registry setter 与 `sweep` 为持续 live 的动态注册表能力：部署后先注册首批 SY/SP/PSM 并核对 getter/事件，后续运行期仍可经 `OutrunRouter.sol::setTrustedSY`/`setTrustedSP`/`setPsmForUAsset`/`sweep` 动态新增、撤销或救援，均由 `Ownable`（产品外 multisig）管控，产品合约内不设 `TimelockController`；`OutrunRouter.sol::setMemeverseLauncher` 不在该 live 集合内——生产 launcher 冻结为 immutable（仅经 constructor 布线，换 launcher 即重部署 router），该 setter 仅部署/测试期可变（见 §7.4）；治理与监控见 `docs/spec/access-control.md`。
- `OutrunRouter.sol::polend` 为 Memeverse 侧 POLend（杠杆创世）合约地址登记，配置模式镜像 launcher：`OutrunRouter.sol::setPolend(polend)` 为 owner-only setter（部署/测试期 live），不做零地址与链上代码校验（allowlisting 为 owner 治理职责，EOA 配错不在配置期回退，失败留待使用期 fail-closed），成功时发出 `IOutrunRouter.sol::SetPolend(oldPolend, newPolend)` 事件并经 `OutrunRouter.sol::polend` 读取核对；运行期 fail-closed——`polend == address(0)` 时杠杆创世门以 `IOutrunRouter.sol::PolendNotSet()` 回退（见「杠杆创世门」节）。生产冻结为 immutable、仅经 constructor 布线（换 POLend 即重部署 router），生产删除该 setter（`OutrunTODO` 标记约定）；`OutrunRouter.sol::setMemeverseLauncher` 同批补同款 `OutrunTODO` 标记（行为不变，见 §7.4）。

#### 1.2.1 PSM registry（路径 A 配对寻址，现状即配对三参登记）

- `OutrunRouter.sol::setPsmForUAsset(uAsset, reserveToken, psm)` 由 owner 按 (uAsset, reserveToken) 配对登记 PSM，供路径 A genesis 寻址（现状即配对三参登记）；撤销传 `psm == address(0)`（只阻断该配对）。
- 登记校验（对齐 `setTrustedSP` 风格，全部在写入前执行）：
  - `uAsset == address(0)` 拒绝（回退 `UntrustedRouterTarget(address(0))`）。
  - 非零 `psm` 不做显式链上代码门校验（移除的显式门不再回退，allowlisting 为 owner 治理职责），但必须同时满足双绑定：`IPSM(psm).uAsset() == uAsset` 且 `IPSM(psm).reserveToken() == reserveToken`——对无代码地址任一绑定读取本身以底层调用/解码错误回退（非绑定 mismatch 错误）；uAsset 绑定不一致回退 `IOutrunRouter.sol::PsmBindingMismatch(psm, uAsset, actualUAsset)`（镜像 `RouterTargetMismatch` 的三方载荷形态），储备绑定不一致回退 `PsmReserveMismatch(psm, reserveToken, actualReserveToken)`（与 `PsmBindingMismatch(psm, uAsset, actualUAsset)` 三方载荷风格对称）。
  - 信任边界：`IPSM` 暴露 `uAsset()` 与 `reserveToken()` getter（现状），且两绑定在 `OutrunPSMUpgradeable.sol::initialize` 后均无 setter（namespaced storage 跨升级存活），登记期一致性检查因此是稳定的；router 不校验 PSM 的费率——那些由 PSM 侧自身入口校验（`docs/spec/psm/peg-stability-module.md`）。
- 配置成功后可通过 `OutrunRouter.sol::psmForUAsset(uAsset, reserveToken)` 读取当前值（现状即配对读取），并核对 `IOutrunRouter.sol::PsmForUAssetUpdated(address indexed uAsset, address indexed reserveToken, address indexed psm)` 事件。
- 运行期（`OutrunRouter.sol::genesisByPSM`）：签名不变，按配对查表——查表为零回退具名错误 `IOutrunRouter.sol::UnregisteredPsm(uAsset, reserveToken)`；且对齐 SP 路径的复读风格，每次调用重读 `IPSM(psm).uAsset()` 与 `IPSM(psm).reserveToken()` 同登记 key 双比对，任一漂移回退对应绑定 mismatch 错误（`PsmBindingMismatch(psm, uAsset, actualUAsset)` / `PsmReserveMismatch(psm, reserveToken, actualReserveToken)`；成本两次 staticcall；绑定虽不可变，复读使两类 registry 的防漂移语义一致；对无代码地址的复读以底层调用/解码错误回退，非绑定 mismatch 错误）。
- 撤销 `setPsmForUAsset(uAsset, reserveToken, address(0))` 只影响该配对后续 `genesisByPSM` 调用，不回滚已完成的兑换或 genesis 流，不影响其它配对。
- 该 registry 不影响 SY/SP 白名单语义；路径 A 不读取 `trustedSY`/`trustedSYForSP`。

## 2. token / native -> SY

`mintSYFromToken(SY, tokenIn, receiver, amountInput, minSyOut)` 是 router 的 token 或 native 入金入口。

- router 先校验 `SY` 已登记（无链上代码复检，allowlisting 为 owner 治理职责）；如果 `tokenIn != NATIVE`，则 `msg.value` 必须为 0，否则回退 `NativeAmountMismatch()`。
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

## 4. token -> stake（自由质押路径，已随 v1 genesis-only 决策删除）

`stakeFromToken` / `stakeFromSY` 及其错误面随 v1 删除：SP 自由借贷入口 `stake()` 不存在，uAsset 铸出量与 genesis 需求严格绑定（唯一铸造入口 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`）；pre-deployment ABI break 免费，禁用 flag 方案否决（不留死代码）。§8 的 `previewStakeFromToken` / `previewStakeFromSY` 保留，报价口径转为路径 B genesis 段（`previewStake` 公式同式覆盖唯一执行入口）。

## 5. SY -> stake（已随 v1 genesis-only 决策删除，编号退役）

## 6. genesis 双路径总览

genesis 是把新供给的 `uAsset` 原子地交给 `IMemeverseLauncher.genesis` 的集成路径，T5 起收敛为两个门：路径 A 单入口（PSM 门），路径 B 双计价入口（token 进 = 正门 / SY 进 = 高级入口，同一 CDP 门）：

| 门 | 入口 | 输入资产 | uAsset 来源 | uAsset 供给对账行 | 是否建 CDP 仓位 | 折扣/定价来源 |
| --- | --- | --- | --- | --- | --- | --- |
| 路径 A（PSM 门） | `OutrunRouter.sol::genesisByPSM` | reserve token（ERC20 或 NATIVE） | `IPSM.mint` 按 1:1 面值铸出（`tin` 折减） | PSM 行（储备铸烧，豁免 minter 台账） | 否——无 position、无债务 | 无折扣：面值 1:1 减 `tin` 费率 |
| 路径 B（CDP 门） | `OutrunRouter.sol::genesisByToken`（token 计价，正门）/ `OutrunRouter.sol::genesisBySY`（SY 计价，高级入口），均为薄转发 | token / native（`genesisByToken`，先经 `SY.deposit` 换成 SY）或 canonical `SY`（`genesisBySY`） | SP 原生物理门 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 按面值（价值平价）铸出（铸给 SP 自身、交易内全额交 SP 侧 `genesisLauncher`） | CDP 行（SP minter 台账） | 是——`genesisUser` 为 position owner | 无折扣：面值（价值平价）铸出，v1 无 LTV 缩放、无利率乘数（背书不变式见 `docs/spec/position/accounting.md` §10.3） |

- 三入口均 caller-funded：输入资产从 `msg.sender` 拉取；router 不垫资、不留存。
- 后置断言分侧（§7.3）：路径 A 消费 router 侧 `memeverseLauncher` 配置（§7.4）与 router 侧严格消费断言；路径 B 的面值开仓与严格消费断言均为 SP 原生（`OutrunStakingPositionUpgradeable.sol::stakeForGenesis`），router 只做 registry 校验与 SY 拉款/approve 薄转发（§7.2/§7.2.1）。部署布线须把 SP 侧 `genesisLauncher` 与 router 侧 `memeverseLauncher` registry 对齐到同一地址（§7.4）。
- 组合性声明：任意 EOA 或合约可直接调用 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 获得 genesis 仓（自备 SY、自设 `minUAssetMinted` 下限）；router 的 B 门双入口是薄转发便利层，非必经路径。
- `genesisUser` 只作为 launcher 侧记账身份与（路径 B）position owner；router 不校验其非零以外的属性（路径 B 由 `SP.stakeForGenesis` 的零地址守卫覆盖；路径 A 由 `OutrunRouter.sol::genesisByPSM` 入口前置校验非零，详见 §7.1——`OutrunRouter.sol::_genesisTail` 把 `genesisUser` 直透外部 launcher，零地址是否回退取决于外部实现，故入口前置）。
- `verseId` 为 launcher 分配并解释的 opaque ID，router 与 SP 均原样转发、不校验（`IMemeverseLauncher.sol::genesis`）。
- 第三入口（双门之外，不在本表内）：杠杆创世门 `OutrunRouter.sol::leveragedGenesisByPSM`——reserve token 经 PSM 面值铸 uAsset 后，全额作为 Memeverse `verseId` 的杠杆创世利息交 `POLend.leveragedGenesis`（借出额度记 `genesisUser`），无 genesis 交付 launcher、无 CDP 仓位；`verseId` ↔ `uAsset` 配对经 POLend 侧 `marketUAsset(verseId)` 复读。该入口独立成节（「杠杆创世门」节），与双门互引、不改变本节双门叙事。

### 6.1 `genesisByToken` 历史注记与 ABI 影响

- 历史注记：`genesisByToken` 曾在 T5 初稿以「三入口稀释双门」为由移除；产品裁决更正该论证——token 与 SY 是同一折扣 CDP 门（路径 B）的两个计价入口（token 进 vs SY 进），用户天然持有 token 而非 SY，token 入口是 B 门正门，删除它使折扣 CDP 路径对 EOA 事实上不可达（须拆两笔）——现已恢复为路径 B 的 token 计价入口（§7.2.1）。
- 恢复后签名（对齐移除前原版、去 `lockupDays`——开放期限 CDP 无锁仓参数）：`OutrunRouter.sol::genesisByToken(SP, tokenIn, tokenAmount, minSyOut, verseId, genesisUser, minUAssetMinted)`，`payable`（NATIVE 腿需要 `msg.value`）。
- 路径叙事：路径 A 仍覆盖 reserve token 直进的无仓位供给；确需 SY 路线的 token 持有者，`OutrunRouter.sol::mintSYFromToken`（token -> SY 到自身）+ `OutrunRouter.sol::genesisBySY`（SY -> genesis）两步组合是等价替代路径（批量钱包/聚合器可单交易完成），`genesisByToken` 是该组合的原子化单笔入口。
- ABI 影响（pre-deployment，无迁移成本，配对与三参即现状）：`IOutrunRouter.sol` 现行 selector 集为 `genesisByToken(SP, tokenIn, tokenAmount, minSyOut, verseId, genesisUser, minUAssetMinted)`（`payable`）、`genesisByPSM`（签名含 `reserveToken`，按配对查表）、`setPsmForUAsset(uAsset, reserveToken, psm)`、`psmForUAsset(uAsset, reserveToken)`，配 `PsmForUAssetUpdated`（配对载荷）事件与 `UnregisteredPsm(uAsset, reserveToken)`、`PsmBindingMismatch(psm, uAsset, actualUAsset)`、`PsmReserveMismatch(psm, reserveToken, actualReserveToken)` 错误；`genesisBySY` 签名为 `genesisBySY(SP, amountInSY, verseId, genesisUser, minUAssetMinted)`。PSM 侧 `mint` / `redeem` / `quoteMint` / `quoteRedeem` 只操作绑定储备、不含 `reserveToken` 参数，`IPSM` 暴露 `reserveToken()` getter。

## 7. genesis 双路径规格

### 7.1 路径 A：`genesisByPSM`（PSM 门，配对查表与双绑定复读即现状）

入口：`OutrunRouter.sol::genesisByPSM(uAsset, reserveToken, amountIn, verseId, genesisUser)`，`payable nonReentrant`（NATIVE reserve 腿需要 `msg.value`）。

前置校验全表（按执行顺序；第 1-3 行先于任何用户资产转移与精确 approve，第 4 行为拉款口径检查，第 5-7 行分别位于 PSM mint 内、铸出后与 genesis 返回后）：

| # | 校验 | 失败回退 | 归属 |
| --- | --- | --- | --- |
| 1 | `psmForUAsset(uAsset, reserveToken)` 按配对查表非零 | `UnregisteredPsm(uAsset, reserveToken)` | router registry |
| 2 | 复读 `IPSM(psm).uAsset() == uAsset` 且 `IPSM(psm).reserveToken() == reserveToken` | `PsmBindingMismatch(psm, uAsset, actualUAsset)` / `PsmReserveMismatch(psm, reserveToken, actualReserveToken)` | router registry（防漂移，同 SP 复读风格） |
| 3 | `genesisUser != address(0)` | `IOutrunRouter.sol::ZeroInput()` | router 入口前置（`_genesisTail` 直透外部 launcher，零地址回退取决于外部实现，故入口前置） |
| 4 | reserve 拉款口径：NATIVE 腿 `msg.value == amountIn`，ERC20 腿 `msg.value == 0` | `NativeAmountMismatch()` | `TokenHelper.sol::_transferIn` |
| 5 | PSM 侧入口校验（透传，不改写） | `ZeroInput()`（零额或铸出额 floor 为 0）/ `StockCapExceeded` / `NotReserveMinter`（uAsset owner 撤销该实例储备 minter 登记） / uAsset 暂停时 reserveMint 的 `EnforcedPause` | `OutrunPSMUpgradeable.sol::mint` |
| 6 | `amountOut > type(uint128).max` | `InvalidParam()` | router（launcher 参数域为 uint128） |
| 7 | genesis 后置断言（§7.3） | `GenesisUAssetNotConsumed(residualBalance, residualAllowance)` | router |

资金流逐步：

1. router 读取 `uAsset` 快照基线 `IERC20(uAsset).balanceOf(address(this))`（铸出前快照，排除第三方预存 dust）。
2. router 经 `_transferIn` 从 `msg.sender` 拉入 `amountIn` 的 reserve（ERC20 需调用者事先 approve router；NATIVE 以 `msg.value` 到账）。
3. router 对 PSM 精确 approve `amountIn`（`_approveExact`；NATIVE 为 no-op；`amountIn == type(uint256).max` 的无限额语义被拒 `InvalidParam()`），再调用 `IPSM(psm).mint{value: native ? amountIn : 0}(address(this), amountIn)`——PSM 从 router 拉走绑定储备，按面值 `× (1 − tin)` 计算铸出额，经 `OutrunUniversalAssetsUpgradeable.sol::reserveMint` 把 `amountOut` uAsset 铸给 router。
4. router 校验 `amountOut <= type(uint128).max`（表第 6 行）。
5. router 对 launcher 精确 approve `amountOut` 的 uAsset。
6. router 调用 `IMemeverseLauncher(launcher).genesis(verseId, uint128(amountOut), genesisUser)`，launcher 经 `transferFrom` 拉走全部 `amountOut`。
7. 后置断言（§7.3）通过后交易成功；router 无残余——reserve 余额回到拉款前状态（PSM 全额拉走、approve 精确）、uAsset 余额回到快照基线、对 launcher 的 allowance 为 0。

滑点与原子性：

- 无 `minUAssetOut` 参数：PSM 为 1:1 面值 + `tin` 费率的确定性数学，`IPSM.quoteMint(amountIn)` 与 `mint` 输出恒等（零 oracle 性质，`docs/spec/psm/peg-stability-module.md`；dust 零输出域除外——quote 返 0 而 `mint` revert `ZeroInput`，见该文档「零输出守卫」），不存在 sandwich 可利用的池失衡面；对齐 IPSM 自身无 `minOut` 的立场。费率与 cap 属治理参数与 fail-closed 边界，非滑点面。
- 原子性由 EVM 同交易回滚语义保证：PSM 铸出、approve、launcher 消费任一步失败，整笔回滚（含 PSM 侧 `netUAssetMinted` 台账与储备转移）；`nonReentrant` 隔离拉款回调与 PSM/launcher 外部调用窗口内的重入。
- 事件面：成功路径链上事件为 `IPSM.sol::SwapMintForUAsset(reserveToken, to = router, amountIn, amountOut, feeIn)`、uAsset 的 ERC20 `Transfer`（零地址 -> router，随 reserveMint）、对 launcher 的 ERC20 `Transfer`（router -> launcher）；router 自身不发 genesis 专属事件（沿用现状，轨迹由 PSM/launcher 事件与链上转移承载）。

### 7.2 路径 B：`genesisBySY`（CDP 门，SY 计价入口，薄转发）

入口：`OutrunRouter.sol::genesisBySY(SP, amountInSY, verseId, genesisUser, minUAssetMinted)`，`nonReentrant`。本变更集起 B 门降级为薄转发便利层：面值开仓、`minUAssetMinted` 下限、uint128 边界、launcher 禁用守卫与严格消费后置断言全部由 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 原生完成（SP 原生物理门，v1 唯一铸造入口），SP 侧错误原样透传；router 在路径 B 不再触碰 uAsset（无 router 侧 uAsset approve/断言，也不再自行组合 stake→approve→genesis）。

router 侧前置校验与资金流（registry 校验先于一切资金移动）：

| # | 校验 / 步骤 | 失败回退 | 归属 |
| --- | --- | --- | --- |
| 1 | SP -> SY 配对已登记、SY 仍 trusted、`SP.SY()` 无漂移（每次调用复读） | `UntrustedRouterTarget(SP 或 SY)` / `RouterTargetMismatch(SP, SY, actualSY)` | router registry |
| 2 | launcher parity：`OutrunRouter.sol::memeverseLauncher` == `OutrunStakingPositionUpgradeable.sol::genesisLauncher`（每次调用复读） | `GenesisLauncherMismatch(routerLauncher, spLauncher)` | router（资金移动前 fail-closed） |
| 3 | SY 拉款：`_transferFrom(SY, msg.sender, address(this), amountInSY)`（余额/授权不足透传依赖错误；SY 暂停时非零额经 `_update` 的 `whenNotPaused` 回退） | 依赖边界错误 / `EnforcedPause` | `TokenHelper.sol::_transferFrom` |
| 4 | 对 `SP` 精确 approve `amountInSY` 后调用 `SP.stakeForGenesis(amountInSY, genesisUser, verseId, minUAssetMinted)`；SP 侧校验透传：genesis 专属四类——`mintedUAsset < minUAssetMinted` 为 `InsufficientUAssetMinted(mintedUAsset, minMinted)`、`mintedUAsset > type(uint128).max` 为 `InvalidParam()`、SP 侧 `genesisLauncher == address(0)` 为 `GenesisLauncherNotSet()`（入口禁用态；parity 通过后可达——router 非零而 SP 置零的分歧配置下先报 `GenesisLauncherMismatch`）、后置断言失败为 `GenesisUAssetNotConsumed(residualBalance, residualAllowance)`；另有 `ZeroInput`、`MinStakeInsufficient`、`ZeroExchangeRate`、`DustRoundedToZero`、SP 暂停 `EnforcedPause`、oracle fail-closed、`ReachMintCap` | 各自具名错误原样透传（不改写 revert data） | `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` |

SP 侧语义（完整规格见 `docs/spec/position/accounting.md` §3.1 与 `docs/spec/position/state-machines.md` §2）：

- 开仓校验、`rate` 结算与铸出量数学为面值（价值平价）两段 down（无 LTV 缩放段、无锁定系数），`principalDebt = mintedUAsset`；`genesisUser` 为 position owner 并承担该仓债务，销债经 `OutrunStakingPositionUpgradeable.sol::redeem`（本金腿 burn + 利息腿转金库，v1 零费默认下利息腿恒 0，`docs/spec/position/accounting.md` §7）。
- uAsset 铸给 SP 自身（`address(this)`），绝不经过 owner、router 或第三方；SP 对其 `genesisLauncher` 精确 approve 恰好 `mintedUAsset`，调用 `IMemeverseLauncher.genesis(verseId, uint128(mintedUAsset), genesisUser)`；后置断言 SP 的 uAsset 余额回到铸出前基线且对 launcher 的 allowance 为 0，否则 `GenesisUAssetNotConsumed` 整笔回滚。
- 事件面：成功路径链上事件为 `IOutrunStakeManager.sol::Stake(positionId, owner = genesisUser, amountInSY, mintedUAsset)` 加 `StakeForGenesis(positionId, positionOwner, verseId, mintedUAsset)`、uAsset 的 ERC20 `Transfer`（零地址 -> SP、SP -> launcher）；router 自身不发 genesis 专属事件（沿用现状）。

「借出量 == genesis 消费量」为 SP 原生严格相等：

- 等式三重构造（全在 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 内闭合）：铸给 SP 的量 = `mintedUAsset`；对 launcher 的精确 approve 额 = `mintedUAsset`（launcher 至多拉走该量，不覆盖预存余额）；转发给 genesis 的 uint128 额 = `uint128(mintedUAsset)`。无任何份额留给用户、router 或 SP；router 全程不持有 uAsset 瞬态余额。
- 等式由 SP 侧后置断言强制（基线为 SP 自身铸出前余额，§7.3 路径 B 侧），"完全消费"是代码断言，不依赖 launcher 实现纪律。
- 驱动方向取舍不变：入参以 SY 额驱动（minted 全额投 genesis），天然相等；不采用 uAsset 目标额驱动（`previewStake` 反推 SY 需求）——两段 floor 换算无精确逆（floor 非单射），反推只能保守超押并引入剩余 SY 退还路径，违背"无残余"目标。代价是调用者无法预先钉死 genesis 的 uAsset 精确额（铸出量随汇率与取整变化），genesis 参与额按弹性量处理，以 `minUAssetMinted` 约束下限。

#### 7.2.1 路径 B token 计价入口：`genesisByToken`（B 门正门）

入口：`OutrunRouter.sol::genesisByToken(SP, tokenIn, tokenAmount, minSyOut, verseId, genesisUser, minUAssetMinted)`，`payable nonReentrant`（NATIVE 腿需要 `msg.value`）。保留 token -> SY 换换头部（registry 校验、NATIVE 哨兵、`minSyOut` 下限，native/ERC20 value 规则同 §2），随后以与 §7.2 完全相同的方式薄转发 `SP.stakeForGenesis(amountInSY, genesisUser, verseId, minUAssetMinted)`；router 同样不触碰 uAsset。两部件均为已评审存量语义（token -> SY 换换头部同 `OutrunRouter.sol::_mintSY`，SY -> genesis 薄转发尾部同 §7.2），本入口不引入新机制。

前置校验全表（按执行顺序；第 1-3 行先于任何用户资产转移与精确 approve）：

| # | 校验 | 失败回退 | 归属 |
| --- | --- | --- | --- |
| 1 | SP -> SY 配对已登记、SY 仍 trusted、`SP.SY()` 无漂移（每次调用复读） | `UntrustedRouterTarget(SP 或 SY)` / `RouterTargetMismatch(SP, SY, actualSY)` | router registry |
| 2 | launcher parity：`OutrunRouter.sol::memeverseLauncher` == `OutrunStakingPositionUpgradeable.sol::genesisLauncher`（每次调用复读） | `GenesisLauncherMismatch(routerLauncher, spLauncher)` | router（资金移动前 fail-closed） |
| 3 | token 拉款口径：NATIVE 腿 `msg.value == tokenAmount`，ERC20 腿 `msg.value == 0` | `NativeAmountMismatch()` | `TokenHelper.sol::_transferIn`（经 `OutrunRouter.sol::_mintSY`） |
| 4 | SY deposit 入口校验（透传）：`tokenIn` 须为 `isValidTokenIn` 支持资产、`tokenAmount` 非零、`amountSharesOut >= minSyOut` | `SYInsufficientSharesOut(amountSharesOut, minSharesOut)`（下限不达）/ SY 侧其余依赖错误 / SY 暂停 `EnforcedPause` | `SYBaseUpgradeable.sol::deposit` |
| 5 | SP 侧校验（透传，同 §7.2 表第 4 行全表）：genesis 专属 `InsufficientUAssetMinted` / `InvalidParam`（uint128 域）/ `GenesisLauncherNotSet`（parity 通过后可达，分歧时先报 `GenesisLauncherMismatch`）/ `GenesisUAssetNotConsumed`，及 `ZeroInput`、`MinStakeInsufficient`、`ZeroExchangeRate`、`DustRoundedToZero`、SP 暂停 `EnforcedPause`、oracle fail-closed、`ReachMintCap` | 各自具名错误原样透传 | `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` |

资金流逐步：

1. router 校验已登记且匹配的 SP -> SY 配对（含复读 `SP.SY()`），派生 canonical `SY`，不接收调用者单独传入的 `SY`。
2. router 经 `OutrunRouter.sol::_mintSY` 从 `msg.sender` 拉入 `tokenAmount` 的 token（ERC20 需调用者事先 approve router；NATIVE 以 `msg.value` 到账），对 `SY` 精确 approve `tokenAmount`（NATIVE 为 no-op）后调用 `IStandardizedYield(SY).deposit(address(this), tokenIn, tokenAmount, minSyOut)`——新 mint 的 `SY` 留在 router，实际换得 `amountInSY >= minSyOut`。
3. router 对 `SP` 精确 approve `amountInSY`，调用 `SP.stakeForGenesis(amountInSY, genesisUser, verseId, minUAssetMinted)`——SP 侧完成面值开仓（价值平价铸出）、uAsset 铸给 SP 自身、对 SP 侧 `genesisLauncher` 的原子交款与后置断言（§7.2 SP 侧语义）；断言通过后交易成功，router 无残余（除换换头部外全程不触碰 uAsset）。

语义要点：

- 两级滑点下限各自独立生效：`minSyOut` 约束 token -> SY 换换（`SYBaseUpgradeable.sol::deposit`），`minUAssetMinted` 约束 SY -> uAsset 铸出（SP 侧 `InsufficientUAssetMinted` 透传）；零值均为无保护透传（§8 零下限语义）。
- 与两步组合的等价性：`OutrunRouter.sol::mintSYFromToken`（receiver = 调用者自身）+ `OutrunRouter.sol::genesisBySY` 与本入口在同输入同参数下铸出额、仓位字段、launcher 收额一致；本入口为其单笔原子化——中间 `SY` 不经调用者账户，无中间持有与二次授权面。
- 事件面：成功路径链上事件为 `IStandardizedYield.sol::Deposit`（token -> SY 换换步）、`IOutrunStakeManager.sol::Stake` + `StakeForGenesis`（SP 侧开仓）、uAsset 的 ERC20 `Transfer`（零地址 -> SP、SP -> launcher）；router 自身不发 genesis 专属事件（沿用现状，无新增事件）。
- 错误面：router 侧仅 registry/拉款/换换/launch parity 错误；其余为 SP 侧错误原样透传（§7.2 表第 4 行全表 + §7.6 透传边界），无新 router 错误。

### 杠杆创世门（双门之外的第三入口）：`leveragedGenesisByPSM`

入口：`OutrunRouter.sol::leveragedGenesisByPSM(uAsset, reserveToken, amountIn, verseId, genesisUser)`，`payable nonReentrant`（NATIVE reserve 腿需要 `msg.value`）。

定位：§6 双门之外的第三条 genesis 入口。路径 A 把 PSM 铸出的 uAsset 交给 launcher 普通 `genesis`（§7.1）；本入口把 reserve 经 PSM 面值铸出的 uAsset 全额作为 Memeverse `verseId` 的杠杆创世利息交给 Memeverse 侧 `POLendUpgradeable` 的 `leveragedGenesis`——POLend 从 payer（= router）拉走利息，按注册期快照的 `interestRate` 记借出额度 `borrowedAmount = interestAmount × 1e18 / interestRate` 给 `genesisUser`，并把 `borrowedAmount` 返回 router 原样转发。无 genesis 交付 launcher、无 CDP 仓位、无 position（uAsset 供给对账与路径 A 同源，走 PSM 储备铸烧行）；本地接口缝为 `IPOLendGenesis.sol`（只声明 `leveragedGenesis(uint256,uint256,address)` 与 `marketUAsset(uint256)`）。`polend` 地址为 owner 登记（§1.2）；`verseId` ↔ `uAsset` 配对经 POLend 侧 `marketUAsset(verseId)` 复读校验（区别于双门的 launcher parity 复读，§7.2 表第 2 行）。

前置校验全表（按执行顺序；第 1-5 行先于任何用户资产转移与精确 approve，第 6 行为拉款口径检查，第 7-8 行分别位于 PSM mint 内与 POLend `leveragedGenesis` 内，第 9 行位于 POLend 返回后）：

| # | 校验 | 失败回退 | 归属 |
| --- | --- | --- | --- |
| 1 | `psmForUAsset(uAsset, reserveToken)` 按配对查表非零 | `UnregisteredPsm(uAsset, reserveToken)` | router registry |
| 2 | 复读 `IPSM(psm).uAsset() == uAsset` 且 `IPSM(psm).reserveToken() == reserveToken` | `PsmBindingMismatch(psm, uAsset, actualUAsset)` / `PsmReserveMismatch(psm, reserveToken, actualReserveToken)` | router registry（防漂移，同 §7.1 复读风格） |
| 3 | `polend != address(0)` | `IOutrunRouter.sol::PolendNotSet()` | router 配置（运行期 fail-closed，§1.2） |
| 4 | verse 配对复读：`IPOLendGenesis(polend).marketUAsset(verseId) == uAsset` | `IOutrunRouter.sol::PolendMarketUAssetMismatch(verseId, uAsset, marketUAsset)`（未注册 verse 读零地址走同一路径；资金移动前 fail-closed） | router（POLend 配对复读） |
| 5 | `genesisUser != address(0)` | `IOutrunRouter.sol::ZeroInput()` | router 入口前置（下游直透外部 POLend，零地址回退取决于外部实现，故入口前置，同 §7.1 第 3 行理由） |
| 6 | reserve 拉款口径：NATIVE 腿 `msg.value == amountIn`，ERC20 腿 `msg.value == 0` | `NativeAmountMismatch()` | `TokenHelper.sol::_transferIn` |
| 7 | PSM 侧入口校验（透传，不改写） | `ZeroInput()`（零额或铸出额 floor 为 0）/ `StockCapExceeded` / `NotReserveMinter`（uAsset owner 撤销该实例储备 minter 登记） / uAsset 暂停时 reserveMint 的 `EnforcedPause` | `OutrunPSMUpgradeable.sol::mint` |
| 8 | POLend 侧入口校验（透传，不改写） | `InvalidState` / `DebtCapExceeded` / `ZeroInput` / `InvalidConfig` / POLend 暂停 `EnforcedPause`（跨仓库独立暂停面） | Memeverse 侧 `POLendUpgradeable.sol::leveragedGenesis` |
| 9 | genesis 后置断言（spender = `polend`，§7.3 同一 helper） | `GenesisUAssetNotConsumed(residualBalance, residualAllowance)` | router |

资金流逐步：

1. router 读取 `uAsset` 快照基线 `IERC20(uAsset).balanceOf(address(this))`（铸出前快照，排除第三方预存 dust，同 §7.1）。
2. router 经 `_transferIn` 从 `msg.sender` 拉入 `amountIn` 的 reserve（ERC20 需调用者事先 approve router；NATIVE 以 `msg.value` 到账）。
3. router 对 PSM 精确 approve `amountIn`（`_approveExact`；NATIVE 为 no-op；`amountIn == type(uint256).max` 的无限额语义被拒 `InvalidParam()`，同 §7.1），再调用 `IPSM(psm).mint{value: native ? amountIn : 0}(address(this), amountIn)`——PSM 从 router 拉走绑定储备，按面值 `× (1 − tin)` 计算铸出额，经 `OutrunUniversalAssetsUpgradeable.sol::reserveMint` 把 `amountOut` uAsset 铸给 router。
4. router 对 `polend` 精确 approve `amountOut` 的 uAsset。
5. router 调用 `IPOLendGenesis(polend).leveragedGenesis(verseId, amountOut, genesisUser)`——POLend 经 `transferFrom` 拉走全部 `amountOut` 作为 `verseId` 利息，记账落 `genesisUser`（payer = router 无记账），emit Memeverse 侧 `LeveragedGenesis(verseId, payer = router, user = genesisUser, interestAmount)` 四字段事件；router 原样转发其返回的 `borrowedAmount`。
6. 尾断言复用 `GenesisGateLib.sol::assertFullConsumption`（spender = `polend`）：POLend 恰好拉走 `interestAmount == amountOut`，严格消费成立，任一方向残余整笔回退——断言通过后交易成功，router 无残余（reserve 余额回到拉款前状态、uAsset 余额回到快照基线、对 `polend` 的 allowance 为 0；基线与载荷语义同 §7.3 的 router 侧构造，授权对象为 `polend` 而非 launcher，第三方预存 dust 不进断言域，同 `genesisByPSM`）。

设计要点：

- 无滑点参数：两段定价均为固定数学——PSM 面值 1:1 减 `tin`（零 oracle、零池、零时间依赖，同 §7.1 立场）；`interestRate` 在 Memeverse 侧 `registerLendMarket` 时快照进 market 且无 per-market setter，`borrowed = interestAmount × 1e18 / interestRate` 确定，不存在 sandwich 可利用的价差面。利息额（= PSM 铸出额）的报价由 `IPSM.quoteMint(amountIn)` 恒等给出（同 §7.1/§8 路径 A 口径），`borrowedAmount` 以 POLend 返回值为单一真源、集成方免重算 rate。治理参数（`tin`、`interestRate`）与 cap（`stockCap`、verse `debtCap`）属 fail-closed 边界，非滑点面。
- 无 uint128 边界：POLend 的 `interestAmount` 参数为 uint256（不同于 launcher 域的 uint128），router 侧无 `InvalidParam` 守卫、不截断转发。
- 事件面：router 不发自有事件（沿用现状），轨迹为 `IPSM.sol::SwapMintForUAsset(reserveToken, to = router, amountIn, amountOut, feeIn)` + Memeverse 侧 `LeveragedGenesis(verseId, payer = router, user = genesisUser, interestAmount)` 四字段事件 + uAsset 的 ERC20 `Transfer`（零地址 -> router 随 reserveMint；router -> polend 随 POLend 拉取）。
- 错误面补充：`polend` 非零但无代码（EOA 误配）时 `marketUAsset(verseId)` 的 staticcall 以底层调用/解码错误回退、非具名错误（对齐 §1.2.1 复读条款惯例），不做 code-size 检查（allowlisting 为 owner 治理职责）。
- 重入隔离：入口挂 `nonReentrant`（transient guard，§1.2），覆盖 `_transferIn` 拉款回调、PSM mint 与 `polend.leveragedGenesis` 外部调用窗口；POLend 入口自带 `whenNotPaused` 与自身 guard，与 router 侧 guard 相互独立（transient slot 按合约实例隔离，同 §7.3）。任一环节失败整笔回滚（含 PSM 侧净铸出台账与储备转移），router 无跨交易状态、失败后无需清理。

### 7.3 共享语义：严格消费后置断言（分侧）、uint128 边界、失败回滚

- **后置断言分侧（单一来源 `GenesisGateLib`）**：路径 A 与路径 B 均通过 `GenesisGateLib.sol::assertFullConsumption` 触发同一错误 `GenesisGateLib.GenesisUAssetNotConsumed(residualBalance, residualAllowance)`（等号严格双向，任何方向的偏离都整笔回退）；路径 A 基线为本次交易 PSM mint 之前的 router 快照（`IERC20(uAsset).balanceOf(address(this))` 与 `allowance(address(this), launcher)`），路径 B 基线为 SP 自身铸出前余额（`SP` 对 `genesisLauncher` 的 allowance）。断言基线均为本次交易铸出前快照，因此第三方预先转入的 `uAsset` dust 不进入断言域（router 侧仍可经 `OutrunRouter.sol::sweep` 回收），而 launcher 部分消费或转回仍会整笔回退。两门断言语义同构：授权给 launcher 的精确额度只覆盖本次铸出量、从不覆盖预存余额；在"铸出为唯一保证流入、流出受精确 allowance 上界约束"的不变式下，可达的偏离只会超出基线，余额差值不会下溢。
- **uint128 边界**：launcher 的 `amountInUAsset` 参数为 uint128。路径 A 在 router 侧铸出量超过 `type(uint128).max` 时回退 `InvalidParam()`，检查位于 PSM 铸出之后、对 launcher 的 approve 与 `genesis(...)` 调用之前；路径 B 的同一守卫由 SP 侧 `stakeForGenesis` 执行（`InvalidParam()` 同名透传）。入参侧（`amountIn`/`tokenAmount`/`amountInSY`）为 uint256，无输入上限。
- **失败回滚语义**：任一环节失败（registry、拉款、PSM/SP 入口、uint128 边界、launcher 内部、后置断言）整笔交易回滚——不留下 position、不留下 PSM 净铸出与储备转移、不留下任何残余 allowance 或余额变化（路径 B 的仓位与 SP 铸出一并消失）；router 除 registry 与 launcher 配置外无跨交易状态，失败后无需清理。依赖错误（SY、PSM、SP、uAsset、launcher）原样透传，router 不捕获、不改写 revert data。
- **重入隔离**：三入口的 `nonReentrant`（transient guard）覆盖 `_transferIn` 拉款回调、SY deposit、PSM mint、`SP.stakeForGenesis` 与（仅路径 A）launcher genesis 外部调用窗口；SP 侧 `stakeForGenesis` 自带 `nonReentrant`，与 router 侧 guard 相互独立（§1.2）。

### 7.4 launcher 配置校验

- `OutrunRouter` 的 constructor 与 `setMemeverseLauncher(...)` 为普通存储写入，不做零地址与链上代码校验（allowlisting 为 owner 治理职责，零地址/EOA 配错在配置期不回退，失败留待使用期）。
- `OutrunRouter.sol::setMemeverseLauncher` 成功轮换时发出 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）。该轮换与事件验收为部署/测试期程序：生产 launcher 冻结为 immutable，仅经 constructor 布线（部署期同样经 `_setMemeverseLauncher` 首发 `SetMemeverseLauncher(address(0), launcher)`，`oldLauncher` 为零初值），并核对 `OutrunRouter.sol::memeverseLauncher` 读取值；生产换 launcher 即重部署 router，无运行期轮换步骤。
- genesis 流程不对 `memeverseLauncher` 做配置期校验前置；零地址/EOA 误配置在使用期失败，而非配置期。
- router 对 launcher 的运行期信任边界已从"地址存在代码即信任"升级为可验证断言：`genesis(...)` 返回后余额必须回到本次交易铸出前快照基线（§7.3）且 `allowance == 0`，否则 `GenesisUAssetNotConsumed` 整笔回退；配置期无代码校验，运行期以同一交易内后置检查兜底。该后置检查属于运行期可观测性/健壮性加固，不改变 launcher 内部仍是外部信任边界这一语义，但将"完全消费"从信任假设升级为强制断言。
- SP 侧 genesis launcher 布线（路径 B）：`OutrunStakingPositionUpgradeable.sol::setGenesisLauncher`（owner-only）写入 SP 侧 `genesisLauncher`，emit `SetGenesisLauncher(oldLauncher, newLauncher)`；该参数不是 initialize 参数——SP 部署默认零地址＝`stakeForGenesis` 入口禁用（`GenesisLauncherNotSet`），须部署后经该 setter 布线（接受任意地址含零；置零即禁用入口的 kill switch）。部署核对项：SP 侧 `genesisLauncher` 与 router 侧 `memeverseLauncher` registry 必须对齐到同一 launcher 地址——断言 `SP.genesisLauncher() == router.memeverseLauncher()`（router 侧 env 键为 `MEMEVERSE_LAUNCHER`，SP 侧测试网 mock 支持路径 env 键为 `GENESIS_LAUNCHER`，生产为 owner 手工调用；布线细节见 `docs/deployment.md`「genesis 门控布线」）。

### 7.5 target registry 与撤销

- Router owner 应先调用 `setTrustedSY(...)` 登记官方 SY，再调用 `setTrustedSP(...)` 登记每个官方 SP 的配对；部署脚本或集成层应记录 `TrustedSYUpdated` 与 `TrustedSPUpdated` 事件并核对 `SP.SY()`。
- 路径 A 的部署 wiring（配对与三参即现状）：每个 (uAsset, reserveToken) 配对先完成 PSM 侧部署与登记（uAsset owner 经 `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter` 把该配对 PSM 实例登记为储备 minter；无 PSM 侧储备登记步骤），再由 router owner 调用 `OutrunRouter.sol::setPsmForUAsset(uAsset, reserveToken, psm)` 并核对 `PsmForUAssetUpdated` 事件、`psmForUAsset(uAsset, reserveToken)` 读取值与 `IPSM(psm).uAsset()` / `IPSM(psm).reserveToken()` 双绑定；遗漏该步时 `genesisByPSM` 以 `UnregisteredPsm(uAsset, reserveToken)` 回退（现状）。
- `redeemSyToToken` 入口还要完成 trusted-router wiring：每个官方 SY 由该实例 owner 调用 `SYBaseUpgradeable.sol::setTrustedRouter(OUTRUN_ROUTER)`（当前 router 地址），使 `SYBaseUpgradeable.sol::trustedRouter()` 等于 router，并核对 `SetTrustedRouter` 事件后再开放该入口；遗漏该步时入口在 `SYBaseUpgradeable.sol::redeem` 以 `SYUnauthorizedInternalRedeemer(address caller)` 回退（见 §3）。轮换 router 时先对每个 SY 设置新 router 并核对读取值与事件，再停用旧入口或撤销（`SYBaseUpgradeable.sol::setTrustedRouter(address(0))`）。
- `setTrustedSY(SY, false)`、`setTrustedSP(SP, address(0))`、`setPsmForUAsset(uAsset, reserveToken, address(0))` 只影响后续 router 入口，不回滚已完成的资产流、position 或 PSM 储备状态。

### 7.6 错误面与下游透传边界

- `NativeAmountMismatch()` 由 `OutrunRouter.sol::_mintSY` 与路径 A 的 reserve 拉款先校验 registry 后委托 `TokenHelper.sol::_transferIn` 完成 router-side 的 native/ERC20 金额检查：native sentinel 要求 `msg.value == amount`，ERC20 输入要求 `msg.value == 0`。该检查先于 transfer、approve 与下游调用；下游 `SYBaseUpgradeable.sol::deposit` 与 `OutrunPSMUpgradeable.sol::mint` 仍有独立的 token / `msg.value` 校验。
- `InvalidParam()` 的 router-side 触发点：`OutrunRouter.sol::_approveExact` 收到非 native token 的 `type(uint256).max`（拒绝无限 allowance，路径 A 的 reserve approve 与 launcher uAsset approve 适用）；以及路径 A genesis 尾部在铸出量 `amountOut > type(uint128).max` 时回退——发生在 launcher approve 与 `genesis(...)` 调用之前。路径 B 的 uint128 守卫随尾部移至 SP 侧（`OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 对 `mintedUAsset` 检查，`InvalidParam()` 同名透传）。
- `memeverseLauncher` 配置为普通存储写入，无 router 侧具名错误；零地址语义见 §7.4。
- `InsufficientUAssetMinted(uint256 mintedUAsset, uint256 minMinted)` 为单一声明错误：仅由 `IOutrunStakeManager.sol` 声明，唯一触发点在 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（实际 `mintedUAsset < minUAssetMinted` 时回退）；router 侧无同名声明、无自有下限检查，路径 B 双入口（`genesisBySY`/`genesisByToken`）经薄转发原样透传，router 不捕获、不改写 revert data。router 侧 `InvalidParam()` 声明仍独立存在（触发点见上条）。路径 A 无此参数（确定性数学无滑点面，§7.1）。
- `SYInsufficientSharesOut(uint256 amountSharesOut, uint256 minSharesOut)` 由 `SYBaseUpgradeable.sol::deposit` 在 token -> SY 换换输出低于 `minSyOut` 时触发，经 `OutrunRouter.sol::_mintSY` 透传（`mintSYFromToken` / `genesisByToken` 共用同一头部）；零值 `minSyOut` 为无保护透传，换换输出为零另回退 `SYZeroSharesOut`（§8 零下限语义）。
- `UnregisteredPsm(uAsset, reserveToken)`（现状）由 `OutrunRouter.sol::genesisByPSM` 在 `psmForUAsset(uAsset, reserveToken)` 按配对查表为零时触发，先于一切资金移动；`PsmBindingMismatch(psm, uAsset, actualUAsset)` 与 `PsmReserveMismatch(psm, reserveToken, actualReserveToken)`（现状）由 `OutrunRouter.sol::setPsmForUAsset` 登记期双绑定校验与 `genesisByPSM` 运行期复读触发。
- `IOutrunRouter.sol::ZeroInput` 由 `OutrunRouter.sol::genesisByPSM` 在 `genesisUser == address(0)` 时触发，先于一切资金移动；`OutrunRouter.sol::_genesisTail` 把 `genesisUser` 直透外部 launcher，零地址是否回退取决于外部实现，故入口前置。
- `GenesisLauncherMismatch(routerLauncher, spLauncher)` 由 `OutrunRouter.sol::genesisBySY` / `OutrunRouter.sol::genesisByToken` / `previewStakeFromToken` / `previewStakeFromSY` 在 `OutrunRouter.sol::memeverseLauncher` != `OutrunStakingPositionUpgradeable.sol::genesisLauncher` 时触发（每次调用复读；执行入口在资金移动前 fail-closed，preview 入口在 registry 解析后、报价前 fail-closed）；冻结后 SP 侧轮换触发该回退，零地址 kill switch 仍可用。
- `SweepZeroAddress()` / `SweepZeroAmount()` 由 `OutrunRouter.sol::sweep` 在 `to == address(0)` / `amount == 0` 时触发，避免静默无操作；`Sweep(address indexed token,address indexed to,uint256 amount)` 事件记录回收。`sweep` 可转出路由器当前持有的任意 ERC20/native（含瞬态 SY/uAsset），无 per-token blocklist 为有意——路由器无背书资产，外置 SY 的 `yieldBearingToken` / `address(this)` blocklist（`SYBaseUpgradeable.sol::sweep`）不适用；瞬态风险仅限单笔交易内余额且受 `onlyOwner` + `nonReentrant`（`ReentrancyGuardTransient`）保护，未授权调用方 DENIED，持续 live（`Ownable` 产品外 multisig 治理，产品合约内不设 `TimelockController`）。
- `GenesisUAssetNotConsumed(uint256 residualBalance, uint256 residualAllowance)` 为单一来源错误 `GenesisGateLib.GenesisUAssetNotConsumed`（`GenesisGateLib.sol::assertFullConsumption`），两门均通过同一 helper 触发，基线分别为 router 侧 PSM 铸出前快照与 SP 侧铸出前余额，载荷语义同构：路径 A `residualBalance` = router 余额相对 PSM 铸出前快照的超出量（第三方预存 dust 不计入）、`residualAllowance` = `IERC20(uAsset).allowance(address(this), launcher)`，任一非零即回退（余额必须严格等于快照基线、allowance 严格为 0）；路径 B 同理以 SP 自身余额与对 `genesisLauncher` 的 allowance 为域，经 router 入口原样透传。铸出量已在 `uint128` 边界内，该检查的原子性来自 EVM 同一交易的回滚语义（launcher 无法跨块延迟消费）。
- 路径 B 的 SP 侧错误面（`InsufficientUAssetMinted` / `InvalidParam` / `GenesisLauncherNotSet` / `GenesisUAssetNotConsumed`）经 router 的 `genesisBySY` / `genesisByToken` 原样透传，router 不捕获、不改写、不重复检查。其中 `GenesisLauncherNotSet` 仅 parity 通过后可达（直调 SP，或 router 与 SP 双零时 parity 照过）；router 非零而 SP 置零的分歧配置下先由 parity 报 `GenesisLauncherMismatch`。
- 下游 `SY` 的 `deposit(...)` / `redeem(...)`、PSM 的 `mint(...)`、`SP` 的 `SY()` / `uAsset()` / `stake(...)` / `stakeForGenesis(...)` 以及 launcher 的 `genesis(...)` 若自身回退，router 不捕获、不改写错误数据，原始 revert 透传给上层；router 自身的 registry 校验、金额、精确 approve、最小铸造量（stake 尾部）与路径 A 的 `uint128` 边界及 `GenesisUAssetNotConsumed` 后置检查可能在相应下游调用前/后回退。

## 8. preview 语义与 slippage 边界

当前 router 暴露的 preview 入口有：

- `previewStakeFromToken(SP, tokenIn, tokenAmount)`
- `previewStakeFromSY(SP, amountInSY)`

router 只暴露上述 2 个交易级 preview；SP 级 quote 族为 `previewStake`、`previewRedeem` 两个（完整失败面与 0-vs-revert 语义以 `docs/spec/position/accounting.md` §5/§11 为 canonical）。`previewStakeFromToken` / `previewStakeFromSY` 会透传 `SP.previewStake` 的 `ZeroInput`（零 SY 输出域）/ `MinStakeInsufficient` / `ZeroExchangeRate` / dust-返 0，`previewStakeFromToken` 另透传 `SY.previewDeposit` 的失败面（如 `SYInvalidTokenIn`）。

genesis 无 router 级 preview 入口，也不新增 genesis 专属 preview：`previewStake` 的铸出量公式与 `stakeForGenesis` 执行入口同式（SP 定价不区分入口），且 genesis 消费量 == 铸出量（确定性），故路径 B 双入口的报价由 `previewStakeFromToken`（token 计价入口，组合口径 token -> SY -> uAsset，含 `SY.previewDeposit` 段）与 `previewStakeFromSY`（SY 计价入口）承担即可全覆盖（SP 铸出段定价即 genesis 段消费额）；路径 A 的报价由 `IPSM.quoteMint(amountIn)` 直接承担（与执行恒等，零 oracle 确定性；dust 零输出域除外——quote 返 0 而 `mint` revert `ZeroInput`，见 `docs/spec/psm/peg-stability-module.md`「零输出守卫」）。

当前 preview 的语义边界：

- `previewStakeFromToken(SP, tokenIn, tokenAmount)` 不接收调用者传入的 `SY`；它先校验已登记的 SP -> SY 配对，再比对 `memeverseLauncher` 与 SP 侧 `genesisLauncher` 一致性（不一致以 `GenesisLauncherMismatch` 回退），再从 `SP.SY()` 派生 canonical `SY`，再做两步静态组合：
  - `SY.previewDeposit(tokenIn, tokenAmount)`
  - `SP.previewStake(amountInSY)`；其语义与执行期一致：先做 `SY -> canonical asset`，再做 `canonical asset -> uAsset`（两段 down 面值换算，无 LTV 缩放段）
- `previewStakeFromSY(SP, amountInSY)` 先校验已登记的 SP -> SY 配对，再比对 `memeverseLauncher` 与 SP 侧 `genesisLauncher` 一致性（不一致以 `GenesisLauncherMismatch` 回退），再调用 `SP.previewStake(amountInSY)`；其语义同样是先 `SY -> canonical asset`，再做 `canonical asset -> uAsset`（面值换算）。
- preview 不接收 genesis 执行参数，结果不反映 `minSyOut` / `minUAssetMinted` / `genesisUser` 的执行期差异。
- preview 只 quote，不锁定执行结果；执行时实际成交保护由入口参数负责：
  - `genesisByToken(...)` 的 token -> SY 阶段使用 `minSyOut`。
  - 路径 B 双入口（`genesisByToken`/`genesisBySY`）的 SY -> uAsset 阶段使用 `minUAssetMinted`。
  - `redeemSyToToken(...)` 的赎回阶段使用 `minTokenOut`。
  - 路径 A genesis 无下限参数（确定性数学，§7.1）。
  - `preview` 与执行期都以 mixed-decimals 可支持为目标，不把 `SY` canonical asset decimals 与 `uAsset` decimals 不同视为禁止配置；差异由归一化换算吸收。
- **零下限 = 无滑点保护（委托式设计）**：`minSyOut == 0` / `minTokenOut == 0` / `minUAssetMinted == 0` 时 router 层无任何强制，零值静默透传给 `SYBaseUpgradeable.sol::deposit`/`::redeem`（`IStandardizedYield.sol` 文档明示 `SYZeroSharesOut` 仅当 `minSharesOut` 为零时可观察到）与 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 的 `InsufficientUAssetMinted` 守卫，链上唯一兜底是零输出守卫——`amountSharesOut == 0` 才 revert；非零而被压低至任意小值的输出在零下限下静默通过。**集成要求**：调用方必须基于 `previewDeposit`/`previewRedeem`/`previewStake` 的链上 quote 计算非零下限（quote ± slippage），SDK/前端默认禁止零下限并监控三明治/池失衡口径；`0` 仅在显式接受无保护语义时使用。路径 A 不在此列——PSM 面值数学无滑点不确定性，无需下限。

## 9. 当前实现提醒

- genesis 路径 B 生成开放期限 CDP 仓位（`positionId`）：无 deadline、无到期门，owner 任意时刻可 redeem（v1 无清算）；不存在共享 wrap 池、keeper 或 harvest 面（已随 position 层重构删除），自由质押入口（`stakeFromToken`/`stakeFromSY`）亦随 v1 genesis-only 决策删除。
- genesis 双路径都是"把新供给 uAsset 原子地全额交给 launcher"：路径 A 经 PSM 储备铸出到 router（无仓位、无债务，router 侧后置断言）；路径 B（token/SY 双计价入口）由 SP 原生 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 开 CDP 仓并铸给 SP 自身（`genesisUser` 承担仓位债务，SP 侧后置断言），router 仅薄转发、路径 B 全程不触碰 uAsset（§7.3 分侧）。
- 定价语义：路径 B 面值（价值平价）铸出——两段 down 换算、无 LTV 缩放、无利率乘数（v1 无折扣机制），铸出量 = 抵押按汇率折算价值 × 100%，生息敞口 100% 留在抵押方；路径 A 无折扣，仅 `tin` 费率折减。参数语义与默认值真源为 `docs/spec/position/accounting.md` §6 与 `docs/spec/psm/peg-stability-module.md`。
- 任何 token / native 与 tokenOut 是否可用，最终都取决于具体 `SY` 实现的 `isValidTokenIn` / `isValidTokenOut`；路径 A 的 reserve 是否可用取决于该 (uAsset, reserveToken) 配对是否已登记其绑定该储备的 PSM 实例。
- 跨链边界：`OutrunStakingPositionUpgradeable.sol::redeem` 由 position owner 用在 position 所在链上的 uAsset 余额经 `OutrunUniversalAssetsUpgradeable.sol::repay` 销毁销债。
- OFT 跨链 `OutrunOFTUpgradeable.sol::_debit` / `::_credit` 只移动流通供应、不移动 minter 债务台账，因此用户把 uAsset 桥到其他链后，必须先把 uAsset 桥回（受 peer / outbound rate limit 配置约束）或在本地另行获取，才能用同一份 uAsset 走 `redeem` 销债；PSM 储备铸烧同样不触碰 minter 台账（`docs/spec/psm/peg-stability-module.md`）。销债可达性与出站限流的联动校准要求见 `docs/spec/protocol.md`「跨链可用性与限流」，PSM 储备消耗的监控与校准要求见 `docs/spec/psm/peg-stability-module.md`「储备消耗监控与校准」，部署侧操作清单见 `docs/deployment.md`「跨链限流（OFT Outbound Rate Limit）高危参数校验清单」。

## 10. Pause / unpause 对 router 入口的影响

router 自身没有 pause 管理能力，但 router 下游的 position、SY、uAsset 各自可被独立 pause（PSM 自身无 pause，其可用性受 uAsset 暂停与自身注册表/cap 约束）。以下矩阵描述三级 pause 下 6 个 router 状态变更入口的可用性与回退点；组件级 pause 机制以 `docs/spec/position/state-machines.md` §8 为准，本节只落 router 入口的映射，不重复 position 面内容。

三级 pause 的生效点（position / SY / uAsset 各自的函数级 `whenNotPaused` 与 `_update` 兜底，含跨链 inbound `_credit` 豁免）以 `docs/spec/position/state-machines.md` §8.1–§8.3 为准，本节不重复机制描述，只落 router 入口映射。

| router 入口 | position pause | SY pause | uAsset pause |
| --- | --- | --- | --- |
| `OutrunRouter.sol::mintSYFromToken` | 可用（不触 SP） | 在 `SYBaseUpgradeable.sol::deposit` 函数级 `whenNotPaused` 回退 | 可用（不触 uAsset mint） |
| `OutrunRouter.sol::redeemSyToToken` | 可用（不触 SP） | 非零额在开头 SY transferFrom 回退；零额在 `SYBaseUpgradeable.sol::redeem` 回退 | 可用（不触 uAsset mint/repay） |
| `OutrunRouter.sol::genesisByPSM`（路径 A） | 可用（不触 SP） | 可用（不触 SY） | 在 `OutrunUniversalAssetsUpgradeable.sol::reserveMint`（PSM 铸出步）回退；launcher 拉取 uAsset 的 transfer 另受 `_update` 兜底 |
| `OutrunRouter.sol::genesisBySY` / `OutrunRouter.sol::genesisByToken`（路径 B 双入口） | 在 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 回退（两入口同） | `genesisBySY` 在开头 SY transferFrom 回退；`genesisByToken` 在 `SYBaseUpgradeable.sol::deposit` 回退（token 拉款不经 SY） | 在 `OutrunUniversalAssetsUpgradeable.sol::mint` 回退（SP 铸出步）；launcher 拉取的 transfer 另受 `_update` 兜底（两入口同） |
| `OutrunRouter.sol::leveragedGenesisByPSM`（杠杆创世门） | 可用（不触 SP） | 可用（不触 SY） | 在 `OutrunUniversalAssetsUpgradeable.sol::reserveMint`（PSM 铸出步）回退；POLend 拉取 uAsset 的 transfer 另受 `_update` 兜底 |

反直觉格补充说明：

- `mintSYFromToken` 与 `redeemSyToToken` 不触 position 或 uAsset，因此 position pause 与 uAsset pause 期间仍可用；「可用」指不触 uAsset 的 mint/repay 表面，若某 SY adapter 支持 `tokenOut == uAsset`，uAsset `_update` 的 `whenNotPaused` 仍会在交付侧兜底。
- 路径 A 在 position pause 与 SY pause 期间仍可用：它不触 SP 与 SY，唯一暂停传导是 uAsset 级（`reserveMint` 铸出步与 launcher transfer 拉取步）。
- `redeemSyToToken` 在 SY pause 期间（非零额）的死点在 `OutrunRouter.sol::redeemSyToToken` 开头的 SY transferFrom（经 `OutrunERC20PausableUpgradeable.sol::_update` 的 `whenNotPaused`），而非 `SYBaseUpgradeable.sol::redeem`；只有零额输入（`TokenHelper.sol::_transferFrom` 跳过零额 transfer）才会到达 `::redeem` 的函数级 `whenNotPaused`。
- 路径 B 双入口在 SY pause 期间的死点不同：`genesisBySY` 死于开头 SY transferFrom（`OutrunERC20PausableUpgradeable.sol::_update` 的 `whenNotPaused`），`genesisByToken` 的 token 拉款不经 SY、死于 `SYBaseUpgradeable.sol::deposit` 函数级 `whenNotPaused`；position pause 与 uAsset pause 的死点两入口相同。
- 路径 A 的非 pause 可用性边界（同为 fail-closed，列出供运维对照；配对与双参错误即现状）：该配对未登记 → `UnregisteredPsm(uAsset, reserveToken)`；配对 PSM 绑定漂移 → `PsmBindingMismatch(psm, uAsset, actualUAsset)` / `PsmReserveMismatch(psm, reserveToken, actualReserveToken)`；uAsset owner 撤销该实例储备 minter 登记（`OutrunUniversalAssetsUpgradeable.sol::setReserveMinter(psm, false)`）→ `NotReserveMinter`（各实例独立 kill switch）；该实例净铸出将超 `stockCap` → `StockCapExceeded`；router 侧撤销 `psmForUAsset(uAsset, reserveToken, address(0))` → `UnregisteredPsm`。
- 杠杆创世门 `OutrunRouter.sol::leveragedGenesisByPSM` 的 pause 可用性边界与路径 A 同构：position pause 与 SY pause 期间仍可用（不触 SP 与 SY），uAsset pause 死点同路径 A（`OutrunUniversalAssetsUpgradeable.sol::reserveMint` 铸出步，POLend 拉取 transfer 另受 `_update` 兜底）；POLend 侧 `whenNotPaused` 为跨仓库独立暂停面，不经 OutStake 三级 pause 传导，POLend 入口暂停时以 `EnforcedPause` 原样透传（「杠杆创世门」节表第 8 行）；非 pause fail-closed 边界另含 `PolendNotSet` 与 `PolendMarketUAssetMismatch`（同节表第 3-4 行）。
- 上述「可用」与退出语义不改变 preview/view 入口的处理：对应 preview 不受 position/uAsset 级 pause 阻断的规则以 `docs/spec/position/state-machines.md` §8 为准。
- 回归说明：`genesisBySY`/`genesisByToken` 在 SY pause 期间的死点（SY transferFrom / `SYBaseUpgradeable.sol::deposit`）与 `mintSYFromToken`/`redeemSyToToken` 的 SY pause 死点在 `test/upgradeable/OutrunStakingPositionUpgradeable.t.sol::OutrunStakingPositionPauseMatrixTest` 的 SY 级场景已逐行回归（SP 侧 `stakeForGenesis` 同源）；router 本套件 `RouterMockSY` 为非 pause mock，未对该四 SY 入口以独立可暂停 SY 另行回归，属同族纯覆盖缺口，行为由 SY/uAsset `whenNotPaused` 与 `_update` 传导可读，无掩盖 bug。

## 11. 测试验收清单（T5 + token 入口恢复）

T5 与 token 入口恢复的测试/不变量以下列条目为验收基准（含任务书三面 + uint128 边界 + registry 校验；第 7-11 条为 token 入口恢复轮归属；第 12-13 条为 B 门薄转发降级新增；第 14 条为杠杆创世门新增）：

1. **路径 A roundtrip**：reserve（ERC20 与 NATIVE 两腿）→ `genesisByPSM` → launcher 收到全额 `amountOut`（== PSM 铸出额 == `uint128` 转发额）；调用者 reserve 扣减 == `amountIn`；`SwapMintForUAsset` 事件与 PSM 储备守恒式回归（`docs/spec/psm/peg-stability-module.md` 测试面）；quoteMint == mint 输出（确定性；dust 零输出域除外，quote 返 0 而执行 revert `ZeroInput`，见 `docs/spec/psm/peg-stability-module.md`「零输出守卫」）。
2. **路径 B roundtrip**：SY → `genesisBySY` → position 创建（`owner == genesisUser`、`principalDebt == mintedUAsset`、`lastRate` 为开仓时刻结算后快照）；launcher 收到全额 `mintedUAsset`；`Stake` + `StakeForGenesis` 事件字段核对。
3. **严格相等（路径 B 借出量 == genesis 消费量，SP 原生）**：`mintedUAsset == uint128 genesis 转发额 == SP 对 launcher 的精确 approve 额`；交易后 SP 的 uAsset 余额回到铸出前基线、SP 对 launcher 的 allowance == 0；路径 A 仍为 router 侧同构断言（router 余额回 PSM 铸出前基线、对 launcher 的 allowance == 0）；mock launcher 部分消费 / 转回 → `GenesisUAssetNotConsumed` 整笔回退（含 payload 字段口径：residualBalance 为相对各自基线超出量）。
4. **registry 校验回归**：
   - trustedSY/trustedSP 面不变：未登记 SP/SY → `UntrustedRouterTarget`，`SP.SY()` 漂移 → `RouterTargetMismatch`，校验时点在资金 pull 与 approve 之前（既有回归保持）。
   - PSM registry（配对与三参即现状）：未登记配对 → `UnregisteredPsm(uAsset, reserveToken)`；`setPsmForUAsset` 登记校验——零 `uAsset` → `UntrustedRouterTarget`（无 psm 代码校验）、uAsset 绑定不一致 → `PsmBindingMismatch(psm, uAsset, actualUAsset)`、储备绑定不一致 → `PsmReserveMismatch(psm, reserveToken, actualReserveToken)`；登记后 `psmForUAsset` getter 与 `PsmForUAssetUpdated` 事件核对；撤销 `setPsmForUAsset(uAsset, reserveToken, address(0))` 后该配对入口 fail-closed 且不影响其它配对；运行期任一绑定漂移（mock）→ 回退。
5. **uint128 边界**：铸出量 `> type(uint128).max` → `InvalidParam()`——路径 A 在 router 侧、路径 B 在 SP 侧（经 router 入口透传，mock 放大铸出量）；恰等于 `type(uint128).max` 可通过（上限 launcher mock）。
6. **滑点与原子性**：路径 B `mintedUAsset < minUAssetMinted` → `InsufficientUAssetMinted` 整笔回退（SP 侧检查、router 透传）；路径 A 无 minOut 参数且输出确定性（quoteMint == 执行；dust 零输出域除外，quote 返 0 而执行 revert `ZeroInput`，见 `docs/spec/psm/peg-stability-module.md`「零输出守卫」）；中途任一依赖 revert（PSM 入口、SP 入口、launcher）→ 整笔回滚——无 position、无 PSM 净铸出/储备转移、无残余 allowance、router 余额不变。
7. **路径 B token 入口恢复（`genesisByToken`）roundtrip（恢复轮）**：token（ERC20 与 NATIVE 两腿）→ `genesisByToken` → CDP 仓创建（`owner == genesisUser`、`principalDebt == mintedUAsset` 面值铸出）；genesis 消费 == 借出严格相等（SP 侧断言，§7.2/§7.2.1）；`IStandardizedYield.sol::Deposit` 与 `Stake`/`StakeForGenesis` 事件字段核对。
8. **token 入口与两步组合等价性（恢复轮）**：同输入同参数下 `genesisByToken` 与 `mintSYFromToken`（receiver = 调用者）+ `genesisBySY` 组合的铸出额、仓位字段、launcher 收额一致；组合路径保持可用（批量钱包单 tx），token 入口中间 `SY` 不经调用者账户。
9. **token 入口两级滑点下限（恢复轮）**：换换输出 `< minSyOut` → `SYInsufficientSharesOut` 整笔回退；`mintedUAsset < minUAssetMinted` → `InsufficientUAssetMinted` 整笔回退；两级各自独立生效（单独压低任一级即回退）。
10. **token 入口 registry 校验回归（恢复轮）**：未登记 SP/SY → `UntrustedRouterTarget`、`SP.SY()` 漂移 → `RouterTargetMismatch`，校验时点先于 token 拉款与 approve；NATIVE 腿 `msg.value != tokenAmount`、ERC20 腿 `msg.value != 0` → `NativeAmountMismatch()`。
11. **token 入口 uint128 边界（恢复轮）**：铸出量 `> type(uint128).max` → `InvalidParam()`（并入第 5 条 mock 放大口径，三入口各跑）。
12. **薄转发等价（router 入口 vs 直接调 SP）**：同输入同参数下 `OutrunRouter.sol::genesisBySY` / `::genesisByToken` 与直接调用 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 的铸出额、仓位字段（owner / `principalDebt`）、launcher 收额一致；router 路径 B 全程不持有 uAsset（router 的 uAsset 余额与 allowance 断言恒为不变）；SP 侧四类错误（`InsufficientUAssetMinted` / `InvalidParam` / `GenesisLauncherNotSet` / `GenesisUAssetNotConsumed`）经 router 入口原样透传。
13. **SP 侧物理门与布线**：成功后 SP 的 uAsset 余额恒等于调用前（mint→consume 闭环）；mock launcher 部分消费 / 转回 → `GenesisUAssetNotConsumed` 整笔回退（无仓位、无铸出）；launcher revert → 无仓位、无 mint；`GenesisLauncherNotSet`（SP 侧 `genesisLauncher == 0`）先于资金移动；部署布线验收——`GENESIS_LAUNCHER` env 与 `SP.genesisLauncher() == router.memeverseLauncher()` 同址断言（`test/upgradeable/OutstakeScriptMockSYDeploy.t.sol`；SP/Router 侧行为面另见 `test/upgradeable/OutrunStakingPositionUpgradeable.t.sol` 与 `test/upgradeable/OutrunRouterUpgradeable.t.sol`）。
14. **杠杆创世门 roundtrip（`leveragedGenesisByPSM`）**：reserve（ERC20 与 NATIVE 两腿）→ `leveragedGenesisByPSM` → POLend mock 恰额拉走 `amountOut`（== PSM 铸出额）作为利息并记账 `genesisUser`（payer = router 无记账）、`borrowedAmount` 原样转发（mock 记录）；调用者 reserve 扣减 == `amountIn`；router 的 uAsset 余额回铸出前基线、对 `polend` 的 allowance == 0（spender = `polend` 的 `GenesisUAssetNotConsumed` 断言；partial-consumption mock → 整笔回退）；错误面——`UnregisteredPsm` / 绑定漂移（`PsmBindingMismatch` / `PsmReserveMismatch`）/ `PolendNotSet` / `PolendMarketUAssetMismatch(verseId, uAsset, marketUAsset)`（配对错配 mock 与未注册 verse 读零两路径）/ 零 `genesisUser` → `ZeroInput` / `NativeAmountMismatch`（两腿 value 规则）；配置面——`SetPolend(oldPolend, newPolend)` 事件与 `polend` getter 核对。
