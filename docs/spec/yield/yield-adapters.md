# OutStakeV2 Yield Adapters

## 文档目的

本文档汇总当前 upgradeable SY adapter 的统一行为和产品边界。

## 统一规则

- 所有 SY adapters 都通过 `SYBaseUpgradeable` 提供的 proxy-backed 抽象实现
- 所有 adapter 都保留 `deposit`、`redeem`、`previewDeposit`、`previewRedeem`、`exchangeRate`、`getTokensIn`、`getTokensOut`
- 跨 adapter 的 SY 单位契约以 `docs/spec/common-foundations.md` 的「单位模型」为准：`SYBaseUpgradeable.sol::__SYBase_init` 绑定 yield-bearing token decimals，`SYBaseUpgradeable.sol::deposit` 将 `SYBaseUpgradeable.sol::_deposit` 返回值直接作为 `_mint` 数量，因此 1 SY unit 等于对应 yield-bearing-token domain 的 1 unit；Aave 族使用 `scaledBalanceOf` 的 scaled-share domain，而非随流动性指数增长的 nominal balance domain
- oracle-backed variants 通过 `exchangeRateOracle` storage 获取汇率
- Optimism-specific `OutrunL2WrappableWstETHSYUpgradeable` 不使用 `exchangeRateOracle` storage / getter / setter；`exchangeRate()` 直接返回 `IL2StETH.getTokensByShares(1 ether)`
- adapter 本身不重复继承 UUPS
- `SYBaseUpgradeable.sol::redeem` 采用 token-out-before-burn 的结算顺序：adapter `_redeem`（含外部调用）先把 tokenOut 交付给 receiver，随后 `_burn` 才烧掉 SY 份额；重入安全完全依赖 `redeem` 上的 `nonReentrant`。`burnFromInternalBalance=true` 仅允许 owner 配置的 trusted router caller 使用，并从 `address(this)` 烧份额；其他 caller 传入 `true` 会回退。`burnFromInternalBalance=false` 仍是直兑路径，从 `msg.sender` 烧份额。这条 CEI 逆序是有意设计，调整顺序或移除 `nonReentrant` 前必须保留该不变量。

## SY 错误面与初始化约束

本节列出 `SYBaseUpgradeable` 和各 adapter 自身声明的自定义错误，供集成方建立 selector、触发条件和重试分支矩阵。`TokenHelper`、OpenZeppelin 以及外部协议产生的错误属于依赖边界，不在下表的 SY/adapter 自定义错误全集内。

### SYBase 错误

| 错误 | 入口 | 触发条件 |
| --- | --- | --- |
| `SYInvalidTokenIn(address token)` | `SYBaseUpgradeable.sol::deposit`、`previewDeposit` | `token` 不满足 `isValidTokenIn`。 |
| `SYInvalidTokenOut(address token)` | `SYBaseUpgradeable.sol::redeem`、`previewRedeem` | `token` 不满足 `isValidTokenOut`。 |
| `SYZeroAddress()` | adapter initializer、`SYBaseUpgradeable.sol::__SYBase_init`、`OutrunL2OracleBackedSYUpgradeable.sol::__L2OracleBackedSY_init`、`setExchangeRateOracle` | 必需的 token、oracle、underlying、stake-manager 或其他配置地址为零地址。具体 initializer 可能先执行自己的地址检查。 |
| `SYZeroDeposit()` | `SYBaseUpgradeable.sol::deposit` | `amountTokenToDeposit == 0`。`previewDeposit` 只做 token 校验，不触发此错误。 |
| `SYZeroRedeem()` | `SYBaseUpgradeable.sol::redeem` | `amountSharesToRedeem == 0`。`previewRedeem` 只做 token 校验，不触发此错误。 |
| `SYZeroSharesOut()` | `SYBaseUpgradeable.sol::deposit` | adapter `_deposit` 返回的 `amountSharesOut` 为零（尘额存款低于汇率量子）。检查位于滑点下限之后：`minSharesOut > 0` 时尘额存款先以 `SYInsufficientSharesOut` 回退，本错误仅在 `minSharesOut == 0` 时可观测。基座在 `_mint` 前统一拒绝，防止铸零份额后尘额本金沉淀下游。`previewDeposit` 只做 token 校验与报价，不触发此错误。 |
| `SYUnauthorizedInternalRedeemer(address caller)` | `SYBaseUpgradeable.sol::redeem` | `burnFromInternalBalance == true` 且 `caller` 不是该 SY 实例 owner 配置的 `trustedRouter`；检查在 adapter `_redeem` 前执行。 |
| `SYInsufficientSharesOut(uint256 actualSharesOut, uint256 requiredSharesOut)` | `SYBaseUpgradeable.sol::deposit` | adapter 返回的 `amountSharesOut` 小于 `minSharesOut`。 |
| `SYInsufficientTokenOut(uint256 actualTokenOut, uint256 requiredTokenOut)` | `SYBaseUpgradeable.sol::redeem` | adapter 返回的 `amountTokenOut` 小于 `minTokenOut`；整个 redeem 原子回滚。 |

