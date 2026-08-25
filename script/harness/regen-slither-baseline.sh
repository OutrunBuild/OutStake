#!/usr/bin/env bash
set -euo pipefail

# Regenerate script/harness/slither-baseline.json deterministically:
#   1. serialized forge build (flock via forge-serialize.sh)
#   2. slither run twice with the gate's exact flags
#   3. keep only the intersection of the two runs' normalized findings
#      (single-run-only findings are forge incremental-build drift noise)
#
# Usage: bash script/harness/regen-slither-baseline.sh

usage() {
    cat >&2 <<'EOF'
Usage: bash script/harness/regen-slither-baseline.sh
EOF
}

die() {
    echo "regen-slither-baseline: ERROR: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
policy_file="$repo_root/.harness/policy.json"
baseline_file="$script_dir/slither-baseline.json"

[ -f "$policy_file" ] || die "policy file is missing: $policy_file"

slither_exclude_detectors="$(jq -r '.risk_rules.slither_exclude_detectors // ""' "$policy_file")"
slither_filter_paths="$(jq -r '.risk_rules.slither_filter_paths // ""' "$policy_file")"
[ -n "$slither_exclude_detectors" ] || die "risk_rules.slither_exclude_detectors is empty in $policy_file"
[ -n "$slither_filter_paths" ] || die "risk_rules.slither_filter_paths is empty in $policy_file"

command -v slither >/dev/null 2>&1 || die "slither not found in PATH"
command -v jq >/dev/null 2>&1 || die "jq not found in PATH"

tmp_dir="$(mktemp -d "$repo_root/.harness/tmp/regen-slither.XXXXXX")"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

run1_file="$tmp_dir/run1.json"
run2_file="$tmp_dir/run2.json"

echo "regen-slither-baseline: serialized forge build"
bash "$script_dir/forge-serialize.sh" build > "$tmp_dir/build.log" 2>&1 || die "serialized forge build failed (see $tmp_dir/build.log)"

run_slither() {
    local output_file="$1"
    set +e
    slither src \
        --filter-paths "$slither_filter_paths" \
        --exclude-dependencies \
        --exclude "$slither_exclude_detectors" \
        --json - \
        --json-types detectors \
        --fail-none \
        --disable-color > "$output_file" 2>&1
    local exit_code=$?
    set -e
    [ "$exit_code" -eq 0 ] || die "slither failed with exit code $exit_code (see $output_file)"
    jq -e '.success == true and (.results.detectors | type == "array")' "$output_file" >/dev/null 2>&1 \
        || die "slither did not emit valid detector JSON (see $output_file)"
}

echo "regen-slither-baseline: slither run 1 of 2"
run_slither "$run1_file"
echo "regen-slither-baseline: slither run 2 of 2"
run_slither "$run2_file"

run1_normalized="$(jq '
    def norm_summary:
        (.description // "")
        | split("\n")[0]
        | sub(" \\([^)]*#L?[0-9]+(-L?[0-9]+)?\\)"; "")
        | sub(" \\([^)]*#[0-9]+(-[0-9]+)?\\)"; "");
    def normalize:
        {
            id: (.id // ""),
            check: (.check // ""),
            impact: (.impact // ""),
            confidence: (.confidence // ""),
            location: (.first_markdown_element // ""),
            summary: norm_summary,
            key: (
                (.check // "") + "|" +
                ((.first_markdown_element // "") | split("#")[0]) + "|" +
                norm_summary
            )
        };
    [.results.detectors[] | normalize]
' "$run1_file")"
run2_keys="$(jq '
    def norm_summary:
        (.description // "")
        | split("\n")[0]
        | sub(" \\([^)]*#L?[0-9]+(-L?[0-9]+)?\\)"; "")
        | sub(" \\([^)]*#[0-9]+(-[0-9]+)?\\)"; "");
    def normalize:
        {
            summary: norm_summary,
            key: (
                (.check // "") + "|" +
                ((.first_markdown_element // "") | split("#")[0]) + "|" +
                norm_summary
            )
        };
    [.results.detectors[] | normalize.key] | unique
' "$run2_file")"

# The baseline is consumed as a KEY SET, so deduplicate by key (keep the first
# occurrence per key): a single run may contain multiple detector entries that
# normalize to the same key (e.g. several timestamp findings in one function).
stable_file="$tmp_dir/stable.json"
printf '%s' "$run1_normalized" | jq --argjson run2_keys "$run2_keys" '
    [.[] | select(.key as $key | $run2_keys | index($key))]
    | group_by(.key) | map(.[0])
    | sort_by(.key)
' > "$stable_file"

run1_count="$(jq '.results.detectors | length' "$run1_file")"
run2_count="$(jq '.results.detectors | length' "$run2_file")"
run1_key_count="$(printf '%s' "$run1_normalized" | jq 'map(.key) | unique | length')"
run2_key_count="$(printf '%s' "$run2_keys" | jq 'length')"
intersection_key_count="$(jq 'map(.key) | unique | length' "$stable_file")"
drift_count=$(( run1_key_count + run2_key_count - 2 * intersection_key_count ))

generated_at="$(date -u +%Y-%m-%d)"
candidate_file="$tmp_dir/baseline.json"
jq -n \
    --arg generated_at "$generated_at" \
    --slurpfile findings "$stable_file" \
    '{version: 1, tool: "slither", generated_at: $generated_at, target: "src", findings: $findings[0]}' \
    > "$candidate_file"

# Validations before writing.
python3 -m json.tool "$candidate_file" >/dev/null 2>&1 || jq -e . "$candidate_file" >/dev/null 2>&1 || die "produced baseline failed JSON round-trip"

written_count="$(jq '.findings | length' "$candidate_file")"
written_key_count="$(jq '[.findings[].key] | unique | length' "$candidate_file")"
run1_keys="$(printf '%s' "$run1_normalized" | jq -c 'map(.key) | unique')"
run2_keys_j="$(printf '%s' "$run2_keys" | jq -c '.')"
[ "$written_count" -eq "$intersection_key_count" ] || die "self-check failed: written count ($written_count) != intersection key count ($intersection_key_count)"
[ "$written_key_count" -eq "$intersection_key_count" ] || die "self-check failed: written unique key count ($written_key_count) != intersection key count ($intersection_key_count)"
missing_from_runs="$(jq --argjson findings "$(jq -c '[.findings[].key]' "$candidate_file")" --argjson r1 "$run1_keys" --argjson r2 "$run2_keys_j" -n '$ARGS.named.findings - ($ARGS.named.r1 + $ARGS.named.r2 | unique) | length')"
[ "$missing_from_runs" -eq 0 ] || die "self-check failed: $missing_from_runs written keys not present in both runs' key sets"

printf '\n' >> "$candidate_file"
mv "$candidate_file" "$baseline_file"

echo "regen-slither-baseline: run1=$run1_count detectors ($run1_key_count unique keys), run2=$run2_count detectors ($run2_key_count unique keys)"
echo "regen-slither-baseline: intersection (written)=$written_count findings, drift=$drift_count (symmetric difference of key sets)"
echo "regen-slither-baseline: wrote $written_count findings to $baseline_file"
