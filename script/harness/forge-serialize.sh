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

exec forge "$@"
