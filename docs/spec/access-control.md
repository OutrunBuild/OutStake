# Access Control

## 目标

本文只基于当前 upgradeable 真源整理权限边界：

- `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`
- `src/psm/OutrunPSMUpgradeable.sol`（随 T1 落地）
- `src/psm/interfaces/IPSM.sol`（随 T1 落地）
- `src/usr/OutrunUSRVaultUpgradeable.sol`（随 T3 落地）
- `src/position/OutrunStakingPositionUpgradeable.sol`
- `src/router/OutrunRouter.sol`
- `src/yield/SYBaseUpgradeable.sol`
- `src/assets/base/OutrunERC20PausableUpgradeable.sol`
- `src/yield/OutrunL2OracleBackedSYUpgradeable.sol`
- `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`

## 权限模型

- protocol owner 是 multisig（部署期 owner 取值约束见 `docs/deployment.md`「关键约束」），主网前按 `docs/deployment.md`「治理操作 timelock 评估提示」收敛为 timelock/multisig（timelock 为产品合约外的治理层，owner 地址形态，产品合约不依赖其实现）
- 产品合约内不引入 timelock（治理机器不进产品继承链）
- 不引入额外 governance module
- router owner 面（权限归属一览；完整语义、事件与撤销/轮换流程见 `docs/spec/router/router-and-user-flows.md` §1.2/§7.4/§7.5/§7.6）：
  - `setTrustedSY(address,bool)`、`setTrustedSP(address,address)`、`setPsmForUAsset(address,address,address)`、`sweep(address,address,uint256)` 均为 owner-only、持续 live 的动态能力（`Ownable`，产品外 multisig 治理，产品合约内不设 timelock），不随主网上线冻结移除。`OutrunRouter.sol::setMemeverseLauncher` 不在该 live 集合内——生产 launcher 冻结为 immutable（仅经 constructor 布线，换 launcher 即重部署 router），该 setter 在部署/测试期为 live owner-only（轮换须与每 SP 的 OutrunStakingPositionUpgradeable.sol::setGenesisLauncher 同一治理事务原子执行），生产删除。`OutrunRouter.sol::setPolend`（杠杆创世门 POLend 目标登记）同款不在 live 集合内——生产 POLend 冻结为 immutable（仅经 constructor 布线，换 POLend 即重部署 router），该 setter 在部署/测试期为 live owner-only（无零地址/代码校验，`IOutrunRouter.sol::SetPolend` 记录轮换；运行期 `polend == address(0)` fail-closed 回退 `IOutrunRouter.sol::PolendNotSet`），生产删除；完整语义见 `docs/spec/router/router-and-user-flows.md` §1.2 与「杠杆创世门」节。
  - `setTrustedSY` 启用为纯 allowlist（owner 治理职责，EOA 可登记，完整语义见 `docs/spec/router/router-and-user-flows.md` §1.2）；`setTrustedSP` 的非零 SY 必须已登记且等于 `SP.SY()`；`setPsmForUAsset` 登记非零 PSM 前要求 `uAsset` 非零且 `IPSM(psm).uAsset() == uAsset`（绑定一致性；PSM 绑定 init 后无 setter，登记期检查稳定，运行期每次调用复读比对，完整语义见 `docs/spec/router/router-and-user-flows.md` §1.2.1）；纯 allowlist 路径接受 EOA 为 owner 治理结果，绑定检查路径对无代码地址仍经绑定读取回退（底层调用/解码错误，非代码门）；`sweep` 为脱困回收（零地址/零额回退，`NATIVE` sentinel 可转出，无 per-token blocklist 为有意设计）。
  - registry 校验在用户资产 `transferFrom`、token pull 与精确 approve 之前执行；未登记 target 回退 `IOutrunRouter.sol::UntrustedRouterTarget`，SP pair 漂移回退 `IOutrunRouter.sol::RouterTargetMismatch`，PSM 未登记回退 `IOutrunRouter.sol::UnregisteredPsm`、绑定漂移回退 `IOutrunRouter.sol::PsmBindingMismatch`。
