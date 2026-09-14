# 部署文档

## 当前部署表面

当前仓库的生产部署入口只有 upgradeable 路径：

- `script/deploy/YieldDeployScript.s.sol`
- `script/deploy/OutstakeScript.s.sol`
- `script/deploy/deployment/OutrunDeployer.sol`

`YieldDeployScript.s.sol::run` 默认执行 `YieldDeployScript.s.sol::_supportAUSDC`，并通过 `ERC1967Proxy` 部署 `OutrunAaveV3SYUpgradeable` 与 `OutrunStakingPositionUpgradeable`。`YieldDeployScript.s.sol::_supportAUSDC` 仅在 `block.chainid` 匹配 `BASE_SEPOLIA_CHAINID`（Base Sepolia）时部署，其余链跳过部署并打印 skip 日志后正常返回，脚本不回退；`BASE_SEPOLIA_CHAINID` 在链比较中无条件求值，该键缺失时 `vm.envUint` 读取失败会使脚本直接 revert，而 `BASE_SEPOLIA_AUSDC` / `BASE_SEPOLIA_POOL` 仅在 chainid 匹配后才求值（未匹配链不读取、不回退）。

`OutstakeScript.s.sol::run` 默认只部署 `OutrunRouter`（附带 owner / deployer 断言与 router 配置），仅要求 `OWNER` / `OUTRUN_DEPLOYER` / `MEMEVERSE_LAUNCHER` 环境变量（外加可选 `OUTRUN_ROUTER`），不要求 3 条测试网（BSC Testnet / Base Sepolia / Sepolia）的 endpoint / EID 环境变量。完整的链配置初始化 `OutstakeScript.s.sol::_chainsInit`（BSC Testnet / Base Sepolia / Sepolia 三条链的 endpoint / EID 环境变量，链集与 `OutstakeScript.s.sol::_sharedOmnichainIds` 一致）仅在启用 uAsset 跨链部署时经其共享入口 `OutstakeScript.s.sol::_deployUAsset`（`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB` 的共同入口）加载并校验；这些调用当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释。

## 关键约束

- SY、uAsset、position 的当前产品实现都通过 proxy-backed upgradeable variants 部署。
- `OutrunStakingPositionUpgradeable.sol` 的 V1 storage namespace 将 `SY` 与两个 decimals 配置值打包在 slot0，完整布局以 `test/upgradeable/OutrunStakingPositionStorageLayout.t.sol::test_StorageLayoutIsPinned` 为准（v1 布局收缩：删除 `mintLtv`/`liquidationLtv`/`liquidationPremium`/`genesisRateMultiplier` 参数字段与 `collSurplus` mapping，`Position` 结构五字段化；语义真源见 `docs/spec/position/accounting.md` §1.1）；布局调整窗口止于 V1 发布，发布后布局冻结。
- router 仍是非 upgradeable helper。
- oracle adapter 仍是非 upgradeable helper。
- SY deploy helper 以 upgradeable 路径为准。
- 部署期 owner 约束按脚本区分（两个脚本对 `OWNER` 环境变量的要求不同）：
  - `OutstakeScript`（部署 uAsset / router；uAsset 部署调用当前在 `OutstakeScript.s.sol::run` 中被注释）：强制 `OWNER == 广播者`，即 `OWNER` 必须等于 `PRIVATE_KEY` 派生地址。`OutrunDeployer` 合约以 `OWNER` 构造、其 `deploy()` 为 `onlyOwner`，脚本在 `_validateUAssetDeploymentConfig` 等处预检 `owner != deployer` 并 `revert InvalidOwner()`，故 `OWNER != 广播者` 时 uAsset / router 部署直接失败。
  - `YieldDeployScript`（部署 SY / position）：强制 `OWNER == 广播者`——每个支持入口在 SY proxy 创建后立即调用 `YieldDeployScript.s.sol::_wireTrustedRouter` 绑定 trusted router（owner-only 调用）；`YieldDeployScript.s.sol::_validateTrustedRouterConfig` 预检 `owner != deployer` 并 revert `InvalidOwner`（见 `SPDefaults.sol::requireBroadcasterIsOwner`），故 `OWNER != 广播者` 时在 SY proxy 已创建之后才失败（live broadcast 下该 SY 处于已部署但未布线状态，需清理/复用）。同路径下 `OUTRUN_ROUTER` 为硬性必填：`YieldDeployScript.s.sol::_routerAddress` 无条件读取该键，缺键同样在 SY 创建后 revert。但其 `YieldDeployScript.s.sol::_deploySP` 在 SP impl/proxy 创建之前预检部署期所有权：broadcaster-is-owner（广播者 == `OWNER` env，`SPDefaults.sol::requireBroadcasterIsOwner` 语义）不满足即 revert `InvalidOwner`，uAsset 零地址即 revert `InvalidAddress`，并按 `SPDefaults.sol::requireSelfOwned` 语义校验 uAsset 当前 owner == `OWNER`，任一前置失败即 fail-closed revert、不遗留已初始化 SP proxy；`setMintingCap` 本身仍为 owner-only 链上调用，若 uAsset 已 `transferOwnership` 给 multisig，再次运行 `YieldDeployScript` 新增 SP 时，需由 multisig 作为广播者执行——预检与链上调用强制同一谓词（广播者 == uAsset 当前 owner），不放宽也不新增部署前提。
  - 终态 owner 为 multisig 的推荐工作流：`OutstakeScript` 以 `OWNER=<部署 EOA>` 部署 uAsset / router，随后对每个合约 `transferOwnership(<multisig>)`；`YieldDeployScript` 以 `OWNER=<部署 EOA>` 部署（含 trusted-router 自动布线），随后对每个 SY / SP 执行 `transferOwnership(<multisig>)`。其中 uAsset 部署调用（`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB`）当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释；当前按本工作流执行 `OutstakeScript` 实际仅部署 router。
  - 新 SP 部署默认参数：`YieldDeployScript.s.sol::_deploySP` 与 `OutstakeScript.s.sol::_supportMockAUSDC` / `_supportMockSUSDS` 部署 SP 时写入 `minStake = 1`（`OutrunStakingPositionUpgradeable.sol::initialize` 拒绝零值，脚本默认取最小正值 1，硬编码、无 env 调整项；v1 定值理由 = genesis 门票最小规模 + 反垃圾，正式值按该理由上线前核定）、`duty = 1e27`（全族零费 v1 默认——零费哨兵合法，`rate` 永不前移、债务冻结、背书率单调上升）、`protocolTreasury`（env `PROTOCOL_TREASURY`）；原 `mintLtv` / `liquidationLtv` / `liquidationPremium` / `genesisRateMultiplier` 四参数随 v1 无 LTV/无清算/零折扣决策整体删除（`script/lib/SPDefaults.sol` 相应收缩，无 env 调整项）；`mintingCap` 为 v1 唯一供给刹车（uAsset minter 台账 cap 直接限总供给），占位默认 `1_000_000_000 ether`；`mintingCap` 经 `SP_MINTING_CAP` env 可覆盖（缺省回落占位默认），覆盖值仍须按「mintingCap 初始值治理」在上线前重核；显式置零（`SP_MINTING_CAP=0` 或 `<SYMBOL>_POLEND_MINTING_CAP=0`）部署脚本直接 revert，不会静默部署零 cap（见 SPDefaults.sol::spMintingCap、OutstakeScript.s.sol::_polendMintingCap）；`OutstakeScript.s.sol::_supportMockAUSDC` / `_supportMockSUSDS` 两个调用点当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释。部署后如需调整，由 uAsset owner 调用 `OutrunUniversalAssetsUpgradeable.sol::setMintingCap`、position owner 调用 `OutrunStakingPositionUpgradeable.sol::setMinStake` / `::setDuty`（接受域 `[1e27, DUTY_CAP = 1000000004431822129783699001]`，sub-RAY 以 `ZeroInput` 拒绝）。
  - mock 栈测试网限制：mock 栈五个部署/支持入口（`OutstakeScript.s.sol::_deployMockERC20` / `OutstakeScript.s.sol::_deployMockOracle` / `OutstakeScript.s.sol::_deployMockERC20SY` / `OutstakeScript.s.sol::_supportMockAUSDC` / `OutstakeScript.s.sol::_supportMockSUSDS`）仅限测试网与 anvil 本地链，由 `OutstakeScript.s.sol::_assertTestnetChain` 依 `OutstakeScript.s.sol::_testnetChainIds` 的硬编码允许列表（anvil 本地链 31337 + 3 条测试网 chainid：BSC Testnet / Base Sepolia / Sepolia，测试网部分与 `OutstakeScript.s.sol::_chainsInit` 键集同源）强制；在允许列表之外的链上执行这些入口会 revert `NotTestnetChain`（fail-closed 回退，非静默跳过）；禁止对生产 uAsset 运行 mock 栈。
