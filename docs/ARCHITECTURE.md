# OutStake 架构总览

## 1. 模块地图

### 1.1 资产层

- `src/assets/base/OutrunERC20Upgradeable.sol`
- `src/assets/base/OutrunERC20PausableUpgradeable.sol`
- `src/assets/base/OutrunUniversalAssetsUpgradeable.sol`
- `src/assets/omnichain/OutrunOFTUpgradeable.sol`
- `src/assets/omnichain/OutrunRateLimiterUpgradeable.sol`（共享 OFT outbound rate-limit 抽象基类）
- `src/assets/interfaces/IUniversalAssets.sol`
- uAsset 统一债务与流通资产层，维护按 minter 维度的 mint cap / 已铸造债务 / mint / repay 路径，以及 PSM 消费的储备铸烧路径（`OutrunUniversalAssetsUpgradeable.sol::setReserveMinter` 登记、`::reserveMint` / `::reserveBurn` 铸烧，豁免 minter 债务台账），并继承 ERC20 / pause / OFT 跨链铸烧能力。
- state-bearing uAsset 使用 `Upgradeable` 后缀变体并通过 `ERC1967Proxy` + UUPS 部署。
- `OutrunUniversalAssetsUpgradeable` 直接继承 `UUPSUpgradeable`；其自定义 `OutrunOFTUpgradeable` 基于 LayerZero 官方 `OFTCoreUpgradeable` / `OAppUpgradeable` 路径，保留自定义 ERC20 metadata/decimals，不在需要自定义 metadata/decimals 时继承默认 `OFTUpgradeable`。

### 1.2 仓位层（v1 收益背书凭证层：genesis-only、面值铸造、0% 利率默认、无清算）

- `src/position/OutrunStakingPositionUpgradeable.sol`
- `src/position/interfaces/IOutrunStakeManager.sol`
- v1 产品定义：SP = **Memeverse 专用、按面值铸造、零利息、无清算的收益背书凭证层**。唯一铸造入口 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（SP 原生物理门：铸出 uAsset 交易内全额交 SP 侧 `genesisLauncher`，后置断言强制全额消费）；自由借贷入口 `stake` 不存在。
- 面值铸造（价值平价）：`mintedUAsset = floor₂(syStaked × SY.exchangeRate())`（两段 down，无 LTV 缩放、无利率乘数）——背书不变式 `positions.principalDebt ≤ syStaked × exchangeRate(铸造时点)` 由取整方向构造成立。
- 计息为 duty 域 virtual accrual（`rate = rmul(rpow(duty, dt), rate)`，timestamp 锚定）；v1 全族默认 `duty = 1e27` 零费（`rate` 永不前移、债务冻结、背书率单调上升），`setDuty` 保留（接受域 `[1e27, DUTY_CAP]`）。
- 无清算：链上不设清算、LTV 或再融资机制；`OutrunStakingPositionUpgradeable.sol::redeem` 任意时刻按比例双腿销债（本金腿 burn 并冲销 minter 台账、利息腿转协议金库——v1 零费下恒 0）是唯一出清通道。
- **铸造侧率值链上守卫按族分形，oracle fail-closed 栈为 oracle-fed 族唯一链上防线**：v1 无 LTV/清算后，汇率虚高时面值铸造即超铸——oracle-fed 族由正性/round 完整性/新鲜度/sequencer/归一化非零校验 + SY 基类锚点偏差熔断守卫，Sky L2 族由 PSM3-SSR 双源偏差守卫守率值（`OutrunL2StakedUsdsSYUpgradeable.sol::exchangeRate`，偏离超 `maxDeviationBps` 即 revert `RateDeviationExceeded` fail-closed），另有族无关的 `ZeroExchangeRate` 单点守卫（关键级上调，语义真源 `docs/spec/yield/oracles-and-integrations.md`）。
- **`mintingCap` 为唯一供给刹车**：uAsset minter 台账的 cap 直接限总供给，原「背书保护」（LTV）职责并入；背书由价值平价铸造构造保证。风险按五层瀑布承接（见 §7 风险模型）。
- `OutrunStakingPositionUpgradeable` 作为 UUPS implementation 部署在 `ERC1967Proxy` 后；`SY`、`uAsset`、`protocolTreasury`（协议金库，利息腿接收方）等依赖由 initializer 写入 storage。
- 行为规格真源：`docs/spec/position/accounting.md`（账务、计息、背书不变式与错误/事件真源）、`docs/spec/position/state-machines.md`（状态机与暂停矩阵）。

### 1.3 PSM 层（锚定兑换供给路径，现状：单实例单储备已落地（四实例 + (uAsset, reserveToken) 配对绑定））

- `src/psm/OutrunPSMUpgradeable.sol`
- `src/psm/interfaces/IPSM.sol`
- 每个 (uAsset, reserve) 配对一个实例（现状即单实例单储备，共四实例）：UUSD 拆为 USDC-PSM 与 USDT-PSM 两实例，UETH / UBNB 各一原生实例，共四实例，每实例绑定单一储备（UETH / UBNB 为 NATIVE 哨兵），以绑定储备与对应 uAsset 按固定 1:1 面值双向兑换（`OutrunPSMUpgradeable.sol::mint` / `::redeem`，只操作绑定储备），为 uAsset 提供独立于 CDP 的锚定供给来源。
- 铸 / 烧经 uAsset 储备铸烧路径（`reserveMint` / `reserveBurn`），豁免 minter 债务台账；兑换费率与 `stockCap` 口径以行为规格真源为准；PSM 自身不设 pause、无 owner 提取面——计费结余经无许可 `OutrunPSMUpgradeable.sol::sweepFees` 提取至部署期 immutable 绑定的 `feeRecipient`。
- 行为规格真源：`docs/spec/psm/peg-stability-module.md`。

