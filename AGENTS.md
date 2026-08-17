# AGENTS Contract

OutStakeV2 is a pre-deployment Foundry (Solidity) staking protocol suite — upgradeable staking positions, a router, standardized-yield (SY) adapters for Aave/Aster/Ethena/Etherfi/Lido/Lista/Sky, oracle libraries, and LayerZero omnichain assets — whose repository work is routed through a policy/gate harness (`script/harness/gate.sh` + `.harness/policy.json`). Goal: route repository work through the harness without violating policy, review, or verification rules.

## Session Entry

- AGENTS.md is the session entry for OutStakeV2.
- Load only the files needed for the current task. Control-file read order is fixed:
  1. AGENTS.md
  2. .harness/policy.json
  3. .harness/runtime/main-session-contract.md
  4. docs/TRACEABILITY.md when you need control-file or artifact locations
  5. docs/VERIFICATION.md when you need verification profile or verdict rules
  6. script/harness/gate.sh when you need enforcement details or emitted evidence
- Linked rule files below are read on trigger, not always:
  - `.harness/runtime/forge-build-and-worktree.md` — before any `forge` invocation and before any work under `.worktrees/*`
  - `.harness/runtime/editing-conventions.md` — before editing any `.sol` (all scopes), writing tests or mocks, editing `docs/`, or editing a nested `src/AGENTS.md` / `script/AGENTS.md` / `test/AGENTS.md` (their regeneration rule lives there)
  - Nested `src/AGENTS.md`, `script/AGENTS.md`, `test/AGENTS.md` — before editing a `.sol` file in that scope; read only that scope's rule file (the generated `.claude/rules/<scope>.md` is equivalent). ZCode and Codex launched from the repository root do **not** auto-load these; for those tools reading them is a mandatory manual step. Tools that auto-load (DSH/Claude Code/Pi via `.claude/rules/solidity-*.md`) need no manual step.

## Truth Precedence

1. explicit human instruction for task intent and requested scope
2. .harness/policy.json
3. script/harness/gate.sh results
4. AGENTS.md and .harness/runtime/main-session-contract.md
5. other repository docs

Human instruction does not override safety, filesystem, policy, gate, or verification constraints.
Do not override policy or gate evidence with natural-language guesses.
.harness/policy.json is the machine truth for classification, review routing, verification profiles, and hard blocks.
docs/TRACEABILITY.md lists control files and artifact locations; other repository docs are context only unless policy or gate evidence explicitly points to them.

## Main-Session Rules

- main-orchestrator stays in the primary session and is never a project agent file.
- Derive `change_class`, `surface_sensitivity`, `orchestration_profile`, `harness_writer_roles`, `code_writer_roles`, and `code_review_roles` from policy/gate evidence before delegating.
- Low-risk small-change exception (full definition in main-session-contract.md): the main session may directly make and self-review a change it judges low-risk — one that alters no runtime behavior, spec truth, policy/product semantics, fund flow, permissions, invariants, or reentrancy surface (e.g. view/pure functions, getters, constants, error-message text, NatSpec, comments, wording, typos, formatting) — without dispatching writer or reviewer agents, even if gate classifies it `prod-semantic` / `full-review` / `delegated`. Hard-excluded (still dispatch per gate profile): any change that does alter any of those concerns — including semantic or behavioral edits to contracts, `policy.json`, `gate.sh`, `.harness/runtime`, `docs/spec`, or `AGENTS.md`. The exception exempts only writer/reviewer dispatch, never gate verification, doc-round judgment, or the authorization-evidence protocol.
- Current local task completion defaults to `gate:fast`. Use `full`, `ci`, release, or merge-equivalent verification only when explicitly requested or running in that context.
- Current Solidity contracts are pre-deployment development artifacts unless a human explicitly says deployed compatibility must be preserved.
- Review roles remain reviewer-only; do not place verifier inside review roles.
- Project agent files (all agent trees listed in docs/TRACEABILITY.md) are execution files. They do not define policy or verdict rules.
- Agent role-body contract text (from the `## Role` section onward) is replicated across every agent tree listed in docs/TRACEABILITY.md (currently four: `.claude/agents/`, `.codex/agents/`, `.zcode/agents/`, `.pi/agents/`); each tree is that tool's agent-definition directory (Claude Code, Codex, ZCode, Pi). Any role-body revision or new role file must land in all trees' same-named files within the same change; never scope a role-body fix or addition to a single tree.
- Do not create a parallel control plane outside policy, gate, and project agent files.
- Deleting untracked files from the current git working tree requires explicit human confirmation.

