# Access Control

## 目标

本文只基于当前 upgradeable 真源整理权限边界：

- `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`
- `src/position/OutrunStakingPositionUpgradeable.sol`
- `src/router/OutrunRouter.sol`
- `src/yield/SYBaseUpgradeable.sol`
- `src/assets/base/OutrunERC20PausableUpgradeable.sol`
- `src/yield/OutrunL2OracleBackedSYUpgradeable.sol`
- `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`

## 权限模型

- protocol owner 是 multisig（部署期 owner 约束按脚本区分：`OutstakeScript.s.sol` 系强制 `OWNER` 等于广播者 EOA、部署完成后 `transferOwnership` 转交 multisig；`YieldDeployScript.s.sol` 系无此 `OWNER == 广播者` 约束、`OWNER` 可直接设为终态 multisig；详见 `docs/deployment.md`「关键约束」）
- 不引入 timelock
- 不引入额外 governance module
- router 的 `setTrustedSY(address,bool)` 与 `setTrustedSP(address,address)` 是 owner-only 的持续 live 目标登记入口（动态新增，产品外 multisig 治理）（`OutrunRouter.sol::setTrustedSY`、`OutrunRouter.sol::setTrustedSP`、`IOutrunRouter.sol::setTrustedSY`、`IOutrunRouter.sol::setTrustedSP`）。`setTrustedSY` 启用前要求目标为有代码的合约；`setTrustedSP` 的非零 SY 必须已登记且等于 `SP.SY()`。`TrustedSYUpdated` 与 `TrustedSPUpdated` 记录配置变化，`setTrustedSP(SP,address(0))` 和禁用 SY 都可撤销后续调用权限。
- `OutrunRouter.sol::mintSYFromToken` 与 `OutrunRouter.sol::redeemSyToToken` 先检查 `OutrunRouter.sol::trustedSY`；所有 SP preview、stake、wrap stake 与 genesis 入口先检查 `OutrunRouter.sol::trustedSYForSP` 并重检 `SP.SY()`。这些检查都发生在用户资产 `transferFrom`、token pull 或下游 `approve` 之前；未注册 target 回退 `IOutrunRouter.sol::UntrustedRouterTarget`，pair 漂移回退 `IOutrunRouter.sol::RouterTargetMismatch`。
- `OutrunRouter.sol::setTrustedSY(SY, false)` 不会自动清除已有的 `trustedSYForSP` mapping，撤销流程应另行调用 `OutrunRouter.sol::setTrustedSP(SP, address(0))` 并核对 `trustedSY` / `trustedSYForSP` getter；撤销只阻断后续 router 调用，不改变既有 position、uAsset debt 或 SY share state。
- 首批 SY/SP 清单部署后核对事件/getter，后续运行期仍支持经 `OutrunRouter.sol::setTrustedSY`/`setTrustedSP` 动态新增、撤销或替换，由 `Ownable`（产品外 multisig）持续管控，不在主网上线时冻结移除。
- router 的 `setMemeverseLauncher(address)` 是 owner 入口（`OutrunRouter.sol::setMemeverseLauncher`、`IOutrunRouter.sol::setMemeverseLauncher`），产品外经 `Ownable`（multisig）管控、产品合约内不设 timelock；成功轮换发出 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）；该事件已落地（`IOutrunRouter.sol` 声明、`OutrunRouter.sol::_setMemeverseLauncher` emit；constructor 部署期同样经该路径首发 `SetMemeverseLauncher(address(0), launcher)`，`oldLauncher` 为零初值）；仅当 launcher 终态确定时可考虑改为 `immutable`，否则保持 live
- router 的 `sweep(address,address,uint256)` 是 owner-only 脱困回收（`OutrunRouter.sol::sweep`、`IOutrunRouter.sol::sweep`），`onlyOwner nonReentrant`（`ReentrancyGuardTransient` 经 `TokenHelper`），零地址回退 `IOutrunRouter.sol::SweepZeroAddress`、零额回退 `IOutrunRouter.sol::SweepZeroAmount`，经 `TokenHelper::_transferOut` 支持 `NATIVE` sentinel（`address(0)`）的 ERC20/native 转出并发 `IOutrunRouter.sol::Sweep` 事件；无 per-token blocklist 为有意设计——路由器无背书资产、背书资产（`SY`）余额仅在 `_mintSY` 到 `SP.stake/wrapStake/genesis` 同一交易瞬态内出现，上界约单笔 `tokenIn` 量；第三方直接转入的无背书 token/`uAsset` dust 可跨交易存留，不进入 genesis 后置断言域，由 owner 经 `OutrunRouter.sol::sweep` 回收；该入口与 `setTrustedSY`/`setTrustedSP`/`setMemeverseLauncher` 同为持续 live 的动态能力，由 `Ownable`（产品外 multisig）管控、产品合约内不设 timelock（见 `docs/spec/router/router-and-user-flows.md` §1.1/§1.2/§7.6）
- oracle adapter 不拥有 proxy upgrade 权限
- uAsset（`OutrunUniversalAssetsUpgradeable` 含完整继承链）owner 入口分为四组，均为 owner-only（当前无 `sweep` 为有意设计，未来若新增必须 `onlyOwner nonReentrant` 经 timelock/multisig 且在 `TokenHelper::_transferOut` 前对 `token == address(this)`/`SY`/`NATIVE` 阻断，否则移动 `balanceOf` 不回写 `amountInMinted` 破坏跨账本不变量）：
  - 铸造面：`setMintingCap`、`revokeMinter`、`transferMinterDebt`
  - 暂停面：`pause`、`unpause`
  - 跨链限流：`setOutboundRateLimit`、`removeOutboundRateLimit`（逐链出站限额）
  - LayerZero OApp 跨链配置（均为 `OutrunOFTUpgradeable.sol` 经 `OFTCoreUpgradeable.sol`/`OAppUpgradeable.sol` 继承的 src OFT 合约 `onlyOwner` 入口，配置关联 LayerZero endpoint，其中仅 `OAppCoreUpgradeable.sol::setDelegate` 转发至 `endpoint`，其余为 OApp 本地存储）：`OutrunOFTUpgradeable.sol::setPeer`（`OAppCoreUpgradeable.sol::setPeer`）、`OutrunOFTUpgradeable.sol::setDelegate`（`OAppCoreUpgradeable.sol::setDelegate`）、`OutrunOFTUpgradeable.sol::setMsgInspector`（`OFTCoreUpgradeable.sol::setMsgInspector`）、`OutrunOFTUpgradeable.sol::setEnforcedOptions`（`OAppOptionsType3Upgradeable.sol::setEnforcedOptions`）、`OutrunOFTUpgradeable.sol::setPreCrime`（`OAppPreCrimeSimulatorUpgradeable.sol::setPreCrime`）
  - 注：`setPeer` 与出站限额是部署流程的生产必经路径；该路径当前经 `OutstakeScript.s.sol::run` 中被注释的 `_deployUETH` / `_deployUUSD` / `_deployUBNB` 到达，启用时按需解除注释