### Adapter 专属错误

- `OutrunAaveV3SYUpgradeable.sol::AaveZeroShares()`：`_deposit` 的 Aave scaled-share 换算结果为零时触发。
- `OutrunAsBNBSYUpgradeable` 初始化校验：
  - `InvalidAsBnbMinterAsBnb(address expected, address actual)`：minter 的 `asBnb()` 与配置的 asBNB 不一致。
  - `InvalidAsBnbMinterToken(address expected, address actual)`：minter 的 `token()` 与配置的 slisBNB 不一致。
  - `InvalidYieldProxy()`：minter 返回的 yield proxy 为零地址。
  - `InvalidStakeManager()`：yield proxy 返回的 Lista StakeManager 为零地址；这是 Aster adapter 的声明。
- `OutrunAsBNBSYUpgradeable.sol::_revertOnZeroShares`：
  - `AsBnbMintQueued()`：mint 返回零份额且 `activitiesOnGoing()` 为真，表示 Aster 队列处理中；等待活动完成后重试。
  - `AsBnbMintZeroShares()`：mint 返回零份额且没有进行中的活动，表示真实零产出失败，不按队列分支重试。
- `OutrunSlisBNBSYUpgradeable`：
  - `InvalidStakeManager()`：初始化时 `convertSnBnbToBnb(1 ether) < 1 ether`；这是 Lista adapter 的同名独立声明，表示 stake-manager 汇率低于平价。
  - `StakeManagerDepositZero()`：原生 BNB 存款前后收到的 slisBNB 余额差为零。

以上 adapter 级零产出守卫保留用于族特定的诊断（如 Aster 队列区分）；`SYBaseUpgradeable.sol::deposit` 另有基座级 `SYZeroSharesOut()` 兜底，在 `_mint` 前统一拒绝任何 adapter 返回的零份额，未自带守卫的族（如 4626/PSM3/wrap/unwrap 路径的尘额存款）由基座拒绝。

### 事件与原生币接收边界

- `OutrunL2OracleBackedSYUpgradeable.sol::setExchangeRateOracle` 更新 oracle 后发出 `SetExchangeRateOracle(address indexed oldOracle, address indexed newOracle)`；该事件只适用于继承 oracle-backed 基类的 L2 adapter。
- `SYBaseUpgradeable.sol::receive()` 接收原生币，但函数本身没有业务分支或转出逻辑。误转原生币可能形成合约余额，集成方应将其视为可能滞留的边界，不把转账成功当作 deposit 成功。
- `NativeAmountMismatch`、`NativeTransferFailed` 以及外部协议 revert 仍需在集成层保留独立分支；它们不是本节列出的 SY/adapter 自定义错误。

## 代表性 adapter

- `OutrunAaveV3SYUpgradeable`
- `OutrunWeETHSYUpgradeable`
- `OutrunWstETHSYUpgradeable`
- `OutrunL2WstETHSYUpgradeable`
- `OutrunL2WrappableWstETHSYUpgradeable`
- `OutrunStakedUsdsSYUpgradeable`
- `OutrunL2StakedUsdsSYUpgradeable`
- `OutrunStakedUSDeSYUpgradeable`
- `OutrunSlisBNBSYUpgradeable`
- `OutrunAsBNBSYUpgradeable`
- `OutrunL2StakedTokenSYUpgradeable`

## 当前证据

- `test/upgradeable/SYUpgradeable.t.sol`
- `test/upgradeable/SYAdaptersUpgradeable.t.sol`
- `test/upgradeable/SYAdaptersFork.t.sol`
- `test/upgradeable/OracleSetterUpgradeable.t.sol`

