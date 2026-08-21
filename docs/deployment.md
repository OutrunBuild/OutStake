# 部署文档

## 当前部署表面

当前仓库的生产部署入口只有 upgradeable 路径：

- `script/deploy/YieldDeployScript.s.sol`
- `script/deploy/OutstakeScript.s.sol`
- `script/deploy/deployment/OutrunDeployer.sol`

`YieldDeployScript.s.sol::run` 默认执行 `YieldDeployScript.s.sol::_supportAUSDC`，并通过 `ERC1967Proxy` 部署 `OutrunAaveV3SYUpgradeable` 与 `OutrunStakingPositionUpgradeable`。`YieldDeployScript.s.sol::_supportAUSDC` 仅在 `block.chainid` 匹配 `ARBITRUM_SEPOLIA_CHAINID` 或 `BASE_SEPOLIA_CHAINID`（Arbitrum Sepolia / Base Sepolia）时部署；在两个 `*_CHAINID` env 键均已配置的前提下，其余链跳过部署并打印 skip 日志后正常返回，脚本不回退；被求值到的键缺失时 `vm.envUint` 读取失败会使脚本直接 revert（chainid 已匹配前序条件时，后续键不再求值）。

`OutstakeScript.s.sol::run` 默认只部署 `OutrunRouter`（附带 owner / deployer 断言与 router 配置），仅要求 `OWNER` / `OUTRUN_DEPLOYER` / `MEMEVERSE_LAUNCHER` 环境变量（外加可选 `OUTRUN_ROUTER`），不要求 14 条链的 endpoint / EID 环境变量。完整的链配置初始化 `OutstakeScript.s.sol::_chainsInit`（14 条链 endpoint / EID 环境变量）仅在启用 uAsset 跨链部署时经其共享入口 `OutstakeScript.s.sol::_deployUAsset`（`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB` 的共同入口）加载并校验；这些调用当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释。

## 关键约束

- SY、uAsset、position 的当前产品实现都通过 proxy-backed upgradeable variants 部署。
- `OutrunStakingPositionUpgradeable.sol` 的 V1 storage namespace 将 `SY` 与两个 decimals 配置值打包在 slot0，后续 `minStake` 至 `positions` 的 slot 顺序保持不变。该顺序调整应在 V1 发布前完成；已有旧布局 position proxy 需要先迁移 decimals，再切换实现。
- router 仍是非 upgradeable helper。
- oracle adapter 仍是非 upgradeable helper。
- SY deploy helper 以 upgradeable 路径为准。
- 部署期 owner 约束按脚本区分（两个脚本对 `OWNER` 环境变量的要求不同）：
  - `OutstakeScript`（部署 uAsset / router；uAsset 部署调用当前在 `OutstakeScript.s.sol::run` 中被注释）：强制 `OWNER == 广播者`，即 `OWNER` 必须等于 `PRIVATE_KEY` 派生地址。`OutrunDeployer` 合约以 `OWNER` 构造、其 `deploy()` 为 `onlyOwner`，脚本在 `_validateUAssetDeploymentConfig` 等处预检 `owner != deployer` 并 `revert InvalidOwner()`，故 `OWNER != 广播者` 时 uAsset / router 部署直接失败。
  - `YieldDeployScript`（部署 SY / position）：无 `owner != deployer` 守卫，`OWNER` 可直接设为终态 multisig（SY / position 的 `initialize` 直接写入该 owner，部署照常成功）。但其 `_deploySP` 调用 uAsset 的 owner-only `setMintingCap`，要求广播者是 uAsset 当前 owner；若 uAsset 已 `transferOwnership` 给 multisig，再次运行 `YieldDeployScript` 新增 SP 时，`setMintingCap` 需由 multisig 作为广播者执行。
  - 终态 owner 为 multisig 的推荐工作流：`OutstakeScript` 以 `OWNER=<部署 EOA>` 部署 uAsset / router，随后对每个合约 `transferOwnership(<multisig>)`；`YieldDeployScript` 的 `OWNER` 可直接设为 multisig。其中 uAsset 部署调用（`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB`）当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释；当前按本工作流执行 `OutstakeScript` 实际仅部署 router。
  - 新 SP 部署默认参数：`YieldDeployScript.s.sol::_deploySP` 与 `OutstakeScript.s.sol::_supportMockAUSDC` / `_supportMockSUSDS` 部署 SP 时自动设置 `mintingCap = 1_000_000_000 ether`、`minStake = 0`；两者均为硬编码部署默认值，不提供 env 调整项；`OutstakeScript.s.sol::_supportMockAUSDC` / `_supportMockSUSDS` 两个调用点当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释。部署后如需调整，由 uAsset owner 调用 `OutrunUniversalAssetsUpgradeable.sol::setMintingCap`、position owner 调用 `OutrunStakingPositionUpgradeable.sol::setMinStake`。
  - mock 栈测试网限制：mock 栈五个部署/支持入口（`OutstakeScript.s.sol::_deployMockERC20` / `OutstakeScript.s.sol::_deployMockOracle` / `OutstakeScript.s.sol::_deployMockERC20SY` / `OutstakeScript.s.sol::_supportMockAUSDC` / `OutstakeScript.s.sol::_supportMockSUSDS`）仅限测试网与 anvil 本地链，由 `OutstakeScript.s.sol::_assertTestnetChain` 依 `OutstakeScript.s.sol::_testnetChainIds` 的硬编码允许列表（anvil 本地链 31337 + 14 条测试网 chainid，与 `OutstakeScript.s.sol::_chainsInit` 键集同源）强制；在允许列表之外的链上执行这些入口会 revert `NotTestnetChain`（fail-closed 回退，非静默跳过）；禁止对生产 uAsset 运行 mock 栈。
