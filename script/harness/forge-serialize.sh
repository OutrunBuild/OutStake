#!/usr/bin/env bash
set -euo pipefail

# Serialize forge subcommands that trigger compilation or read/write the build
# cache or compiled artifacts (build, compile, test, ...) so concurrent
# invocations can't corrupt the incremental build cache or burn the 12-15 min
# via_ir rebuild budget at the same time. fmt and config never compile and
# never touch the cache or artifacts, so they pass through without the lock.
#
# Usage: bash script/harness/forge-serialize.sh <forge args...>
#   e.g. bash script/harness/forge-serialize.sh build
#        bash script/harness/forge-serialize.sh compile --
#        bash script/harness/forge-serialize.sh build --force
#
# Two-level model. Compile-capable invocations (build, compile, script, ...)
# hold an exclusive flock on /tmp/outstake-forge-$(id -u)/outstake-forge.lock
# for their whole run and exec the real forge under it. test is split in two:
# it compiles under the exclusive lock, releases the lock, then runs in one of
# at most 2 test execution slots. fmt/config/lint pass through without taking
# any lock. The lock auto-releases when forge exits or is killed; the lock
# file is harmless if left behind. The lock file also records the current
# holder's pid and command line so queued callers can see who is ahead.

# Fixed path: mutual exclusion must not silently depend on the caller's TMPDIR.
# Two agents with different TMPDIR values would otherwise hold two different
# locks and compile concurrently. Scoped to the uid: the lock file lives in a
# predictable world-writable directory and is rewritten by path, so a shared
# /tmp entry would be a symlink-swap target and cross-user stale files would
# break acquisition.
lock_dir="/tmp/outstake-forge-$(id -u)"
lock_file="$lock_dir/outstake-forge.lock"
# Test execution slots: test runs only read compiled artifacts, so up to two
# proceed at once; compile-capable invocations stay mutually exclusive because
# concurrent solc runs corrupt the shared cache.
exec_dir="$lock_dir/exec"

command -v forge >/dev/null 2>&1 || {
    echo "forge-serialize: forge not found in PATH" >&2
    exit 127
}

subcmd="${1:-}"

# fmt/config/lint never compile and never read or write the build cache or
# compiled artifacts (lint is source-level analysis only), so they cannot
# corrupt the incremental cache; run them directly so they cannot queue behind
# a long build/test holding the lock.
case "$subcmd" in
    fmt|config|lint)
        exec forge "$@"
        ;;
esac

mkdir -m 700 -p "$lock_dir"
chmod 700 "$lock_dir" 2>/dev/null || true
mkdir -m 700 -p "$exec_dir"
chmod 700 "$exec_dir" 2>/dev/null || true

# Append-open does not truncate, so the record written by the current holder
# survives for waiters to read; once the lock is acquired, the holder rewrites
# the whole file with its own record.
exec 9>>"$lock_file"

# Render the lock-file record for display. The record outlives its holder
# (kept until the next holder rewrites it) and pids can be recycled, so a
# dead pid gets an explicit staleness marker instead of posing as the
# current holder.
holder_display() {
    local record pid
    record="$(head -n 1 "$lock_file" 2>/dev/null || true)"
    [ -n "$record" ] || { printf 'not recorded'; return; }
    pid="$(printf '%s\n' "$record" | awk '{print $2}')"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$record"
    else
        printf '%s (record stale: pid gone)' "$record"
    fi
}

if ! flock -n 9; then
    holder_info="$(holder_display)"
    echo "forge-serialize: another wrapped forge invocation is running (holder: ${holder_info:-not recorded}); waiting on lock $lock_file. This is normal serialization, not a hang — the call proceeds once the prior invocation finishes." >&2
    # Heartbeat every 15s so callers (including background/polling agents and
    # their users) can see the call is still queued, not frozen. Killed once the
    # lock is acquired so it never overlaps forge's own output.
    (
        exec 9>&-  # heartbeat subshell closes the inherited lock fd: it holds no ofl on the lock file, so its survival cannot block the main process from releasing the lock.
        elapsed=0
        while true; do
            sleep 15
            # $$ in a subshell is still the parent wrapper's pid. If the parent
            # died while this waiter sat on the lock (e.g. SIGKILLed by its
            # caller), exit instead of heartbeating forever to a reader that no
            # longer exists.
            kill -0 "$$" 2>/dev/null || exit 0
            elapsed=$((elapsed + 15))
            holder_info="$(holder_display)"
            echo "forge-serialize: still waiting on lock, ${elapsed}s elapsed (holder: ${holder_info:-not recorded}) ..." >&2
        done
    ) &
    heartbeat=$!
    flock 9
    kill "$heartbeat" 2>/dev/null || true
    # The heartbeat's in-flight `sleep 15` is a separate process: the subshell is
    # now an unreaped zombie, so the sleeper still shows as its child and can be
    # killed by parent pid; without this it orphans out for up to 15s (silent,
    # but unhygienic). pkill may be absent on minimal systems; that is fine.
    command -v pkill >/dev/null 2>&1 && pkill -P "$heartbeat" 2>/dev/null || true
    # Do NOT wait: the heartbeat subshell has run exec 9>&- so it holds no lock fd; it exits
    # asynchronously and is reaped by init. Calling wait instead risks being blocked by a
    # subshell that caught an ineffective SIGTERM while the lock was held (a hold-lock deadlock).