### 1.4 USR 层（储蓄金库）

- `src/usr/OutrunUSRVaultUpgradeable.sol`
- `src/usr/interfaces/IUSRVault.sol`
- 每个 uAsset 族一个 ERC4626 vault 实例（suETH / suUSD / suBNB，share 即该族 suToken）：存入对应 uAsset、随存随取，share 价格按治理设定的族利率（`usrRate`，取值边界与默认值以行为规格真源为准）按秒增长（timestamp 锚定）。
- 硬预算 fail-safe：禁 mint 计息，owner 计息注资唯一入口是 `OutrunUSRVaultUpgradeable.sol::fund`，利息预算由余额超出份额负债的部分支撑；无 sweep、无回收函数，入池资金仅存款人可经 ERC4626 提款取出。
- USR vault 不是 uAsset 的 minter 或储备 minter，无需任何 uAsset 侧登记。
- 行为规格真源：`docs/spec/usr/usr-vaults.md`。

### 1.5 收益层

当前 yield adapter 路径以 `find src/yield -type f` 和 `.harness/policy.json` 分类为准；本节列出当前收益层 product adapter、共享 base 与 interface 源文件。

- `src/yield/SYBaseUpgradeable.sol`
- `src/yield/adapters/aave/OutrunAaveV3SYUpgradeable.sol`
- `src/yield/adapters/aster/OutrunAsBNBSYUpgradeable.sol`
- `src/yield/adapters/ethena/OutrunStakedUSDeSYUpgradeable.sol`
- `src/yield/adapters/etherfi/OutrunWeETHSYUpgradeable.sol`
- `src/yield/adapters/lista/OutrunSlisBNBSYUpgradeable.sol`
- `src/yield/adapters/lido/OutrunWstETHSYUpgradeable.sol`
- `src/yield/adapters/lido/OutrunL2WstETHSYUpgradeable.sol`
- `src/yield/adapters/sky/OutrunStakedUsdsSYUpgradeable.sol`
- `src/yield/adapters/sky/OutrunL2StakedUsdsSYUpgradeable.sol`
- `src/yield/OutrunL2StakedTokenSYUpgradeable.sol`
- `src/yield/OutrunL2OracleBackedSYUpgradeable.sol`（oracle-backed L2 SY 变体抽象基类）
- `src/yield/interfaces/IStandardizedYield.sol`
- SY 份额层抽象，把外部收益资产包装为统一的 deposit / redeem / preview / exchangeRate 接口。
- 所有当前 SY adapter product surface 都通过 `ERC1967Proxy` + UUPS 部署，包括 Lido 相关 adapter。`SYBaseUpgradeable` 统一继承 `UUPSUpgradeable`，具体 SY adapter 通过该 base 取得 upgrade authority，不重复继承 UUPS。
- oracle-backed SY upgradeable variants 使用 mutable `exchangeRateOracle` storage 与 `setExchangeRateOracle(address)` onlyOwner 入口（换指针保留已存 rate anchor）；基类 `OutrunL2OracleBackedSYUpgradeable` 同一 ERC-7201 storage 另持锚点偏差熔断状态（rate anchor 值 + anchor timestamp + 三个熔断参数 `maxDropBps`/`riseBpsPerHour`/`maxRiseCapBps`）：`commitRateAnchor()` 为 permissionless 带内推进入口，`resetRateAnchor()` / `setRateBreakerParams(...)` 为 owner-only（语义真源 `docs/spec/yield/oracles-and-integrations.md`「边界」锚点偏差熔断条目）；`OutrunExchangeOracleAdapter` 自身仍是非 upgradeable、可重部署 helper。

### 1.6 路由层

