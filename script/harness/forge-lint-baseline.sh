#!/usr/bin/env bash
set -euo pipefail

# Forge-lint findings baseline manager:
#   check — run `forge lint --json`, build the current finding-key set, and fail on any key
#           absent from script/harness/forge-lint-baseline.json (NEW findings only).
#   regen — regenerate the baseline file from the current `forge lint --json` output.
#
# Finding key (content-addressed so line drift does not mass-invalidate the baseline):
#   <detector-id>|<repo-relative-file>|<first-16-hex-of-sha256(trimmed source line at line_start)>
# The trimmed source line strips ALL whitespace before hashing, so re-indentation does not
# change the key.
#
# Exit codes (check): 0 = no new findings; 1 = new findings (printed to stdout);
# 2 = fail closed (baseline missing/invalid, or forge lint produced no parseable output).
#
# Usage: bash script/harness/forge-lint-baseline.sh {check|regen}

usage() {
    cat >&2 <<'EOF'
Usage: bash script/harness/forge-lint-baseline.sh {check|regen}
  check — exit 0 when every current forge-lint finding is within the baseline;
          exit 1 printing each NEW finding as `detector file:line`;
          exit 2 when the baseline is missing/invalid or forge lint fails.
  regen — regenerate script/harness/forge-lint-baseline.json from current findings.
EOF
}

die() {
    local exit_code="${2:-1}"
    echo "forge-lint-baseline: ERROR: $*" >&2
    exit "$exit_code"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
baseline_file="$repo_root/script/harness/forge-lint-baseline.json"

command -v forge >/dev/null 2>&1 || die "forge not found in PATH"
command -v jq >/dev/null 2>&1 || die "jq not found in PATH"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found in PATH"

case "${1:-}" in
    check|regen) mode="$1" ;;
    *) usage; die "unsupported mode: ${1:-<none>}" ;;
esac

mkdir -p "$repo_root/.harness/tmp"
tmp_dir="$(mktemp -d "$repo_root/.harness/tmp/forge-lint-baseline.XXXXXX")"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

baseline_notes="Snapshot of forge-lint findings accepted under this repo's verified conventions (formerly the foundry.toml exclude_lints list): naming-style rules (mixed-case variable/function, screaming-snake immutable, pascal-case struct, interface naming/file-naming), block-timestamp, reentrancy-events (CEI trailing emits), unused-return (multi-return oracle destructures), non-reentrant-not-first, literal-instead-of-constant, inline-assembly, low-level-calls, internal-function-used-once, unwrapped-modifier-logic — patterns that misfire on verified codebase conventions. Detectors run at severity high/med/low. Any NEW finding beyond this set fails the gate and the wrapped build. Former inline \`// forge-lint: disable-next-line(...)\` directives were removed and their sites absorbed here after per-site review (arbitrary-send-eth ×6: exact-value native deposits to trusted configured adapters or the caller's own recipient; unsafe-typecast ×5: bounds argued in adjacent comments; missing-events ×5: accounting aggregates announced by function-level events; plus divide-before-multiply = LayerZero dust-removal formula, sequencer-feed zero sentinel, zero-default loop/rate locals); the baseline is now the single suppression inventory. Regen intentionally re-snapshots: it is an explicit, git-reviewed acceptance decision. Regenerate: bash script/harness/forge-lint-baseline.sh regen"

