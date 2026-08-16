# Solidity tests (test/)

Auto-loads when you edit `test/` files.

## Naming
| Pattern | Use | Example |
|---|---|---|
| `test_Description` | standard | `test_TransferUpdatesBalances` |
| `testFuzz_Description` | fuzz | `testFuzz_TransferAnyAmount` |
| `test_RevertWhen_Condition` | revert | `test_RevertWhen_InsufficientBalance` |
| `test_RevertIf_Condition` | revert (alt) | `test_RevertIf_NotOwner` |
| `invariant_Description` | invariant test (below) | `invariant_positionIdMonotonic` |

## Organization
- Test files end with `.t.sol`, test contracts inherit `forge-std/Test.sol`, test functions start with `test`/`test_`.
- `setUp()` runs before each test — use it to establish fresh state.
- Mirror `src/`: `src/token/Foo.sol` → `test/token/Foo.t.sol`.
- Group related tests in one contract: `contract FooTransferTest is Test { … }`.
- Expose internals via a harness in the area's `mocks/` directory (e.g. `exposed_mint` wrapping `_mint`), never by widening production visibility.

## Common cheatcodes
- Impersonate a caller: `vm.prank(alice)` (single) / `vm.startPrank(alice)` … `vm.stopPrank()` (multiple).
- Fund an address: `vm.deal(alice, 100 ether)`.
- Time / block: `vm.warp(ts)` (block timestamp), `vm.roll(n)` (block number).
- Assert a revert: `vm.expectRevert(MyError.selector)` or `vm.expectRevert("msg")`.
- Assert an event: `vm.expectEmit(bool indexed1, bool indexed2, bool indexed3, bool data)` — call `expectEmit` first, then `emit` the reference event, then trigger the call under test.
- Stub an external contract: `vm.mockCall(addr, calldata, returndata)` / `vm.mockFunction`; clean up with `vm.clearMockedCalls()`.
- Label an address for readable traces: `vm.label(addr, "Alice")`.

## Invariant tests
- Function names start with `invariant_`; Forge asserts the invariant holds after a random sequence of calls during fuzzing.
- Use a handler contract plus `targetContract()`/`targetSelector()` to restrict which entry points the fuzzer may call, avoiding arbitrary calls to any function.
- This repo already uses invariant tests (e.g. `OutrunStakingPositionInvariantUpgradeable`, functions like `invariant_positionIdMonotonic`) — new invariants must follow the same pattern.

## Fork testing
- Test against live chain state: `forge test --fork-url <rpc> --fork-block-number <n>` (pin the block number for reproducibility); or set `eth_rpc_url` in `foundry.toml`.

## Fuzzing & coverage
- Prefer `bound(x, lo, hi)` over `vm.assume(cond)` — `assume` discards inputs (slows fuzzing), `bound` maps them into range.
- Always cover: zero / max amounts, unauthorized caller (`vm.prank(attacker)` + `vm.expectRevert(...)`).
- Coverage: `forge coverage` (`--report lcov` for lcov).

## Inheritance (strict — see AGENTS.md "Test Code Rules")
Never directly inherit a production contract. Simulate dependencies with interfaces, abstract contracts, or standalone implementations. Mocks go in the area's `mocks/` subdirectory (e.g. `test/support/mocks/`, `test/upgradeable/mocks/`, `test/deploy/mocks/`). (AGENTS.md is always in context — this is a reminder.)

## Debugging verbosity
- `-vvv`: traces for failing tests only (most common for debugging).
- `-vvvv`: traces for all tests, including setup.
- `-vvvvv`: traces plus storage changes.
