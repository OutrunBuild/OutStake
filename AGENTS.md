# AGENTS Contract

## Goal

Route repository work through the harness without violating policy, review, or verification rules.

## Success Criteria

A task is complete only when:

- the intended planned-file set is known, or the task is reported blocked
- every edited path is classified by `gate.sh --classify-only` before editing
- every edited path matches `.harness/policy.json`
- writer, reviewer, and verifier routing follows policy and gate evidence
- fresh matching `gate.sh` output supports the final verdict

## Session Entry

- AGENTS.md is the session entry for OutStakeV2.
- Load only the files needed for the current task. When multiple control files are needed, read order is fixed:
  1. AGENTS.md
  2. .harness/policy.json
  3. .harness/runtime/main-session-contract.md
  4. docs/TRACEABILITY.md when you need control-file or artifact locations
  5. docs/VERIFICATION.md when you need verification profile or verdict rules
  6. script/harness/gate.sh when you need enforcement details or emitted evidence

## Truth Precedence

1. explicit human instruction for task intent and requested scope
2. .harness/policy.json
3. script/harness/gate.sh results
4. AGENTS.md and .harness/runtime/main-session-contract.md
5. other repository docs

Human instruction does not override safety, filesystem, policy, gate, or verification constraints.
Do not override policy or gate evidence with natural-language guesses.

## Main-Session Rules

- main-orchestrator stays in the primary session and is never a project agent file.
- Derive `change_class`, `surface_sensitivity`, `orchestration_profile`, `harness_writer_roles`, `code_writer_roles`, and `code_review_roles` from policy/gate evidence before delegating.
- Low-risk small-change exception (see main-session-contract.md): the main session may directly make and self-review a change it judges low-risk (view/pure, getter, constant, error message, NatSpec, comments, wording, typos, formatting) without dispatching writer or reviewer agents, even if gate classifies it `prod-semantic` / `full-review` / `delegated`. Hard-excluded (still dispatch per gate profile): any change altering runtime behavior, spec truth, policy/product semantics, fund flow, permissions, invariants, or reentrancy surface — including semantic or behavioral edits to contracts, `policy.json`, `gate.sh`, `.harness/runtime`, `docs/spec`, or `AGENTS.md`.
- Current local task completion defaults to `gate:fast`. Use `full`, `ci`, release, or merge-equivalent verification only when explicitly requested or running in that context.
- Current Solidity contracts are pre-deployment development artifacts unless a human explicitly says deployed compatibility must be preserved.
- Review roles remain reviewer-only; do not place verifier inside review roles.
- Project agent files (all agent trees listed in docs/TRACEABILITY.md) are execution files. They do not define policy or verdict rules.
- Agent role-body contract text (from the `## Role` section onward) is replicated across every agent tree listed in docs/TRACEABILITY.md (currently four: `.claude/agents/`, `.codex/agents/`, `.zcode/agents/`, `.pi/agents/`); each tree is that tool's agent-definition directory (Claude Code, Codex, ZCode, Pi). Any role-body revision or new role file must land in all trees' same-named files within the same change; never scope a role-body fix or addition to a single tree.
- Do not create a parallel control plane outside policy, gate, and project agent files.
- Deleting untracked files from the current git working tree requires explicit human confirmation.

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

## High-Priority Beginner-Readable Code

