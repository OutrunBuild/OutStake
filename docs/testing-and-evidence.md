# OutStakeV2 Testing And Evidence

## 测试布局

当前产品证据主要分布在：

- `test/upgradeable/`
- `test/deploy/`
- `test/support/`

`test/upgradeable/` 是当前产品测试主入口，覆盖 upgradeable assets、position、router proxy integration、SY base、proxy-backed adapters、oracle setter、SY adapter fork coverage、fuzz、invariant 和 adversarial cases。`SYAdaptersFork.t.sol` 中已有固定 block 的 Ethereum mainnet、BSC mainnet、Optimism mainnet 与 Base mainnet fork evidence；没有固定 block 的 fork 结果不得作为可审计 pinned-block evidence。

`test/deploy/` 覆盖 upgradeable deployment scripts。

`test/support/` 保留 library 与 token helper 测试证据及 Faucet 等 helper 合约；mock 与 harness 位于 `test/support/mocks/`。

`test/{assets,integration,position,router,security,yield}/` 当前不承载 `.sol` 测试文件；相关证据已迁移到 `test/upgradeable/` 或 `test/deploy/`。

## 直接证据

- `OutrunUniversalAssetsUpgradeable` 的 mint cap、repay、OFT shared-decimal envelope 与 rate-limit quote。
- `OutrunOFTUpgradeable` 的 OFT shared-decimal envelope 与 rate-limit quote。
- `OutrunStakingPositionUpgradeable` 的建仓、补提债务、到期赎回、keeper 代偿赎回、wrap stake、wrap redeem 与收益 harvest。
- `test/upgradeable/OutrunStakingPositionStorageLayout.t.sol` 验证 position ERC-7201 namespace 的 `SY` 与两个 decimals 共用 slot0。
- `OutrunRouter` 的 caller-funded pull 模式、native/erc20 输入约束、wrap 路径与 genesis mock 路径。
- `SYBaseUpgradeable` 的 initializer、pause、redeem 重入边界，以及 trusted-router 配置与权限边界：owner-only setter、零地址撤销、trusted caller 的 `redeem(..., true)`、非 trusted caller 的 `SYUnauthorizedInternalRedeemer` 回退、router 替换后旧 caller 失效、`redeem(..., false)` 的 caller 余额直兑。
- proxy-backed SY adapters 的核心 deposit / redeem / preview / exchangeRate 行为。
- oracle-backed upgradeable SY variants 的 owner-only `setExchangeRateOracle(address)` 边界。
- `OutstakeScript` 与 `YieldDeployScript` 的 upgradeable deployment evidence。

## Harness 映射

`.harness/policy.json` 的 `test_mapping` 当前把证据归到：

- assets：`test/upgradeable/OutrunOFTUpgradeable.t.sol`、`test/upgradeable/OutrunUniversalAssetsUpgradeable.t.sol`
- position：`test/upgradeable/OutrunStakingPositionUpgradeable.t.sol`、`test/upgradeable/OutrunStakingPositionFuzzUpgradeable.t.sol`、`test/upgradeable/OutrunStakingPositionInvariantUpgradeable.t.sol`
- router：`test/upgradeable/OutrunRouterUpgradeable.t.sol`、`test/upgradeable/OutrunRouterFuzzUpgradeable.t.sol`、`test/upgradeable/RouterProxyIntegration.t.sol`
- yield：`test/upgradeable/SYUpgradeable.t.sol`、`test/upgradeable/SYAdaptersUpgradeable.t.sol`、`test/upgradeable/SYAdaptersFork.t.sol`、`test/upgradeable/OracleSetterUpgradeable.t.sol`
- deployment：`test/deploy/OutstakeScriptUpgradeable.t.sol`、`test/deploy/YieldDeployScriptUpgradeable.t.sol`
- libraries：`test/support/Libraries.t.sol`、`test/support/TokenHelper.t.sol`、`test/support/MockOracleWarnings.t.sol`
- security：`test/upgradeable/AdversarialTestsUpgradeable.t.sol`

## 仍需留意

- 外部协议真实结算、价格更新、队列、权限和可用性仍属于外部依赖。
- 当前测试更偏向统一 proxy-backed 回归，而非每个 adapter 的独立专项集。
- `npm run test:fork` 当前运行 `SYAdaptersFork.t.sol` 的 pinned fork coverage：Ethereum mainnet block `25_108_887`、BSC mainnet block `98_653_065`、Optimism mainnet block `151_675_883` 与 Base mainnet block `46_080_598`。只有测试显式固定 block number 并记录可复现 trace 后，运行结果才可作为 pinned-block evidence；当前仓内 fork 环境变量名是 `ETHEREUM_MAINNET_RPC`、`BSC_MAINNET_RPC`、`OPTIMISM_MAINNET_RPC` 和 `BASE_MAINNET_RPC`，不得改写为 `MAINNET_RPC_URL`、`BSC_RPC_URL` 或其他别名。