# Run `forge lint --json` (newline-delimited diagnostic objects, slurped with jq -s) and emit
# one TSV row per finding: detector <TAB> repo-relative-file <TAB> line_start <TAB> trimmed-source-line
collect_findings_tsv() {
    local tsv_file="$1"
    local stdout_file="$tmp_dir/lint.json"
    local stderr_file="$tmp_dir/lint.stderr.log"
    local exit_code
    set +e
    # Anchor to the repo root: forge lint resolves the project from cwd, and an inherited foreign cwd silently lints the wrong project (or nothing).
    cd "$repo_root"
    forge lint --json > "$stdout_file" 2> "$stderr_file"
    exit_code=$?
    set -e

    if [ ! -s "$stdout_file" ]; then
        [ "$exit_code" -eq 0 ] || die "forge lint --json failed with exit code $exit_code and no output (see $stderr_file)" 2
        : > "$tsv_file"
        return
    fi

    local parsed_file="$tmp_dir/findings.parsed.tsv"
    jq -sr --arg repo_root "$repo_root" '
        def repo_relative:
            gsub("\\\\"; "/")
            | sub("^" + $repo_root + "/"; "");
        def selected: select((.code.code // "") != "" and .spans[0] != null);
        [.[] | selected]
        | map({
            detector: .code.code,
            file: (.spans[0].file_name | repo_relative),
            line: (.spans[0].line_start // 0),
            source: ([.spans[0].text[]?.text] | join("") | gsub("\\s+"; ""))
          })
        | .[]
        | [.detector, .file, (.line | tostring), .source]
        | @tsv
    ' "$stdout_file" > "$parsed_file" || die "forge lint --json did not emit parseable diagnostic JSON (see $stderr_file)" 2

    # Every diagnostic object must yield a row; a dropped diagnostic would silently shrink
    # the checked set, so a count mismatch fails closed.
    local total_objects selected_rows
    total_objects="$(jq -s 'length' "$stdout_file")"
    selected_rows="$(wc -l < "$parsed_file" | tr -d '[:space:]')"
    [ "$selected_rows" -eq "$total_objects" ] \
        || die "diagnostic parse mismatch: $total_objects objects, $selected_rows rows (see $stdout_file)" 2

    mv "$parsed_file" "$tsv_file"
}

# Turn finding rows into keyed rows (sorted, deduplicated by key, C collation):
#   key <TAB> detector <TAB> file <TAB> line
build_key_rows() {
    local tsv_file="$1"
    local rows_file="$2"
    local detector file line source hash
    : > "$rows_file"
    while IFS=$'\t' read -r detector file line source; do
        [ -n "$detector" ] && [ -n "$file" ] || die "finding row missing detector or file: '$detector' '$file'" 2
        hash="$(printf '%s' "$source" | sha256sum | cut -c1-16)"
        printf '%s\t%s\t%s\t%s\n' "$detector|$file|$hash" "$detector" "$file" "$line" >> "$rows_file"
    done < "$tsv_file"
    LC_ALL=C sort -t$'\t' -k1,1 "$rows_file" | awk -F'\t' '!seen[$1]++' > "$rows_file.sorted"
    mv "$rows_file.sorted" "$rows_file"
}

if [ "$mode" = "check" ]; then
    [ -f "$baseline_file" ] || die "baseline file is missing: $baseline_file" 2
    jq -e '
        type == "object"
        and .version == 1
        and (.finding_count | type) == "number"
        and (.findings | type) == "array"
        and (.findings | length) == .finding_count
        and all(.findings[]; ((.key | type) == "string") and (.key != ""))
    ' "$baseline_file" >/dev/null 2>&1 || die "baseline file is invalid: $baseline_file" 2

    collect_findings_tsv "$tmp_dir/findings.tsv"
    build_key_rows "$tmp_dir/findings.tsv" "$tmp_dir/key_rows.tsv"
    cut -f1 "$tmp_dir/key_rows.tsv" > "$tmp_dir/current_keys.txt"
    jq -r '.findings[].key' "$baseline_file" | LC_ALL=C sort > "$tmp_dir/baseline_keys.txt"

    new_keys_file="$tmp_dir/new_keys.txt"
    LC_ALL=C comm -23 "$tmp_dir/current_keys.txt" "$tmp_dir/baseline_keys.txt" > "$new_keys_file"

    if [ -s "$new_keys_file" ]; then
        while IFS= read -r new_key; do
            awk -F'\t' -v key="$new_key" '$1 == key { print $2 " " $3 ":" $4; exit }' "$tmp_dir/key_rows.tsv"
        done < "$new_keys_file"
        exit 1
    fi
    exit 0
fi

# regen mode
collect_findings_tsv "$tmp_dir/findings.tsv"
build_key_rows "$tmp_dir/findings.tsv" "$tmp_dir/key_rows.tsv"
cut -f1 "$tmp_dir/key_rows.tsv" > "$tmp_dir/current_keys.txt"

finding_count="$(wc -l < "$tmp_dir/current_keys.txt" | tr -d '[:space:]')"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
candidate_file="$tmp_dir/baseline.json"

jq -R -s 'split("\n") | map(select(length > 0)) | map({key: .}) | sort_by(.key)' \
    "$tmp_dir/current_keys.txt" > "$tmp_dir/findings.json"
jq -n \
    --arg generated_at "$generated_at" \
    --arg notes "$baseline_notes" \
    --argjson finding_count "$finding_count" \
    --slurpfile findings "$tmp_dir/findings.json" \
    '{version: 1, generated_at: $generated_at, finding_count: $finding_count, notes: $notes, findings: $findings[0]}' \
    > "$candidate_file"

# Validations before writing.
jq -e . "$candidate_file" >/dev/null 2>&1 || die "produced baseline failed JSON round-trip"
written_count="$(jq '.findings | length' "$candidate_file")"
[ "$written_count" -eq "$finding_count" ] || die "self-check failed: written count ($written_count) != computed count ($finding_count)"
written_key_count="$(jq '[.findings[].key] | unique | length' "$candidate_file")"
[ "$written_key_count" -eq "$finding_count" ] || die "self-check failed: written unique key count ($written_key_count) != computed count ($finding_count)"
jq -e '[.findings[].key] == ([.findings[].key] | sort)' "$candidate_file" >/dev/null 2>&1 \
    || die "self-check failed: findings are not sorted by key"
missing_from_run="$(comm -23 <(jq -r '.findings[].key' "$candidate_file" | LC_ALL=C sort) "$tmp_dir/current_keys.txt" | wc -l | tr -d '[:space:]')"
[ "$missing_from_run" -eq 0 ] || die "self-check failed: $missing_from_run written keys are not present in the current run"

printf '\n' >> "$candidate_file"
mv "$candidate_file" "$baseline_file"

echo "forge-lint-baseline: wrote $finding_count findings to $baseline_file"