- `src/router/OutrunRouter.sol`
- `src/router/interfaces/IOutrunRouter.sol`
- `src/router/interfaces/IMemeverseLauncher.sol`
- `src/router/interfaces/IPOLendGenesis.sol`
- 把 token <-> SY <-> CDP 仓位、PSM 兑换组合为单次入口，并承载 memeverseLauncher genesis 集成。
- genesis 为双路径：路径 A（PSM 门）`OutrunRouter.sol::genesisByPSM` 以 reserve token 经 PSM 1:1 面值铸 uAsset 后全额交 launcher（无仓位、无债务，router 侧后置断言）；路径 B（CDP 门）双计价入口——`OutrunRouter.sol::genesisByToken`（token 计价正门）/ `OutrunRouter.sol::genesisBySY`——为薄转发便利层，转发至 SP 原生物理门 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`（面值/价值平价铸出，uAsset 铸给 SP 自身、交易内全额交 launcher，SP 侧后置断言；任意 EOA/合约可直调 SP，router 非必经）。自由质押入口（`stakeFromToken`/`stakeFromSY`）随 v1 genesis-only 决策删除。双门之外另有杠杆创世门 `OutrunRouter.sol::leveragedGenesisByPSM`：reserve token 经 PSM 面值铸 uAsset 后全额作为 Memeverse 侧 POLend 杠杆创世利息（借出额度记 `genesisUser`），无仓位、无 launcher 交付，`polend` 地址经 owner 测试期 setter 登记（生产冻结 immutable，完整行为见 `docs/spec/router/router-and-user-flows.md`「杠杆创世门」节）。
- `OutrunRouter` 不进入 upgradeable product surface；仍保持非 upgradeable、可重部署 helper，并通过参数或配置调用 proxy-backed uAsset / SY / position / PSM。
- target registry 由 owner 在 pre-mainnet wiring 阶段配置：`OutrunRouter.sol::setTrustedSY` 登记 SY，`OutrunRouter.sol::setTrustedSP` 登记并校验 `SP -> SY` canonical pair，`OutrunRouter.sol::setPsmForUAsset` 登记路径 A 与杠杆创世门共用的 `(uAsset, reserveToken) -> PSM` 配对绑定（现状即配对三参登记）；router 在任何 pull 或精确 approve 前拒绝未登记或不匹配的 target。registry 为 owner 持续 live 能力，不随主网上线冻结移除（见 `docs/spec/protocol.md`「router」）。

### 1.7 集成与 Oracle 层

- `src/integrations/aave/interfaces/IAToken.sol`
- `src/integrations/aave/interfaces/IAaveV3Pool.sol`
- `src/integrations/aster/interfaces/IAsBnbMinter.sol`
- `src/integrations/aster/interfaces/IYieldProxy.sol`
- `src/integrations/etherfi/interfaces/IDepositAdapter.sol`
- `src/integrations/etherfi/interfaces/ILiquidityPool.sol`
- `src/integrations/etherfi/interfaces/IWeETH.sol`
- `src/integrations/lido/interfaces/IStETH.sol`
- `src/integrations/lido/interfaces/IWstETH.sol`
- `src/integrations/lista/interfaces/IListaStakeManager.sol`
- `src/integrations/sky/interfaces/IPSM3.sol`
- `src/libraries/oracle/OutrunExchangeOracleAdapter.sol`
- 外部协议最小 interface 与 adapter 调用封装；oracle adapter 的校验语义与错误面以 `docs/spec/yield/oracles-and-integrations.md` 为准。
- `OutrunExchangeOracleAdapter` 不部署在 proxy 后；需要更换 oracle normalization 规则时部署新 adapter，再由 oracle-backed SY proxy 的 owner 更新 `exchangeRateOracle`——换指针保留已存 rate anchor，换入源仍须对旧锚点通过带界；owner 采纳量级合法不同的新源走显式 `resetRateAnchor()`。
- 后续执行 adapter / integration 相关任务时，以 `find src -type f` 得到的当前文件树和 `.harness/policy.json` 分类为准；本文件提供架构背景，不覆盖实际文件存在性与 harness surface 分类。

### 1.8 底层库

- `src/libraries/TokenHelper.sol`
- `src/libraries/SYUtils.sol`
- `src/libraries/AaveAdapterLib.sol`
- `src/libraries/ArrayLib.sol`
- `src/libraries/AutoIncrementIdUpgradeable.sol`
- `src/libraries/GenesisGateLib.sol`
- `src/libraries/WadRayMath.sol`
- 跨业务域共享的 token 传输、汇率换算、重入保护、数组操作、ID 生成、genesis 物理门守恒断言、错误定义等基础工具。`GenesisGateLib.sol` 为三条 genesis 入口（路径 A / 路径 B / 杠杆创世门）共用的安全承载闸门（`assertFullConsumption`，见 §2.8/§3）。
- 当前 helper 中 `TokenHelper.sol` 继承 vendored OpenZeppelin `ReentrancyGuardTransient.sol`（`@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol`），该 guard 使用 EIP-1153 transient storage；部署目标链必须支持 EIP-1153。

### 1.9 Upgradeable deployment model

当前 state-bearing product 使用 UUPS + `ERC1967Proxy`：

- proxy-backed：`OutrunUniversalAssetsUpgradeable`、`OutrunStakingPositionUpgradeable`、`OutrunPSMUpgradeable`、`OutrunUSRVaultUpgradeable`、全部 SY adapter upgradeable variants。
- non-upgradeable / redeployable：`OutrunRouter`、`OutrunExchangeOracleAdapter`、interfaces、pure libraries、外部协议 interface。
- deployment flow：部署 implementation，编码 initializer calldata，部署 `ERC1967Proxy(implementation, initData)`，把 proxy address 作为产品地址写入后续 wiring。
- owner：单一 protocol owner 为 multisig（部署期 owner 取值约束见 `docs/deployment.md`「关键约束」），主网前按其「治理操作 timelock 评估提示」收敛为 timelock/multisig（timelock 处于产品合约外治理层）；产品合约内无 timelock、无新增 governance module。
- upgrade authority：每个 UUPS product 的 `_authorizeUpgrade(address)` 由 `onlyOwner` 保护，只暴露 UUPS base 的 `upgradeToAndCall`。
- initializer boundary：构造参数迁移到 `initialize(...)` / `__..._init(...)`，implementation constructor 禁用 initializers。LayerZero endpoint 与 local decimals 是 `OutrunOFTUpgradeable` 继承官方 upgradeable OFT/OApp 路径所需的 implementation-level constructor 参数，每个 endpoint / local-decimal 配置部署一个 implementation。
## 2. 关键资金流

### 2.1 Token / Native -> SY

owner 先登记 trusted SY；用户授权 router -> router 校验 SY registry -> 从调用者拉取 tokenIn -> 调用 SY.deposit() -> SY 份额 mint 给 receiver。

### 2.2 SY -> Token

router 路径先校验 trusted SY，再把 SY 转入 SY 合约地址（直调路径份额留在调用者账户、不转入）-> 调用 `SYBaseUpgradeable.sol::redeem`（该 SY 实例须由 owner 将当前 router 配置为 trusted router caller）-> adapter `_redeem` 先把目标 token 交付给 receiver -> 随后 burn SY 份额（router 路径从 `address(this)` 烧、直调路径从 `msg.sender` 烧）。非 trusted caller 传入 `burnFromInternalBalance=true` 会回退；`false` 直兑路径保持 caller 余额扣除。重入安全由 `redeem` 的 `nonReentrant` 保证。

### 2.3 Token / SY -> CDP 开仓（自由质押路径，已随 v1 genesis-only 决策删除）

`stakeFromToken` / `stakeFromSY` 与 SP 自由借贷入口 `stake()` 随 v1 删除；CDP 开仓唯一入口为 genesis 路径 B 的 SP 原生物理门（§2.8）。

### 2.4 CDP redeem（任意时刻按比例双腿销债）

position owner 授权 uAsset -> `OutrunStakingPositionUpgradeable.sol::redeem` -> 本金腿经 `uAsset.repay` burn 并冲销 minter 台账、利息腿 transfer 给 `protocolTreasury` -> 减记 `syStaked`（full redeem 删除仓位）-> 输出 SY（直转）或经 `SY.redeem` 换目标 token。partial redeem 按比例双腿、不得清空本金留 SY。

### 2.5 JIT 清算与 CollSurplus 领回（已随 v1 无清算决策删除）

v1 链上不设清算、LTV 或再融资机制；仓位出清唯一通道为 owner `redeem`（§2.4）。风险承接见 §7 风险模型。

### 2.6 PSM 双向兑换（reserve <-> uAsset，现状即单实例单储备）

用户带 reserve（ERC20 approve 或 NATIVE `msg.value`）-> `OutrunPSMUpgradeable.sol::mint` -> PSM 拉入 reserve、经 `uAsset.reserveMint` 铸出 uAsset 给用户；反向前用户对 PSM approve uAsset -> `OutrunPSMUpgradeable.sol::redeem` -> 经 `uAsset.reserveBurn` 销毁并付出 reserve（费率折算与 `stockCap` 约束口径以行为规格真源 `docs/spec/psm/peg-stability-module.md` 为准）。mint 豁免 minter 债务台账。

### 2.7 USR 存取（uAsset <-> suToken）

uAsset 持有人 -> `OutrunUSRVaultUpgradeable` ERC4626 `deposit` / `mint`（资产转入步）-> 按当前指数铸 suToken 份额；`withdraw` / `redeem` 按份额与当前指数结算付出 uAsset。owner 经 `OutrunUSRVaultUpgradeable.sol::fund` 注资计息预算、`::setUsrRate` 设族利率（计息指数口径、付出边界与参数边界以行为规格真源 `docs/spec/usr/usr-vaults.md` 为准）。

### 2.8 Genesis 入口（PSM 门 / CDP 门 / 杠杆创世门）

- 路径 A（PSM 门）：用户带 reserve token -> `OutrunRouter.sol::genesisByPSM` -> router 校验 `psmForUAsset` registry -> PSM 铸出 uAsset 给 router -> router 精确 approve 并调用 `launcher.genesis`，launcher 拉走全额铸出量，router 侧后置断言余额回基线且 allowance 归零；无仓位、无债务。
- 路径 B（CDP 门，双计价入口，薄转发便利层）：用户带 token（`OutrunRouter.sol::genesisByToken`，token 计价正门，router 先经 `SY.deposit` 换 SY）或 SY（`OutrunRouter.sol::genesisBySY`）-> router 校验 `trustedSYForSP`、拉入资产并精确 approve 给 SP -> 转发 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`——SP 侧原生物理门完成开 CDP 仓位（`genesisUser` 为 position owner、面值/价值平价铸出）、uAsset 铸给 SP 自身、对 SP 侧 `genesisLauncher` 精确 approve、`launcher.genesis` 原子交款与后置断言（余额回铸出前基线且 allowance 归零，否则 `GenesisUAssetNotConsumed` 整笔回滚）；router 在路径 B 不触碰 uAsset，任意 EOA/合约也可绕过 router 直接调用 `stakeForGenesis`（组合性）。
- 杠杆创世门（双门之外的第三入口）：用户带 reserve token -> `OutrunRouter.sol::leveragedGenesisByPSM` -> router 校验 `psmForUAsset` registry 与 `polend` 登记、复读 verse ↔ uAsset 配对 -> PSM 铸出 uAsset 给 router -> router 精确 approve 并调用 `IPOLendGenesis.leveragedGenesis`，POLend 拉走全额铸出量作为杠杆创世利息、借出额度记 `genesisUser`，router 侧后置断言余额回基线且 allowance 归零；无仓位、无 launcher 交付（完整行为见 `docs/spec/router/router-and-user-flows.md`「杠杆创世门」节）。

