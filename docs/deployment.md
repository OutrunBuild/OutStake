# 部署文档

## 当前部署表面

当前仓库的生产部署入口只有 upgradeable 路径：

- `script/deploy/YieldDeployScript.s.sol`
- `script/deploy/OutstakeScript.s.sol`
- `script/deploy/deployment/OutrunDeployer.sol`

`YieldDeployScript.run()` 默认执行 `_supportAUSDC()`，并通过 `ERC1967Proxy` 部署 `OutrunAaveV3SYUpgradeable` 与 `OutrunStakingPositionUpgradeable`。

`OutstakeScript.run()` 默认只部署 `OutrunRouter` 与基础链配置。

## 关键约束

- SY、uAsset、position 的当前产品实现都通过 proxy-backed upgradeable variants 部署。
- router 仍是非 upgradeable helper。
- oracle adapter 仍是非 upgradeable helper。
- SY deploy helper 以 upgradeable 路径为准。
- 部署期 owner 约束按脚本区分（两个脚本对 `OWNER` 环境变量的要求不同）：
  - `OutstakeScript`（部署 uAsset / router）：强制 `OWNER == 广播者`，即 `OWNER` 必须等于 `PRIVATE_KEY` 派生地址。`OutrunDeployer` 合约以 `OWNER` 构造、其 `deploy()` 为 `onlyOwner`，脚本在 `_validateUAssetDeploymentConfig` 等处预检 `owner != deployer` 并 `revert InvalidOwner()`，故 `OWNER != 广播者` 时 uAsset / router 部署直接失败。
  - `YieldDeployScript`（部署 SY / position）：无 `owner != deployer` 守卫，`OWNER` 可直接设为终态 multisig（SY / position 的 `initialize` 直接写入该 owner，部署照常成功）。但其 `_deploySP` 调用 uAsset 的 owner-only `setMintingCap`，要求广播者是 uAsset 当前 owner；若 uAsset 已 `transferOwnership` 给 multisig，再次运行 `YieldDeployScript` 新增 SP 时，`setMintingCap` 需由 multisig 作为广播者执行。
  - 终态 owner 为 multisig 的推荐工作流：`OutstakeScript` 以 `OWNER=<部署 EOA>` 部署 uAsset / router，随后对每个合约 `transferOwnership(<multisig>)`；`YieldDeployScript` 的 `OWNER` 可直接设为 multisig。
- 跨链同地址部署约束：`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB` 经 `OutstakeScript.s.sol::_configureUAssetOmnichain` 把每条远端链的 peer 设为本链 uAsset 地址（peer = 自身地址设计），该设计只有在各链 uAsset 地址相同时才正确：
  - 地址决定链：`CREATE3` 代理地址只依赖 deployer 地址、salt 与固定 proxy bytecode，与 initcode 无关；`OutrunDeployer.sol::deploy` 再把 salt 与 msg.sender 再哈希，故 uAsset 地址 = f(OutrunDeployer 地址, 广播者地址, salt)。
  - 因此要求：(1) OutrunDeployer 各链同址——经 `OutstakeScript.s.sol::_deployOutrunDeployer` 以同一 `OWNER`、同一 nonce 于各链 CREATE2 部署，或 env 注入的 `OUTRUN_DEPLOYER` 必须为各链同一地址；(2) 广播者 EOA（`PRIVATE_KEY` 派生）各链一致；(3) 部署用 nonce/salt 各链一致。
  - 违反后果：各链 uAsset 地址不同，源链 burn 后目标链 peer 校验失败、永不到账，已发送的跨链报文不可自动恢复。
  - 脚本侧约束：`OutstakeScript.s.sol::_assertOutrunDeployer` 对 env 注入的 `OUTRUN_DEPLOYER` 校验其等于按 `OutstakeScript.s.sol::_deployOutrunDeployer` 同款 salt/initcode 配方（salt = keccak256(owner, "OutrunDeployer", nonce)，initcode = creationCode ++ abi.encode(owner)，creator = 脚本合约，即 Foundry 广播时以确定性地址部署脚本合约、以 `address(this)` 表示）计算的 CREATE2 期望地址，偏离即 revert `InvalidDeployer`；且该断言首行要求 `OWNER` 等于广播者，否则 revert `InvalidOwner`，与本文档 owner 约束（`OWNER == 广播者`）一致。断言与 `_deployOutrunDeployer` 调用点共用 `OutstakeScript.s.sol::run` 内同一 nonce 单常量，不存在独立的 nonce env 变量；其中 `_deployOutrunDeployer` 当前在 `OutstakeScript.s.sol::run` 中被注释，跨链部署启用时按需解除注释。

## 运行时入口

部署脚本依赖环境变量注入 owner、keeper、revenuePool、router、launcher、endpoint 与外部协议地址。
`OutrunDeployer` 提供 owner-only 的 CREATE3 部署能力。