- 跨链同地址部署约束：`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB` 经 `OutstakeScript.s.sol::_configureUAssetOmnichain` 把每条远端链的 peer 设为本链 uAsset 地址（peer = 自身地址设计），该设计只有在各链 uAsset 地址相同时才正确（三个部署调用当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释）：
  - 地址决定链：`CREATE3` 代理地址只依赖 deployer 地址、salt 与固定 proxy bytecode，与 initcode 无关；`OutrunDeployer.sol::deploy` 再把 salt 与 msg.sender 再哈希，故 uAsset 地址 = f(OutrunDeployer 地址, 广播者地址, salt)。
  - 因此要求：(1) OutrunDeployer 各链同址——经 `OutstakeScript.s.sol::_deployOutrunDeployer` 以同一 `OWNER`、同一 nonce、同一编译配置（solc、via_ir、optimizer、optimizer_runs）于各链 CREATE2 部署，其跨链同址保证基于 CREATE2 creator 为各链同一链上常量 canonical factory 地址（`0x4e59b44847b379578588920cA78FbF26c0B4956C`，不再依赖「脚本合约在各链同址」），无论经 `OutstakeScript.s.sol::_deployOutrunDeployer` 部署还是 env 注入 `OUTRUN_DEPLOYER`，其地址都必须等于按下方配方可计算的 CREATE2 期望地址且各链同一；编译配置不一致会使 `OutrunDeployer.sol` 的 `creationCode` 变化，进而改变 initcode 哈希与 CREATE2 期望地址；(2) 广播者 EOA（`PRIVATE_KEY` 派生）各链一致；(3) 部署用 nonce/salt 各链一致。
  - 编译配置落地：`script/ops/deploy.sh` 与 `script/ops/yieldDeploy.sh` 统一以 `optimizer_runs=20000` 传给各链 forge 命令；`foundry.toml` 的 `optimizer_runs = 200` 仅供非部署构建，任何手工 forge 部署命令都必须显式传 `--optimizer-runs 20000`。
  - 违反后果：各链 uAsset 地址不同，源链 burn 后目标链 peer 校验失败、永不到账，已发送的跨链报文不可自动恢复。
  - 脚本侧约束：`OutstakeScript.s.sol::_assertOutrunDeployer` 对 env 注入的 `OUTRUN_DEPLOYER` 校验其等于按 `OutstakeScript.s.sol::_deployOutrunDeployer` 同款 salt/initcode 配方（salt = keccak256(owner, "OutrunDeployer", nonce)，initcode = creationCode ++ abi.encode(owner)，creator = canonical deterministic-deployment proxy 常量地址 `0x4e59b44847b379578588920cA78FbF26c0B4956C`，各链同一，不再是脚本合约/`address(this)`）计算的 CREATE2 期望地址，即 CREATE2(FACTORY, salt, keccak256(initcode))，经三参 `Create2.computeAddress(salt, hash, FACTORY)` 计算，偏离即 revert `InvalidDeployer`；且该断言首行要求 `OWNER` 等于广播者，否则 revert `InvalidOwner`，与本文档 owner 约束（`OWNER == 广播者`）一致。工具链约束：仓库 CI 钉定的 Foundry v1.7.1（`.github/workflows/test.yml` 的 `FORGE_VERSION`）实测中，`forge script` 下脚本合约内求值 `address(this)` 即触发硬 revert（脚本合约为 ephemeral、其地址不可依赖），因此部署脚本内不得出现 `address(this)`（含 OZ `Create2.sol` 二参 `computeAddress` 与 `Create2.deploy`，二者内部均使用 `address(this)`），creator 必须取链上常量地址。前置条件——各目标链必须已在上述 canonical factory 地址部署 deterministic-deployment proxy（该地址无代码时须先按其 canonical 部署流程补齐再广播）；`OutstakeScript.s.sol::_assertOutrunDeployer` 为纯地址计算，不校验 factory 是否在链上存在，缺链 factory 只会在 `_deployOutrunDeployer` 广播时以 revert `FactoryDeployFailed` 暴露。断言与 `_deployOutrunDeployer` 调用点共用 `OutstakeScript.s.sol::run` 内同一 nonce 单常量，不存在独立的 nonce env 变量；其中 `_deployOutrunDeployer` 当前在 `OutstakeScript.s.sol::run` 中被注释，跨链部署启用时按需解除注释。