- This section is high-priority. Optimize for code a beginner can read top to bottom.
- Favor beginner-readable names over protocol jargon, abbreviations, or internal shorthand.
- If a specialized term must stay, explain it at first use in a short local comment.
- Add short implementation comments for non-obvious business logic, invariants, or cross-step reasoning. NatSpec alone is not enough.
- Many tiny single-use helpers make code harder to follow because readers must jump around.
- Extract a helper only when it clearly improves readability, naming, reuse, or testability.
- Inline trivial single-use logic unless extraction clearly improves comprehension.
- Solidity style and best practices live in `.claude/rules/` (`solidity-contracts.md` for `src/`, `solidity-tests.md` for `test/`, `solidity-scripts.md` for `script/`), mirrored as lazy-loaded project skills for the other tools: `.dsh/skills/` (DeepSeek Harness), `.codex/skills/` (Codex), `.zcode/skills/` (ZCode), `.pi/skills/` (Pi). Claude Code auto-loads `.claude/rules/` by scope when editing `.sol` files (no manual read needed); Pi also auto-loads them when the project-level `.pi/extensions/claude-rules.ts` loader is installed. The skill files are gitignored (local-only, not shipped with the repo), so on machines where they are absent — or for any tool whose skill mechanism is unavailable — you MUST lazy-load the rules yourself: before writing or modifying Solidity, use the Read tool to read only the rule file matching the file type you are about to touch (`src/**` → solidity-contracts.md, `test/**` → solidity-tests.md, `script/**` → solidity-scripts.md). Do NOT preemptively read all three — read only the relevant one at the moment you start editing Solidity, treat its content as mandatory instructions, and do not restate it in replies. Follow them when writing or modifying Solidity code.

## Doc-Code Citation Convention

- All documents under `docs/` except the `review/` subdirectory must cite code in `File.sol::function` or `File.sol` form (e.g. `Contract.sol::functionName`).
- Do not write code line numbers in these documents (e.g. `Contract.sol:130-131`): line numbers drift as code evolves and distort doc anchors; function names/symbols are the stable anchors.
- New or modified documents must follow this convention; when reviewing these documents, treat violations as minor-level findings.

## Test Code Rules

- Test contracts must NOT inherit upgradeable production contracts (those using `Initializable`, proxy patterns, or storage-in-heritage layouts). Use interfaces, abstract contracts, or standalone implementations to simulate dependencies.
- Test contracts MAY inherit non-upgradeable production contracts (plain contracts without initializer logic or proxy storage risks).
- Mock contracts go in `test/mocks/`. Do not co-locate with test files.
- Mock contracts reuse interfaces from `src/`. Define test-only interfaces only when src/ interfaces are insufficient.
- **Exception:** Test contracts may inherit an upgradeable `src/` contract only when it is declared `abstract contract` — either to implement its abstract functions for unit testing, or to expose its internal `pure`/`view` functions. Such harnesses must live in `test/mocks/`.

## Uncommitted Changes

- Do not overwrite, delete, or revert uncommitted changes you did not create. If a required edit overlaps them, stop and report it.
- Parallel-change ownership: when you notice a suspicious or out-of-scope change mid-task, do not assume it was made by a subagent you dispatched. First check whether a parallel session or another workflow is also editing the same file (compare file mtime, git status/diff, the active state of other agents and sessions, and review/batch documents). When ownership is uncertain, treat the change as someone else's uncommitted work: do not revert, restore, or rewrite it — stop and report. Before reverting any suspicious or out-of-scope change, confirm more than once that it is not a parallel-session change.

## Context Scope

- Use the minimum repository context needed to classify, route, edit, review, and verify the task.
- Do not read Solidity code for harness/docs-only work unless a policy rule or requested change depends on Solidity surface classification.
- Do not read `script/harness/gate.sh` when policy, runtime, or verification docs already answer the routing question.
- If tool output is empty, partial, or suspicious, retry once with a different command before treating it as evidence.

## Verification Contract

- gate.sh is the enforcement entrypoint.
- Completion, readiness, or pass claims require fresh output from the selected matching gate profile.
- For pre-edit routing, invoke `gate.sh --classify-only` with the exact planned-file set via `--planned-files`.
- For local current-work verification, invoke `gate.sh` with the exact changed-file set via `--changed-files`. If any Solidity file is involved, also provide diff evidence via `CHANGE_CLASSIFIER_DIFF_FILE` or `GATE_DIFF_BASE`.
- See docs/VERIFICATION.md for profile meanings and command entrypoints.

## Harness Dispatch Procedure

When `.harness/policy.json` exists and the task modifies repository files, follow this procedure.

