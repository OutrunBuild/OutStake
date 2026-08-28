# OutStake Oracles And Integrations

## 文档目的

本文档只说明当前 upgradeable 产品真源里与 oracle 和外部 integration 相关的边界。

## 边界

本节为 `OutrunExchangeOracleAdapter` 的语义真源；其他文档（基础规则表、术语表、架构总览、implementation map）对该 adapter 的描述均为指针或摘要。

- `OutrunExchangeOracleAdapter` 仍是非 upgradeable helper
- adapter 经 `AggregatorInterface.latestRoundData()` 读取 feed（`answer` 与 `updatedAt` 取自同一 round），不使用 `latestAnswer()`
- oracle-backed SY upgradeable variants 通过 `exchangeRateOracle` storage 指向 oracle adapter
- `setExchangeRateOracle(address)` 是 owner-only
- adapter 自身做 raw answer 正性检查（非正 revert `InvalidOracleAnswer`）与 `maxStaleness` 新鲜度窗口校验（`updatedAt == 0`、`updatedAt > block.timestamp`（feed 时钟超前）或超窗均 fail-closed，revert `StaleOracleAnswer`）及可选构造期 L2 sequencer 校验，并在归一化后校验结果非零（`ZeroNormalizedRate`）；不提供 heartbeat、deviation bounds、fallback 或多源聚合保证；5 个具名错误全集声明于 `IExchangeRateOracle.sol`，校验实现见 `OutrunExchangeOracleAdapter.sol::getExchangeRate` 与 `OutrunExchangeOracleAdapter.sol::_validateSequencer`
- 构造期边界：`OutrunExchangeOracleAdapter.sol::constructor` 预计算 `_rawScale = 10 ** rawDecimals`（fail-fast）；feed `decimals() >= 78` 时 `10 ** rawDecimals` 超出 uint256，构造 revert `Panic(0x11)`、此类 feed 不可绑定——属构造期裸算术 panic，不在上述具名运行期错误之列
- 运行期边界：`OutrunExchangeOracleAdapter.sol::getExchangeRate` 归一化 `uint256(answer) * 1e18 / _rawScale` 中 checked 乘法在 `answer > floor((2**256-1)/1e18) ≈1.1579e59` 时 `uint256(answer) * SYUtils.ONE` 超出 uint256，revert `Panic(0x11)` fail-closed——属运行期裸算术 panic，不在 `IExchangeRateOracle.sol` 5 个具名运行期错误之列，与构造期 `10 ** rawDecimals` Panic 同一分隔；常规 feed 域（`decimals ≤18` 且值域远低于该阈值）不触发，极值域行为由 `MockOracleWarnings.t.sol:test_ExtremeAnswerRevertsFailClosed` 钉死为接受的 fail-closed 终态
- 构造期边界：`OutrunExchangeOracleAdapter.sol::constructor` 拒绝 `_oracle == address(0)`（revert `InvalidOracle`）与 `_maxStaleness == 0`（revert `InvalidStaleness`）；零值不代表关闭新鲜度检查——零窗口下任何 `updatedAt < block.timestamp` 的异步 feed 均判 stale，等同永久不可用，故 fail-fast 于构造期；`InvalidOracle`/`InvalidStaleness` 属构造期错误，不属 `IExchangeRateOracle.sol` 声明的 5 个具名运行期错误之列（与 `Panic(0x11)` 同一分隔）
- `OutrunL2WrappableWstETHSYUpgradeable` 是 Optimism-specific wrappable L2 wstETH variant，不属于 oracle-backed variant；当前实现没有 `exchangeRateOracle` storage / getter / setter，`exchangeRate()` 返回 `IL2StETH.getTokensByShares(1 ether)`
- L2 sequencer 校验语义（仅当构造期配置了非零 `sequencerUptimeFeed` 才启用）：① Chainlink uptime feed 编码方向与直觉相反——`answer == 0` 表示 sequencer 在线，非 0 表示宕机（revert `SequencerDown`）；② 恢复后须经过 `sequencerGracePeriod` 宽限期才采信 answer（revert `SequencerGracePeriodNotOver`）；③ `startedAt == 0`（恢复从未记录）与 `startedAt > block.timestamp`（feed 时钟超前）两类不可信状态与宽限期未过共用同一错误名，简化实现下部署排错无法仅凭错误名区分根因（如需区分可拆分错误）。校验逻辑实现于 `OutrunExchangeOracleAdapter.sol::_validateSequencer`。
- Position 侧速率读取（消费端）：`OutrunStakingPositionUpgradeable.sol::_currentExchangeRate` 为全链路唯一速率读取点，仅校验 `rate != 0`（`ZeroExchangeRate`），不设本地带宽；适配器层保 `maxStaleness`/`sequencer` 新鲜度/可用性，链上带宽监控由链下完成。名义余额族两个 1:1 适配器在该读取点上游入口另设 resident 背书对账守卫：`OutrunL2StakedUsdsSYUpgradeable.sol::exchangeRate` 与 `OutrunL2WrappableWstETHSYUpgradeable.sol::exchangeRate` 要求适配器自持 yield-bearing-token 余额 ≥ 流通 SY `totalSupply`，不足即 revert `InsufficientBacking(uint256 residentBacking, uint256 outstandingShares)`（fail-closed，随单一率读取点传导至 SP 全部换算路径；单位依据、适用范围与诚实边界见 `docs/spec/yield/yield-adapters.md`）。`docs/deployment.md`「SY 背书沦陷应急处置」为该守卫的操作端文档锚点。

