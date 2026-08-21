# OutStakeV2

Foundry-only workspace.

Project commands:

- `npm run lint`
- `npm run build`
- `npm run test`
- `npm run gas:report`

Harness commands:

- `npm run gate:fast` - rapid local feedback: fmt, lint, build, and changed/mapped tests
- `npm run gate` - default local gate, same as `gate:fast`
- `npm run gate:full` - release-like local gate
- `npm run gate:ci` - CI gate; CI must pass explicit changed-file input

`script/harness/gate.sh --classify-only` emits policy-derived orchestration fields without running verification commands.

## How The Gate Works

1. **Classify surfaces** - every changed file is matched against `.harness/policy.json`.
2. **Classify change class** - Solidity diffs are parsed for semantic changes while ignoring comments, whitespace, and punctuation-only lines.
3. **Select orchestration** - gate emits `orchestration_profile`, `selected_writer_roles`, and `selected_review_roles`.
4. **Run verification** - normal gate profiles run commands selected by profile and changed-file scope.
5. **Emit run record** - when `RUN_RECORD_PATH` is set, the gate writes classification, orchestration, command results, and final verdict.

Change classes: `no-op` | `non-semantic` | `test-semantic` | `prod-semantic`.

Orchestration profiles:

| Profile | Meaning |
|---|---|
| `direct` | main session edits; no writer/reviewer dispatch |
| `direct-review` | main session edits; selected reviewers run |
| `delegated` | policy-selected writer handles docs/process/control changes |
| `full-review` | policy-selected writer plus full review matrix |
| `full-subagent` | full review plus independent verifier |
| `blocked` | stop before editing |
| `no-op` | no classified changes |

Production Solidity semantic changes never downgrade by static allowlist and never escalate by static keyword denylist alone. Small localized production Solidity changes may use `direct-review` only after a main-session Risk Analysis Record. If analysis is incomplete or uncertain, use at least `full-review`.

## Verification Commands

| Command | fast | full / ci | Condition |
|---|---|---|---|
| `forge fmt --check` | yes | yes | changed Solidity files |
| `npx solhint` | yes | yes | changed Solidity files |
| `forge build` | yes | yes | always |
| `forge test --match-path` | yes | no | changed/mapped targeted tests |
| `forge test -vvv` | no | yes | full / ci |
| `forge coverage` | no | yes | `change_class=prod-semantic` and `surface_sensitivity=sensitive` |
| `slither` | no | yes | same as coverage, only when changed production Solidity includes `src/**/*.sol` |
| `bash -n` | yes | yes | changed shell files |
| `node --check` | yes | yes | changed JavaScript files |
| `npm ci` | yes | yes | package manifest or lockfile changed |

## Test Mapping

When production Solidity changes, `gate:fast` resolves targeted tests from `policy.json -> test_mapping`. Each rule maps source paths to `change_tests` and `evidence_tests`.

Repository layout:

- `src/assets/{base,interfaces,omnichain}`
- `src/position/{interfaces}` plus `OutrunStakingPositionUpgradeable.sol`
- `src/yield/{interfaces,adapters/{aave,aster,ethena,etherfi,lido,lista,sky}}` plus `SYBaseUpgradeable.sol`, `OutrunL2OracleBackedSYUpgradeable.sol`, `OutrunL2StakedTokenSYUpgradeable.sol`
- `src/router/{interfaces}` plus `OutrunRouter.sol`
- `src/integrations/{aave,aster,etherfi,lido,lista,sky}`
- `src/libraries/{oracle}`
- `test/{deploy,support,upgradeable}`
- `script/{deploy,deploy/deployment,harness,lib,ops}`
- `.harness/{runtime,schemas}` and `docs/`

## Integration Notes — Self-Issued Tokens: Weird-ERC20 Disclosure (F5)

Third-party integrators (DEXs, vaults, bridges, memeverse, or any external protocol) must not assume standard ERC20 behavior when integrating the self-issued token family: `uAsset` (`OutrunUniversalAssetsUpgradeable` / `OutrunOFTUpgradeable`) and SY shares (`SYBaseUpgradeable` family). The six behaviors below are intentional by design, documented as the product truth in `docs/spec/common-foundations.md` and audited in `docs/audits/2026-08-19/04b-token-integration.md §1.5`, but summarized here for external visibility so integrations do not rely on `totalSupply` or transfer-amount invariants that do not hold.