- oracle adapter 不拥有 proxy upgrade 权限
- uAsset（`OutrunUniversalAssetsUpgradeable` 含完整继承链）owner 入口分为四组，均为 owner-only（当前无 `sweep` 为有意设计，未来若新增必须 `onlyOwner nonReentrant` 经 timelock/multisig 且在 `TokenHelper::_transferOut` 前对 `token == address(this)`/`SY`/`NATIVE` 阻断，否则移动 `balanceOf` 不回写 `amountInMinted` 破坏跨账本不变量）：
  - 铸造面：`setMintingCap`、`revokeMinter`、`transferMinterDebt`、`setReserveMinter`（储备 minter 登记/撤销，为储备铸烧路径的 kill switch，语义见 `docs/spec/psm/peg-stability-module.md`）
  - 暂停面：`pause`、`unpause`
  - 跨链限流：`setOutboundRateLimit`、`removeOutboundRateLimit`（逐链出站限额）
  - LayerZero OApp 跨链配置（均为 `OutrunOFTUpgradeable.sol` 经 `OFTCoreUpgradeable.sol`/`OAppUpgradeable.sol` 继承的 src OFT 合约 `onlyOwner` 入口，配置关联 LayerZero endpoint，其中仅 `OAppCoreUpgradeable.sol::setDelegate` 转发至 `endpoint`，其余为 OApp 本地存储）：`OutrunOFTUpgradeable.sol::setPeer`（`OAppCoreUpgradeable.sol::setPeer`）、`OutrunOFTUpgradeable.sol::setDelegate`（`OAppCoreUpgradeable.sol::setDelegate`）、`OutrunOFTUpgradeable.sol::setMsgInspector`（`OFTCoreUpgradeable.sol::setMsgInspector`）、`OutrunOFTUpgradeable.sol::setEnforcedOptions`（`OAppOptionsType3Upgradeable.sol::setEnforcedOptions`）、`OutrunOFTUpgradeable.sol::setPreCrime`（`OAppPreCrimeSimulatorUpgradeable.sol::setPreCrime`）
  - 注：`setPeer` 与出站限额是部署流程的生产必经路径；该路径当前经 `OutstakeScript.s.sol::run` 中被注释的 `_deployUETH` / `_deployUUSD` / `_deployUBNB` 到达，启用时按需解除注释
