# OutStakeV2 Traceability

- Machine truth: .harness/policy.json
- Session contract: .harness/runtime/main-session-contract.md
- Policy schema: .harness/schemas/policy.schema.json
- Claude agents: .claude/agents/*
- Codex agents: .codex/agents/*
- ZCode agents: .zcode/agents/*
- Pi agents: .pi/agents/*
- Enforcement entrypoint: script/harness/gate.sh
- Scope-rule generator: script/harness/sync-agent-docs.sh (regenerates `.claude/rules/solidity-*.md` from the nested `src/AGENTS.md`, `script/AGENTS.md`, `test/AGENTS.md`; `--check` verifies no drift)
- Generated scope rules: `.claude/rules/solidity-contracts.md` (from `src/AGENTS.md`), `.claude/rules/solidity-scripts.md` (from `script/AGENTS.md`), `.claude/rules/solidity-tests.md` (from `test/AGENTS.md`)

The gate reports phase fields for `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.

For `prod-semantic` work, classification precedes dispatch. The main session decides whether spec/docs changes are needed before doc writers, `spec-reviewer`, code writers, or code reviewers are dispatched. Gate only classifies changed files and verification requirements.