## 3. 系统架构图

### 3.1 合约依赖树

方向: `→` 表示"依赖 / 调用"，`⟶` 表示"extends(继承)"。

#### uAsset 继承链

```
OutrunUniversalAssetsUpgradeable (concrete)
  ⟶ Initializable                       ← openzeppelin-upgradeable
  ⟶ IUniversalAssets (interface)
  ⟶ OutrunOFTUpgradeable (abstract)
    ⟶ OFTCoreUpgradeable                ← @layerzerolabs/oft-evm-upgradeable
    ⟶ OutrunRateLimiterUpgradeable
    ⟶ OutrunERC20PausableUpgradeable
      ⟶ OutrunERC20Upgradeable
      ⟶ PausableUpgradeable             ← openzeppelin-upgradeable
      ⟶ OwnableUpgradeable              ← openzeppelin-upgradeable
  ⟶ UUPSUpgradeable                     ← openzeppelin-upgradeable
```

#### Position 继承链

```
OutrunStakingPositionUpgradeable (concrete)
  ⟶ IOutrunStakeManager (interface)
  ⟶ AutoIncrementIdUpgradeable
  ⟶ TokenHelper
  ⟶ PausableUpgradeable                ← openzeppelin-upgradeable
  ⟶ OwnableUpgradeable                 ← openzeppelin-upgradeable
  ⟶ UUPSUpgradeable                    ← openzeppelin-upgradeable
  依赖:
    → IUniversalAssets (uAsset)          mint / repay（本金腿 burn + 台账冲销）
    → IStandardizedYield (SY)            exchangeRate / redeem
    → IMemeverseLauncher                 genesis（stakeForGenesis 物理门交款）
    → SYUtils
    → GenesisGateLib                     assertFullConsumption（genesis 物理门全额消费断言，SP/Router 双侧三入口共用）
```

