# OutStakeV2 Traceability

- Machine truth: .harness/policy.json
- Session contract: .harness/runtime/main-session-contract.md
- Policy schema: .harness/schemas/policy.schema.json
- Claude agents: .claude/agents/*
- Codex agents: .codex/agents/*
- ZCode agents: .zcode/agents/*
- Pi agents: .pi/agents/*
- Enforcement entrypoint: script/harness/gate.sh

The gate reports phase fields for `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.

For `prod-semantic` work, classification precedes dispatch. The main session decides whether spec/docs changes are needed before doc writers, `spec-reviewer`, code writers, or code reviewers are dispatched. Gate only classifies changed files and verification requirements.
