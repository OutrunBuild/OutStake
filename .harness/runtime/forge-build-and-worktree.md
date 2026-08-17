# Forge Build and Worktree Rules

Read this file before any `forge` invocation and before any work under `.worktrees/*`.

## Worktree Dependency Rule

- In project-local `.worktrees/*`, never run `git submodule update`, `forge install`, or dependency repair to fix missing `lib/` dependencies.
- Before any `forge build`, `forge test`, or `gate.sh` run from `.worktrees/*`, run `bash script/harness/prepare-worktree-libs.sh`.
- If `prepare-worktree-libs.sh` fails, report the environment blocker. Do not clone, repair, delete, or overwrite submodules from the worktree.
- If a task intentionally modifies `.gitmodules` or `lib/**`, stop and get explicit human direction before dependency setup.

## Forge Build Rules

- `via_ir = true`; full rebuild takes 12-15 minutes. Do not use `forge build --force` unless one of:
  - compiler settings changed (solc version, via_ir, optimizer, evm_version)
  - library versions updated (`forge update` or `lib/` changes)
  - build output is suspect (ABI mismatch, unexplained test failures)
  - CI or pre-release clean build
  - after `forge clean`
- For routine code/test edits, run a non-`--force` build through the wrapper (`bash script/harness/forge-serialize.sh build`). When unsure, try without `--force` first.
- Serialize every `forge build` / `forge compile` through `bash script/harness/forge-serialize.sh <forge args...>` (e.g. `bash script/harness/forge-serialize.sh build`). The wrapper takes an exclusive flock on `${TMPDIR:-/tmp}/outstake-forge.lock` and blocks until any other forge build/compile finishes, then `exec`s the real `forge`. Never run `forge build` / `forge compile` directly — concurrent compiles corrupt the incremental cache and waste the 12-15 min rebuild budget. This rule also applies to any `forge` invocation that triggers compilation; when in doubt, route through the wrapper.
- The wrapper call blocks until forge exits, so a queued build looks silent for minutes. Before invoking the wrapper, tell the user you are about to run a serialized forge build/compile and may queue behind another one (up to ~12-15 min per build ahead). For long builds prefer `run_in_background: true` and poll output so the user sees the wrapper's 60s heartbeat live. If the wrapper reports it is waiting on the lock (line starts `forge-serialize: ... waiting`), tell the user the call is queued normally — do not present the wait as a hang or an error.