#### PSM 继承链

```
OutrunPSMUpgradeable (concrete)
  ⟶ IPSM (interface)
  ⟶ TokenHelper
  ⟶ OwnableUpgradeable                 ← openzeppelin-upgradeable
  ⟶ UUPSUpgradeable                    ← openzeppelin-upgradeable
  依赖:
    → IUniversalAssets (uAsset)          reserveMint / reserveBurn（储备铸烧，豁免 minter 台账）
    → IERC20 (reserve tokens)            transferFrom / transfer / decimals
```

#### USR vault 继承链

```
OutrunUSRVaultUpgradeable (concrete)
  ⟶ IUSRVault (interface)
  ⟶ TokenHelper
  ⟶ ERC4626Upgradeable                  ← openzeppelin-upgradeable
  ⟶ OwnableUpgradeable                 ← openzeppelin-upgradeable
  ⟶ UUPSUpgradeable                    ← openzeppelin-upgradeable
  依赖:
    → ERC20（资产 uAsset）              transfer / transferFrom / balanceOf（偿付封顶读余额）
```

#### Router 依赖扇出

```
OutrunRouter (concrete)
  ⟶ IOutrunRouter (interface)
  ⟶ Ownable                            ← openzeppelin
  依赖:
    → IStandardizedYield               deposit / redeem / preview*
    → IOutrunStakeManager              stakeForGenesis / preview*
    → IPSM                             mint（路径 A 与杠杆创世门，经 `OutrunRouter.sol::_psmMintForRouter` 共用）
    → IMemeverseLauncher               genesis（仅路径 A genesisByPSM）
    → IPOLendGenesis                   leveragedGenesis / marketUAsset（杠杆创世门 `OutrunRouter.sol::leveragedGenesisByPSM`）
    → TokenHelper
    → GenesisGateLib                   assertFullConsumption（genesis 物理门全额消费断言，SP/Router 双侧三入口共用）
```

#### SY Adapter 统一结构

```
Concrete Adapter (e.g. OutrunAaveV3SYUpgradeable)
  ⟶ SYBaseUpgradeable (abstract)
    ⟶ IStandardizedYield (interface)
    ⟶ OutrunERC20PausableUpgradeable
      ⟶ OutrunERC20Upgradeable
      ⟶ PausableUpgradeable             ← openzeppelin-upgradeable
      ⟶ OwnableUpgradeable              ← openzeppelin-upgradeable
    ⟶ TokenHelper
    ⟶ UUPSUpgradeable                   ← openzeppelin-upgradeable
Concrete Adapter (e.g. OutrunL2StakedTokenSYUpgradeable / OutrunL2WstETHSYUpgradeable)
  ⟶ OutrunL2OracleBackedSYUpgradeable (abstract)   ← L2 oracle 接线 + 1:1 helpers + assetInfo
    ⟶ SYBaseUpgradeable (abstract)                 ← 子链同上方 Aave 条目
  依赖:
    → IExchangeRateOracle              getExchangeRate()

OutrunExchangeOracleAdapter
  → AggregatorInterface                latestRoundData()
  → IExchangeRateOracle
```

### 3.2 全局调用关系图

#### 3.2.1 合约调用关系

```
  User (EOA / ECA) / Owner (multisig)
  approve(router / position / SY / PSM / USR vault, ...)
       │
   ├────────┬─────────────┬──────────────┬───────────┬───────────┬─────────────────┐
   ▼        ▼             ▼              ▼           ▼           ▼                 ▼
+--------+ +-----------+ +------------+ +---------+ +---------+ +--------------+ +-----------+
| Router | | SYBase +  | | Outrun     | | Outrun  | | Outrun  | | IMemeverse   | |  LayerZero |
|        | | Adapters  | | StakingPos | | PSM     | | USR     | | Launcher     | |  Endpoint  |
|mintSY  | | deposit   | | stakeFor-  | | mint    | | Vault   | | (external)   | | (external) |
|redeemSy| | redeem    | | Genesis    | | redeem  | | deposit | | genesis      | +-----------+
|genesis | | preview*  | | redeem     | | quote*  | | redeem  | +--------------+
|  A/B   | | exchange- | |            | |         | | fund /  |
|        | | Rate      | |            | |         | | setUsr- |
|        | |           | |            | |         | | Rate    |
+---┬----+ +-----┬-----+ +-----┬------+ +----┬----+ +----┬----+
    │            │             │           │           │
    └────────────┴──────┬──────┴───────────┴─────────────┴──┘
                        ▼
            +---------------------------+
            | OutrunUniversalAssets     |
            | (uAsset, per 族)          |
            | ·mint      (minter cap)   ├──► OutrunOFT _debit / _credit ──► LayerZero
            | ·repay                    |
            | ·reserveMint / reserveBurn│            (PSM 储备路径，豁免台账)
            | ·setReserveMinter /       │
            |  setMintingCap (owner)    │
            +---------------------------+
```

本图为调用主干摘要，非穷举：Router→Position（`genesisBySY`/`genesisByToken` → `stakeForGenesis`）、Router→PSM（`genesisByPSM` / `leveragedGenesisByPSM` → `IPSM.mint`）与 Position→Launcher（`stakeForGenesis` → `launcher.genesis`；Router 仅路径 A `genesisByPSM` 直调 launcher）等编排调用未画出，完整调用清单见 §3.2.2 表与 §3.1 依赖扇出。

#### 3.2.2 调用关系说明