## L2 oracle-backed SY 部署校验清单（G-1 + G-4）

`OutrunL2OracleBackedSYUpgradeable.sol::__L2OracleBackedSY_init` 与 `OutrunL2WrappableWstETHSYUpgradeable.sol::initialize` 的 `underlyingAssetOnEthAddr_` / `underlyingAssetOnEthDecimals_` 为 L1 侧信息，L2 链上无法 `IERC20Metadata.decimals()` 核验。误配会经 `OutrunStakingPositionUpgradeable.sol::initialize` 冻结 `canonicalAssetDecimals`，再经 `OutrunStakingPositionUpgradeable.sol::_scaleCanonicalAssetToUAsset` / `OutrunStakingPositionUpgradeable.sol::_scaleUAssetToCanonicalAsset` 系统性错标（如 stETH 18 填成 6 则放大 1e12）。本仓库以部署期断言收敛该风险，链上不做上游 decimals 查询。

- 校验入口：`L2AssetValidation.sol::validateL2OracleBackedParams` 与 `L2AssetValidation.sol::validateL2WrappableParams`（`script/lib/L2AssetValidation.sol`）负责 decimals；`L2AssetValidation.sol::validateL2OracleAdapter` 负责 oracle 适配器（G-1）。`YieldDeployScript.s.sol::_deployL2WstETHSY` / `YieldDeployScript.s.sol::_deployL2StakedTokenSY` 在 `new ERC1967Proxy` 前依次调用两项校验，fail-fast；`_deployL2WrappableWstETHSY` 仅校验 decimals（其汇率源为 `IL2StETH`，非 oracle）。
- 已知资产族硬编码：`L2AssetValidation.sol::L1_STETH`（`0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`）期望 `18`，不匹配即 `L2InvalidDecimalsForKnownAsset`。新增族时在该库追加 `if` 分支并同步本清单。
- 通用范围：未知资产仅允许 `1..18`，`0` 或 `>18` 即 `L2InvalidDecimalsZero` / `L2InvalidDecimalsOutOfRange`。该范围不区分 6 与 18 的互换，仍需人工清单复核。
- Oracle 适配器强制（G-1，仅 oracle-backed 家族，原为 NatSpec 建议现为部署期代码强制）：
  - `validateL2OracleAdapter` 读取 `OutrunExchangeOracleAdapter` 的 immutable：`maxStaleness`、`sequencerUptimeFeed`、`sequencerGracePeriod`；非 adapter 合约直接 `L2InvalidOracleAdapterNotAdapter`。
  - Lido wstETH 家族（`underlying == L1_STETH`）：`maxStaleness == 2 days`（`EXPECTED_WSTETH_MAX_STALENESS`，Lido 指引“stETH rate data should not be outdated by more than 2 days”），`sequencerUptimeFeed != address(0)`，`gracePeriod ∈ [30 min, 1 day]`，否则 `L2InvalidOracleAdapterMaxStaleness` / `SequencerZero` / `GracePeriod`。
  - 通用 L2 家族：`maxStaleness ∈ [1 hour, 7 days]`，同样要求 `sequencer !=0` 且 `gracePeriod ∈ [30 min, 1 day]`。
  - 设计意图：`OutrunL2WstETHSYUpgradeable.sol:11-14` 的 NatSpec “should use maxStaleness=2 days and enable sequencer” 长期仅为建议，`setExchangeRateOracle` 可运行时换入任意 `IExchangeRateOracle`（仅非零校验），全链路无带宽护栏；本校验将该建议提升为广播前 fail-fast，配合 `OutrunExchangeOracleAdapter` 的正数/新鲜度/sequencer 运行时校验，收敛 G-1 单点信任根的误配面。`setExchangeRateOracle` 的任意 oracle 风险仍为 owner 信任模型（`docs/spec/access-control.md` 不引入 timelock），链上不追加 allowlist/band，收敛点选在部署期而非运行期。
