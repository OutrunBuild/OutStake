# OutStakeV2 Oracles And Integrations

## 文档目的

本文档只说明当前 upgradeable 产品真源里与 oracle 和外部 integration 相关的边界。

## 边界

- `OutrunExchangeOracleAdapter` 仍是非 upgradeable helper
- oracle-backed SY upgradeable variants 通过 `exchangeRateOracle` storage 指向 oracle adapter
- `setExchangeRateOracle(address)` 是 owner-only
- adapter 自身做 raw answer 正性检查（非正 revert `InvalidOracleAnswer`）与 `maxStaleness` 新鲜度窗口校验（`updatedAt == 0`、`updatedAt > block.timestamp`（feed 时钟超前）或超窗均 fail-closed，revert `StaleOracleAnswer`）及可选构造期 L2 sequencer 校验，并在归一化后校验结果非零（`ZeroNormalizedRate`）；不提供 heartbeat、deviation bounds、fallback 或多源聚合保证；5 个具名错误全集声明于 `IExchangeRateOracle.sol`，校验实现见 `OutrunExchangeOracleAdapter.sol::getExchangeRate` 与 `OutrunExchangeOracleAdapter.sol::_validateSequencer`
- `OutrunL2WrappableWstETHSYUpgradeable` 是 Optimism-specific wrappable L2 wstETH variant，不属于 oracle-backed variant；当前实现没有 `exchangeRateOracle` storage / getter / setter，`exchangeRate()` 返回 `IL2StETH.getTokensByShares(1 ether)`
- L2 sequencer 校验语义（仅当构造期配置了非零 `sequencerUptimeFeed` 才启用）：① Chainlink uptime feed 编码方向与直觉相反——`answer == 0` 表示 sequencer 在线，非 0 表示宕机（revert `SequencerDown`）；② 恢复后须经过 `sequencerGracePeriod` 宽限期才采信 answer（revert `SequencerGracePeriodNotOver`）；③ `startedAt == 0`（恢复从未记录）与 `startedAt > block.timestamp`（feed 时钟超前）两类不可信状态与宽限期未过共用同一错误名，简化实现下部署排错无法仅凭错误名区分根因（如需区分可拆分错误）。校验逻辑实现于 `OutrunExchangeOracleAdapter.sol::_validateSequencer`。

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
- `OutrunL2StakedUsdsSYUpgradeable` 的 `exchangeRate()` 来源是 PSM3 `previewSwapExactIn(yieldBearingToken -> USDS)`，不是 oracle；quote、liquidity、token config 和 governance config 都属于外部依赖
- oracle-backed variants 只消费配置好的单一 oracle 输出；当前实现不提供 freshness、bounds、fallback 或多源聚合
- pinned fork evidence 必须固定 block；不得把 latest fork 结果写成本地保证或长期语义保证