## 当前缺口

- 不是每个 adapter 都有独立专项测试
- 外部协议行为仍属于外部依赖
- `OutrunL2WrappableWstETHSYUpgradeable` 的 OP 路径仍依赖上游 L2 stETH / wstETH token conversion 行为；本文档只规定 adapter 调用边界，不声明外部 token 转换规则本身
- `OutrunL2WstETHSYUpgradeable` 仍是 oracle-backed 的 only-wstETH 变体

## Adapter Evidence Matrix

| Adapter | Chain / Fork | Tokens In | Tokens Out | Yield-Bearing Token | Exchange Rate Source | assetInfo / Canonical Asset Decimals Source | Local Unit Evidence | Fork Evidence | Primary Evidence | Remaining Boundary |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `OutrunAaveV3SYUpgradeable` | Ethereum mainnet pinned fork at block `25_108_887` | `WETH`, `aWETH` | `WETH`, `aWETH` | `aWETH` (scaled-share domain; not nominal balance) | `IAaveV3Pool.getReserveNormalizedIncome(underlying) / 1e9` | `live: IERC20Metadata(underlying).decimals()` | `testAaveATokenRoundtripMatchesPreviewAndExchangeRate`, `testAaveUnderlyingDepositMatchesAaveRayDivScaledDelta`, `testAaveATokenDepositUsesAaveRayDivRounding`, `testAaveUnderlyingDepositThatRoundsToZeroReverts` | `testMainnetFork_AaveWethDepositMatchesLiveAave` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Ethereum block `25_108_887`; upstream protocol semantics outside that block remain external | Reserve pause, supply cap, liquidity, interest index movement, and governance config are external — F3 (P1) `redeem(underlying)` 经 `IAaveV3Pool.withdraw` fail-closed（高利用率/储备 pause/freeze/流动性不足时 revert 至恢复）；`redeem(aToken)` 为流动性无关直转逃生门；position 层 `redeem(..., tokenOut=underlying)` 同步继承该依赖，`keepRedeem`/`keepWrapRedeem` 固定 SY 结算不受影响；运维按储备登记利用率/暂停监控并优先以 YBT 兑付、仅最终经 Router 二次退出 underlying |
| `OutrunWeETHSYUpgradeable` | Ethereum mainnet pinned fork at block `25_108_887` | native ETH, `eETH`, `weETH` | `eETH`, `weETH` | `weETH` | `ILiquidityPool.amountForShare(1 ether)`（wrap/unwrap 为 `_deposit`/ `_redeem` 执行路径，非汇率来源）；`ILiquidityPool.sharesForAmount` 仅用于存款预览（`_previewDeposit`），非汇率来源；NATIVE 三跳存款预览是对 `_deposit` 实际路由（`IDepositAdapter.depositETHForWeETH`）的近似重建，pinned fork 实测偏差 ≤1 wei，不利偏差由 `SYBaseUpgradeable.sol::deposit` 的 `minSharesOut` 拒绝 | `(TOKEN, NATIVE sentinel, 18)` | `testWeEtheEthRoundtripMatchesPreviewAndExchangeRate` | `testMainnetFork_EtherfiWeEthDepositAndRedeemMatchesLiveQuote` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Ethereum block `25_108_887` covers native ETH deposit, `eETH` redeem, and live quote alignment; `eETH` deposit and direct `weETH` transfer paths remain local-unit evidence | Liquidity pool availability, quote behavior, and upstream wrap/unwrap semantics are external |
| `OutrunWstETHSYUpgradeable` | Ethereum mainnet pinned fork at block `25_108_887` | native ETH, `stETH`, `wstETH` | `stETH`, `wstETH` | `wstETH` | `IWstETH.stEthPerToken()`（wrap/unwrap 为 `_deposit`/ `_redeem` 执行路径，非汇率来源） | `live: IERC20Metadata(stETH()).decimals()` | `testWstETHInitializerRevertsWhenWstETHIsZero`, `testWstEthStEthRoundtripMatchesPreviewAndExchangeRate` | `testMainnetFork_LidoNativeDepositAndRedeemToStEthMatchesLiveLido` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Ethereum block `25_108_887`; upstream protocol semantics outside that block remain external | Lido conversion state, withdrawal behavior, liquidity, and governance state are external |
| `OutrunL2WstETHSYUpgradeable` | L2 pinned fork required before release evidence; no current fork case | `wstETH` | `wstETH` | `wstETH` | `exchangeRateOracle` storage target | `ctor param (via OutrunL2OracleBackedSY base)` | `testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate`, `testL2WstEthOwnerCanSetExchangeRateOracle`, `testAllAdaptersInitializeBehindProxy`, `testAdapterMatrixTokensPreviewExchangeRateAndInvalidTokenReverts`; setter 的 nonOwner/零地址/汇率更新/更新不调 oracle 行为经共享基类 `OutrunL2OracleBackedSYUpgradeable.sol::setExchangeRateOracle` 由 `OutrunL2StakedTokenSYUpgradeable` 行所列测试覆盖（同一继承实现） | No current pinned fork evidence | No verified primary source recorded in this spec beyond local oracle setter coverage; oracle-fed rate semantics remain trust boundary until backed by verified source, official docs, or pinned fork trace | No freshness, bounds, fallback, or multi-source aggregation; oracle input and L2 token semantics are external |
| `OutrunL2WrappableWstETHSYUpgradeable` | Optimism pinned fork at block `151_675_883` | `stETH`, `wstETH` | `stETH`, `wstETH` | `wstETH` | `IL2StETH.getTokensByShares(1 ether)` | `ctor/storage param (own storage)` | `testL2WrappableWstETHStoresUnderlyingImmediatelyAfterStETH`, `testMockL2StEthUsesShareBalancesForTransfersAndTokenAllowances`, `testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate` | `testOptimismFork_LidoL2WrappableWstEthMatchesLiveQuote` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Optimism block `151_675_883`; upstream protocol semantics outside that block remain external | Optimism token conversion semantics, bridge/token config, and upstream pause/governance state are external |
| `OutrunStakedUsdsSYUpgradeable` | Ethereum mainnet pinned fork at block `25_108_887` | `USDS`, `sUSDS` | `USDS`, `sUSDS` | `sUSDS` | ERC-4626 `convertToAssets`（vault deposit/redeem 为 `_deposit`/ `_redeem` 执行路径，非汇率来源） | `storage usds()（init 注入）+ hardcoded 18` | `testVaultBackedAdaptersUseDepositRedeemAndExchangeRate` | `testMainnetFork_SkyUSDSDepositAndRedeemMatchesLiveVault` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Ethereum block `25_108_887`; upstream protocol semantics outside that block remain external | Vault limits, liquidity, pause state, and governance config are external |
| `OutrunL2StakedUsdsSYUpgradeable` | Base pinned fork at block `46_080_598` | `USDC`, `USDS`, `sUSDS` | `USDC`, `USDS`, `sUSDS` | `sUSDS` | `IRateProviderLike.getConversionRate()/1e27` (SSR cross-chain mirror, `PSM3.rateProvider()` auto-bound at init) with `PSM3.previewSwapExactIn` deviation guard `maxDeviationBps=100` fail-closed; PSM remains execution-only for `_deposit`/`_redeem`/`_preview*` | `storage usds()（init 注入 L2 本地 USDS）+ hardcoded 18; rateProvider/maxDeviationBps own storage (ERC7201)` | `testVaultBackedAdaptersUseDepositRedeemAndExchangeRate` | `testBaseFork_SkyL2StakedUsdsMatchesLivePsmQuote` (now asserts `exchangeRate() == RateProvider` within 100bps of PSM; mock fallback preserves `preview` compat) | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Base block `46_080_598`; `RateProvider` liveness on Base `0x65d946e533748A998B1f0E430803e39A6388f7a1` via `cast call PSM3.rateProvider` | `RateProvider` staleness/fallback and PSM liquidity remain external; deviation guard externalizes 1% threshold as deployment param (owner `setRateProvider`/`setMaxDeviationBps`) |
| `OutrunStakedUSDeSYUpgradeable` | Ethereum mainnet pinned fork at block `25_108_887` | `USDe`, `sUSDe` | `sUSDe` | `sUSDe` | ERC-4626 `convertToAssets`（vault deposit 为 `_deposit` 执行路径，非汇率来源） | `storage usde()（init 注入）+ hardcoded 18` | `testVaultBackedAdaptersUseDepositRedeemAndExchangeRate` | `testMainnetFork_EthenaUSDeDepositMatchesLiveVault` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at Ethereum block `25_108_887`; upstream protocol semantics outside that block remain external | Cooldown, withdrawal mode, vault limits, and governance state are external |
| `OutrunSlisBNBSYUpgradeable` | BSC mainnet pinned fork at block `98_653_065` | native BNB, `slisBNB` | `slisBNB` | `slisBNB` | `IListaStakeManager.convertSnBnbToBnb`；`IListaStakeManager.convertBnbToSnBnb` 仅用于 native BNB 存款预览（`_previewDeposit`），非汇率来源 | `(TOKEN, NATIVE sentinel, 18)` | `testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate` | `testFork_SlisBnbLiveWiringMatchesMainnetAddress`, `testFork_SlisBnbExchangeRateMatchesOnchainQuote`, `testFork_SlisBnbPreviewDepositNativeMatchesOnchainQuote`, `testFork_SlisBnbPreviewDepositMatchesActualDeposit` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at BSC block `98_653_065`; upstream protocol semantics outside that block remain external | Stake-manager caps, pause state, quote behavior, and liquidity are external |
| `OutrunAsBNBSYUpgradeable` | BSC mainnet pinned fork at block `98_653_065` | native BNB, `slisBNB`, `asBNB` | `asBNB` | `asBNB` | `IAsBnbMinter.convertToTokens` + `IListaStakeManager.convertSnBnbToBnb`（`exchangeRate()` 两跳）；`IAsBnbMinter.convertToAsBnb` / `IListaStakeManager.convertBnbToSnBnb` 仅用于存款预览（`_previewDeposit`），非汇率来源 | `(TOKEN, NATIVE sentinel, 18)` | `testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate` | `testFork_AsBnbLiveWiringMatchesMainnetAddress`, `testFork_AsBnbExchangeRateMatchesTwoHopQuote`, `testFork_AsBnbPreviewDepositNativeMatchesTwoHopQuote`, `testFork_AsBnbPreviewDepositMatchesActualDeposit` | Pinned fork trace in `test/upgradeable/SYAdaptersFork.t.sol` at BSC block `98_653_065`; upstream protocol semantics outside that block remain external | Minter caps, pause state, quote behavior, and underlying stake-manager liquidity are external |
| `OutrunL2StakedTokenSYUpgradeable` | L2 pinned fork required before release evidence; no current fork case | configured staked token | configured staked token | configured staked token | `exchangeRateOracle` storage target | `ctor param (via OutrunL2OracleBackedSY base)` | `testL2StakedTokenOwnerCanSetExchangeRateOracle`, `testNonOwnerCannotSetExchangeRateOracle`, `testExchangeRateReflectsUpdatedOracle`, `testSetterDoesNotCallOracleDuringUpdate`, `testZeroExchangeRateOracleReverts`, `testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate`; `testL2StakedRedeemTransfersRequestedTokenOut` covers internal hook transfer behavior only | No current pinned fork evidence | No verified primary source recorded in this spec beyond local oracle setter coverage; oracle-fed rate semantics remain trust boundary until backed by verified source, official docs, or pinned fork trace | No freshness, bounds, fallback, or multi-source aggregation; oracle input and configured token semantics are external |