| Caller | Callee | 入口 |
| --- | --- | --- |
| Router | SY | `mintSYFromToken` → `SY.deposit`；`redeemSyToToken` → `SY.redeem` |
| Router | PSM | `genesisByPSM` / `leveragedGenesisByPSM` → `IPSM.mint`（路径 A 与杠杆创世门，经 `psmForUAsset` registry 寻址、共用 `OutrunRouter.sol::_psmMintForRouter`） |
| Router | POLend | `leveragedGenesisByPSM` → `marketUAsset` 复读校验 + `leveragedGenesis`（杠杆创世门，经 `polend` 登记寻址，全额拉款） |
| Router | Position | `genesisBySY`/`genesisByToken` → `stakeForGenesis`（路径 B 双入口薄转发，面值 CDP 开仓） |
| Router | Launcher | `genesisByPSM` → `launcher.genesis`（仅路径 A；router 侧精确 approve 后全额消费） |
| Position | Launcher | `stakeForGenesis` → `launcher.genesis`（路径 B；SP 侧精确 approve 后全额消费，后置断言） |
| Position | uAsset | `stakeForGenesis` → `mint`；`redeem` 本金腿 → `repay` |
| Position | SY | `redeem` → `SY.redeem`（非 SY tokenOut 时经 adapter 兑换） |
| PSM | uAsset | `mint` → `reserveMint`；`redeem` → `reserveBurn`（豁免 minter 债务台账） |
| 用户 / Owner | USR vault | ERC4626 `deposit`/`mint`/`withdraw`/`redeem`（公开）；`fund`/`setUsrRate`（owner-only） |
| Adapter | External Protocol | deposit → `supply`/`wrap`/`deposit`/`depositETHForWeETH`/`swapExactIn`/`mintAsBnb`；redeem → `withdraw`/`unwrap`/`redeem`/`swapExactIn`；或 1:1 直付 |
| OutrunOFT | LayerZero | `_toSD` 编码消息；`_debit` burn 本链；`_credit` mint 远端 |

Router 复合路径会透传或校验用户传入的 slippage floors：`minSyOut` 约束 token -> SY，`minUAssetMinted` 约束 genesis 路径 B 输出，`minTokenOut` 约束 redeem 输出；PSM 路径输出确定性（面值 1:1 减费率），无 minOut 参数。

### 3.3 资金流方向

本节为 §2 各资金流的图示化对照，语义以 §2 为准。

方向标注: `token/token → SY` 表示资金从调用者流入 SY。

```
入金路径 (token -> SY):

  User tokenIn  ──approve──► Router ──transferFrom──► Router
                                                         │
                                                    deposit
                                                         ▼
  User tokenIn  ──approve──► Adapter/SY ──transferFrom──► Adapter
                                                         │
                                                   deposit → external supply
                                                         │
                                                    mint SY shares
                                                         ▼
                                                   User receives SY

CDP 开仓 (SY -> uAsset，v1 唯一入口 stakeForGenesis，面值/价值平价):

  SY ──transferFrom──► Position ──exchangeRate 两段 down 面值──► mintedUAsset
                                                        │
                                                   mint uAsset（minter 台账 +principalDebt，铸给 SP 自身）
                                                        ▼
                                                  launcher.genesis 交易内全额消费

CDP 赎回（双腿销债）:

  Position owner uAsset ──approve──► Position
    → 本金腿 repay(burn) + 冲销 minter 台账
    → 利息腿 transfer → protocolTreasury（v1 零费下恒 0）
    → 输出 SY（直转）或经 SY.redeem → token to receiver

（JIT 清算资金流随 v1 无清算决策删除；仓位出清唯一通道为 owner redeem）

PSM 兑换（储备 ↔ uAsset，面值 1:1 减费率）:

  reserve（ERC20 / NATIVE）──mint──► PSM ──reserveMint──► uAsset to 用户
  uAsset ──approve + redeem──► PSM ──reserveBurn──► reserve to 用户

USR 存取:

  uAsset ──deposit──► USR vault ──按 accrualIndex 铸份额──► suToken
  suToken ──redeem──► USR vault ──按 accrualIndex 结算──► uAsset（余额为硬边界）
  Owner uAsset ──approve + fund──► USR vault（计息注资，只进不出）

Genesis 入口（双门与双门之外的杠杆创世门）:

  路径 A: reserve ──genesisByPSM──► PSM.mint ──reserveMint──► uAsset(router) ──► launcher.genesis
          （无仓位、无债务；router 侧后置断言全额消费；PSM 行供给）
  路径 B: token ──genesisByToken──► SY.deposit ──SY──► SP.stakeForGenesis ──mint──► uAsset(SP) ──► launcher.genesis
          SY ────genesisBySY───► SP.stakeForGenesis ──mint──► uAsset(SP) ──► launcher.genesis
          （router 薄转发、不触碰 uAsset；genesisUser 承担 CDP 债务，面值铸出；SP 侧后置断言全额消费；CDP 行供给）
  杠杆门: reserve ──leveragedGenesisByPSM──► PSM.mint ──reserveMint──► uAsset(router) ──► POLend.leveragedGenesis（杠杆创世利息）
          （无仓位、无 launcher 交付；借出额度记 genesisUser；router 侧后置断言全额消费；PSM 行供给）
```

### 3.4 设计约束