- 人工清单（广播前必做，记录为验收证据）：
  1. 在 L1 主网 Etherscan / 官方文档核对 `underlyingAssetOnEthAddr_` 的真实 `decimals`，截图存档
  2. 核对 `underlyingAssetOnEthAddr_` 地址本身（非 L2 侧 token 地址），与 `YieldDeployScript.s.sol` 传入值逐字符比对
  3. 确认 `exchangeRateOracle_`（或 wrappable 路径的 `stETH_`）非零且已部署；oracle-backed 路径额外核对 `OutrunExchangeOracleAdapter` 的 `maxStaleness`、`sequencerUptimeFeed`、`sequencerGracePeriod` 读取值与本清单一致（Lido 家族必须 2 days + 非零 sequencer）
  4. 广播后读取 `IStandardizedYield.assetInfo` 与 `OutrunStakingPositionUpgradeable.sol::SY` 侧 `canonicalAssetDecimals` 缓存值，确认与清单一致；并读取 `OutrunL2OracleBackedSYUpgradeable.exchangeRateOracle()` 与 adapter 的 `maxStaleness/sequencer` 二次确认
- 扩展约束：`OutrunStakingPositionUpgradeable.sol::initialize` 缓存后不再重读，部署后无法通过 SY 侧更新修复 decimals；错配需重新部署 SY + SP。Oracle 适配器为 immutable helper，`maxStaleness/sequencer` 部署后不可改，错配需重新部署 adapter + SY。

## 跨链限流（OFT Outbound Rate Limit）高危参数校验清单（GO-4）