> `OutrunWstETHSYUpgradeable.sol::_previewDeposit` 的 NATIVE 路径只执行一次 `getSharesByPooledEth` 报价；`OutrunWstETHSYUpgradeable.sol::_deposit` 实际执行 `submit -> getPooledEthByShares -> wrap`，上游 floor 舍入可能使实际 SY 输出低于 preview（链式复合上界 2-3 wei，当前主网 fork 快照实测 ≤1 wei 为单一状态点）。调用方将该报价用于 `SYBaseUpgradeable.sol::deposit` 的 `minSharesOut` 或组合路由最小值时，应预留协议舍入与状态变化余量，勿将 preview 原样作为下限。

> assetInfo 列：NATIVE sentinel 指 assetAddress = address(0)，表示 canonical asset 为原生 ETH/BNB（WeETH/SlisBNB/AsBNB）；L2 族中 oracle-backed（ctor param）与 wrappable wstETH（own storage）的 canonical asset decimals 由部署期参数配置，`OutrunL2StakedUsdsSYUpgradeable` 则硬编码 18；position 在 `OutrunStakingPositionUpgradeable.sol::initialize` 缓存后不再重读，部署期可配置族的错误值会被静默缓存——该风险由 `L2AssetValidation.sol::validateL2OracleBackedParams` / `L2AssetValidation.sol::validateL2WrappableParams` 在 `YieldDeployScript.s.sol::_deployL2WstETHSY` 等部署入口的 fail-fast 断言收敛（已知族如 stETH 硬编码 18，见 `docs/deployment.md` L2 校验清单），未知族仍需人工按清单核对 L1 真值。

