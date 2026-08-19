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
- router 的 `setTrustedSY(address,bool)` 与 `setTrustedSP(address,address)` 是 owner-only 的 pre-mainnet 目标登记入口（`OutrunRouter.sol::setTrustedSY`、`OutrunRouter.sol::setTrustedSP`、`IOutrunRouter.sol::setTrustedSY`、`IOutrunRouter.sol::setTrustedSP`）。`setTrustedSY` 启用前要求目标为有代码的合约；`setTrustedSP` 的非零 SY 必须已登记且等于 `SP.SY()`。`TrustedSYUpdated` 与 `TrustedSPUpdated` 记录配置变化，`setTrustedSP(SP,address(0))` 和禁用 SY 都可撤销后续调用权限。
- `OutrunRouter.sol::mintSYFromToken` 与 `OutrunRouter.sol::redeemSyToToken` 先检查 `OutrunRouter.sol::trustedSY`；所有 SP preview、stake、wrap stake 与 genesis 入口先检查 `OutrunRouter.sol::trustedSYForSP` 并重检 `SP.SY()`。这些检查都发生在用户资产 `transferFrom`、token pull 或下游 `approve` 之前；未注册 target 回退 `IOutrunRouter.sol::UntrustedRouterTarget`，pair 漂移回退 `IOutrunRouter.sol::RouterTargetMismatch`。
- `OutrunRouter.sol::setTrustedSY(SY, false)` 不会自动清除已有的 `trustedSYForSP` mapping，撤销流程应另行调用 `OutrunRouter.sol::setTrustedSP(SP, address(0))` 并核对 `trustedSY` / `trustedSYForSP` getter；撤销只阻断后续 router 调用，不改变既有 position、uAsset debt 或 SY share state。
- 主网前完成最终 SY 清单和 SP -> SY pair 清单，核对事件/getter 后冻结并移除这些临时 owner setter；主网运行不依赖运行期新增、替换或撤销 target。
- router 的 `setMemeverseLauncher(address)` 是 pre-mainnet 临时 owner 入口（`OutrunRouter.sol::setMemeverseLauncher`、`IOutrunRouter.sol::setMemeverseLauncher`）；成功轮换发出 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）；该事件已落地（`IOutrunRouter.sol` 声明、`OutrunRouter.sol::_setMemeverseLauncher` emit；constructor 部署期同样经该路径首发 `SetMemeverseLauncher(address(0), launcher)`，`oldLauncher` 为零初值）；主网部署时随 owner 权限面一并移除
- oracle adapter 不拥有 proxy upgrade 权限
- uAsset（`OutrunUniversalAssetsUpgradeable` 含完整继承链）owner 入口分为四组，均为 owner-only：
  - 铸造面：`setMintingCap`、`revokeMinter`、`transferMinterDebt`
  - 暂停面：`pause`、`unpause`
  - 跨链限流：`setOutboundRateLimit`、`removeOutboundRateLimit`（逐链出站限额）
  - LayerZero OApp 跨链配置：`setPeer`、`setDelegate`、`setMsgInspector`、`setEnforcedOptions`、`setPreCrime`
  - 注：`setPeer` 与出站限额是部署流程的生产必经路径；该路径当前经 `OutstakeScript.s.sol::run` 中被注释的 `_deployUETH` / `_deployUUSD` / `_deployUBNB` 到达，启用时按需解除注释
- SY 赎回授权面：每个 `SYBaseUpgradeable.sol` 实例维护一个 `trustedRouter` 地址。owner 通过 `SYBaseUpgradeable.sol::setTrustedRouter` 设置或替换；初始值为零地址，零地址表示暂未配置且 `burnFromInternalBalance=true` 全部拒绝。`SYBaseUpgradeable.sol::trustedRouter` 提供当前值，`SetTrustedRouter(address indexed oldRouter, address indexed newRouter)` 记录轮换；设置零地址可撤销旧 router。`SYBaseUpgradeable.sol::redeem` 在调用 adapter `_redeem` 前检查 caller，非当前 trusted router 使用 `true` 回退 `SYUnauthorizedInternalRedeemer(address caller)`；`false` 仍由 caller 直接赎回。

UUPS 边界：

- `OutrunUniversalAssetsUpgradeable` 由 owner 授权升级
- `OutrunStakingPositionUpgradeable` 由 owner 授权升级
- `SYBaseUpgradeable` 为所有 SY adapters 提供 UUPS authority
- 所有 SY adapter 经 `SYBaseUpgradeable` 继承 `OutrunERC20PausableUpgradeable`，owner 因此拥有 `pause`/`unpause`（经 `_update` 的 `whenNotPaused` 阻断 transfer/mint/burn，叠加 deposit/redeem 的 `whenNotPaused`，可一键停摆全部 SY 转账/铸造/销毁/存入/赎回）；oracle-backed SY upgradeable variants 另有 owner-only `setExchangeRateOracle(address)`

## 重要结果

- `uAsset` 铸造面 owner 入口为 `setMintingCap`、`revokeMinter`、`transferMinterDebt`，完整权限面见「权限模型」
- position 的 `setMinStake`、`setRevenuePool`、`setKeeper`、`pause`、`unpause`、`harvestWrapYield` 仍是 owner 权限；行为语义见 `docs/spec/position/state-machines.md` §7/§8
- router、SY、position 的公开入口都仍受 allowance、余额、pause 与下游校验约束；router 的 target registry 校验在用户资金转移和精确 approve 前执行，降低误配或钓鱼地址造成的自损面
