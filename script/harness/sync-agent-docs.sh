#!/usr/bin/env bash
#
# sync-agent-docs.sh — single-source generator for per-scope Solidity rule files.
#
# The nested scope AGENTS.md files are the single source of truth:
#   src/AGENTS.md, script/AGENTS.md, test/AGENTS.md
# This script materializes them (frontmatter + identical body) into the
# per-scope .claude/rules/*.md files that tools auto-load by scope when editing
# .sol files. Editing a nested AGENTS.md requires regenerating the rule files.
#
# Usage:
#   bash script/harness/sync-agent-docs.sh            # regenerate all rule files
#   bash script/harness/sync-agent-docs.sh --check    # verify no drift; exits non-zero on mismatch
#
# Idempotent and repeatable: it never double-nests frontmatter (body is taken
# verbatim from the nested AGENTS.md, which itself has no frontmatter).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

check_mode=0
if [ "${1:-}" = "--check" ]; then
    check_mode=1
elif [ -n "${1:-}" ]; then
    echo "usage: bash $0 [--check]" >&2
    exit 2
fi

# scope | source AGENTS.md | generated rule file | comma-separated path globs
scopes=(
    "src|src/AGENTS.md|.claude/rules/solidity-contracts.md|src/**/*.sol"
    "script|script/AGENTS.md|.claude/rules/solidity-scripts.md|script/**/*.sol"
    "test|test/AGENTS.md|.claude/rules/solidity-tests.md|test/**/*.sol"
)

fail=0

for entry in "${scopes[@]}"; do
    IFS='|' read -r scope source_rel rule_rel paths_csv <<< "$entry"
    source_file="$repo_root/$source_rel"
    rule_file="$repo_root/$rule_rel"

    if [ ! -f "$source_file" ]; then
        echo "sync-agent-docs: missing source $source_rel" >&2
        fail=1
        continue
    fi

    if [ "$check_mode" -eq 1 ]; then
        # Strip the frontmatter block (leading '---' delimited block) from the
        # generated rule file and compare the remaining body to the source.
        body_from_rule="$(awk 'BEGIN{in_fm=0; seen=0}
            /^---[[:space:]]*$/ {
                if (!seen) { seen=1; in_fm=1; next }
                if (in_fm) { in_fm=0; next }
            }
            !in_fm { print }
        ' "$rule_file")" || body_from_rule=""
        body_from_source="$(cat "$source_file")"

        if [ "$body_from_rule" != "$body_from_source" ]; then
            echo "sync-agent-docs: DRIFT in $rule_rel (differs from $source_rel)" >&2
            diff -u <(printf '%s\n' "$body_from_rule") <(printf '%s\n' "$body_from_source") >&2 || true
            fail=1
        fi
        continue
    fi

    {
        printf -- '---\n'
        printf 'paths:\n'
        IFS=',' read -ra paths <<< "$paths_csv"
        for p in "${paths[@]}"; do
            printf '  - "%s"\n' "$p"
        done
        printf -- '---\n'
        cat "$source_file"
    } > "$rule_file"
done

if [ "$fail" -eq 1 ]; then
    exit 1
fi

if [ "$check_mode" -eq 1 ]; then
    echo "sync-agent-docs --check: OK (all scope rule files match their AGENTS.md)"
fi