## Uncommitted Changes

- Do not overwrite, delete, or revert uncommitted changes you did not create. If a required edit overlaps them, stop and report it.
- Parallel-change ownership: when you notice a suspicious or out-of-scope change mid-task, do not assume it was made by a subagent you dispatched. First check whether a parallel session or another workflow is also editing the same file (compare file mtime, git status/diff, the active state of other agents and sessions, and review/batch documents). When ownership is uncertain, treat the change as someone else's uncommitted work: do not revert, restore, or rewrite it — stop and report. Before reverting any suspicious or out-of-scope change, confirm more than once that it is not a parallel-session change.

## Context Scope

- Use the minimum repository context needed to classify, route, edit, review, and verify the task.
- Do not read Solidity code for harness/docs-only work unless a policy rule or requested change depends on Solidity surface classification.
- Do not read `script/harness/gate.sh` when policy, runtime, or verification docs already answer the routing question.
- If tool output is empty, partial, or suspicious, retry once with a different command before treating it as evidence.

## Harness Dispatch Procedure

When `.harness/policy.json` exists and the task modifies repository files:

1. **Classify before editing.** After the planned-file set is known and before the first edit, run `bash script/harness/gate.sh --classify-only --planned-files <path> [<path> ...]` with exact existing paths and intended-created paths. If the planned-file set is not knowable yet, inspect only enough context to identify candidate paths, then classify before editing. `--planned-files` is pre-edit routing only: it needs no diff evidence and conservatively classifies planned Solidity files as semantic. `--changed-files` is only for real changed-file verification after edits or in CI. Do not use stale mental classification.
2. **Surface completeness.** Every file that will be modified or created must match a surface pattern in policy.json. Unknown paths are blocked until policy is updated.
3. **Follow the emitted flow.** Use the `orchestration_profile`, writer roles, review roles, verifier requirement, and blockers emitted by policy and gate evidence. Detailed flow rules — prod-semantic sequence, product-doc round, spec-reviewer hook, authorization-evidence protocol, direct-review risk record, README attestation, retry routing — live in `.harness/runtime/main-session-contract.md`.

## Verification Contract

- gate.sh is the enforcement entrypoint.
- Completion, readiness, or pass claims require fresh output from the selected matching gate profile.
- For pre-edit routing, invoke `gate.sh --classify-only` with the exact planned-file set via `--planned-files`.
- For local current-work verification, invoke `gate.sh` with the exact changed-file set via `--changed-files`. If any Solidity file is involved, also provide diff evidence via `CHANGE_CLASSIFIER_DIFF_FILE` or `GATE_DIFF_BASE`.
- See docs/VERIFICATION.md for profile meanings and command entrypoints.

## When Not To Trigger Harness

- User asks a question without requesting code changes
- User requests exploration only
- Task is purely conversational

## Completion Loop

Before final response, check:

- the intended planned-file set is known, or the task is reported blocked
- all requested files or items are handled, or marked blocked
- every edited path was classified pre-edit, matches `.harness/policy.json`, and no edited path is outside the classified surface
- writer, reviewer, and verifier routing followed policy and gate evidence
- validation command and result are fresh
- final answer reports only completed work, validation, and blockers

## Escalation Boundaries

Escalate instead of deciding locally when a change would alter product semantics, fund flow, permission semantics, security assumptions, upgrade behavior, or acceptance thresholds for residual risk.