- Router **不承担**独立资金池角色，所有资金来自调用者（caller-funded pull 模式）。
- Router 的 target registry 是部署期安全边界：`OutrunRouter.sol::setTrustedSY(SY, false)` 会立即阻断直接 SY 路径及引用该 SY 的 SP 路径，但不自动清除 pair mapping；撤销时应显式 `OutrunRouter.sol::setTrustedSP(SP, address(0))`；路径 A 的寻址 registry 为 `OutrunRouter.sol::setPsmForUAsset`（按 `(uAsset, reserveToken)` 配对，现状即配对三参登记），撤销置零地址阻断该配对的 `OutrunRouter.sol::genesisByPSM` 与 `OutrunRouter.sol::leveragedGenesisByPSM`（两入口共享同一 registry 查表）。
- 用户也**可直接调用** `SYBaseUpgradeable.sol::deposit`/`redeem`、`OutrunStakingPositionUpgradeable.sol::stakeForGenesis`/`redeem`、`OutrunPSMUpgradeable.sol::mint`/`redeem` 与 USR vault 的 ERC4626 公开面，无需经过 Router；直兑 `redeem(..., false)` 从调用者余额烧份额，`redeem(..., true)` 只对每个 SY 实例 owner 配置的 trusted router caller 开放。
- uAsset 供给共三条路径：CDP（position 层，经 `mint`/`repay` 记 minter 台账）、PSM（储备铸烧路径，豁免台账）、POLend（Memeverse 侧杠杆创世，不在本仓库实现）；三行对账式见 `docs/spec/position/accounting.md` §10.2，跨仓库接线约束见 `docs/spec/protocol.md`「跨仓库接线约束（Memeverse/POLend）」。
- uAsset.mint 是公开函数，但受 owner 配置的 mintingCap 约束，不是任何人都能铸造；储备铸烧路径不受 mintingCap 约束，受储备 minter 登记表（`setReserveMinter`）约束，PSM 侧 kill switch 为撤销该登记。
- Position 合约本身必须先在 uAsset 上被授予 mintingCap，才能继续铸造。

## 4. 文档分层（Doc Layering）

当前文档系统按四层组织：

1. Harness Contract 层
   - `AGENTS.md`
   - `CLAUDE.md`
   - `.harness/policy.json`
   - `script/harness/gate.sh`
   - `README.md`
   - `.github/workflows/test.yml`
   - `.githooks/*`
   - `.claude/settings.json`
2. Product Truth 层（当前规则真源）
   - `docs/spec/protocol.md`（系统目标与模块边界）
   - `docs/spec/router/router-and-user-flows.md`（完整路由路径分析）
   - `docs/spec/position/state-machines.md`（状态机与暂停矩阵）
   - `docs/spec/position/accounting.md`（账务规则、背书不变式与三行对账式）
   - `docs/spec/psm/peg-stability-module.md`（PSM 行为规格）
   - `docs/spec/usr/usr-vaults.md`（USR 行为规格）
   - `docs/spec/access-control.md`（权限边界）
   - `docs/spec/yield/yield-adapters.md`（adapter 行为与缺口）
   - `docs/spec/yield/oracles-and-integrations.md`（外部集成边界）
   - `docs/spec/common-foundations.md`（library 基础语义）
   - `docs/deployment.md`（部署入口与环境变量）
   - `docs/implementation-map.md`（surface 表格索引）
   - `docs/testing-and-evidence.md`（测试分层与证据强度）
   - `docs/ARCHITECTURE.md`（本文件：系统级模块地图）
   - `docs/GLOSSARY.md`（术语表）
   - `docs/TRACEABILITY.md`（规则到证据追溯）
   - `docs/VERIFICATION.md`（验证入口指南）
   - `docs/SECURITY_AND_APPROVALS.md`（安全审阅规则）
3. Implementation Evidence 层（规则落地证据）
   - `src/**`
   - `test/**`

冲突处理顺序：

- 当前规则判断以 Product Truth 层为准，并用 Implementation Evidence 层核验。
- 若 `docs/spec/*.md` 与 `src/**` 冲突，以 `src/**` 为准。

## 5. 推荐阅读顺序

1. `CLAUDE.md`（仓库流程与角色约定，5 分钟）
2. `docs/ARCHITECTURE.md`（本文件，先建立层次与边界，5 分钟）
3. `docs/GLOSSARY.md`（术语定义基线，3 分钟）
4. `docs/spec/protocol.md`（系统目标与模块边界；用户流程见 `docs/spec/router/router-and-user-flows.md`，8 分钟）
5. `docs/spec/position/state-machines.md`（stakeForGenesis / redeem 状态机与暂停矩阵，8 分钟）
6. `docs/spec/position/accounting.md`（账务与计息规则，含背书不变式与三行对账式，8 分钟）
7. `docs/spec/access-control.md`（权限边界清单，5 分钟）
8. `docs/spec/router/router-and-user-flows.md`（完整路由路径与边界，10 分钟）
9. `docs/spec/psm/peg-stability-module.md` + `docs/spec/usr/usr-vaults.md`（两条非 CDP 供给/储蓄路径，10 分钟）
10. `docs/spec/yield/yield-adapters.md`（全部 adapter 族实现与缺口，10 分钟）
11. `docs/TRACEABILITY.md` + `docs/VERIFICATION.md`（证据追溯与验证路径）

## 6. 当前已知边界提醒