- SY 赎回授权面：每个 `SYBaseUpgradeable.sol` 实例维护一个 `trustedRouter` 地址。owner 通过 `SYBaseUpgradeable.sol::setTrustedRouter` 设置或替换；初始值为零地址，零地址表示暂未配置且 `burnFromInternalBalance=true` 全部拒绝。`SYBaseUpgradeable.sol::trustedRouter` 提供当前值，`SetTrustedRouter(address indexed oldRouter, address indexed newRouter)` 记录轮换；设置零地址可撤销旧 router。`SYBaseUpgradeable.sol::redeem` 在调用 adapter `_redeem` 前检查 caller，非当前 trusted router 使用 `true` 回退 `SYUnauthorizedInternalRedeemer(address caller)`；`false` 仍由 caller 直接赎回。
- SY 脱困回收面：每个 `SYBaseUpgradeable.sol` 实例的 `sweep(address,address,uint256)` 是 owner-only 脱困回收（`SYBaseUpgradeable.sol::sweep`），`onlyOwner nonReentrant`（`ReentrancyGuardTransient` 经 `TokenHelper`），`yieldBearingToken()` 与 `address(this)`（SY 份额自身）以 `SYSweepInvalidToken` 阻断分别保护份额背书与 router 待烧份额，`to == address(0)` / `amount == 0` 分别以 `SYSweepZeroAddress` / `SYSweepZeroAmount` 回退，经 `TokenHelper::_transferOut` 支持 `NATIVE` sentinel（`address(0)`）的 ERC20/native 转出并发 `Sweep(address indexed token,address indexed to,uint256 amount)` 事件（见 `SYBaseUpgradeable.sol::sweep` 与 `docs/spec/yield/yield-adapters.md` 错误与事件边界）。
- PSM owner 面（UUSD 两实例 + UETH/UBNB 各一、共四实例，owner 部署期绑定）：`OutrunPSMUpgradeable.sol::setFees`（边界 0 ≤ fee ≤ 1%）、`OutrunPSMUpgradeable.sol::setStockCap`（恒 > 0）与 UUPS 升级权均为 owner-only；PSM 自身不设 pause、无 owner 提取面，owner 仅参数面；计费结余提取 `OutrunPSMUpgradeable.sol::sweepFees` 为无许可公开入口（任何人可调，对标 dss-psm `kick()`），接收方为部署期 initialize 绑定后 immutable 的 `feeRecipient`（非零校验、无 setter，运行期不可变更）。公开兑换面无许可：`OutrunPSMUpgradeable.sol::mint` / `OutrunPSMUpgradeable.sol::redeem` 任何人可调，受绑定储备、费率、cap 与 uAsset 暂停（fail-closed）约束；完整语义见 `docs/spec/psm/peg-stability-module.md`。
- USR owner 面（每个 uAsset 族一个 `OutrunUSRVaultUpgradeable` 实例，部署期绑定该族 uAsset 资产地址与 suToken name/symbol）：`OutrunUSRVaultUpgradeable.sol::fund`（owner 注资，经 approve 拉入真实 uAsset、不铸份额、只进不出）与 `OutrunUSRVaultUpgradeable.sol::setUsrRate`（族利率，`newRate ≤ 1e17` 直接指定，上线默认 0）均为 owner-only；无 sweep、无回收函数、无自有 pause（uAsset 暂停经资产转账传导为 fail-closed），owner 仅注资与利率参数面。ERC4626 公开面无许可：`OutrunUSRVaultUpgradeable.sol::deposit` / `::mint` / `::withdraw` / `::redeem` 及 preview/max/convertTo 族任何人可调，受余额封顶与 uAsset 暂停约束；完整语义见 `docs/spec/usr/usr-vaults.md`。
- position owner 面（已落地，随 v1 变更一并落地；每个 SY 及其对应 uAsset 一个 `OutrunStakingPositionUpgradeable` 实例）：参数 setter 族 `OutrunStakingPositionUpgradeable.sol::setDuty`（接受域 `[1e27, DUTY_CAP]`（`DUTY_CAP` 年化 15% 等效每秒率）、`duty < 1e27` 以 `ZeroInput` 拒绝、`1e27` 零费哨兵合法且为 v1 默认、分段生效）、`::setGenesisLauncher`（接受任意地址含零；零＝禁用 `stakeForGenesis` 入口的 kill switch，非 initialize 参数、部署后布线）、`::setMinStake`（恒 > 0）、`::setProtocolTreasury`（非零地址，利息腿唯一去向——v1 零费下恒 0 腿，参数保留供未来加息）与 `pause`/`unpause`、UUPS 升级权均为 owner-only；原 `setMintLtv`/`setLiquidationLtv`/`setLiquidationPremium`/`setGenesisRateMultiplier` 随 v1 无 LTV/无清算/零折扣决策删除；无 keeper、无 harvest、无 revenuePool 入口。经 uAsset 侧的 owner 权限（`setMintingCap`/`revokeMinter`/`transferMinterDebt`）见上文 uAsset owner 面。约束数值语义见 `docs/spec/position/accounting.md` §6，setter 状态机见 `docs/spec/position/state-machines.md` §6。

UUPS 边界：

- `OutrunUniversalAssetsUpgradeable` 由 owner 授权升级
- `OutrunStakingPositionUpgradeable` 由 owner 授权升级
- `SYBaseUpgradeable` 为所有 SY adapters 提供 UUPS authority
- `OutrunPSMUpgradeable` 由 owner 授权升级（UUSD 两实例 + UETH/UBNB 各一、共四实例）
- `OutrunUSRVaultUpgradeable` 由 owner 授权升级（每个 uAsset 族一个实例）
- 所有 SY adapter 经 `SYBaseUpgradeable` 继承 `OutrunERC20PausableUpgradeable`，owner 因此拥有 `pause`/`unpause`（经 `_update` 的 `whenNotPaused` 阻断 transfer/mint/burn，叠加 deposit/redeem 的 `whenNotPaused`，可一键停摆全部 SY 转账/铸造/销毁/存入/赎回）；oracle-backed SY upgradeable variants 另有 owner-only `setExchangeRateOracle(address)` / `resetRateAnchor()`（锚点重置至当前 oracle 读数，不能注入任意值）/ `setRateBreakerParams(uint16,uint16,uint16)`（带宽调整），及 permissionless `commitRateAnchor()`（仅带内推进锚点）