- SP 计息参数部署核对（计息锚为 timestamp 秒）：`OutrunStakingPositionUpgradeable` 的计息锚为 `block.timestamp`，复利整段闭式为 `rate = rmul(rpow(duty, dt), rate)`（`rpow` 系 Maker assembly 版）；`duty` 为 RAY 1e27 域每秒率，v1 全族默认 `1e27`（零费哨兵，`rate` 永不前移、利息永不 accrue），无 `SECONDS_PER_YEAR` 换算常数、无 per-chain 定值、无对应 env 键——未来加息时族年化名义到 `duty` 的换算式为 `duty = 1e27*(1+年化)^(1/31536000)` 向下取整（python3 decimal 高精度）。`duty` 经 init/setter 边界约束：接受域 `[1e27, DUTY_CAP]`（`duty < 1e27` 即 sub-RAY/负利率含 0 以 `ZeroInput` 拒绝，保 `rate` 单调不减；`duty == 1e27` 合法且为 v1 默认），上限 `DUTY_CAP = 1000000004431822129783699001` 越界以 `DutyCap` 拒绝（见 `docs/spec/position/accounting.md` §6）；`BorrowRateBelowResolution` 已废除。加息（`duty > 1e27`）后的背书率监控口径变更见「SP v1 运行手册」。
- 协议金库 env 核对（广播前必做）：两个部署脚本均经 `vm.envAddress("PROTOCOL_TREASURY")` 读取协议金库地址（redeem 利息腿接收方——v1 零费默认下利息腿恒 0，该参数为未来加息保留，写入 `OutrunStakingPositionUpgradeable.sol::protocolTreasury`）；读取时点按脚本区分——`YieldDeployScript.s.sol::run` 无条件读取（缺键即 revert，fail-fast），`OutstakeScript.s.sol` 侧该读取位于 mock 支持入口 `OutstakeScript.s.sol::_supportMockSY`（测试网限定，其两个调用点当前在 `OutstakeScript.s.sol::run` 中被注释），仅该入口启用时才 fail-fast；`.env` 必须使用现名 `PROTOCOL_TREASURY`；部署后读取 `OutrunStakingPositionUpgradeable.sol::protocolTreasury()` 与 `SetProtocolTreasury` 事件核对为家族金库地址（金库内利息归属与分配规则为商务待定，见 `docs/spec/protocol.md`「跨仓库接线约束（Memeverse/POLend）」）。
- 跨链同地址部署约束：`OutstakeScript.s.sol::_deployUETH` / `_deployUUSD` / `_deployUBNB` 经 `OutstakeScript.s.sol::_configureUAssetOmnichain` 把每条远端链的 peer 设为本链 uAsset 地址（peer = 自身地址设计），该设计只有在各链 uAsset 地址相同时才正确（三个部署调用当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释）：
  - 地址决定链：`CREATE3` 代理地址只依赖 deployer 地址、salt 与固定 proxy bytecode，与 initcode 无关；`OutrunDeployer.sol::deploy` 再把 salt 与 msg.sender 再哈希，故 uAsset 地址 = f(OutrunDeployer 地址, 广播者地址, salt)。
  - 因此要求：(1) OutrunDeployer 各链同址——经 `OutstakeScript.s.sol::_deployOutrunDeployer` 以同一 `OWNER`、同一 nonce、同一编译配置（solc、via_ir、optimizer、optimizer_runs）于各链 CREATE2 部署，其跨链同址保证基于 CREATE2 creator 为各链同一链上常量 canonical factory 地址（`0x4e59b44847b379578588920cA78FbF26c0B4956C`，不再依赖「脚本合约在各链同址」），无论经 `OutstakeScript.s.sol::_deployOutrunDeployer` 部署还是 env 注入 `OUTRUN_DEPLOYER`，其地址都必须等于按下方配方可计算的 CREATE2 期望地址且各链同一；编译配置不一致会使 `OutrunDeployer.sol` 的 `creationCode` 变化，进而改变 initcode 哈希与 CREATE2 期望地址；(2) 广播者 EOA（`PRIVATE_KEY` 派生）各链一致；(3) 部署用 nonce/salt 各链一致。
  - 编译配置落地：`script/ops/deploy.sh` 与 `script/ops/yieldDeploy.sh` 统一以 `optimizer_runs=20000` 传给各链 forge 命令；`foundry.toml` 的 `optimizer_runs = 200` 仅供非部署构建，任何手工 forge 部署命令都必须显式传 `--optimizer-runs 20000`。
  - 违反后果：各链 uAsset 地址不同，源链 burn 后目标链 peer 校验失败、永不到账，已发送的跨链报文不可自动恢复。
  - 脚本侧约束：`OutstakeScript.s.sol::_assertOutrunDeployer` 对 env 注入的 `OUTRUN_DEPLOYER` 校验其等于按 `OutstakeScript.s.sol::_deployOutrunDeployer` 同款 salt/initcode 配方（salt = keccak256(owner, "OutrunDeployer", nonce)，initcode = creationCode ++ abi.encode(owner)，creator = canonical deterministic-deployment proxy 常量地址 `0x4e59b44847b379578588920cA78FbF26c0B4956C`，各链同一，不再是脚本合约/`address(this)`）计算的 CREATE2 期望地址，即 CREATE2(FACTORY, salt, keccak256(initcode))，经三参 `Create2.computeAddress(salt, hash, FACTORY)` 计算，偏离即 revert `InvalidDeployer`；且该断言首行要求 `OWNER` 等于广播者，否则 revert `InvalidOwner`，与本文档 owner 约束（`OWNER == 广播者`）一致。工具链约束：仓库 CI 钉定的 Foundry 版本（见 `.github/workflows/test.yml` 的 `FORGE_VERSION`）实测中，`forge script` 下脚本合约内求值 `address(this)` 即触发硬 revert（脚本合约为 ephemeral、其地址不可依赖），因此部署脚本内不得出现 `address(this)`（含 OZ `Create2.sol` 二参 `computeAddress` 与 `Create2.deploy`，二者内部均使用 `address(this)`），creator 必须取链上常量地址。前置条件——各目标链必须已在上述 canonical factory 地址部署 deterministic-deployment proxy（该地址无代码时须先按其 canonical 部署流程补齐再广播）；`OutstakeScript.s.sol::_assertOutrunDeployer` 为纯地址计算，不校验 factory 是否在链上存在，缺链 factory 只会在 `_deployOutrunDeployer` 广播时以 revert `FactoryDeployFailed` 暴露。断言与 `_deployOutrunDeployer` 调用点共用 `OutstakeScript.s.sol::run` 内同一 nonce 单常量，不存在独立的 nonce env 变量；其中 `_deployOutrunDeployer` 当前在 `OutstakeScript.s.sol::run` 中被注释，跨链部署启用时按需解除注释。

## L2 oracle-backed SY 部署校验清单

`OutrunL2OracleBackedSYUpgradeable.sol::__L2OracleBackedSY_init` 的 `underlyingAssetOnEthAddr_` / `underlyingAssetOnEthDecimals_` 为 L1 侧信息，L2 链上无法 `IERC20Metadata.decimals()` 核验。误配会经 `OutrunStakingPositionUpgradeable.sol::initialize` 冻结 `canonicalAssetDecimals`，再经 `OutrunStakingPositionUpgradeable.sol::_scaleCanonicalAssetToUAsset` 系统性错标（如 stETH 18 填成 6 则放大 1e12）。本仓库以部署期断言收敛该风险，链上不做上游 decimals 查询。

- 校验入口：`L2AssetValidation.sol::validateL2OracleBackedParams`（`script/lib/L2AssetValidation.sol`）。当前部署脚本未为 `OutrunL2WstETHSYUpgradeable.sol` / `OutrunL2StakedTokenSYUpgradeable.sol` 布线部署入口；任何未来部署入口必须在 `new ERC1967Proxy` 前调用该校验，fail-fast。
- 已知资产族硬编码：`L2AssetValidation.sol::L1_STETH`（`0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`）期望 `18`，不匹配即 `L2InvalidDecimalsForKnownAsset`。新增族时在 `L2AssetValidation.sol::_validateDecimals` 追加分支并同步本清单。
- 通用范围：未知资产仅允许 `1..18`，`0` 或 `>18` 即 `L2InvalidDecimalsZero` / `L2InvalidDecimalsOutOfRange`。该范围不区分 6 与 18 的互换，仍需人工清单复核。
- 人工清单（广播前必做，记录为验收证据）：
  1. 在 L1 主网 Etherscan / 官方文档核对 `underlyingAssetOnEthAddr_` 的真实 `decimals`，截图存档
  2. 核对 `underlyingAssetOnEthAddr_` 地址本身（非 L2 侧 token 地址），与 `YieldDeployScript.s.sol` 传入值逐字符比对
  3. 确认 `exchangeRateOracle_` 非零且已部署
  4. 广播后读取 `IStandardizedYield.assetInfo` 与 `OutrunStakingPositionUpgradeable.sol::SY` 侧 `canonicalAssetDecimals` 缓存值，确认与清单一致