## Aave aToken 接口消费面

`OutrunAaveV3SYUpgradeable` 通过本地 `IAToken` 接口（`src/integrations/aave/interfaces/IAToken.sol`）消费以下 aToken 成员：

- `UNDERLYING_ASSET_ADDRESS()`：在 `initialize` 中绑定 adapter 的 underlying（`OutrunAaveV3SYUpgradeable.sol::initialize`）
- `scaledBalanceOf(user)`：在 underlying 存款路径中按流动性指数前后差值计量 scaled shares（`OutrunAaveV3SYUpgradeable.sol::_deposit`）

下列成员仅为镜像上游 Aave V3 aToken 读面而保留，本仓库 `OutrunAaveV3SY` 不消费：`getScaledUserBalanceAndSupply`、`scaledTotalSupply`、`getPreviousIndex`。

deposit / redeem 的份额换算公式与 half-up / floor 舍入方向以 `docs/spec/common-foundations.md` 单位模型的「ray 域换算（Aave 流动性指数）」小节为准（引用不复述）；该小节与上表 `OutrunAaveV3SYUpgradeable` 行 Exchange Rate Source 列的 `IAaveV3Pool.getReserveNormalizedIncome(underlying) / 1e9`（ray→wad 派生：1e27 域指数 ÷ 1e9 = 1e18 域汇率）互为对照。

