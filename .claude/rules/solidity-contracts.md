---
paths:
  - "src/**/*.sol"
---

# Solidity production contracts (src/)

Auto-loads when you edit `src/` contracts. Goal: consistency and readability, not "one true way". `forge fmt` is authoritative for whitespace/braces/wrapping — this repo has no `[fmt]` override, so defaults apply (`line_length = 120`, `tab_width = 4`), matching the official Solidity style guide. This rule covers what `forge fmt` does **not** enforce: ordering, naming, NatSpec, imports, security.

## File layout
Top to bottom: SPDX → `pragma` → `import` (top of file only, never between contracts) → `interface` → `library` → `contract`.

Inside each contract / library / interface:
1. Type declarations (`struct`, `enum`)
2. State variables
3. Events
4. Errors
5. Modifiers
6. `constructor` → `receive` → `fallback`
7. Functions: `external` → `public` → `internal` → `private`; within each group, state-changing (including `payable`) first, then `view`, then `pure`.

## Function signature
Modifiers in this exact order: **visibility → mutability (`view`/`pure`) → `virtual` → `override` → custom modifiers**.

```solidity
function balance(uint256 id) public view override returns (uint256)
function shutdown() public onlyOwner
```

**Explicit visibility**: every function declares `external`/`public`/`internal`/`private` explicitly — never rely on defaults (implicit visibility is a common source of security bugs).

## Imports
Named imports only — `import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";`. Avoid bare/star imports (slower compilation, hidden dependencies). Prefer one contract per file; the filename matches the core contract name in PascalCase (`Owned.sol` → `contract Owned`).

## Naming
| Element | Convention | Example |
|---|---|---|
| contract / library / interface / struct / enum / event | CapitalizedWords (PascalCase) | `SimpleToken`, `Position`, `Deposit` |
| function / parameter / modifier / local & state variable | mixedCase (lowerCamelCase) | `getBalance`, `initialSupply`, `onlyOwner` |
| `constant` | UPPER_CASE_WITH_UNDERSCORES | `MAX_BLOCKS`, `TOKEN_NAME` |
| `immutable` | match the surrounding file — follow the repo's dominant convention; the official guide prefers UPPER_SNAKE_CASE for new files with no precedent | `TREASURY` vs `lzEndpoint` |

- Abbreviations: in PascalCase capitalize all letters (`HTTPServerError`); in mixedCase only the leading one is lowercase (`xmlHTTPRequest`).
- Never name a single-letter variable `l`, `O`, or `I` (confusable with `1`/`0`).
- Resolve a name clash with a single trailing underscore (`owner_`).
- Prefix `private`/`internal` functions and state variables with a single leading underscore (`_treasury`). When you later promote such a member to `external`/`public`, the forced rename makes you re-check every call site — never bulk find-and-replace a leading underscore away (a common cause of unintended external exposure).
- A library function that operates on a struct takes that struct first, named `self`.

## NatSpec
Fully annotate every public/external member (the whole ABI) with `///` or `/** ... */`, placed directly above the declaration. Use `@param`, `@return`, `@dev`, `@notice`, `@title`, `@author`; document reverts/errors and any non-obvious invariant. Annotate the contract declaration itself (`@title`/`@notice`).

## Error handling
Prefer custom errors: `error InsufficientBalance();` + `revert InsufficientBalance();`, over `require(cond, "string")` (cheaper gas; the project already uses them heavily). Error names are PascalCase.

## Security
- **Checks-Effects-Interactions (CEI)**: perform checks first (caller, argument range, balance) → then apply state effects → only then interact with other contracts or transfer ETH. Prevents reentrancy; even calls to "known" contracts can reach unknown ones, so apply it always.
- **Never use `tx.origin` for authorization** — always `msg.sender` (`tx.origin` lets a phished contract drain funds).
- **Pull over push (withdrawal pattern)**: let users `withdraw` themselves; do not push ETH/tokens to recipients (a failing recipient causes DoS, and push invites reentrancy).
- **Send ETH with `.call{value: ...}("")`**: it forwards all remaining gas (a **reentrancy surface** — check the return value and pair with CEI/ReentrancyGuard); `transfer`/`send` only provide the 2300 gas stipend and are no longer recommended (modern contracts' receive/fallback often exceed it and fail).
- **Unbounded loops = gas-limit DoS**: if a loop's iteration count depends on storage or user input, cap it or document it, or the contract can be stalled permanently (even `view` functions can stall their callers).
- **0.8 arithmetic is checked by default; `unchecked{}` silently disables overflow checks** — confirm no overflow can occur before using it (otherwise the contract may be permanently stuck), and tighten inputs with `require`.
- **Everything on-chain is public (including `private`)**: store no secrets; `block.timestamp`/`blockhash` etc. are manipulable by block builders and **must not be used as a randomness source**.
- **Upgradeable contracts: internal function pointers are ephemeral — never persist them across upgrades** (an upgrade invalidates them). This repo uses upgradeable contracts heavily — take extra care.
- **Mapping clearing pitfall**: `delete`/`pop` on an array or struct containing a mapping does **not** clear the mapping entries (mappings don't track keys) → storage leak; use an iterable mapping to clean up.
- **Modifiers should only validate** — avoid external calls or heavy logic inside a modifier (easy path to reentrancy/bypass).
- **`msg.data` malleability**: sub-32-byte types carry dirty higher-order bits — do not `keccak256(msg.data)`.
- **Treat compiler warnings as errors**; limit the value held by a single contract.

## Project specifics
- Compiler: Solidity `0.8.35`, `via_ir = true`, `optimizer_runs = 200`, `evm_version = prague`. Verify deployments use exactly these settings.
- Naming lints may not flag every deviation depending on the repo's `[lint]` config — apply the naming table above yourself.
- "Stack too deep": pack variables into structs, split large functions, or rely on `via_ir` (already enabled) as a last resort.
- On surgical edits, follow the file's existing conventions; do not rename or reorder unrelated code.
- Before you ship: `forge test -vvvv`, `forge lint`, `forge fmt --check`; `forge taint src/<Contract>.sol` for untrusted-data flows; production keys in keystore/HW (never plaintext, never Anvil defaults); keep `.env` out of VCS.