## 当前 product integration surface

- Aave: `OutrunAaveV3SYUpgradeable`
- Ether.fi: `OutrunWeETHSYUpgradeable`
- Lido: `OutrunWstETHSYUpgradeable`、oracle-backed only-wstETH `OutrunL2WstETHSYUpgradeable`、Optimism-specific wrappable `OutrunL2WrappableWstETHSYUpgradeable`
- Sky: `OutrunStakedUsdsSYUpgradeable`、`OutrunL2StakedUsdsSYUpgradeable`
- Ethena: `OutrunStakedUSDeSYUpgradeable`
- Lista: `OutrunSlisBNBSYUpgradeable`
- Aster: `OutrunAsBNBSYUpgradeable`
- Generic oracle-backed L2 staked token: `OutrunL2StakedTokenSYUpgradeable`

## Evidence Rules

- Local unit tests prove only local adapter branching, arithmetic, token validation, pause, owner setter, and revert behavior.
- Fork tests prove only pinned-block interaction with configured upstream contracts.
- External protocol semantics require primary evidence: verified source, official upstream repository, official documentation, or reproducible fork trace.
- If no primary evidence exists for a behavior, it remains a trust boundary and must not be described as a local guarantee.

## 外部依赖边界

- `OutrunL2WrappableWstETHSYUpgradeable` 的 OP path rate source是 upstream L2 stETH token-native conversion call；adapter 依赖外部 token 合约的 `getTokensByShares` 行为，不在本地 oracle adapter 内提供 freshness、bounds、fallback 或多源聚合保证
- `OutrunL2StakedUsdsSYUpgradeable` 的 `exchangeRate()` 率源为 `OutrunL2StakedUsdsSYUpgradeable.sol::initialize` 经 `IPSM3.rateProvider()` 绑定的 SSR RateProvider（外部依赖），PSM3 `previewSwapExactIn` 仅作 `maxDeviationBps` 偏差守卫引用（与 `docs/spec/yield/yield-adapters.md` Adapter Evidence Matrix 对齐）；quote、liquidity、token/governance config 均属外部依赖
- oracle-backed variants 只消费配置好的单一 oracle 输出；当前实现不提供 freshness、bounds、fallback 或多源聚合
- pinned fork evidence 必须固定 block；不得把 latest fork 结果写成本地保证或长期语义保证