`OutrunOFTUpgradeable.sol::setOutboundRateLimit` 的 `limit` 为 LD（local decimals）单位，与 `OutrunOFTUpgradeable.sol::_debit` 的 `amountSentLD` 同单位（`OutrunRateLimiterUpgradeable.sol:10-14`）。18-dec 部署下 `DCR = 1e12`，1 token = 1e18 LD = 1e6 SD，`1e12`（1 SD 单位 = dust 阈值）若被当作 LD 传入则任何真实出站立即 `RateLimitExceeded`，静默 fail-closed 停摆（与 GO-3 同方向）。NatSpec 已在 `OutrunOFTUpgradeable.sol:103-108` 明示 `Do NOT pass SD — 1e12 equals only 1 dust unit`，本清单为运维二次确认（与 04a G-1 oracle 换址同级高危）。

- 高危定级：纳入 ops 高危参数变更清单，变更需双人复核
- 单位校验（变更前）：
  1. `limit` 必须按 LD 填写（如 `1_000_000e18` 表示 100 万 token），切勿按 SD（6 位）习惯填写
  2. 部署脚本 env `*_OUTBOUND_RATE_LIMIT` 同为 LD；示例：`UETH_OUTBOUND_RATE_LIMIT=1000000000000000000000000`（= 1e6 × 1e18），禁止 `1e12` / `1000000e6`
  3. 对照 `OutrunRateLimiterUpgradeable.sol::RateLimit` 存储注释与 `docs/spec/common-foundations.md## OFT 与 rate limiter` 单位约定复核
- 生效复核（变更后必做，记录为验收证据）：
  1. 调用 `OutrunOFTUpgradeable.sol::getAmountCanBeSent(dstEid)` 读取 `(currentAmountInFlight, amountCanBeSent)`，确认 `amountCanBeSent` 去 dust 后接近新 `limit`（`window` 内无在途时应 `== _removeDust(limit)`）
  2. 核对 `OutboundRateLimitSet(dstEid, limit, window)` 事件参数与 `rateLimits(dstEid).limit/window` 读取值一致
  3. 执行 `quoteOFT(SendParam)` 抽检 `maxAmountLD` 受限于新限额且 `minAmountLD == decimalConversionRate`
- 失败特征：误配为 SD 量级时 `getAmountCanBeSent` 返回 dust 级、`quoteOFT.maxAmountLD == 0` 或 `1e12`，出站即 `RateLimitExceeded`；与在途超限不同，dust 限额不随衰减自愈，需重配正限额或 `removeOutboundRateLimit` 恢复

## 暂停矩阵（PA-1）三 Owner 开关联动与运维约束

`OutrunStakingPositionUpgradeable` (SP)、`SYBaseUpgradeable` 族 (SY)、`OutrunUniversalAssetsUpgradeable` (uAsset via `OutrunOFTUpgradeable` → `OutrunERC20PausableUpgradeable`) 各持独立 `owner` 暂停开关。任一关闭即冻结 SP 全部用户面；uAsset 暂停为全协议熔断。暂停期 `uAsset` 供给单边增长（`_credit` 仍铸币）需设告警。

| 暂停方 | 触发 | SP 用户面影响 | uAsset 面 | SY 面 | 恢复 |
|---|---|---|---|---|---|
| SP `pause()` | `position.pause()` | `stake`/`drawUAsset`/`redeem`/`keepRedeem`/`wrapStake`/`keepWrapRedeem`/`harvestWrapYield` 全部 `EnforcedPause` | 无直接影响（但 SP 的 `mint`/`repay` 依赖 uAsset 未暂停） | 无直接影响 | `unpause()` |
| SY `pause()` | `sy.pause()` | `stake`/`wrapStake` 经 `SY` 的 `transfer`/`_update` 间接 `EnforcedPause`；`redeem`/`keepRedeem` 的 `SY` 转出亦受阻 | 无直接影响 | `deposit`/`redeem` `EnforcedPause` | `unpause()` |
| uAsset `pause()` | `uAsset.pause()` | `stake`/`drawUAsset`(`mint`)、`redeem`/`keepRedeem`/`keepWrapRedeem`(`repay`)、`transfer`/`transferFrom` 全部 `EnforcedPause` → 全协议熔断 | `mint`/`repay`/`transfer`/`_debit`(`send`) 全部 `EnforcedPause`；`approve` 不受暂停影响 (OZ 标准，暂停期可预授权，恢复后生效) | 无直接影响 | `unpause()`；恢复后 `repay` 立即恢复 |