- 扩展约束：`OutrunStakingPositionUpgradeable.sol::initialize` 缓存后不再重读，部署后无法通过 SY 侧更新修复 decimals；错配需重新部署 SY + SP。
- feed 信任根核对（广播前必做，记录为验收证据）：
  1. `exchangeRateOracle_` 指向的 `OutrunExchangeOracleAdapter` 所绑定 feed（`OutrunExchangeOracleAdapter.sol::oracle`）须核对为官方发布渠道：官方 feed 页比对地址与 aggregator/治理权归属，截图存档；不接受未经验证的自建或代理 feed
  2. `maxStaleness` 逐 feed 定值：部署时以链上 round 历史实测 round 节奏并留档（`latestRoundData` / `getRoundData` 回溯，定值原则与实测样本参照见 `docs/spec/yield/oracles-and-integrations.md`「边界」），取区间 `2 × 实测节奏 ≤ maxStaleness ≤ 2 天`（上限为 wstETH 家族按 Lido 跨链指引的 2 天，与 `OutrunL2OracleBackedSYUpgradeable.sol` 的 `exchangeRateOracle` 存储字段注释指引同源）；区间为空（`2 × 实测节奏 > 2 天`）时按 Lido 指引重估口径并显式留档升级决策，不静默取任一侧；部署后监控 round 节奏变化（feed 会在线降档，如 USDC/USD 2026-08 由 ~1h 降至 ~23h（行业降档实证，非本栈绑定 feed）），降档即按同区间重估窗口并经 owner 调用 `OutrunExchangeOracleAdapter.sol::setMaxStaleness` 应用（owner-only，值域 `0 < v <= MAX_STALENESS`，30 天链上上限，无 timelock）；重部署 adapter 并由 owner 换 `exchangeRateOracle` 指针仅适用于更换底层 feed 源（换指针保留已存 rate anchor，换入源仍须对旧锚点通过带界；量级合法不同的新源走 `resetRateAnchor()`，见下方锚点重置 runbook）
  3. 锚点偏差熔断阈值校准（与上条 `maxStaleness` 同法的 round 历史回测）：经 `getRoundData` 回溯 feed 全 round 历史逐参数归一定值——`maxDropBps` 取 `max(3 × 观测到的最大相邻 round 下行跳变 bps, 默认 10)`、`riseBpsPerHour` 取 `max(3 × 观测到的最大相邻 round 跳变折算 bps/hour（跳变 bps ÷ round 间隔小时数）, 默认 5)`、`maxRiseCapBps` 仍为绝对上界的校准定值（默认 200）——均只上调不下调，样本留档（阈值口径与诚实残余缺口见 `docs/spec/yield/oracles-and-integrations.md`「边界」锚点偏差熔断条目）
  4. L2 部署须配置非零 `sequencerUptimeFeed`，`sequencerGracePeriod` 落在恢复宽限合理区间（建议 30 分钟至 1 天），防 sequencer 恢复窗口内消费旧价
- 监控告警（链下必配）：
  1. 率漂移告警（双向监控，偏高与偏低均告警）：逐实例监控 `OutrunExchangeOracleAdapter.sol::getExchangeRate`（经 `OutrunL2OracleBackedSYUpgradeable.sol::exchangeRate` 透传至 `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate`）读值相对外部可信参考（官方数据源或近期读数中位数）的偏离，超阈值即告警——单 round 跳变已由 oracle-backed SY 基类锚点偏差熔断链上拦截（带外读数 revert `RateDeviationExceeded`，fail-closed 冻结铸造面，按秒累计带宽语义见 `docs/spec/yield/oracles-and-integrations.md`「边界」），链下监控重心为带内缓变漂移（累计/持续漂移无链上拦截，`maxRiseCapBps` 只封界自最近一次锚点写入起的单窗口超铸——每次带内 `commitRateAnchor` 重定带基准，持续提交可使锚点按 `riseBpsPerHour`/hour 复利上旋、累计无上限，锚点永不超出真实 oracle 读数，跟踪腐化 feed 的累计漂移仅由单源 oracle 信任与监控约束）与治理事件监视（`RateAnchorCommitted` 的节奏与幅度异常即告警——锚点推进速率监视，不只盯带界；`RateAnchorReset` / `SetRateBreakerParams` / `SetExchangeRateOracle` / `OutrunExchangeOracleAdapter.sol::SetMaxStaleness` 任一事件即告警复核——owner 可换源、可重置锚点、可改带宽、可调 adapter 新鲜度窗口，产品模型为 owner-only，仅监控缓解）；v1 oracle fail-closed 栈（适配器新鲜度栈 + SY 基类锚点偏差熔断）是 SP 率值完整性（喂价异常导致超铸）的唯一链上防线（`docs/spec/yield/oracles-and-integrations.md`「边界」；背书代币丢失维度由 resident 背书对账守卫守，见「SY 背书沦陷应急处置」节）：带内 fresh 偏高 answer 的窗口内 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（面值铸出）按偏高面值超铸（背书缺口直接成形）；fresh 偏低 answer 为静默低估铸出（协议侧安全方向）；`redeem` SY 直出不读率（owner 退出通道，oracle 无关）
  2. 应急联动：告警触发后 owner 执行 `OutrunStakingPositionUpgradeable.sol::pause` 冻结用户面，并以 `OutrunUniversalAssetsUpgradeable.sol::setMintingCap(SP, 0)` 封顶续铸敞口（唯一供给刹车）；恢复前先核对率源回归可信区间，再经 `OutrunStakingPositionUpgradeable.sol::currentRate` 与 `positionDebt` 视图族核对存量仓位计息后评估 `unpause`
  3. keeper 职责（锚点推进）：周期性调用 `OutrunL2OracleBackedSYUpgradeable.sol::commitRateAnchor`（permissionless）推进 rate anchor——带界上行额度自锚点 timestamp 起按秒连续累计且封顶 `maxRiseCapBps`，周期推进使正常运行时带宽收敛在最小额度；commit 重置 elapsed 无可用性损失（额度自新锚点起随秒连续重积，现实 feed tick（逐 round +wei 量级）数秒内即通过带界）；keeper 停摆不放大带宽超过 cap，只使上行额度随时间向 cap 逼近（带内缓变漂移敞口随之变大，属监控项 1 的监控对象）
  4. 锚点重置 runbook（合法 regime 变更）：feed 源迁移等量级合法变化会使新读数对旧锚点带外、铸造面持续 fail-closed；恢复路径为 owner 先核验新 feed 读数符合预期（相对外部可信参考比对），再调用 `OutrunL2OracleBackedSYUpgradeable.sol::resetRateAnchor` 采纳当前读数为新锚点（emit `RateAnchorReset(uint256 indexed oldAnchor, uint256 indexed newAnchor)`，事件复核）——不得以 `setRateBreakerParams` 放宽带宽替代核验，不得对未核验读数重置锚点
  5. 边界标注：单 round 跳变的链上拦截由 oracle-backed SY 基类锚点偏差熔断承担；残余为带内缓变漂移与 owner 换源/重置信任——单源消费为 `docs/spec/yield/oracles-and-integrations.md` 明文钉住的设计（v1 无独立第二源），带内漂移带宽监控与治理事件复核由链下完成（本节即该分派的运维落点，accepted risk）

## 跨链限流（OFT Outbound Rate Limit）高危参数校验清单

`OutrunOFTUpgradeable.sol::setOutboundRateLimit` 的 `limit` 为 LD（local decimals）单位，与 `OutrunOFTUpgradeable.sol::_debit` 的 `amountSentLD` 同单位（`OutrunRateLimiterUpgradeable.sol` 的 `RateLimit` struct 单位注释）。18-dec 部署下 `DCR = 1e12`，1 token = 1e18 LD = 1e6 SD，`1e12`（1 SD 单位 = dust 阈值）若被当作 LD 传入则任何真实出站立即 `RateLimitExceeded`，静默 fail-closed 停摆（与 oracle 换址误配同方向的静默停摆类高危）。NatSpec 已在 `OutrunOFTUpgradeable.sol::setOutboundRateLimit` 明示 `Do NOT pass SD — 1e12 equals only 1 dust unit`，本清单为运维二次确认。

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
- 暂停误用警告：`removeOutboundRateLimit` 会 `delete` 整条 `RateLimit` 记录（`amountInFlight/lastUpdated/limit/window` 一并清零），重设 `setOutboundRateLimit` 后从零会计、满额开始，不保留衰减后残留；不可当作“暂停限流但保留会计”的开关。需保留会计的暂停应直接重配（`setOutboundRateLimit` 会先以 `amount==0` checkpoint 结算，见 `OutrunRateLimiterUpgradeable.sol::_setRateLimits`）或使用 `pause` 熔断；删除后应监控 `OutboundRateLimitRemoved` 与 `isRateLimited(dstEid)==false` 的无限态，重设后复核 `isRateLimited==true` 且 `getAmountCanBeSent` 接近新限额（见 `docs/spec/common-foundations.md## OFT 与 rate limiter` 与 `OutrunRateLimiterUpgradeable.sol::_deleteRateLimit` 的 NatSpec）
- 销债可达性校准：每个 live eid 的 `limit`/`window` 须相对该 uAsset 的跨链流通分布与预期回桥销债流评估后配置；运行期调低限额前须评估对销债可达性的影响（重配先以 `amount==0` checkpoint 结算，已 in-flight 超新限额时可用额度瞬态为 0，存在瞬态全阻断窗口，见上文「暂停误用警告」）；对 live eid 的持续 `RateLimitExceeded` 按「销债可达性事件」口径告警处置——出站额度为该方向全部流量共享、无按用途豁免，回桥受阻即跨链持币用户 `OutrunStakingPositionUpgradeable.sol::redeem` 事实上不可达（fail-closed 流动性中断、无资金损失）；口径对齐 `docs/spec/protocol.md`「跨链可用性与限流」。

