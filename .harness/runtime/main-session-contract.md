# Main Session Contract

## Read Order

1. `AGENTS.md`
2. `.harness/policy.json`
3. this file
4. `docs/TRACEABILITY.md` when you need control-file or artifact locations
5. `docs/VERIFICATION.md` when you need verification profile or verdict rules
6. `script/harness/gate.sh` when you need enforcement details or emitted evidence
7. `.claude/rules/*.md` — Solidity style/best-practices, auto-loaded by `paths:` scope (`src/` / `test/` / `script/`) when editing `.sol` files; consult directly only for cross-scope reference

## Truth Precedence

1. explicit human instruction
2. `.harness/policy.json`
3. `script/harness/gate.sh` results
4. `AGENTS.md` and this file
5. other repository docs

## Main-Session Rules

- `main-orchestrator` stays in the primary session and is never a project agent file.
- Every repository modification must go through `gate.sh --classify-only --planned-files <path> [<path> ...]` before editing.
- Dispatch and review are selected by policy-derived `orchestration_profile`.
- Derive `change_class`, `surface_sensitivity`, `orchestration_profile`, `harness_writer_roles`, `code_writer_roles`, and `code_review_roles` from policy/gate evidence before delegating.
- For `prod-semantic` work, the main session decides whether spec/docs or other harness-control changes are needed before dispatching `harness_writer_roles`, `code_writer_roles`, or `code_review_roles`.
- For `prod-semantic` changes the gate emits `doc_round_required=true` and fills `harness_writer_roles` with `process-implementer`. When `doc_round_required=true`, the main session MUST run the product-doc round first — grep the entire `docs/` tree (both `docs/spec/` and `docs/` root-level product docs), output a per-item update/no-update verdict, dispatch `process-implementer` for the affected `docs/` files, then dispatch `spec-reviewer` — before any code writer. The gate does not compute `affected_docs`; that semantic judgment stays with the main session.
- If the main session decides spec/docs changes are required, complete that spec/doc writing round first and dispatch `spec-reviewer` immediately after the spec/doc changes are ready, before any code writer is dispatched.
- `spec-reviewer` dispatch is a main-session orchestration hook, not a `gate.sh` output field. For `prod-semantic` work the doc round that precedes it is triggered by the gate's `doc_round_required` signal; `spec-reviewer` itself remains a hook, not a routing field.

`requires_spec_authorization_evidence=true` is a path-based gate signal, not proof that authorization, approval, intent, or coverage has been validated.

Before editing selected spec files after this signal, the main session records:
1. the authorization source: the direct human task or human-approved plan;
2. the selected spec files; and
3. the exact approved behavior covered by that source for those files.

A direct human task or human-approved plan is sufficient when the selected specs only record behavior already approved by that source and add no product semantics, permissions, invariants, or acceptance criteria. No pre-listed filename set is required. When this evidence is sufficient, do not request the same human approval again.

Pause only when no authorization source exists, the authorization source does not cover the exact behavior to be recorded in the selected spec files, the requested documentation expands scope, or it introduces new product semantics, permissions, invariants, or acceptance criteria.

