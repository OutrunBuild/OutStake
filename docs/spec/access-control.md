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
- router 仍只有 `setMemeverseLauncher(address)` owner 入口
- oracle adapter 不拥有 proxy upgrade 权限
- uAsset（`OutrunUniversalAssetsUpgradeable` 含完整继承链）owner 入口分为四组，均为 owner-only：
  - 铸造面：`setMintingCap`、`revokeMinter`、`transferMinterDebt`
  - 暂停面：`pause`、`unpause`
  - 跨链限流：`setOutboundRateLimit`、`removeOutboundRateLimit`（逐链出站限额）
  - LayerZero OApp 跨链配置：`setPeer`、`setDelegate`、`setMsgInspector`、`setEnforcedOptions`、`setPreCrime`
  - 注：`setPeer` 与出站限额是部署流程的生产必经路径
- SY 赎回授权面：每个 `SYBaseUpgradeable.sol` 实例维护一个 `trustedRouter` 地址。owner 通过 `SYBaseUpgradeable.sol::setTrustedRouter` 设置或替换；初始值为零地址，零地址表示暂未配置且 `burnFromInternalBalance=true` 全部拒绝。`SYBaseUpgradeable.sol::trustedRouter` 提供当前值，`SetTrustedRouter(address indexed oldRouter, address indexed newRouter)` 记录轮换；设置零地址可撤销旧 router。`SYBaseUpgradeable.sol::redeem` 在调用 adapter `_redeem` 前检查 caller，非当前 trusted router 使用 `true` 回退 `SYUnauthorizedInternalRedeemer(address caller)`；`false` 仍由 caller 直接赎回。

UUPS 边界：

- `OutrunUniversalAssetsUpgradeable` 由 owner 授权升级
- `OutrunStakingPositionUpgradeable` 由 owner 授权升级
- `SYBaseUpgradeable` 为所有 SY adapters 提供 UUPS authority
- 所有 SY adapter 经 `SYBaseUpgradeable` 继承 `OutrunERC20PausableUpgradeable`，owner 因此拥有 `pause`/`unpause`（经 `_update` 的 `whenNotPaused` 阻断 transfer/mint/burn，叠加 deposit/redeem 的 `whenNotPaused`，可一键停摆全部 SY 转账/铸造/销毁/存入/赎回）；oracle-backed SY upgradeable variants 另有 owner-only `setExchangeRateOracle(address)`

## 重要结果

- `uAsset` 铸造面 owner 入口为 `setMintingCap`、`revokeMinter`、`transferMinterDebt`，完整权限面见「权限模型」
- position 的 `setMinStake`、`setRevenuePool`、`setKeeper`、`pause`、`unpause`、`harvestWrapYield` 仍是 owner 权限；行为语义见 `docs/spec/position/state-machines.md` §7/§8
- router、SY、position 的公开入口都仍受 allowance、余额、pause 与下游校验约束