## Aster 接口消费面

`OutrunAsBNBSYUpgradeable` 消费以下接口成员（Aster 集成位于 `src/integrations/aster/interfaces/`，Lista 换算接口位于 `src/integrations/lista/interfaces/`）：

- `IAsBnbMinter.asBnb()` / `token()` / `yieldProxy()`：initialize 期经 `OutrunAsBNBSYUpgradeable.sol::_validateMinter` 做 minter 绑定校验——`asBnb()` 绑定 yield-bearing token、`token()` 绑定 slisBNB 支持集、`yieldProxy()` 抵达 Lista stake manager（`OutrunAsBNBSYUpgradeable.sol::initialize`）
- `IAsBnbMinter.mintAsBnb()`（slisBNB 重载）/ `mintAsBnb()` payable（native BNB 重载）：存款主路径的铸造调用——native 分支以 call value 转入 BNB，slisBNB 分支先经 `_safeApproveInf` 无限授权再传入数量；零返回值进入 `_revertOnZeroShares` 的区分逻辑（`OutrunAsBNBSYUpgradeable.sol::_deposit`）
- `IYieldProxy.stakeManager()`：initialize 期从校验过的 yieldProxy 取得 Lista StakeManager 地址写入 storage，供 `exchangeRate()` 与 `_previewDeposit` 换算路径使用
- `IYieldProxy.activitiesOnGoing()`：mint 返回零份额时区分「Aster 队列处理中（可重试）」与「真实零产出失败」（`OutrunAsBNBSYUpgradeable.sol::_revertOnZeroShares`）
- `IListaStakeManager.convertSnBnbToBnb` / `convertBnbToSnBnb`：lista 包接口，与上表 SlisBNB 行所引同一 `IListaStakeManager`；Aster adapter 在 initialize 期经 `IAsBnbMinter.yieldProxy()` → `IYieldProxy.stakeManager()` 校验并取得其实例；分别用于 `exchangeRate()` 的第二跳换算与 native BNB 存款预览的第一跳换算

本文档的逐成员消费面小节为按需补记（现仅 Aave 与 Aster）；小节未覆盖的被消费成员以 Adapter Evidence Matrix 各行点名为准。

## Sky PSM3 / Lista StakeManager 接口镜像保留

下列成员仅为镜像上游 Sky PSM3 / Lista StakeManager 接口面而保留，本仓库 adapter 不消费：`IPSM3.sol::swapExactOut`、`IPSM3.sol::previewSwapExactOut`、`IListaStakeManager.sol::requestWithdraw`、`IListaStakeManager.sol::claimWithdraw`、`IListaStakeManager.sol::getTotalPooledBnb`。