## 跨链信任根投产校验与应急处置

`OutrunOFTUpgradeable.sol::_credit` 的入站铸币权完全委托给 LayerZero `endpoint` / `DVN` / `peers` 三元组（`OAppUpgradeable::lzReceive` 校验后经 `OFTCoreUpgradeable::_lzReceive` 调 `OutrunOFTUpgradeable::_credit` 直调 `OutrunERC20Upgradeable::_update` 铸造，不叠加链上二次签名/金额复核）。该路径为跨链活性刻意 bypass `OutrunERC20PausableUpgradeable::whenNotPaused`（`docs/spec/common-foundations.md## Pause 与跨链 OFT 执行边界`、`docs/spec/common-foundations.md## OFT 信任根与入站不限流/暂停豁免边界`），但导致目标链单方 `pause()` 不阻断入站增发，`totalSupply` 可单边增长需告警（`test/upgradeable/OutrunStakingPositionUpgradeable.t.sol::OutrunStakingPositionPauseMatrixTest` 回归）。语义真值在 `docs/spec/common-foundations.md`，本节为操作真值。

- 信任根：`endpoint` 地址、`DVN` quorum/`enforcedOptions`/`ULN` 配置、`peers[dstEid]` 三者即为伪造边界；任意一方被接管/误配即可按 `uint64` wire 包络 `OutrunOFTUpgradeable::_maxOFTAmountLD = type(uint64).max × decimalConversionRate` 单消息任意 `_amountLD`、无限消息累积铸造，无链上 cap。
- 限流与暂停边界：`OutrunRateLimiterUpgradeable::_outflow` 仅在 `OutrunOFTUpgradeable::_debit` 出站 burn 前记账，`_credit` 入站不经限流、不减 `amountInFlight`；`getAmountCanBeSent`/`quoteOFT` 的出站可用额度不约束入站；单链 `pause()` 仅阻断本地 transfer/`mint`/`repay` 与 pause 之后新发起的 outbound send，不阻断已在途入站。
- 投产校验（每条 `dstEid` peer 部署/变更后必做，记录为验收证据）：
  1. 调用 `peers(dstEid)` 核对远端 uAsset 地址与各链同址预期一致；核对 `endpoint` 地址与部署配置一致
  2. 核对 DVN quorum 与 `enforcedOptions` 在源/目的链对称配置，`quoteSend` 探测往返
  3. 调用 `isRateLimited(dstEid)` 确认为 `true` 且 `getAmountCanBeSent` 接近限额，监控 `OutboundRateLimitRemoved` 与新 `peers` 的无限态
  4. 读取 `nextNonce`/`allowInitializePath` 路径状态：排序未启用——`nextNonce` 取上游默认 0，不要求按序投递（安全前提是 OFT 报文无状态可交换，见 `docs/spec/common-foundations.md`「OFT 信任根与入站不限流/暂停豁免边界」）；`allowInitializePath` 取默认 peer 校验
- 监控告警（链下必配）：
  1. 暂停期入站告警：`paused()==true` 期间的 `_credit` mint（`Transfer(address(0), to, amount)` 且 `srcEid` 非零来源）与 `totalSupply` 单边增长；告警阈值按 `rateLimiter.limit × peers` 估算在途上限
  2. 跨链突增告警：`totalSupply` 跨链突增、单笔 `amountLD` 接近 `uint64.max × DCR`、单位时间 `_credit` 次数/总量异常
  3. 配置漂移告警：`PeerSet`/`OutboundRateLimitSet`/`OutboundRateLimitRemoved`/`EnforcedOptionSet` 等事件的未授权变更
  4. 卡报文积压告警：`PacketVerified` 未伴随 `PacketDelivered` 的 verified-not-executed 报文数量与最长滞留时长，排除已发 `PacketNilified`/`PacketBurnt` 终态的 nonce（nilify 为待重验暂停态、burn 为永不可执行态，二者均不再发 `PacketDelivered`）；源链已 burn、目标链未铸的在途敞口上限按 `Σ rateLimiter.limit × peers` 估算；超阈值触发应急处置第 4 条
- 应急处置 runbook（活性豁免的运维收敛，`pause` 为不完全熔断）：
  1. 定序：先在所有对端链暂停出站（`pause()` 阻断 `send`/`_debit`），再在目标链 `pause()`；仅暂停目标链不能止血，已在途报文仍会 `lzReceive→_credit` 铸造（endpoint 时序决定，非 `block.timestamp`）
  2. 止血：对受影响 `srcEid` 执行 `setPeer(eid, bytes32(0))` 撤销 peer（`onlyOwner`），阻断该通道后续 `lzReceive` 的 peer 校验；必要时同步调整 DVN/`enforcedOptions` 或暂停 endpoint 通道
  3. 排空：在途报文上限 = `Σ rateLimiter.limit`（每 peer 独立），需等待或按第 4 条卡报文处置排空后，再 `unpause()` 恢复
  4. 卡报文处置（verified-not-executed）：先重试——修复 executor gas/配置后，任何人可携带原报文重调 `EndpointV2.sol::lzReceive`（payloadHash 留存即可重试，无需重新 verify）；`EndpointV2.sol::clear`（OApp/delegate 授权）仅为最后手段——对 OFT 等价 burn-without-mint（源链已 burn、目标链永不铸），执行前必须先落用户补偿方案，与禁忌条目同类永久损失；重试恒 revert 且已发 `PacketNilified`/`PacketBurnt` 的报文按其终态处置（nilified 待 DVN 重验后恢复可执行、burnt 已终局），勿对其叠加 clear
  5. 禁忌：不可通过给 `_credit` 加 `whenNotPaused` 代码修复——会造成源链已 burn、目标链 revert 的永久丢资产（burn-without-mint），与暂停矩阵的活性保证冲突；本处置为文档/监控收敛，无代码改动（accepted risk）

## SY 背书沦陷应急处置

名义余额族 SY 适配器（Sky L2 sUSDS、主网 wstETH/sUSDS/sUSDe 三族、slisBNB、asBNB 与 L2 oracle-backed 变体共七成员）在各自 `exchangeRate` 入口设有 resident 背书对账断言：断言为 `SYBaseUpgradeable` 共享实现（`SYBaseUpgradeable.sol::_revertIfBackingBelowShares`），适配器自持 yield-bearing-token 余额低于流通 SY `totalSupply` 时 revert `InsufficientBacking(uint256 residentBacking, uint256 outstandingShares)`（fail-closed）。守卫语义、单位约定依据与诚实边界在 `docs/spec/yield/yield-adapters.md`「SY 错误面与初始化约束」，本节为操作真值。