This evidence protocol does not alter sequencing: complete the product-doc round first where required, then run spec review before code writing. Every writer still receives gate classification for its exact planned files.
- Main session may directly modify files only for `direct` and `direct-review`.
- Main session must not author `delegated`, `full-review`, or `full-subagent` changes except to integrate approved subagent output.
- Do not dispatch writer or reviewer agents for `direct`.
- Low-risk small-change exception (an exception to the three rules above): the main session may, by its own reasoning, directly make and self-review a change it judges low-risk — dispatching no writer agent and no reviewer agent — even when gate classifies it `prod-semantic` / `full-review` / `delegated`. Low-risk = a change that alters no runtime behavior, spec truth, policy semantics, product semantics, fund flow, permissions, invariants, or reentrancy surface (e.g. view/pure functions, getters, constants, error-message text, NatSpec, comments, wording, typos, formatting). Hard-excluded (still dispatch writer + reviewer per gate profile): any change that does alter any of the above — including semantic or behavioral edits to contracts, `policy.json`, `gate.sh`, `.harness/runtime`, `docs/spec`, or `AGENTS.md`. This exception exempts only writer/reviewer dispatch — not gate verification (build / test / lint / fmt still run), not doc-round judgment, or the authorization-evidence protocol when `requires_spec_authorization_evidence=true`.
- Use only project agents under `.claude/agents/` or `.codex/agents/` for delegated work. This clause is interpreted by the tool running the harness: all four agent trees are equivalent in nature — each is that tool's agent-definition directory (Claude Code → `.claude/agents/`, Codex → `.codex/agents/`, ZCode → `.zcode/agents/`, Pi → `.pi/agents/`). The current harness delegation flow (gate writer/reviewer role resolution, `spec-reviewer` hook) is only exercised in Claude Code and Codex sessions, so delegated writer/reviewer roles resolve from the corresponding tool tree; the remaining trees serve their tool when that tool runs the harness.
- Do not bypass `process-implementer`, `spec-reviewer`, or the authorization-evidence protocol when `requires_spec_authorization_evidence=true`; a recorded direct human task or human-approved plan that satisfies the protocol does not require a second confirmation, and pauses remain only under the protocol's stated conditions.
- Production Solidity semantic changes without structural escalation require a main-session Risk Analysis Record before using `direct-review`; otherwise use `full-review`.
- README.md editorial-only direct changes require a Doc Editorial Attestation; otherwise use `delegated`.
- `direct-review` reviewer roles come from `orchestration_review_roles`, not `full_review_matrix`.
- Dispatch consumes resolved `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.
- For pre-edit routing, invoke `gate.sh --classify-only` with exact planned-file input through `--planned-files`. Planned Solidity files are conservatively classified as semantic because no diff exists yet.
- For local current-work verification on tracked or intended-to-commit repository changes, invoke `gate.sh` with exact changed-file input through `--changed-files`. If any Solidity file is involved, provide diff evidence without creating persistent repository files:
  - Prefer `GATE_DIFF_BASE=<git-ref>` when a stable base ref exists.
  - If a patch file is required, create it with `mktemp` outside the repository, pass its path through `CHANGE_CLASSIFIER_DIFF_FILE`, and remove it after `gate.sh` exits.
  - Do not create, commit, or leave behind repository files named after `CHANGE_CLASSIFIER_DIFF_FILE`, `GATE_DIFF_BASE`, or related diff-evidence artifacts.
- Ignored/local scratch artifacts are outside repository readiness. Do not use ignored scratch paths as `gate.sh` changed-file input for a repository PASS/BLOCKED verdict. Verify them with artifact-specific checks, report that result separately, and mark repository gate as not applicable.
- If an ignored/local artifact is intended to become a formal deliverable, first move it into a policy-classified tracked path or update policy so the path is classified; then run the matching gate before claiming repository readiness.
- If changed files imply multiple writer roles, route each touched surface to its configured writer; only stop as blocked when policy or gate evidence emits a hard block.
- Completion claims require fresh output from the selected matching `gate.sh` profile.
- If required verification evidence is missing, keep the final verdict blocked or fail instead of projecting pass.
- If Solidity surface or risk is unclear, inspect the related contracts, imports/inheritance, existing tests, and mapped spec documents before classifying. Do not rely on a separate explorer agent for this step.

## Reviewer Dispatch — Diff Handoff

When dispatching a reviewer, choose the diff handoff by size:

- **Multi-file or large diff** (e.g. prod-semantic changes spanning several contracts): run `script/harness/review-package.sh BASE` and pass the printed file path. The diff content never enters the main session's context; the reviewer reads the file once.
- **refinement-reviewer**: write the exact byte-sorted canonical `changed_files` paths to a temporary changed-files file, then generate its package with `script/harness/review-package.sh BASE [HEAD] [OUTFILE] --files <each changed_files path>`. `--files` is mandatory. The changed-files file and readable package are this reviewer's only inputs; retain the same file for response validation.
- **Single-file small change, already read by the main session**: the diff snippet may be passed inline to save the reviewer a Read.
- **REVIEW_BASE**: capture `REVIEW_BASE=$(git rev-parse HEAD)` immediately before dispatching the implementer. Use it only with `review-package.sh`; it must remain a `HEAD` ancestor.
- Never use `HEAD~1` with `review-package.sh`; it silently truncates a multi-commit task.

Never paste accumulated prior-round summaries into later dispatches — hand the reviewer its diff as a file path and the current findings list only.

## Handling Refinement Reviewer Output

- Before dispatching `refinement-reviewer`, require the package's authoritative `## Scope Manifest` to exactly equal the supplied `changed_files` set. Generate it with `review-package.sh --files` and retain the exact changed-files file. Repair a missing or mismatched input before dispatching.
- Before reading, deciding, or routing any `refinement-reviewer` JSON, run `bash script/harness/validate-refinement-review.sh RESPONSE_JSON REVIEW_PACKAGE CHANGED_FILES_FILE`. A nonzero result is `blocked`: do not consume the response or route work until inputs are repaired and the reviewer is re-dispatched.
- Process `handoffs` first. Dispatch `security-reviewer` for a `security` handoff and `logic-reviewer` for a `correctness` handoff. Do not route a writer from a handoff, and do not process findings until all handoffs are triaged.
- After handoff triage, route only proven actionable `findings` to the owning writer. Every resulting fix requires a new `refinement-reviewer` review.
- A `candidate` never routes a writer and is a valid final output. Record its `hypothesis` and exact `required_evidence`. Re-dispatch `refinement-reviewer` only if the caller later supplies that evidence.
- Interpret verdicts strictly: `pass` has empty report arrays and complete `reviewed_files`; `action-required` has at least one report item and complete `reviewed_files`; `blocked` has empty report arrays and means a required input or skill is unavailable or invalid, or the supplied scope cannot be completely inspected or reviewed; its `reviewed_files` is the actual completed subset, and its `summary` identifies the reason and unreviewed paths.

## Handling Reviewer needs_cross_check

A reviewer may set `needs_cross_check: true` on a finding it cannot verify from this diff alone (the requirement depends on unchanged code, other files, or other tasks). This does not block the rest of the review. The main session holds the cross-file and cross-task context the reviewer lacks, so it adjudicates each such item: confirm a real gap and route it back to the owning writer for a fix plus re-review, or close it as a non-issue. Never silently drop a `needs_cross_check` item.

## Handling Reviewer needs_fp_check (security)

security-reviewer uses `needs_fp_check: true` (not `needs_cross_check`) when it suspects an exploitable vulnerability but cannot fully trace the call path to confirm exploitability. The main session routes any such finding to the `fp-check` skill for deep verification before acting on it — the security counterpart to needs_cross_check.
