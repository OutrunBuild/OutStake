#!/usr/bin/env bash
set -euo pipefail

# Serialize forge build/compile (and any other forge subcommand run through this
# wrapper) so concurrent invocations can't corrupt the incremental build cache or
# burn the 12-15 min via_ir rebuild budget at the same time.
#
# Usage: bash script/harness/forge-serialize.sh <forge args...>
#   e.g. bash script/harness/forge-serialize.sh build
#        bash script/harness/forge-serialize.sh compile --
#        bash script/harness/forge-serialize.sh build --force
#
# Holds an exclusive flock on ${TMPDIR:-/tmp}/outstake-forge.lock, then execs
# the real forge under that lock. The lock auto-releases when forge exits or is
# killed; the lock file is harmless if left behind.

lock_dir="${TMPDIR:-/tmp}"
lock_file="$lock_dir/outstake-forge.lock"

command -v forge >/dev/null 2>&1 || {
    echo "forge-serialize: forge not found in PATH" >&2
    exit 127
}

mkdir -p "$lock_dir"
exec 9>"$lock_file"

if ! flock -n 9; then
    echo "forge-serialize: another forge build/compile is running; waiting on lock $lock_file. This is normal serialization, not a hang — the call proceeds once the prior build finishes." >&2
    # Heartbeat every 60s so callers (including background/polling agents and
    # their users) can see the call is still queued, not frozen. Killed once the
    # lock is acquired so it never overlaps forge's own output.
    (
        exec 9>&-  # heartbeat subshell closes the inherited lock fd: it holds no ofl on the lock file, so its survival cannot block the main process from releasing the lock.
        elapsed=0
        while true; do
            sleep 60
            elapsed=$((elapsed + 60))
            echo "forge-serialize: still waiting on lock, ${elapsed}s elapsed ..." >&2
        done
    ) &
    heartbeat=$!
    flock 9
    kill "$heartbeat" 2>/dev/null || true
    # Do NOT wait: the heartbeat subshell has run exec 9>&- so it holds no lock fd; it exits
    # asynchronously and is reaped by init. Calling wait instead risks being blocked by a
    # subshell that caught an ineffective SIGTERM while the lock was held (a hold-lock deadlock).
fi

# Post-build forge-lint baseline enforcement. For build/compile the wrapper injects
# --no-lint so wrapped builds stay compile-signal only, runs forge in the foreground
# (output must stream live for background/polling callers), and after a successful
# compile checks the findings baseline — NEW findings fail the invocation. All other
# subcommands (test, lint, fmt, inspect, script, ...) exec straight through so the
# gate's per-test-file loop never re-runs the lint N times; the gate always runs
# forge build first, so coverage is preserved.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

subcmd="${1:-}"
case "$subcmd" in
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
