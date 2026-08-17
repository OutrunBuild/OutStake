---
paths:
  - "script/**/*.sol"
---
# Solidity scripts (script/)

Auto-loads when you edit `script/` files. General Solidity style (named imports, ordering, naming) still applies; run `forge fmt`.

## Structure
Split large deploys into focused scripts — `DeployToken.s.sol`, `DeployVault.s.sol` — plus an orchestrator `Deploy.s.sol` whose `run()` instantiates and calls each.

## No hardcoded config or secrets
- Read config from env: `vm.envAddress("ADMIN_ADDRESS")`, `vm.envOr("INITIAL_SUPPLY", uint256(1_000_000 ether))`.
- Keys never in source. This repo's deploy scripts inherit `BaseScript` (`script/lib/BaseScript.s.sol`); its `setUp()` unconditionally requires the `PRIVATE_KEY` environment variable (`privateKey = vm.envUint("PRIVATE_KEY")`). The `script/ops/*.sh` wrappers `source "$repo_root/.env"` and call `forge script …` directly — they pass **no** `--account`/`--ledger` flags.
- The current code path supports only the `PRIVATE_KEY` env-based flow; there is no keystore or hardware-wallet (`--account`/`--ledger`) flow. Supporting one requires first changing `BaseScript`.

## Broadcast & logging
- `vm.startBroadcast()` … `vm.stopBroadcast()` wraps **multiple** transactions; `vm.broadcast()` wraps a **single** call — choose accordingly.
- For multi-step deploys within one script, keep `startBroadcast()` open across all steps (it persists until `stopBroadcast()`). To resume a deployment whose transactions failed or timed out, re-run with `forge script … --resume` (CLI; resubmits from the broadcast log without re-simulating).
- State changes (`new Contract(...)`, sending transactions) must be inside the broadcast region; pure computation/reads can be outside.
- Log results for verification:

```solidity
console.log("Token deployed at:", address(token));
console.log("Chain ID:", block.chainid);
console.log("Deployer:", msg.sender);
```

## Running
- **Simulate before broadcasting**: omitting `--broadcast` is a dry-run/simulate; confirm the trace is correct, then add `--broadcast`.
- Actual entry points are the `script/ops/*.sh` wrappers, e.g. `script/ops/deploy.sh` and `script/ops/yieldDeploy.sh`. They `source "$repo_root/.env"` (so `PRIVATE_KEY` must be set there) then run `forge script …` directly — **no** `--account`/`--ledger`. This differs from the generic upstream `--account deployer` / `--ledger` example below.

```bash
# 1) Simulate (dry-run): omit --broadcast
forge script script/Deploy.s.sol --rpc-url $RPC_URL
# 2) Real broadcast + verify
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --account deployer --verify
# Hardware signing: use --ledger instead of --account
```

The `--account`/`--ledger` example is illustrative only — this repo does not support it without first changing `BaseScript` (see "No hardcoded config or secrets").

## Key management
| Environment | Key source |
|---|---|
| Local (anvil) | Anvil default keys — publicly known, never on real networks |
| Testnet / Mainnet | Env var `PRIVATE_KEY` via `BaseScript.setUp()` (loaded from `.env` by `script/ops/*.sh`) |

Note: the keystore (`--account`) and hardware-wallet (`--ledger`) key sources are **not** currently wired into this repo — only the `PRIVATE_KEY` env flow works today.

Keep `.env` out of VCS (`.gitignore` lists `.env` and `.env.*`, with `!.env.example` for the committed template); required vars are documented in the root `.env.example`.