fi

# Record this invocation into the lock file: it doubles as the holder registry,
# so queued callers can see who holds the lock, with what args, since when.
# Overwritten by each new holder; kept after release as the last holder record.
printf 'pid %s since %s: %s\n' "$$" "$(date +%s)" "$*" > "$lock_file" 2>/dev/null || true

# Post-build forge-lint baseline enforcement. For build/compile the wrapper injects
# --no-lint so wrapped builds stay compile-signal only, runs forge in the foreground
# (output must stream live for background/polling callers), and after a successful
# compile checks the findings baseline — NEW findings fail the invocation. All other
# subcommands (test, lint, inspect, script, ...) exec straight through so the
# gate's per-test-file loop never re-runs the lint N times; the gate always runs
# forge build first, so coverage is preserved.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

case "$subcmd" in
    test)
        if printf '%s\n' "$@" | grep -qE -- '--force|--use|--no-auto-detect'; then
            # A forced rebuild or a changed compiler (settings) must recompile
            # inside the slot phase; that recompile must stay under the lock.
            exec forge "$@"
        fi
        touch "$lock_dir/.compile_stamp"
        set +e
        forge build --no-lint
        build_status=$?
        set -e
        if [ "$build_status" -ne 0 ]; then
            exit "$build_status"     # nothing to test without a successful compile
        fi
        if [ -n "$(find "$repo_root/src" "$repo_root/test" "$repo_root/script" "$repo_root/lib" -name '*.sol' -newer "$lock_dir/.compile_stamp" -print -quit 2>/dev/null)" ]; then
            # A source file changed during (or after) the compile, so the cache
            # may be stale. Fall back to the fully serialized path: the
            # exclusive lock is still held here, so forge test recompiles
            # under it instead of racing other compiles.
            exec forge "$@"
        fi
        exec 9>&-                    # fresh compile: release the lock before queueing for an execution slot
        exec 8>"$exec_dir/slot0"
        exec 7>"$exec_dir/slot1"
        if ! flock -n 8 && ! flock -n 7; then
            echo "forge-serialize: both test execution slots busy (2 running); waiting for a free slot ..." >&2
            flock 8
        fi
        exec forge test "${@:2}"
        ;;
    build|compile)
        has_no_lint=0
        for arg in "$@"; do
            if [ "$arg" = "--no-lint" ]; then
                has_no_lint=1
                break
            fi
        done
        if [ "$has_no_lint" -eq 0 ]; then
            set -- "$1" --no-lint "${@:2}"
        fi

        set +e
        forge "$@"
        forge_status=$?
        if [ "$forge_status" -ne 0 ]; then
            set -e
            exit "$forge_status"  # nothing to lint-check on a failed compile
        fi

        # The baseline script invokes plain `forge lint` directly (never this wrapper),
        # so there is no lock recursion; the check runs while the flock is held, which
        # merely extends serialization by the lint duration (~seconds).
        lint_out="$(bash "$repo_root/script/harness/forge-lint-baseline.sh" check)"
        lint_status=$?
        set -e
        case "$lint_status" in
            0)
                exit 0  # silent: clean build stays 3 lines
                ;;
            1)
                printf '%s\n' "$lint_out"
                echo "forge-serialize: NEW forge-lint findings beyond baseline (listed above); fix them, or re-snapshot as an explicit git-reviewed decision via: bash script/harness/forge-lint-baseline.sh regen" >&2
                exit 1
                ;;
            2)
                # its own fail-closed message has already printed to stderr
                exit 2
                ;;
            *)
                exit "$lint_status"
                ;;
        esac
        ;;
    *)
        exec forge "$@"
        ;;
esac