- uAsset 按 minter 独立记账，不是全局总债务池；PSM 储备铸烧与 OFT 跨链均不触碰 minter 债务台账。
- Router 当前是 pull 模式，不会消费 pre-funded 余额代替调用者出资。
- Genesis 为双路径：路径 A（`OutrunRouter.sol::genesisByPSM`）无仓位无债务，路径 B（`OutrunRouter.sol::genesisByToken`/`::genesisBySY` 双计价入口，薄转发至 SP 原生 `OutrunStakingPositionUpgradeable.sol::stakeForGenesis`）为 CDP 开仓、`genesisUser` 承担债务；两路径铸出量与 launcher 消费量严格相等——路径 A 全额消费断言在 router 侧，路径 B 断言在 SP 侧；双门之外另有杠杆创世门 `OutrunRouter.sol::leveragedGenesisByPSM`（PSM 面值铸出后全额付 Memeverse 侧 POLend 杠杆创世利息，无仓位，router 侧全额消费断言同路径 A 构造、spender 为 `polend`）。
- Position 层无 keeper / harvest / wrap / 自由借贷 / 清算面（已随 v1 删除）；v1 无清算即无清算活性依赖面，仓位出清唯一通道为 owner `redeem`（SY 直出 oracle 无关）。
- CDP 债务按 virtual accrual 按秒复利计息（timestamp 锚定）；v1 全族默认 `duty = 1e27` 零费下 `rate` 恒 `1e27`、债务冻结；加息（`duty > 1e27`）后 SP 暂停期间 `rate` 仍按秒复利增长（暂停是入口熔断，不是计息冻结）。
- 全部 SY adapter 的 deposit/redeem 核心路径在 `test/upgradeable/SYAdaptersUpgradeable.t.sol` 均有 roundtrip 覆盖，但部分由 `SYAdaptersUpgradeable.t.sol::testVaultBackedAdaptersUseDepositRedeemAndExchangeRate`、`SYAdaptersUpgradeable.t.sol::testOracleAndBnbFamiliesCoverRoundtripPreviewAndExchangeRate` 家族共享测试覆盖，非每 adapter 专属；残余边界：oracle-backed L2 族（`OutrunL2WstETHSYUpgradeable`、`OutrunL2StakedTokenSYUpgradeable`）无 fork/primary 证据，个别 roundtrip 分支仍用恒等 mock 汇率，详见 `docs/spec/yield/yield-adapters.md` 证据矩阵。
- Oracle adapter 是精度归一化器（语义以 `docs/spec/yield/oracles-and-integrations.md` 为准）；不实现 deviation bounds；不实现 fallback。v1 无 LTV/清算后，铸造侧率值链上守卫按族分形——oracle fail-closed 栈守 oracle-fed 族，Sky L2 族由 PSM3-SSR 双源偏差守卫守率值，另有族无关零点守卫（背书完整性守卫全集见 §1.2 与 §7，语义真源 `docs/spec/yield/oracles-and-integrations.md`）。
- 跨链 OFT 消息传递的正确性依赖 LayerZero 端点与 peer 配置，不属于本地仓库可直接证明的事实。

## 7. 风险模型（v1 正式声明）

**链上不设保险、清算或再融资机制。** 风险按五层瀑布承接，逐层强度诚实声明：

| 层 | 承接范围 | 强度评估 |
| --- | --- | --- |
| 1. 集成准入标准 | 事前唯一防线 | 标准与裁决见下。已知小例外：LST 削罚可使汇率小幅回撤（历史 ≤1% 量级，Lido/Lista 国库有自补先例）——非黑天鹅形态，模型可吸收，但每个 LST 集成须单独评估 |
| 2. 发行方自救 | 中型事故 | 梯队发行方有真实恢复先例（被盗追回、保险基金、国库回补）；非保证，作为等待期的事故消化方 |
| 3. 协议资金桥接 | 等待期流动性缺口 | 时序风险：v1 协议收入未起量，桥接能力 = 金库存量，前期薄 |
| 4. 收入年金 | 长期坏账 | v1 为政策承诺（协议后续收入优先处理坏账）；v1 已建收入源 = PSM 点差（tin/tout），Memeverse 生态收入属跨仓范围；v2 可编码为收入路由硬优先级 |
| 5. 脱钩社会化 | 终局 | 全部层级耗尽后接受 uAsset 脱钩，持有人承担全部损失，协议后续收入继续用于处理坏账 |

集成准入标准与裁决表（准入标准三要素：(i) 发行方梯队——背景、管理规模、事故应对历史；(ii) 汇率行为尽调——历史最大回撤 + 回补机制；(iii) oracle 栈兼容（oracle-fed 族现有 fail-closed 全集；Sky L2 族为 PSM3-SSR 双源偏差守卫，见 `docs/spec/yield/oracles-and-integrations.md`「边界」）。尽调清单与复审触发条件见 `docs/deployment.md` 运行手册）：

| 家族 | v1 处置 |
| --- | --- |
| Aave / Sky / Ethena / Lido / Lista | 准入（人类已拍板名单） |
| EtherFi | 剔除——多链覆盖论据不成立（独占链仅 Blast/Mode 低活动链）；UETH 族 SY 收敛为 wstETH（Lido，8 链）+ aWETH（Aave，22 链）。adapter 代码保留为 v2 候选：获 A+ 风险评级 + 主要链部署后按标准复评。aWETH 形态当前不在部署脚本布线路径内，UETH 族部署守卫白名单（`SPDefaults.sol::assertFamilySY`）现为 wstETH 单符号，aWETH 接线批次须同批扩白名单（UBNB 双符号分支现已是真实双符号准入，非模板） |
| Aster | 原始评估剔除——准入标准 (i) 不达标（TGE 2025-09，市场考验 <1 年）、(ii) 未验证（高 APY 收益资产无压力周期回撤数据）、(iii) 规模不足（USDF 铸造 ~112.8M）。2026-09 人类再裁决：asBNB 重新准入 v1——UBNB 族双符号（slisBNB+asBNB），adapter 挂名义 1:1 背书对账守卫后随守卫覆盖接入，初始小 mintingCap 起步 |

回锚双管道（脱钩不是单行道）：uAsset 折价 → genesis 借款人买折价 uAsset 还债赎 SY（债赎套利，`redeem` SY 直出保证该通道 oracle 无关）；uAsset 溢价 → PSM 储备放出。借款人与非借款人两条锚定管道并存。

治理救济工具（已存在，无需新增）：`pause`、UUPS 升级、`transferMinterDebt`（修账验收流程已有）、`setMintingCap`/`revokeMinter`（SP 退役路径已有）、PSM 储备。链下恢复 playbook、背书率监控口径与集成复审触发条件见 `docs/deployment.md` 运行手册。
