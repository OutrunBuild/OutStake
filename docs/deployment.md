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

## L2 oracle-backed SY 部署校验清单（G-4）

`OutrunL2OracleBackedSYUpgradeable.sol::__L2OracleBackedSY_init` 与 `OutrunL2WrappableWstETHSYUpgradeable.sol::initialize` 的 `underlyingAssetOnEthAddr_` / `underlyingAssetOnEthDecimals_` 为 L1 侧信息，L2 链上无法 `IERC20Metadata.decimals()` 核验。误配会经 `OutrunStakingPositionUpgradeable.sol::initialize` 冻结 `canonicalAssetDecimals`，再经 `OutrunStakingPositionUpgradeable.sol::_scaleCanonicalAssetToUAsset` / `OutrunStakingPositionUpgradeable.sol::_scaleUAssetToCanonicalAsset` 系统性错标（如 stETH 18 填成 6 则放大 1e12）。本仓库以部署期断言收敛该风险，链上不做上游 decimals 查询。

- 校验入口：`L2AssetValidation.sol::validateL2OracleBackedParams` 与 `L2AssetValidation.sol::validateL2WrappableParams`（`script/lib/L2AssetValidation.sol`）。`YieldDeployScript.s.sol::_deployL2WstETHSY` / `YieldDeployScript.s.sol::_deployL2StakedTokenSY` / `YieldDeployScript.s.sol::_deployL2WrappableWstETHSY` 在 `new ERC1967Proxy` 前必调该校验，fail-fast。
- 已知资产族硬编码：`L2AssetValidation.sol::L1_STETH`（`0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`）期望 `18`，不匹配即 `L2InvalidDecimalsForKnownAsset`。新增族时在该库追加 `if` 分支并同步本清单。
- 通用范围：未知资产仅允许 `1..18`，`0` 或 `>18` 即 `L2InvalidDecimalsZero` / `L2InvalidDecimalsOutOfRange`。该范围不区分 6 与 18 的互换，仍需人工清单复核。
- 人工清单（广播前必做，记录为验收证据）：
  1. 在 L1 主网 Etherscan / 官方文档核对 `underlyingAssetOnEthAddr_` 的真实 `decimals`，截图存档
  2. 核对 `underlyingAssetOnEthAddr_` 地址本身（非 L2 侧 token 地址），与 `YieldDeployScript.s.sol` 传入值逐字符比对
  3. 确认 `exchangeRateOracle_`（或 wrappable 路径的 `stETH_`）非零且已部署
  4. 广播后读取 `IStandardizedYield.assetInfo` 与 `OutrunStakingPositionUpgradeable.sol::SY` 侧 `canonicalAssetDecimals` 缓存值，确认与清单一致
- 扩展约束：`OutrunStakingPositionUpgradeable.sol::initialize` 缓存后不再重读，部署后无法通过 SY 侧更新修复 decimals；错配需重新部署 SY + SP。

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
- 暂停误用警告（G-031）：`removeOutboundRateLimit` 会 `delete` 整条 `RateLimit` 记录（`amountInFlight/lastUpdated/limit/window` 一并清零），重设 `setOutboundRateLimit` 后从零会计、满额开始，不保留衰减后残留；不可当作“暂停限流但保留会计”的开关。需保留会计的暂停应直接重配（`setOutboundRateLimit` 会先以 `amount==0` checkpoint 结算，见 `OutrunRateLimiterUpgradeable.sol::_setRateLimits`）或使用 `pause` 熔断；删除后应监控 `OutboundRateLimitRemoved` 与 `isRateLimited(dstEid)==false` 的无限态，重设后复核 `isRateLimited==true` 且 `getAmountCanBeSent` 接近新限额（见 `docs/spec/common-foundations.md## OFT 与 rate limiter` 与 `OutrunRateLimiterUpgradeable.sol:200-201`）

## 跨链信任根投产校验与应急处置 (G-033/G-034)

`OutrunOFTUpgradeable.sol::_credit` 的入站铸币权完全委托给 LayerZero `endpoint` / `DVN` / `peers` 三元组（`OAppUpgradeable::lzReceive` 校验后经 `OFTCoreUpgradeable::_lzReceive` 调 `OutrunOFTUpgradeable::_credit` 直调 `OutrunERC20Upgradeable::_update` 铸造，不叠加链上二次签名/金额复核）。该路径为跨链活性刻意 bypass `OutrunERC20PausableUpgradeable::whenNotPaused`（`docs/spec/common-foundations.md## Pause 与跨链 OFT 执行边界` PA-1、`docs/spec/common-foundations.md## OFT 信任根与入站不限流/暂停豁免边界`），但导致目标链单方 `pause()` 不阻断入站增发，`totalSupply` 可单边增长需告警（`PositionPauseMatrix.t.sol` 回归，G-034）。语义真值在 `docs/spec/common-foundations.md`，本节为操作真值。

- 信任根：`endpoint` 地址、`DVN` quorum/`enforcedOptions`/`ULN` 配置、`peers[dstEid]` 三者即为伪造边界；任意一方被接管/误配即可按 `uint64` wire 包络 `OutrunOFTUpgradeable::_maxOFTAmountLD = type(uint64).max × decimalConversionRate` 单消息任意 `_amountLD`、无限消息累积铸造，无链上 cap。
- 限流与暂停边界：`OutrunRateLimiterUpgradeable::_outflow` 仅在 `OutrunOFTUpgradeable::_debit` 出站 burn 前记账，`_credit` 入站不经限流、不减 `amountInFlight`；`getAmountCanBeSent`/`quoteOFT` 的出站可用额度不约束入站；单链 `pause()` 仅阻断本地 transfer/`mint`/`repay` 与 pause 之后新发起的 outbound send，不阻断已在途入站（G-034）。
- 投产校验（每条 `dstEid` peer 部署/变更后必做，记录为验收证据）：
  1. 调用 `peers(dstEid)` 核对远端 uAsset 地址与各链同址预期一致；核对 `endpoint` 地址与部署配置一致
  2. 核对 DVN quorum 与 `enforcedOptions` 在源/目的链对称配置，`quoteSend` 探测往返
  3. 调用 `isRateLimited(dstEid)` 确认为 `true` 且 `getAmountCanBeSent` 接近限额，监控 `OutboundRateLimitRemoved` 与新 `peers` 的无限态
  4. 读取 `nextNonce`/`allowInitializePath` 等路径初始化状态（如启用）