- 识别信号（链下必配监控）：
  1. 交换率读取处 revert：SP 全部换算经 `OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 汇入 `exchangeRate`，任一读率用户面入口（`stakeForGenesis` 及 preview 视图族，与 `docs/spec/position/accounting.md` §11 的 `ZeroExchangeRate` 消费面一致）回退 `InsufficientBacking(uint256 residentBacking, uint256 outstandingShares)` 即为守卫触发；`redeem` 的 SY 直出路径不读率（owner 退出通道），守卫触发时仍可用——用户仍可经 redeem 换出背书已失的 SY，为有意的退出通道保留，不是遗漏
  2. 余额对账告警：适配器自持 yield-bearing-token 余额监控跌破流通 SY `totalSupply`（应先于断言触发告警；断言已触发时本地用户面已自动冻结）
- 守卫效果：本地 SP 用户面自动冻结（面值铸出路径 fail-closed；`redeem` 不读率，守卫触发时仍可用——退出通道保留），不依赖 owner 响应；守卫只阻断续铸，不恢复已失背书。守卫触发 ≠ pause 态：SP `paused()` 仍为 false，仅上述率读取入口（及对应 preview）revert；需 owner 的熔断仍按定序显式 `pause()`。
- 应急处置 runbook（对齐上文 OFT runbook 的排序逻辑——先断对端、再断本地）：
  1. 定序：先在所有对端链暂停出站（对端 `pause()` 阻断向本链的 outbound send），再在本地 `pause()`
  2. 入站豁免注意：`OutrunOFTUpgradeable.sol::_credit` 的跨链活性豁免使单链 `pause()` 不阻断对端铸入（见上文「跨链信任根投产校验与应急处置」），在途报文仍可能落地增发——对端出站暂停必须先行
  3. 清盘路径：对受影响 SP 执行 `OutrunUniversalAssetsUpgradeable.sol::setMintingCap(SP, 0)` 封顶续铸，或 `OutrunUniversalAssetsUpgradeable.sol::revokeMinter` 撤销其铸币权
- 恢复前置：背书缺口清算（resident backing 补足至 ≥ 流通 SY `totalSupply`）确认后才可 `unpause()`，未确认背书恢复前不解除暂停（选项 B 的受控解冻窗口为唯一显式例外，见下）。若未执行本地 pause，背书补足后守卫即自动放行，无需 unpause。若迁移至新 SY/新 SP（SP 无换绑 SY 入口），原 SP 终局取下述两个显式选项之一，由 owner 按事件裁量，不可混用——不得在“不解除暂停”的表述下声称走完存量清偿中段：
  1. 选项 A（冻结迁移，默认）：原 SP 保持 paused，`OutrunUniversalAssetsUpgradeable.sol::setMintingCap`(SP,0) 阻断新铸；存量仓位与 minter 债务记录冻结在链上——存量清偿入口 `OutrunStakingPositionUpgradeable.sol::redeem` 带 `whenNotPaused`，paused 期不可用；收尾可直接 `OutrunUniversalAssetsUpgradeable.sol::revokeMinter` 清盘，或保留冻结态等待链上/链下清算方案；用户资金迁移经新 SY/新 SP 承接。
  2. 选项 B（受控解冻清偿）：若选择按 `OutrunStakingPositionUpgradeable.sol::redeem` 完成存量清偿（本金腿 burn 冲销 minter 台账，至第一行对账式归零，见 `docs/spec/position/accounting.md` §10.2），必须显式接受“临时 unpause 窗口内赎回的是背书已失的 SY”这一风险并配套补偿/公告方案；清偿完成后 `OutrunUniversalAssetsUpgradeable.sol::revokeMinter` 收尾。
- 投产前置校验（守卫记账前提，投产前必做并记录为验收证据）：背书对账守卫按名义转账额记账（存款转入 N 即背书 +N、份额 +N），其前提是所绑 yield-bearing token 为标准代币（非 fee-on-transfer，名义转账额 = 实收额）。若部署绑定的 yield-bearing token 存在转账损耗，每次存款流通份额增量将超过背书增量，守卫将持续回退 `InsufficientBacking(uint256 residentBacking, uint256 outstandingShares)` 并冻结全部读率入口（见上「识别信号」）；投产前必须核实所绑 YBT 无转账损耗。

## SP 退役清盘布线（v1 无清算，无 keeper 布线）

position 层为 v1 收益背书凭证层（genesis-only、面值铸造、0% 利率默认、无清算，`docs/spec/position/accounting.md`、`docs/spec/position/state-machines.md`），不存在 keeper / harvest / wrap / 清算角色与布线面；仓位出清唯一通道为 owner `redeem`（SY 直出 oracle 无关）。

- 无清算布线项：v1 链上不设清算、LTV 或再融资机制，无清算人激励与触线监控布线；风险承接按五层瀑布（集成准入 → 发行方自救 → 协议桥接 → 收入年金 → 终局脱钩社会化，见 `docs/ARCHITECTURE.md` §7）与「SP v1 运行手册」的背书率监控执行。
- SP 退役清盘路径（活 SP 退役的标准序，对齐 `docs/spec/position/accounting.md` §10.2 第一行）：`OutrunUniversalAssetsUpgradeable.sol::setMintingCap(SP, 0)` 封顶续铸（唯一供给刹车）→ 存量仓位经 `OutrunStakingPositionUpgradeable.sol::redeem` 清偿（本金腿 burn 并冲销 minter 台账，第一行对账式归零）→ `OutrunUniversalAssetsUpgradeable.sol::revokeMinter` 收尾（`revokeMinter` 只封未来 mint，不清既有 `amountInMinted`，故必须在存量清偿后执行）。
- 投产校验：
  1. `setMintingCap(SP, 0)` 后新开仓预期 `ReachMintCap`，既有仓位的 `redeem` 仍可用
  2. 清盘收尾后 `mintingStatusTable(SP).amountInMinted == 0` 且 `mintingCap == 0`（`SetMintingCap`/`RevokeMinter` 事件核对）

## SP v1 运行手册（背书率监控、恢复 playbook 与集成复审）

v1 链上不设保险、清算或再融资机制，风险按五层瀑布承接（声明见 `docs/ARCHITECTURE.md` §7）；本节为链下运行真值。

### 背书率监控

- 监控口径：看**趋势**，不看绝对值 100%——0 利率 + 抵押生息下，收益率基数继续向上即自愈（背书不变式 `docs/spec/position/accounting.md` §10.3）；汇率小幅回撤（LST 削罚量级）属可吸收形态。
- 告警阈值绑定「**汇率回撤事件**」（各集成 SY 的 `exchangeRate` 回撤幅度/持续时间越过该集成的尽调回撤档案阈值）而非「背书率 < 100%」；oracle 读值漂移告警另见「L2 oracle-backed SY 部署校验清单」监控节。
- 加息（`duty > 1e27`）后监控口径变更：债务恢复计息（利息腿）后背书率不再单调上升，监控口径需计入利息腿增量（`pendingInterest`/`accruedInterest` 并入分子），并按「发行方自救 → 协议桥接 → 收入年金」逐层评估偿付来源。

### 恢复 playbook 骨架（背书缺口事件）

pause → 缺口评估 → 发行方追回等待 / 协议桥接 → 收入优先级偿付 → 复盘与白名单复审：

1. **pause**：owner `OutrunStakingPositionUpgradeable.sol::pause` 冻结铸造面，`OutrunUniversalAssetsUpgradeable.sol::setMintingCap(SP, 0)` 封顶续铸（唯一供给刹车）；`redeem` SY 直出（oracle 无关）是否保留按缺口性质裁量（对齐「SY 背书沦陷应急处置」选项 A/B）。
2. **缺口评估**：按各仓铸造时点汇率计 `Σ collateralValue` 与 `Σ principalDebt`（背书不变式聚合口径），量化缺口规模与发行方追回可能性。
3. **发行方追回等待 / 协议桥接**：梯队发行方自救（被盗追回、保险基金、国库回补）为中型事故第一消化层；等待期流动性缺口由协议金库存量桥接（前期薄，时序风险如实声明）。
4. **收入优先级偿付**：协议后续收入（v1 已建收入源 = PSM 点差 tin/tout，沉淀费额经无许可 `OutrunPSMUpgradeable.sol::sweepFees` 提取至部署期绑定的 `feeRecipient`，见「PSM 部署接线」）优先处理坏账（政策承诺）。
5. **复盘与白名单复审**：按下方触发条件复审集成名单，复盘结论记录为验收证据。

### 集成准入尽调与复审

- **集成汇率回撤尽调清单（准入标准三要素，准入前必做并记录为验收证据）**：(i) 发行方梯队——背景、管理规模、事故应对历史；(ii) 汇率行为尽调——**历史最大回撤 + 回补机制**（逐集成建立回撤档案，作为背书率监控告警阈值的定值输入）；(iii) oracle 栈兼容——现有 fail-closed 全集（正性/新鲜度/sequencer/归一化非零）。准入五家族名单、EtherFi 剔除裁决及 Aster 原始剔除评估（2026-09 再裁决重新准入 v1）见 `docs/ARCHITECTURE.md` §7，per-链 SY 候选见 `docs/spec/yield/yield-adapters.md`「v1 集成准入与 per-链 SY 候选（部署视角）」。
- **集成复审触发条件**：发行方治理重大变更、汇率回撤事件（越过尽调回撤档案阈值）、oracle 源变更；触发后按准入标准三要素重评并留档。
- **治理操作 timelock 评估提示**：SP/uAsset/SY 三 owner 主网前收敛为 timelock/multisig（见「跨链信任根投产校验与应急处置」与 `docs/spec/position/state-machines.md` §8.5）；高危治理操作（`setDuty` 加息、`setMintingCap`、`transferMinterDebt`、`setReserveMinter` 撤销、`resetRateAnchor` 换源/重锚定、`setRateBreakerParams` 放宽带宽、UUPS 升级）逐项评估是否纳入 timelock 延时窗口与双人复核，评估结论记录为上线验收证据。权限分层：pause 动作允许快速路径（multisig/keeper 秒级执行），`unpause` 与 owner 变更走 timelock/治理延时——错误恢复比错误暂停危害大，见下「暂停矩阵运维（协同约束与告警）」。`setDuty` 加息（`duty > 1e27`）执行前另须完成并留痕 `docs/spec/position/accounting.md` §6「加息前置校准」的三项治理前置。

### 暂停矩阵运维（协同约束与告警）

暂停矩阵语义真值在 `docs/spec/position/state-machines.md` §8.4，本节为 `docs/deployment.md` 侧的协同约束落点与链下告警配置。

- uAsset 协同约束：存在待赎回仓位时，uAsset 单独暂停会阻断全部销债出口（本金腿 `repay` 与利息腿 transfer 均被阻）；计划内操作禁止单独 `uAsset.pause()`——需与 `position.pause()` 同步执行，或改用 `setMintingCap`/`revokeMinter` 仅限制 mint 面（沿用 `docs/spec/position/state-machines.md` §8.3 既有语义）；紧急场景（uAsset 自身故障、跨链信任根事故）可单独执行立即止血，但须事后公告与补齐协同暂停。
- SY 单独暂停：存在活跃仓位时效果等价冻结全部赎回出口（`redeem` 两条输出路径均经 SY）。紧急场景（SY 自身故障、底层协议事故）必须保留单独立即暂停能力，不设操作禁令；计划内维护推荐先 `position.pause()` 再 `sy.pause()`（仅为推荐顺序，非硬约束）。与 uAsset 的不对称依据：uAsset 暂停附带 `_credit` 单边供给增长与全协议熔断副作用，故计划内禁止单停；SY 暂停只冻结赎回出口、无单边供给增长副作用，故不设禁令仅告警。
- 监控告警（链下必配）：
  1. 单边态告警：`SY.paused() == true && SP.paused() == false` 即触发——该状态对用户是「系统看似正常但出金全断」的隐蔽锁定，必须显式告警
  2. SY 暂停时长告警：`<24h` 阈值，与 uAsset 暂停时长告警对齐（见 `docs/spec/position/state-machines.md` §8.4 运维条目）
  3. 暂停事件告警：SP/SY/uAsset 任一 `Paused` / `Unpaused` 事件即入告警通道；`EnforcedPause` 为 revert error 非事件，其观测（failed tx / RPC 日志）作为补充信号
- 权限分层：SP/uAsset/SY 三 owner 收敛条目（见上「治理操作 timelock 评估提示」）下，pause 动作允许快速路径（multisig/keeper），`unpause` 与 owner 变更走 timelock/治理延时。

## PSM 部署接线（现状：单实例单储备已落地（四实例 + (uAsset, reserveToken) 配对绑定），详见下文各节标注）

PSM 行为规格真源为 `docs/spec/psm/peg-stability-module.md`；本节只落部署与接线顺序。

- 实例粒度（现状即单实例单储备，共四实例）：四个 `OutrunPSMUpgradeable` 实例（UUSD 拆为 USDC-PSM 与 USDT-PSM 两实例，UETH / UBNB 各一原生实例，UUPS + `ERC1967Proxy` 部署，每实例独立 CREATE3 部署，UUSD 两实例 salt stem 区分——salt stem 区分与 `OutrunPSMUpgradeable.sol::initialize` 加 `reserveToken` 均为已落地现状）；`OutrunPSMUpgradeable.sol::initialize` 参数为 uAsset、reserveToken、owner、feeRecipient、初始 `stockCap` / `tin` / `tout`，按各自边界校验（cap > 0、0 ≤ fee ≤ 1%、feeRecipient 非零，零地址 revert `ZeroInput`——部署期需指定金库/财务地址并核实非零）；`reserveToken` 与 `feeRecipient` 初始化后均 immutable（UETH / UBNB 实例 reserveToken 为 NATIVE 哨兵 `address(0)`，UUSD 两实例分别为 USDC / USDT 地址），无 setter、无注册表；计费结余经无许可 `OutrunPSMUpgradeable.sol::sweepFees` 提取至 `feeRecipient`（详见 `docs/spec/psm/peg-stability-module.md`）；上线默认 `tin` = `tout` = 0.1%，如无差异化定价需求按默认部署。部署前置：NATIVE 腿（UETH / UBNB）实例的 `feeRecipient` 必须可接收 native 转账——收款地址拒收会使该实例 `OutrunPSMUpgradeable.sol::sweepFees` 永久 revert、计费结余滞留 PSM 内作储备覆盖（无资金损失但费额出口失效），部署前应探测收款能力。
- uAsset 侧登记：uAsset owner 为每个 PSM 实例逐个调用 `OutrunUniversalAssetsUpgradeable.sol::setReserveMinter(psm, true)` 登记为储备 minter（`SetReserveMinter` 事件为审计点）；撤销某实例登记 `setReserveMinter(psm, false)` 即该实例双向兑换 kill switch（`NotReserveMinter`，fail-closed），不影响其它实例。
- 储备地址前置校验：无 PSM 侧储备登记步骤；`PSM_USDC` / `PSM_USDT` 保留为储备地址（UUSD 两实例的绑定储备），登记前必须核实无转账损耗（标准币前提：非 fee-on-transfer/非 rebasing，名义转账额=实收额）；UETH / UBNB 实例绑定原生腿（NATIVE 哨兵），不消费该两键。该前置域封闭为上述标准币，与 `docs/spec/psm/peg-stability-module.md` 前置条件及 `docs/spec/yield/yield-adapters.md` 投产前置校验同源。uAsset 侧 minter 登记完成后该实例兑换入口方可用。
- router 布线（路径 A 配对寻址，现状即配对三参）：router owner 按 (uAsset, reserveToken) 配对逐个调用 `OutrunRouter.sol::setPsmForUAsset(uAsset, reserveToken, psm)`——零 `uAsset` revert `UntrustedRouterTarget`；无代码 `psm` 在绑定读取以底层解码错误回退（非具名错误）；uAsset 绑定不一致 revert `PsmBindingMismatch`，储备绑定不一致 revert `PsmReserveMismatch(psm, reserveToken, actualReserveToken)`；登记后读取 `OutrunRouter.sol::psmForUAsset(uAsset, reserveToken)` 与 `PsmForUAssetUpdated` 事件核对；撤销 `setPsmForUAsset(uAsset, reserveToken, address(0))` 后该配对 `OutrunRouter.sol::genesisByPSM` fail-closed（`UnregisteredPsm(uAsset, reserveToken)`），不影响其它配对。
- 初始 stock cap 部署期定值原则（目标；现状为单族 cap）：`stockCap`（各实例净铸出存量上限）锚定该实例计划储备注入规模——净铸出上限不应显著超出可注入储备，使 PSM 供给始终有足额储备背书；单笔兑换规模无独立限流参数（mint 侧实际单笔上限即本实例 stockCap 剩余 headroom，redeem 侧为本实例实际持有的绑定 reserve 余额，超大额兑换不受拆单限制）；cap 恒 > 0、setter 拒绝置零，PSM 不存在 cap 关闭态。
- 监控告警（链下必配）：各实例绑定 reserve 实际余额的深度枯竭监控（主口径为绑定 reserve `balanceOf(psm)`，native 腿为合约 native 余额；`OutrunPSMUpgradeable.sol::sweepableFees` 为费额结余口径（非深度度量，常态近零），仅作对账辅助）——PSM 无时间窗限流为有意设计，绑定储备可在单块内被抽干，枯竭关闭的是该实例 uAsset→reserve 面值出口（非借款人回锚 redeem 腿；借款人债赎 SP `redeem` SY 直出与 PSM mint 面值铸出不依赖储备余额，风险落在持有人面值退出关闭与折价无界加深），按该实例回锚管道关闭事件口径告警处置；监控与校准要求对齐 `docs/spec/psm/peg-stability-module.md`「储备消耗监控与校准」。
- 投产前置校验（储备记账前提，投产前必做并记录为验收证据）：PSM 储备按名义转账额记账，其前提是所绑储备为标准币（非 fee-on-transfer/非 rebasing，名义转账额=实收额），UUSD 两实例 USDC/USDT 与原生腿均满足该前提，与 `docs/spec/psm/peg-stability-module.md` 前置条件及 `docs/spec/yield/yield-adapters.md` 投产前置校验同源；绑定前必须核实 `PSM_USDC`/`PSM_USDT` 无转账损耗。
- 投产验收：`OutrunPSMUpgradeable.sol::quoteMint` / `::quoteRedeem` 与执行输出一致（零 oracle 确定性；dust 零输出域除外——quote 返 0 而执行 revert `ZeroInput`，见 `docs/spec/psm/peg-stability-module.md`「零输出守卫」）；`SwapMintForUAsset` / `SwapRedeemForReserve` 事件与双侧余额核对；按实例口径的储备守恒式（「本实例所持绑定 reserve 按面值折算后余额（`余额 × _faceValueScale`，6-dec 储备×1e12，原生腿×1）== 该实例累计净流入面值 + 该实例未提取计费结余」，以前置标准币前提与『赎回的 uAsset ⊆ 本实例铸出』流内前提为成立条件；混合外部赎回流量下精确等式不再保证，退化为 `绑定 reserve 面值 ≥ 本实例 netUAssetMinted` + 余额硬边界与 `netUAssetMinted` 对账，见 `docs/spec/psm/peg-stability-module.md`「储备侧账务与 minter 豁免」）核对，结果记录为验收证据。
- 部署 env 键（`OutstakeScript` 侧 PSM 布线；必填键缺失即 revert，fail-fast；消费调用点按实例拆分，UUSD 两实例 salt stem 区分，当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释）：

  | env 键 | 必填 / 可选 | 默认值 |
  | --- | --- | --- |
  | `UETH_PSM_STOCK_CAP` / `UUSD_USDC_PSM_STOCK_CAP` / `UUSD_USDT_PSM_STOCK_CAP` / `UBNB_PSM_STOCK_CAP` | 必填（每实例独立，四键均为已落地现状） | 无 |
  | `PSM_USDC` / `PSM_USDT` | UUSD 两实例必填（分别为 USDC-PSM / USDT-PSM 的绑定储备地址；UETH / UBNB 原生实例不消费） | 无 |
  | `PSM_FEE_RECIPIENT` | 必填（fee recipient 经 `OutrunPSMUpgradeable.sol::initialize` 绑定，之后 immutable，零地址 revert） | 无 |
  | `PSM_TIN` / `PSM_TOUT` | 可选 | `1e15`（0.1%） |

  PSM 布线要求 router 仍归部署 EOA 所有（`OutstakeScript.s.sol::_validatePSMDeploymentConfig` 预检 broadcaster-is-owner 与 router self-ownership）；若已按推荐工作流把 router `transferOwnership` 给 multisig，则由 multisig 广播，或由其直接调用 `OutrunRouter.sol::setPsmForUAsset`。
- 暂停语义：PSM 自身无 pause；uAsset 暂停经 `reserveMint` / `reserveBurn` 的 `whenNotPaused` 双向阻断（fail-closed），联动矩阵见 `docs/spec/protocol.md`「跨仓库接线约束（Memeverse/POLend）」与 `docs/spec/router/router-and-user-flows.md` §10。

## USR 部署接线

USR 行为规格真源为 `docs/spec/usr/usr-vaults.md`；本节只落部署与运营入口。

- 实例粒度：每个 uAsset 族一个 `OutrunUSRVaultUpgradeable` 实例（suETH / suUSD / suBNB，share 即该族 suToken，UUPS + `ERC1967Proxy` 部署）；`OutrunUSRVaultUpgradeable.sol::initialize` 绑定该族 uAsset 资产地址与 suToken `name` / `symbol`，owner 另经 init 写入——均为 immutable-style init 参数，init 后无 setter、不可变更；asset 零地址、name/symbol 空值 revert `ZeroInput`。计息锚为 timestamp 秒：换算常数 `SECONDS_PER_YEAR = 31_536_000`（365 天口径）为合约内部常数（该常数为 USR vault 合约内部专属；SP 合约内无此常数，365 天口径仅与 SP 治理侧链下年化换算式共用），非 init 参数、无 per-chain 定值。
- 布线边界：USR vault 不是 uAsset 的 minter 或储备 minter，无需任何 uAsset 侧登记；owner 面仅 `fund` / `setUsrRate` 与 UUPS 升级。
- 计息面无部署期核定项：速率语义为纯日历时间（每秒因子 `1e18 + usrRate / SECONDS_PER_YEAR`，floor），与链出块节奏无关，无年均块数定值、无 per-chain 误配风险面；`usrRate` 的上限（`1e17`）默认治理域远高于每秒增量整除归零域。
- 激活前状态：部署后 `usrRate == 0`（未激活，`accrualIndex` 停在 `1e18` 面值）；激活经 `OutrunUSRVaultUpgradeable.sol::setUsrRate` 设非零率（绝对上限 10%，越界 revert `UsrRateTooHigh`），新率前瞻生效。
- 运营入口：
  - `OutrunUSRVaultUpgradeable.sol::fund(amount)`：owner-only 计息注资，前置 owner 对 vault 的 uAsset approve；只进不出、不铸份额；`UsrFunded` 事件核对。
  - `OutrunUSRVaultUpgradeable.sol::setUsrRate(newRate)`：owner-only 设族利率；`UsrRateSet(oldRate, newRate)` 事件核对；结算在 emit 后、写率前完成（未结算时间段按旧率结算，新率前瞻生效）。
  - `AccrualIndexSettled(oldIndex, newIndex)` 可作为链下订阅源：`OutrunUSRVaultUpgradeable.sol::_settleIndex` 仅在指数实际变化时发出。
- 监控项（链下必配，口径见 USR spec）：偿付不变量 `totalSupply() × accrualIndex / 1e18 ≤ 实际 uAsset 余额` 持续成立；计息停摆告警（外推持续超封顶、指数停在封顶值——实质恢复路径是 `fund` 注资）；`UsrRateSet` 上限的治理合规复核。
  补充：可另订阅 `AccrualIndexSettled` 跟踪指数结算变化，不替代上段必配监控项。
- 部署 env 键：USR 布线无计息参数 env 键——计息换算常数为合约内部 `SECONDS_PER_YEAR`，`OutstakeScript` 侧 USR init 参数仅为该族 uAsset 资产地址与 suToken `name` / `symbol`；USR 部署调用点 `OutstakeScript.s.sol::_deploySuETH` / `_deploySuUSD` / `_deploySuBNB` 当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释。

## genesis 门控布线

genesis 路径 B（CDP 门）为 SP 原生物理门：面值开仓与全额消费由 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis` 原生门控（面值/价值平价铸出、uAsset 铸给 SP 自身、交易内全额交 launcher、后置断言；v1 唯一铸造入口），router 双入口（`genesisByToken`/`genesisBySY`）仅薄转发。布线分两侧：