- 设计说明：`uAsset` 的 `_credit` (入站跨链铸币) 显式绕过 `whenNotPaused` 直调 `OutrunERC20Upgradeable._update` (见 `OutrunOFTUpgradeable.sol:185-194`)，符合 Trail of Bits “桥接入账不可因暂停丢资产”实践；暂停期入站仍单边增加 `totalSupply`，需监控告警。
- 限流器与暂停为两级出站熔断：`setOutboundRateLimit(dstEid, limit=0, window>0)` 已被 `InvalidRateLimit` 拒绝，暂停外不再支持 `limit=0` 单链冻结，需用 `removeOutboundRateLimit` 或 `pause()`。
- 运维约束：uAsset 暂停时长设告警上限（建议 <24h 需人工复核）；三开关联动需写入 runbook，`docs/spec/position/state-machines.md` 为执行真值；主网前三 `owner` 收敛为 timelock/multisig (PA-6 同一治理面)，`pause`/`unpause` 走多签。
- 回归证据：`test/upgradeable/PositionPauseMatrix.t.sol` 参数化覆盖“分别暂停 SP/SY/uAsset 后逐入口 `EnforcedPause`”与“uAsset 暂停期 `_credit` 仍增供给 + 恢复后 `repay` 可用”。

## 跨账本不变量与治理（PA-6）

债务仅由代码路径隐式维持，无链上强制等式：

```
uAsset.mintingStatusTable[SP].amountInMinted == Σ positions[id].UAssetMinted + wrapUAssetDebt
```

SP 每条 `mint` (`stake`/`drawUAsset`/`wrapStake`) 与 `repay` (`redeem`/`keepRedeem`/`keepWrapRedeem`) 同步更新两侧；OFT ` _debit`/`_credit` 不触碰 minter 债务表。唯一可打破等式的是 `uAsset.transferMinterDebt` (NatSpec 已警告需协调迁移，但无链上强制)。

- 主网前：`uAsset` `owner` 与 SP `owner` 收敛为 timelock/multisig；`transferMinterDebt` 必须与 SP 侧账本迁移在同一原子脚本中执行 (见 `script/lib/L2AssetValidation.sol` 迁移建议与下述 checklist)，禁止单独调用。
- 部署后校验：`uAsset.checkMintableAmount(SP)` 反推的 SP 债务、`Σ position`、`wrapUAssetDebt` 三方对账；`test/upgradeable/OutrunStakingPositionInvariantUpgradeable.t.sol:invariant_uAssetSupplyConsistency` 为链上回归。
- `setMinStake` 可即时 DoS 新增 `stake` (设为高于任何质押额)，变更走公示/多签。

## Wrap 池兑付边界（PA-2）

`wrapStake` 的唯一系统内兑回通道为 keeper 专用 `keepWrapRedeem`；池欠担保时 (`_assetToSyUp(wrapUAssetDebt, rate) > syWrapStaking`) 兑付全停 `WrapPoolUndercollateralized` (all-or-nothing，非 pro-rata)，wrap 用户仅余系统外流动性 (转让/桥接/市售)。

- 语义锁定：`test/upgradeable/OutrunStakingPositionFuzzUpgradeable.t.sol:testFuzz_WrapPoolUndercollateralizedThenRecovers` fuzz “wrapStake → 汇率下跌 → keepWrapRedeem revert → 回升 → 兑付恢复”，确保欠担保为暂时冻结非永久坏账。
- 若后续采纳自助 `wrapRedeem`，同测试承载新路径；当前 keeper 信任模型 (仅 keeper 可触发) 保持不变。

## Oracle 带宽护栏（PA-3 / G-1/G-2）