| # | Weird-ERC20 pattern | Carries | Location | Integrator impact / required handling |
|---|---|---|---|---|
| 1 | Pausable — `whenNotPaused` freezes all transfers/mints/burns (user-initiated `transfer`/`transferFrom`/`mint`/`repay`/`SY deposit`/`SY redeem`/OFT outbound `send`) | SY family, uAsset | `src/assets/base/OutrunERC20PausableUpgradeable.sol:23` (`_update whenNotPaused`); `src/yield/SYBaseUpgradeable.sol:129,162` (`whenNotPaused` on deposit/redeem); `docs/spec/common-foundations.md:122-128` | Owner circuit-breaker. Integrators must handle `transfer`/`redeem`/`send` reverts during pause and not treat `approve` as frozen — `approve` bypasses `_update` per OZ standard and remains usable while paused. |
| 2 | Upgradeable (UUPS proxy) | SY family, uAsset, `OutrunStakingPositionUpgradeable` | Each `*_Upgradeable.sol::_authorizeUpgrade` (e.g. `src/assets/base/OutrunUniversalAssetsUpgradeable.sol:192`, `src/yield/SYBaseUpgradeable.sol:__SYBase_init`); `docs/spec/common-foundations.md` deployment & upgrade constraints | Single-sig owner upgrade with no timelock (trust assumption, see `docs/spec/common-foundations.md` and `01-entry-points` §9). On-chain behavior can change; do not hardcode logic that assumes immutable bytecode. |
| 3 | OFT outbound dust truncation — actual bridged amount may be less than requested | uAsset | `src/assets/omnichain/OutrunOFTUpgradeable.sol:166-171` (`_debit`/`_debitView` dust check), `201-206` (`_removeDust`); `docs/spec/common-foundations.md:138,155` | Cross-chain amount is truncated to `DCR = 10**(localDecimals-sharedDecimals)` granularity: `amountSentLD = floor(amountLD / DCR) * DCR`. Dust (< DCR) stays in sender balance, never burned or bridged. Loss ≤ 1 SD unit per send (on 18-dec deployments DCR=1e12, i.e. < 1e-6 token). Call `quoteOFT()` / `quoteSend()` and enforce `minAmountLD = DCR`; do not assert `amountReceived == amountRequested`. |
| 4 | OFT `send` does not use ERC20 `allowance` | uAsset | `src/assets/omnichain/OutrunOFTUpgradeable.sol:63-67` (`approvalRequired() == false`, `token() == address(this)`); `docs/spec/common-foundations.md` OFT sections | LayerZero OFT native semantics. Integrators must not `approve` the OFT contract for `send`; no allowance is consumed. Standard ERC20 `transferFrom` allowance checks do not apply to the cross-chain path. |
| 5 | Inbound `_credit` mints while paused — `totalSupply` can increase during pause | uAsset | `src/assets/omnichain/OutrunOFTUpgradeable.sol:185-195` (`_credit` calls `OutrunERC20Upgradeable._update` bypassing `whenNotPaused`, remaps zero-recipient to `0xdead`); `docs/spec/common-foundations.md:126`, `docs/spec/protocol.md:16` | Asymmetry is intentional for cross-chain safety: in-flight LayerZero messages must not revert or funds are permanently lost. Integrators must not assume `totalSupply` is static while `paused() == true`; monitor `Transfer` events from `address(0)` during pause. |
| 6 | Forced native reception (`receive()`) — contract balance can be inflated by anyone | SY family | `src/yield/SYBaseUpgradeable.sol:46` (`receive() external payable {}`); `docs/audits/2026-08-19/04b-token-integration.md §1.5 #6` | Anyone can force-send native ETH/BNB to an SY contract via `selfdestruct` or coinbase. This does not mint SY shares and is not yield-bearing (`_selfBalance` aware). SY `sweep()` can rescue stranded native only by owner and blocks `yieldBearingToken` and `address(this)`. Do not account SY backing by `address(this).balance`. |

References: canonical spec is `docs/spec/common-foundations.md` ("Pause 与跨链 OFT 执行边界", "OFT 与 minter 债务豁免边界", "OFT 换算参数"), `docs/spec/protocol.md` (system scope), and the audited matrix `docs/audits/2026-08-19/04b-token-integration.md §1.5`. Code comments at the cited locations are the secondary truth.