- SP 侧：`genesisLauncher` 不是 initialize 参数——SP 部署默认零地址＝`stakeForGenesis` 入口禁用（`GenesisLauncherNotSet`）。测试网 mock 支持路径（`OutstakeScript.s.sol::_supportMockAUSDC` / `_supportMockSUSDS`，测试网限定）经 env 键 `GENESIS_LAUNCHER` 布线 SP 侧 setter（env 键清单与 `OutstakeScript.s.sol` 顶部 env 注释段一致维护，不引行号）；生产布线为 SP owner 手工调用 `OutrunStakingPositionUpgradeable.sol::setGenesisLauncher`（接受任意地址含零），并以 `SetGenesisLauncher(oldLauncher, newLauncher)` 事件与 `OutrunStakingPositionUpgradeable.sol::genesisLauncher` 读取值核对。
- router 侧（部署/测试期程序）：沿用 `MEMEVERSE_LAUNCHER` env 与 `OutrunRouter.sol::setMemeverseLauncher` / `SetMemeverseLauncher` 事件（见「运行时入口」）；生产 launcher 冻结为 immutable，仅经 constructor 布线，换 launcher 即重部署 router，无运行期轮换步骤。
- 同址断言（部署核对项，必做）：`SP.genesisLauncher() == router.memeverseLauncher()`——两侧必须读自同一 launcher 地址；错位时 router 路径 B 双入口（genesisByToken/genesisBySY）以 GenesisLauncherMismatch 回退（fail-closed，不交款）；残余分叉面为路径 A（router launcher 交款）与直调 SP.stakeForGenesis（SP launcher 交款）的跨路径目标分流。
- 运行期轮换原子性（部署/测试期程序，必做）：`OutrunRouter.memeverseLauncher` 与每个 `SP.genesisLauncher` 为两处独立 owner 存储，代码已在 `OutrunRouter.genesisByToken`/`genesisBySY` 入口对 `SP.genesisLauncher()` 做运行期复读校验（`GenesisLauncherMismatch`，镜像 `RouterTargetMismatch`/`PsmBindingMismatch` 风格，资金移动前 fail-closed），单侧轮换会使 router 路径 B 双入口直接 revert 以暴露漂移；该 parity 守卫在生产冻结后保留为 fail-closed 防 SP 侧漂移手段，非 dead code。router 路径 B 双入口内单侧轮换不会产生静默记账分叉——`OutrunRouter.sol::genesisByToken` / `OutrunRouter.sol::genesisBySY` 在资金移动前经 `GenesisLauncherMismatch` 回退（fail-closed），残余静默面为路径 A（`genesisByPSM`/`_genesisTail` 只用 router launcher）与直接 `SP.stakeForGenesis`（只用 SP launcher）的跨路径目标分叉（单笔内全额消费断言仍成立），冻结前部署/测试期运维仍须将两侧轮换打包在同一治理事务内原子执行（`router.setMemeverseLauncher(new)` + `SP.setGenesisLauncher(new)`）以避免服务停摆，执行后立即以 `SP.genesisLauncher() == router.memeverseLauncher()` 做链上复核并记录 `SetGenesisLauncher`/`SetMemeverseLauncher` 事件。生产无运行期双 setter 轮换步骤：router 侧 launcher 冻结为 immutable，生产换 launcher 即重部署 router + SP 侧轮换，SP 漂移触发 mismatch 回退。有意不对称：SP 侧 `OutrunStakingPositionUpgradeable.sol::setGenesisLauncher`（含零地址 kill switch）保持 live owner 能力；冻结后 SP 侧轮换触发 mismatch revert（安全 fail-closed），kill switch 仍可用。
- kill switch 运维：owner 调 `OutrunStakingPositionUpgradeable.sol::setGenesisLauncher(address(0))` 禁用 `stakeForGenesis` 入口（唯一 kill switch 形态；原 `genesisRateMultiplier` 上调收紧的第二形态随折扣机制删除）。不影响存量仓位（v1 零费默认下债务冻结），供给刹车另由 `setMintingCap(SP, 0)` 承担。
- 投产校验：测试网以 mock launcher 冒烟一次 `stakeForGenesis`——成功后 SP 的 uAsset 余额与调用前相等、`Stake` + `StakeForGenesis` 事件与 launcher 收额核对一致；`GENESIS_LAUNCHER` 布线与同址断言证据见 `test/upgradeable/OutstakeScriptMockSYDeploy.t.sol`。