- 监控告警（链下必配）：
  1. 暂停期入站告警：`paused()==true` 期间的 `_credit` mint（`Transfer(address(0), to, amount)` 且 `srcEid` 非零来源）与 `totalSupply` 单边增长；告警阈值按 `rateLimiter.limit × peers` 估算在途上限（G-030）
  2. 跨链突增告警：`totalSupply` 跨链突增、单笔 `amountLD` 接近 `uint64.max × DCR`、单位时间 `_credit` 次数/总量异常
  3. 配置漂移告警：`PeerSet`/`OutboundRateLimitSet`/`OutboundRateLimitRemoved`/`EnforcedOptionSet` 等事件的未授权变更
- 应急处置 runbook（G-034 活性豁免的运维收敛，`pause` 为不完全熔断）：
  1. 定序：先在所有对端链暂停出站（`pause()` 阻断 `send`/`_debit`），再在目标链 `pause()`；仅暂停目标链不能止血，已在途报文仍会 `lzReceive→_credit` 铸造（endpoint 时序决定，非 `block.timestamp`）
  2. 止血：对受影响 `srcEid` 执行 `setPeer(eid, bytes32(0))` 撤销 peer（`onlyOwner`），阻断该通道后续 `lzReceive` 的 peer 校验；必要时同步调整 DVN/`enforcedOptions` 或暂停 endpoint 通道
  3. 排空：在途报文上限 = `Σ rateLimiter.limit`（每 peer 独立），需等待或通过 endpoint 侧重放/丢弃策略排空后，再 `unpause()` 恢复
  4. 禁忌：不可通过给 `_credit` 加 `whenNotPaused` 代码修复——会造成源链已 burn、目标链 revert 的永久丢资产（burn-without-mint），与 PA-1 活性保证冲突；本处置为文档/监控收敛，无代码改动（accepted risk）

## Keeper/Harvest 权限分区与活性布线 (G-037)

`OutrunStakingPositionUpgradeable.sol::keepRedeem` / `OutrunStakingPositionUpgradeable.sol::keepWrapRedeem` 仅 `OutrunStakingPositionUpgradeable.sol::keeper` 可调用（`keeper()` 比对 `msg.sender`，非 keeper `PermissionDenied`），`OutrunStakingPositionUpgradeable.sol::harvestWrapYield` 仅 owner 可调用（`onlyOwner`）。该分区为故意设计（`docs/audits/2026-08-24/04a-guidelines-position-assets.md:85`、`docs/spec/access-control.md`、`docs/spec/position/state-machines.md` §7.2），非缺陷，但需部署布线保证清算与收割活性。

- 信任边界：keeper 为不可信活性角色（通常为 EOA/bot），需预先对 position 合约授权 uAsset 额度以执行 `repay` 销债；owner 为可信多签，控制 `revenuePool`/`minTokenOut`/`setKeeper`/`pause`；二者不可互替，keeper 无法收割，owner 无法直接清算。
- 布线选项（选一并记录为验收证据）：
  1. 共控 bot：`OutrunStakingPositionUpgradeable.sol::setKeeper` 设为由 owner 多签共控的 bot 地址，bot 负责 `keepWrapRedeem`/`keepRedeem`，owner 负责 `harvestWrapYield`；`SetKeeper` 事件为审计点。
  2. owner 自提升清算：需清算时 owner 先 `OutrunStakingPositionUpgradeable.sol::setKeeper(owner)` 将自身设为 keeper，再以 keeper 身份调用 `keep*`，完成后可 `setKeeper` 切回 bot；该路径为单交易可恢复 liveness halt，不属权限提升（owner 已是 `setKeeper` 控制者）。
  3. 不推荐给 keeper 开放 `harvestWrapYield`：若需 keeper 触发收割，应新增带 `revenuePool`/`minTokenOut` 白名单的包装入口并经 owner 审批，而非直接将 `harvestWrapYield` 改为 `onlyOwnerOrKeeper`（`04a:85` 指出需附加 destination/slippage 控制）。
- 投产校验：
  1. `OutrunStakingPositionUpgradeable.sol::keeper()` 读取值与预期 keeper 地址一致，`revenuePool()` 与预期一致
  2. 以 keeper 身份 `keepWrapRedeem`/`keepRedeem` 可成功（`uAsset` 已 approve），以非 keeper 调用预期 `PermissionDenied`
  3. 以 owner 身份 `harvestWrapYield(SY,0)` 在有超额时可成功，非 owner 预期 `OwnableUnauthorizedAccount`；无超额时返回 0 不发事件
  4. `SetKeeper`/`HarvestWrapYield`/`KeepRedeem`/`KeepWrapRedeem` 事件与链上余额核对一致
- 监控告警：`syWrapStaking - wrapDebtInSY` 超额持续增长而 `harvestWrapYield` 久未触发，或到期仓位 `deadline` 已过而 `keepRedeem` 未触发，均视为布线/活性告警（非资金损失，仅 halt）。

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