## 重要结果

- `uAsset` 铸造面 owner 入口为 `setMintingCap`、`revokeMinter`、`transferMinterDebt`、`setReserveMinter`，完整权限面见「权限模型」
- PSM 的 `setFees`、`setStockCap` 与 UUPS 升级为 owner 权限；`mint`/`redeem` 为无许可公开入口，双向兑换经 uAsset 储备铸烧路径完成；计费结余提取 `sweepFees` 亦为无许可公开入口，接收方 deploy 期 immutable 绑定；行为语义见 `docs/spec/psm/peg-stability-module.md`
- USR 的 owner 入口仅 `OutrunUSRVaultUpgradeable.sol::fund` 与 `OutrunUSRVaultUpgradeable.sol::setUsrRate`（加 UUPS 升级权），无 sweep、无回收函数、无自有 pause，入池资金仅存款人可经 ERC4626 提款取出；`deposit`/`mint`/`withdraw`/`redeem` 为无许可公开入口；行为语义见 `docs/spec/usr/usr-vaults.md`
- position 的 owner 入口（已落地，随 v1 变更一并落地）为参数 setter 族 `setDuty`/`setGenesisLauncher`/`setMinStake`/`setProtocolTreasury` 加 `pause`/`unpause` 与 UUPS 升级权；原 `setMintLtv`/`setLiquidationLtv`/`setLiquidationPremium`/`setGenesisRateMultiplier` setter 族随 v1 无 LTV/无清算/零折扣决策删除（`setBorrowRate` 更名 `setDuty`）；`setMintingCap`/`revokeMinter`/`transferMinterDebt` 经 uAsset owner 面行使；无 keeper、无 harvest、无 revenuePool 入口；行为语义见 `docs/spec/position/state-machines.md` §6/§8
- position 的用户面（已落地，随 v1 变更一并落地）：`OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 无许可（v1 唯一铸造入口，任何人可开 genesis 仓——面值（价值平价）铸出，SP 物理门控：铸出 uAsset 交易内全额交 launcher，后置断言强制全额消费；自由借贷入口 `stake` 随 v1 genesis-only 决策删除）；`OutrunStakingPositionUpgradeable.sol::redeem` 仅 position owner（`onlyPositionOwner`，无到期门）；preview/view 族公开；v1 无清算面（`liquidate`/`claimCollSurplus` 随无清算决策删除）
- router、SY、position 的公开入口都仍受 allowance、余额、pause 与下游校验约束；router 的 target registry 校验在用户资金转移和精确 approve 前执行，降低误配或钓鱼地址造成的自损面；router 公开面含 genesis 双路径三入口 `OutrunRouter.sol::genesisByPSM`（PSM 门，reserve token 进、无仓位）与 CDP 门 B 门双入口 `OutrunRouter.sol::genesisByToken`（token 进先换 SY）与 `OutrunRouter.sol::genesisBySY`（SY 进）——两者均为薄转发便利层，转发至 SP 原生 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（面值铸出、SP 侧错误透传；任意 EOA/合约可直调 SP，router 非必经），均为无许可入口，registry 校验先于资金移动，滑点下限按入口分列（节号指 `docs/spec/router/router-and-user-flows.md`）：`genesisByToken` 两级 `minSyOut`/`minUAssetMinted`（§7.2.1）、`genesisBySY` 仅 `minUAssetMinted`（§7.2）、`genesisByPSM` 无下限参数（PSM 面值确定性数学，§7.1）；自由质押入口（`stakeFromToken`/`stakeFromSY`）随 v1 genesis-only 决策删除；完整行为见 `docs/spec/router/router-and-user-flows.md` §6/§7