## mintingCap 初始值治理

- 初值来源：CDP（各 SP）与 POLend（Memeverse 引擎侧 minter，跨仓库）的 uAsset `mintingCap` 初值均为部署期定值；v1 定位下 SP 的 `mintingCap` 是**唯一供给刹车**（原 LTV 背书保护职责并入，定值依据 = Memeverse 首期需求 + 安全余量）；部署脚本的硬编码默认值（`mintingCap = 1_000_000_000 ether`，见上文「关键约束」）仅为占位，正式上线前必须按下述治理原则核定，并经 `OutrunUniversalAssetsUpgradeable.sol::setMintingCap` 重设（`SetMintingCap(minter, oldMintingCap, mintingCap)` 事件为审计点）。
- CDP 供给锚定 PSM 储备比例（治理约束）：各族 CDP（SP）供给规模应与该族 PSM 储备锚定比例挂钩——SP 的 `mintingCap` 按该族 PSM 预计储备规模的既定比例/倍数核定，防止 CDP 供给脱离储备锚定无序扩张；比例定值属治理决策，部署验收时记录核定依据。
- POLend 侧初值：Memeverse 引擎 minter 的 `mintingCap` 按引擎侧 maxReserve 与 genesis 需求核定，且须与该族 OutStake 侧供给上限（PSM `stockCap`、CDP `mintingCap`）的相对关系核对（跨仓库检查项见 `docs/spec/protocol.md`「跨仓库接线约束（Memeverse/POLend）」）。
- asBNB / UBNB 族初始小 cap 声明：asBNB（SY 侧）/ UBNB（uAsset 侧）族上线初期以显著小于其他族的小 `mintingCap` 起步，后续按治理经 `setMintingCap` 上调；初始小 cap 期间的 `ReachMintCap` 为预期行为，不是故障。
- 部署 env 键（`OutstakeScript` 侧 mintingCap 布线；必填键缺失即 revert，fail-fast；POLend 键消费调用点 `OutstakeScript.s.sol::_registerPOLendMinter` 当前在 `OutstakeScript.s.sol::run` 中被注释，启用时按需解除注释）：

  | env 键 | 必填 / 可选 | 默认值 |
  | --- | --- | --- |
  | `SP_MINTING_CAP` | 可选 | `1_000_000_000 ether`（占位，须按上文治理原则上线前重核） |
  | `POLEND_MINTER` | 必填 | 无（Memeverse 引擎侧 minter 地址，非本仓库部署） |
  | `<SYMBOL>_POLEND_MINTING_CAP` | 可选 | 非 UBNB 族 `1_000_000_000 ether`（占位）；UBNB 族 `100_000 ether`（初始小 cap） |

