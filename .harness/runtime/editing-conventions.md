# Editing Conventions

Read this file before editing any `.sol` file (all scopes), writing tests or mocks, editing `docs/`, or editing a nested `src/AGENTS.md` / `script/AGENTS.md` / `test/AGENTS.md`.

## Beginner-Readable Code (high priority)

- Optimize for code a beginner can read top to bottom.
- Favor beginner-readable names over protocol jargon, abbreviations, or internal shorthand.
- If a specialized term must stay, explain it at first use in a short local comment.
- Add short implementation comments for non-obvious business logic, invariants, or cross-step reasoning. NatSpec alone is not enough.
- Many tiny single-use helpers make code harder to follow because readers must jump around.
- Extract a helper only when it clearly improves readability, naming, reuse, or testability.
- Inline trivial single-use logic unless extraction clearly improves comprehension.
- Solidity style and best practices for each scope are maintained as nested `AGENTS.md` files whose **single source of truth** is the nested file itself: `src/AGENTS.md`, `script/AGENTS.md`, `test/AGENTS.md`. The per-scope `.claude/rules/*.md` files (`solidity-contracts.md` for `src/`, `solidity-tests.md` for `test/`, `solidity-scripts.md` for `script/`) are **generated from** those nested files — after editing a nested `AGENTS.md`, regenerate them by running `bash script/harness/sync-agent-docs.sh`. The local per-tool skill mirrors (`.dsh/skills/`, `.codex/skills/`, `.zcode/skills/`, `.pi/skills/`) have been removed and must **not** be rebuilt.

## Doc-Code Citation Convention

- All documents under `docs/` except the `review/` subdirectory must cite code in `File.sol::function` or `File.sol` form (e.g. `Contract.sol::functionName`).
- Do not write code line numbers in these documents (e.g. `Contract.sol:130-131`): line numbers drift as code evolves and distort doc anchors; function names/symbols are the stable anchors.
- New or modified documents must follow this convention; when reviewing these documents, treat violations as minor-level findings.

## Test Code Rules

- Test contracts must NOT inherit upgradeable production contracts (those using `Initializable`, proxy patterns, or storage-in-heritage layouts). Use interfaces, abstract contracts, or standalone implementations to simulate dependencies.
- Test contracts MAY inherit non-upgradeable production contracts (plain contracts without initializer logic or proxy storage risks).
- Mock contracts go in the `mocks/` subdirectory of the test area they serve (e.g. `test/support/mocks/`, `test/upgradeable/mocks/`, `test/deploy/mocks/`). Do not co-locate mock files with test files.
- Mock contracts reuse interfaces from `src/`. Define test-only interfaces only when src/ interfaces are insufficient.
- **Exception:** Test contracts may inherit an upgradeable `src/` contract only when it is declared `abstract contract` — either to implement its abstract functions for unit testing, or to expose its internal `pure`/`view` functions. Such harnesses must live in the area's `mocks/` subdirectory.
- Mock fidelity is part of Test Code Rules: every mock must model every seam the tested path depends on. A mock that intentionally models only part of a production interface MUST declare `@dev Partial mock:` in its header NatSpec and enumerate the modeled and unmodeled seams. Token-surface seams (`getTokensIn`/`getTokensOut` vs `isValidTokenIn`/`isValidTokenOut`) must be mutually consistent; redeem must not mint new mock SY to satisfy a token-out path.