### Mandatory Pre-condition

After the intended planned-file set is known and before the first edit, run `bash script/harness/gate.sh --classify-only --planned-files <path> [<path> ...]` with exact existing paths and intended-created paths. If the planned-file set is not knowable yet, inspect only enough context to identify candidate paths, then classify before editing.

`--planned-files` is for pre-edit routing only. It does not require diff evidence and conservatively classifies planned Solidity files as semantic. Use `--changed-files` only for real changed-file verification after edits or in CI.

Do not use stale mental classification.

### Surface Completeness

Every file that will be modified or created must match a surface pattern in policy.json. Unknown paths are blocked until policy is updated.

### Flow Source

Follow the `orchestration_profile`, writer roles, review roles, verifier requirement, and blockers emitted by policy and gate evidence. Use `.harness/runtime/main-session-contract.md` for detailed flow rules.

For `prod-semantic` work, use this sequence:

1. run `gate.sh --classify-only`
2. the gate emits `doc_round_required=true` (and fills `harness_writer_roles=["process-implementer"]`); when that signal is true, the main session MUST run the product-doc round first: grep the entire `docs/` tree for entries describing the affected behavior, fund flow, permissions, events, or invariants, and output a candidate-doc list with a per-item verdict (update / no-update + reason) before proceeding — a silent decision is not allowed. Scope: `docs/spec/` subtree AND `docs/` root-level product docs (`GLOSSARY`, `ARCHITECTURE`, `implementation-map`, `deployment`, `SECURITY_AND_APPROVALS`, `TRACEABILITY`, `VERIFICATION`, `testing-and-evidence`); `docs/superpowers/` is a design record, NOT this round. The gate does not compute `affected_docs`; the verdict comes from the main session's grep.
3. dispatch `harness_writer_roles` for the doc round across the affected `docs/` files
4. once the doc round is ready, dispatch `spec-reviewer` before any code writer
5. if other harness-control changes are required, dispatch `harness_writer_roles`
6. dispatch `code_writer_roles`
7. run `code_review_roles`
8. run the selected gate profile and report the result

`spec-reviewer` is a main-session orchestration hook, not a `gate.sh` routing field. A `requires_spec_authorization_evidence=true` result requires the recorded authorization source and coverage before spec edits; see `.harness/runtime/main-session-contract.md`. The gate does not validate that natural-language evidence.

Production Solidity semantic changes without structural escalation require a Risk Analysis Record before selecting `direct-review`. If analysis is incomplete or uncertain, use at least `full-review`.

README.md editorial-only direct changes require a Doc Editorial Attestation. README workflow, gate, verification, policy, command, CI, or repository-truth semantics are `delegated`.

## Retry Routing

- surface=solidity_prod/test -> route back to `solidity-implementer`
- surface=harness_control -> route back to `process-implementer`
- spec/doc review feedback -> route back to `process-implementer`
- code review feedback -> route back to the owning code writer
- Multiple findings, same writer → one re-dispatch with the full findings list (per-finding dispatches rebuild context and re-run suites each time).
- Multiple findings, different writer surfaces → route each surface's findings to its own writer (e.g. solidity-implementer vs process-implementer).

## When Not To Trigger Harness

- User asks a question without requesting code changes
- User requests exploration only
- Task is purely conversational

## Repository Truth

- .harness/policy.json is the machine truth for classification, review routing, verification profiles, and hard blocks.
- docs/TRACEABILITY.md lists control files and artifact locations.
- Other repository docs are context only unless policy or gate evidence explicitly points to them.

## Completion Loop

Before final response, check:

- all requested files or items are handled, or marked blocked
- no edited path is outside the classified surface
- validation command and result are fresh
- final answer reports only completed work, validation, and blockers

## Escalation Boundaries

Escalate instead of deciding locally when a change would alter product semantics, fund flow, permission semantics, security assumptions, upgrade behavior, or acceptance thresholds for residual risk.