## 运行时入口


部署脚本依赖环境变量注入 owner、router、launcher、协议金库（`PROTOCOL_TREASURY`）、endpoint 与外部协议地址；PSM / mintingCap 相关 env 键的必填性与默认值见上文「PSM 部署接线」「mintingCap 初始值治理」两节的 env 键表；USR 布线无计息参数 env 键（见上文「USR 部署接线」）。

Router target registry wiring：

- router、SY proxy 与 SP proxy 部署完成后，由 router owner 逐个调用 `OutrunRouter.sol::setTrustedSY(SY, true)`，再调用 `OutrunRouter.sol::setTrustedSP(SP, SY)`；后者必须使用该 SP 当前 `SP.SY()` 返回的 canonical SY，且该 SY 已先登记。
- 注册完成后读取 `OutrunRouter.sol::trustedSY` 与 `OutrunRouter.sol::trustedSYForSP`，并核对 `TrustedSYUpdated` / `TrustedSPUpdated` 事件；所有清单项验收完成前，不开放 router 的用户入口。registry 检查在用户资金 pull、`transferFrom` 和精确 approve 之前执行，未登记 target 或 pair mismatch 会回退且不移动用户资产。
- `OutrunRouter.sol::setMemeverseLauncher` 成功轮换应发出 `IOutrunRouter.sol::SetMemeverseLauncher` 事件（旧 launcher 为 `oldLauncher`、新 launcher 为 `newLauncher`）；该轮换为部署/测试期 live owner-only 程序（轮换须与每 SP 的 OutrunStakingPositionUpgradeable.sol::setGenesisLauncher 同一治理事务原子执行），生产删除，生产 launcher 冻结为 immutable（仅经 constructor 布线，换 launcher 即重部署 router）：部署验收需确认该事件及 `OutrunRouter.sol::memeverseLauncher` 读取值，并将结果记录为验收证据。
- `setTrustedSY(SY, false)` 会阻断该 SY 的直接路径及引用它的 SP 路径，但不会自动清零 SP mapping；撤销或换对时显式调用 `OutrunRouter.sol::setTrustedSP(SP, address(0))`，再按“注册 SY -> 注册 pair”的顺序接入新配置。撤销不回滚已完成 position、uAsset debt 或 SY share state。
- PSM registry（路径 A 配对寻址，现状即配对三参）与上述 target registry 同为 owner 持续 live 能力：`OutrunRouter.sol::setPsmForUAsset` 的按配对布线、`psmForUAsset` getter 与 `PsmForUAssetUpdated` 事件验收见上文「PSM 部署接线」；撤销 `setPsmForUAsset(uAsset, reserveToken, address(0))` 只阻断该配对 `OutrunRouter.sol::genesisByPSM`（路径 A，`UnregisteredPsm`），不影响 SY / SP 路径与其它配对。
- 这些 registry setter（`OutrunRouter.sol::setTrustedSY` / `::setTrustedSP` / `::setPsmForUAsset`）为持续 live 的 owner 能力（见 `docs/spec/protocol.md`「router」），不随主网上线冻结移除；`OutrunRouter.sol::setMemeverseLauncher` 不在该 live 集合内——生产 launcher 冻结为 immutable（仅经 constructor 布线，换 launcher 即重部署 router），该 setter 在部署/测试期为 live owner-only（轮换须与每 SP 的 OutrunStakingPositionUpgradeable.sol::setGenesisLauncher 同一治理事务原子执行），生产删除；首批 target 清单与 getter/event 验收完成前不开放用户入口，运行期新增、替换或撤销由 owner（multisig）按治理流程执行。

SY router wiring：

- 每个 `SYBaseUpgradeable.sol` proxy 初始化完成后，由该实例 owner 调用 `SYBaseUpgradeable.sol::setTrustedRouter(OUTRUN_ROUTER)`，再启用 `OutrunRouter.sol::redeemSyToToken`；未配置时 router 的 `burnFromInternalBalance=true` 调用会回退。
- `SYBaseUpgradeable.sol::trustedRouter` 是验收前的读取点；配置交易应核对 `SetTrustedRouter` 事件的旧值和新值。切换 router 时先设置新地址并确认读取值，再停用旧入口；设置零地址撤销 router 并使 true 分支关闭。
- owner 轮换不改变 `redeem(..., false)` 的直接赎回语义；该路径从 caller 余额烧份额，不依赖 router wiring。
- `YieldDeployScript` 路径自动完成该绑定：每个支持入口经 `YieldDeployScript.s.sol::_wireTrustedRouter` 以 `OUTRUN_ROUTER` env（必填）写入；上条手工步骤保留给非 Yield 流程。

`OutrunDeployer` 提供 owner-only 的 CREATE3 部署能力。