- SY 赎回授权面：每个 `SYBaseUpgradeable.sol` 实例维护一个 `trustedRouter` 地址。owner 通过 `SYBaseUpgradeable.sol::setTrustedRouter` 设置或替换；初始值为零地址，零地址表示暂未配置且 `burnFromInternalBalance=true` 全部拒绝。`SYBaseUpgradeable.sol::trustedRouter` 提供当前值，`SetTrustedRouter(address indexed oldRouter, address indexed newRouter)` 记录轮换；设置零地址可撤销旧 router。`SYBaseUpgradeable.sol::redeem` 在调用 adapter `_redeem` 前检查 caller，非当前 trusted router 使用 `true` 回退 `SYUnauthorizedInternalRedeemer(address caller)`；`false` 仍由 caller 直接赎回。
- SY 脱困回收面：每个 `SYBaseUpgradeable.sol` 实例的 `sweep(address,address,uint256)` 是 owner-only 脱困回收（`SYBaseUpgradeable.sol::sweep`），`onlyOwner nonReentrant`（`ReentrancyGuardTransient` 经 `TokenHelper`），`yieldBearingToken()` 与 `address(this)`（SY 份额自身）以 `SYSweepInvalidToken` 阻断分别保护份额背书与 router 待烧份额，`to == address(0)` / `amount == 0` 分别以 `SYSweepZeroAddress` / `SYSweepZeroAmount` 回退，经 `TokenHelper::_transferOut` 支持 `NATIVE` sentinel（`address(0)`）的 ERC20/native 转出并发 `Sweep(address indexed token,address indexed to,uint256 amount)` 事件（见 `src/yield/SYBaseUpgradeable.sol:35,38-40,59-71` 与 `docs/spec/yield/yield-adapters.md` 错误与事件边界）。

UUPS 边界：

- `OutrunUniversalAssetsUpgradeable` 由 owner 授权升级
- `OutrunStakingPositionUpgradeable` 由 owner 授权升级
- `SYBaseUpgradeable` 为所有 SY adapters 提供 UUPS authority
- 所有 SY adapter 经 `SYBaseUpgradeable` 继承 `OutrunERC20PausableUpgradeable`，owner 因此拥有 `pause`/`unpause`（经 `_update` 的 `whenNotPaused` 阻断 transfer/mint/burn，叠加 deposit/redeem 的 `whenNotPaused`，可一键停摆全部 SY 转账/铸造/销毁/存入/赎回）；oracle-backed SY upgradeable variants 另有 owner-only `setExchangeRateOracle(address)`

## 重要结果

- `uAsset` 铸造面 owner 入口为 `setMintingCap`、`revokeMinter`、`transferMinterDebt`，完整权限面见「权限模型」
- position 的 `setMinStake`、`setRevenuePool`、`setKeeper`、`pause`、`unpause`、`harvestWrapYield` 仍是 owner 权限；行为语义见 `docs/spec/position/state-machines.md` §7/§8
- position 的 `OutrunStakingPositionUpgradeable.sol::keepRedeem` / `OutrunStakingPositionUpgradeable.sol::keepWrapRedeem` 仅 `OutrunStakingPositionUpgradeable.sol::keeper` 可调用（`OutrunStakingPositionUpgradeable.sol::keepRedeem` / `OutrunStakingPositionUpgradeable.sol::keepWrapRedeem` 以 `keeper()` 比对 `msg.sender`，非 keeper 回退 `PermissionDenied`），与 `OutrunStakingPositionUpgradeable.sol::harvestWrapYield` 的 `onlyOwner` 形成刻意职责分离：keeper 负责到期仓位/共享池清算，owner 负责收割超额收益至 `revenuePool`；keeper 无收割权，owner 无清算权。该分区为故意设计，非缺陷；owner 需自行清算时可先 `OutrunStakingPositionUpgradeable.sol::setKeeper` 设为自身再调用 `keep*`，但不应给 keeper 赋予 `harvestWrapYield` 权限（收益目标与 `minTokenOut` 需仅由 owner 控制，见 `docs/spec/position/state-machines.md` §7.2）。部署布线见 `docs/deployment.md`「Keeper/Harvest 权限分区与活性布线」节
- router、SY、position 的公开入口都仍受 allowance、余额、pause 与下游校验约束；router 的 target registry 校验在用户资金转移和精确 approve 前执行，降低误配或钓鱼地址造成的自损面