`OutrunStakingPositionUpgradeable._currentExchangeRate` 为全链路唯一速率读取点，历史仅 `rate != 0` 护栏。现新增可选带宽护栏 `minExchangeRate`/`maxExchangeRate` (0/0 表示禁用，兼容已部署代理)，`setExchangeRateBounds` owner-only。

- 运行时：`_currentExchangeRate` 先 `rate != 0` 再 `max != 0 ? rate ∈ [min,max] : pass`，否则 `ExchangeRateOutOfBounds`。配置示例：`[0.9e18, 11e17]` 收敛 10% 带，后续按资产族波动率收紧。
- 部署期：`script/lib/L2AssetValidation.sol:validateL2OracleAdapter` 已对 `OutrunExchangeOracleAdapter` 的 `maxStaleness`/`sequencer` 做 fail-fast (G-1)，带宽与新鲜度分层：适配器层保 staleness/sequencer，position 层保带宽。
- 验收：`test/upgradeable/OutrunStakingPositionFuzzUpgradeable.t.sol:testFuzz_BandwidthGuardRejectsOutOfBoundsRate` 覆盖带外拒收与禁用恢复。
- 文档真值：`docs/spec/yield/oracles-and-integrations.md` 构造期边界与 `docs/spec/position/state-machines.md` 速率读取点为双端文档锚点。

## 运行时入口


部署脚本依赖环境变量注入 owner、keeper、revenuePool、router、launcher、endpoint 与外部协议地址。

Router target registry wiring：

- router、SY proxy 与 SP proxy 部署完成后，由 router owner 逐个调用 `OutrunRouter.sol::setTrustedSY(SY, true)`，再调用 `OutrunRouter.sol::setTrustedSP(SP, SY)`；后者必须使用该 SP 当前 `SP.SY()` 返回的 canonical SY，且该 SY 已先登记。
- 注册完成后读取 `OutrunRouter.sol::trustedSY` 与 `OutrunRouter.sol::trustedSYForSP`，并核对 `TrustedSYUpdated` / `TrustedSPUpdated` 事件；所有清单项验收完成前，不开放 router 的用户入口。registry 检查在用户资金 pull、`transferFrom` 和精确 approve 之前执行，未登记 target 或 pair mismatch 会回退且不移动用户资产。
- `OutrunRouter.sol::setMemeverseLauncher` 成功轮换应发出 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）；代码落地后，部署验收需确认该事件及 `OutrunRouter.sol::memeverseLauncher` 读取值，并将结果记录为验收证据。
- `setTrustedSY(SY, false)` 会阻断该 SY 的直接路径及引用它的 SP 路径，但不会自动清零 SP mapping；撤销或换对时显式调用 `OutrunRouter.sol::setTrustedSP(SP, address(0))`，再按“注册 SY -> 注册 pair”的顺序接入新配置。撤销不回滚已完成 position、uAsset debt 或 SY share state。
- 这些 registry setter 与 `OutrunRouter.sol::setMemeverseLauncher` 都是 pre-mainnet wiring。主网发布前完成最终 target 清单、getter/event 验收并冻结/移除临时 owner/admin setter；主网运行不依赖运行期新增、替换或撤销 target。

SY router wiring：

- 每个 `SYBaseUpgradeable.sol` proxy 初始化完成后，由该实例 owner 调用 `SYBaseUpgradeable.sol::setTrustedRouter(OUTRUN_ROUTER)`，再启用 `OutrunRouter.sol::redeemSyToToken`；未配置时 router 的 `burnFromInternalBalance=true` 调用会回退。
- `SYBaseUpgradeable.sol::trustedRouter` 是验收前的读取点；配置交易应核对 `SetTrustedRouter` 事件的旧值和新值。切换 router 时先设置新地址并确认读取值，再停用旧入口；设置零地址撤销 router 并使 true 分支关闭。
- owner 轮换不改变 `redeem(..., false)` 的直接赎回语义；该路径从 caller 余额烧份额，不依赖 router wiring。

`OutrunDeployer` 提供 owner-only 的 CREATE3 部署能力。
