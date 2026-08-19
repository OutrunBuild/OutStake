#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_classify() {
    local name="$1"
    local changed_files="$2"
    local diff_file="${3-}"
    local expected_status="${4-0}"
    local record="$tmp_dir/$name.record.json"
    local stdout="$tmp_dir/$name.stdout"
    local status
    local -a changed_file_args=()

    mapfile -t changed_file_args <"$changed_files"

    set +e
    if [ -n "$diff_file" ]; then
        RUN_RECORD_PATH="$record" CHANGE_CLASSIFIER_DIFF_FILE="$diff_file" \
            bash script/harness/gate.sh --classify-only --changed-files "${changed_file_args[@]}" >"$stdout"
        status=$?
    else
        RUN_RECORD_PATH="$record" \
            bash script/harness/gate.sh --classify-only --changed-files "${changed_file_args[@]}" >"$stdout"
        status=$?
    fi
    set -e

    if [ "$status" -ne "$expected_status" ]; then
        echo "expected classify status $expected_status for $name, got $status" >&2
        return 1
    fi

    jq -e . "$record" >/dev/null
    jq -e . "$stdout" >/dev/null
    printf '%s\n' "$record"
}

run_classify_with_changed_args() {
    local name="$1"
    shift
    local expected_status="${1-0}"
    shift
    local record="$tmp_dir/$name.record.json"
    local stdout="$tmp_dir/$name.stdout"
    local status

    set +e
    RUN_RECORD_PATH="$record" \
        bash script/harness/gate.sh --classify-only "$@" >"$stdout"
    status=$?
    set -e

    if [ "$status" -ne "$expected_status" ]; then
        echo "expected classify status $expected_status for $name, got $status" >&2
        return 1
    fi

    jq -e . "$record" >/dev/null
    jq -e . "$stdout" >/dev/null
    printf '%s\n' "$record"
}

run_classify_from_subdir() {
    local name="$1"
    local subdir="$2"
    local expected_status="${3-0}"
    shift 3
    local record="$tmp_dir/$name.record.json"
    local stdout="$tmp_dir/$name.stdout"
    local stderr="$tmp_dir/$name.stderr"
    local status

    set +e
    (
        cd "$subdir"
        RUN_RECORD_PATH="$record" \
            bash ../script/harness/gate.sh --classify-only --changed-files "$@" >"$stdout" 2>"$stderr"
    )
    status=$?
    set -e

    if [ "$status" -ne "$expected_status" ]; then
        echo "expected classify status $expected_status for $name, got $status" >&2
        return 1
    fi

    jq -e . "$record" >/dev/null
    jq -e . "$stdout" >/dev/null
    printf '%s\n' "$record"
}

run_classify_capture() {
    local name="$1"
    shift
    local stdout="$tmp_dir/$name.stdout"
    local stderr="$tmp_dir/$name.stderr"
    local status

    set +e
    bash script/harness/gate.sh --classify-only --changed-files "$@" >"$stdout" 2>"$stderr"
    status=$?
    set -e

    printf '%s\n%s\n%s\n' "$status" "$stdout" "$stderr"
}

run_default_classify_in_scratch_repo() {
    local name="$1"
    local dirty_file="$2"
    local repo="$tmp_dir/$name.repo"
    local record="$tmp_dir/$name.record.json"

    mkdir -p "$repo/script/harness" "$repo/.harness"
    cp script/harness/gate.sh "$repo/script/harness/gate.sh"
    cp -R .harness/policy.json .harness/schemas "$repo/.harness/"
    # The policy's test_mapping references repo test files, and the gate validates those
    # references against the working tree; seed stub files so the scratch repo satisfies it.
    while IFS= read -r mapped_test; do
        mkdir -p "$repo/$(dirname "$mapped_test")"
        : >"$repo/$mapped_test"
    done < <(jq -r '.test_mapping | .. | strings | select(startswith("test/"))' .harness/policy.json | sort -u)
    (
        cd "$repo"
        git init -q
        git config user.email test@example.invalid
        git config user.name "Harness Test"
        git add .
        git commit -q -m baseline
        mkdir -p "$(dirname "$dirty_file")"
        printf 'dirty\n' >"$dirty_file"
        RUN_RECORD_PATH="$record" bash script/harness/gate.sh --classify-only >/dev/null
    )

    jq -e . "$record" >/dev/null
    printf '%s\n' "$record"
}

write_changed_files() {
    local name="$1"
    shift
    local file="$tmp_dir/$name.changed"
    printf '%s\n' "$@" >"$file"
    printf '%s\n' "$file"
}

write_diff() {
    local name="$1"
    local path="$2"
    local removed="$3"
    local added="$4"
    local file="$tmp_dir/$name.diff"
    cat >"$file" <<EOF
diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -1 +1 @@
-$removed
+$added
EOF
    printf '%s\n' "$file"
}

write_multi_diff() {
    local name="$1"
    shift
    local file="$tmp_dir/$name.diff"
    : >"$file"

    while [ "$#" -gt 0 ]; do
        local path="$1"
        local removed="$2"
        local added="$3"
        shift 3
        cat >>"$file" <<EOF
diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -1 +1 @@
-$removed
+$added
EOF
    done

    printf '%s\n' "$file"
}

run_ci_entrypoint_capture() {
    local name="$1"
    local event_name="$2"
    local fake_bin="$tmp_dir/$name.bin"
    local capture_dir="$tmp_dir/$name.capture"
    local runner_temp="$tmp_dir/$name.runner"

    mkdir -p "$fake_bin" "$capture_dir" "$runner_temp"

    cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

capture_dir="${HARNESS_CAPTURE_DIR:?}"
printf '%s\n' "$@" >"$capture_dir/argv"
printf '%s' "${CHANGE_CLASSIFIER_DIFF_FILE:-}" >"$capture_dir/diff_path"

capture_changed_files=0
: >"$capture_dir/changed_files_args"
for arg in "$@"; do
    if [ "$capture_changed_files" -eq 1 ]; then
        if [[ "$arg" == --* ]]; then
            break
        fi
        printf '%s\n' "$arg" >>"$capture_dir/changed_files_args"
        continue
    fi
    if [ "$arg" = "--changed-files" ]; then
        capture_changed_files=1
    fi
done

if [ -n "${CHANGE_CLASSIFIER_DIFF_FILE:-}" ] && [ -f "${CHANGE_CLASSIFIER_DIFF_FILE}" ]; then
    cp "${CHANGE_CLASSIFIER_DIFF_FILE}" "$capture_dir/diff_file"
fi
EOF
    chmod +x "$fake_bin/npm"

    HARNESS_CAPTURE_DIR="$capture_dir" \
    HARNESS_EVENT_NAME="$event_name" \
    RUNNER_TEMP="$runner_temp" \
    PATH="$fake_bin:$PATH" \
    bash script/harness/ci-gate-entrypoint.sh

    printf '%s\n' "$capture_dir"
}

assert_ci_workflow_expressions() {
    python3 - <<'PY'
import yaml

with open(".github/workflows/test.yml", "r", encoding="utf-8") as fh:
    workflow = yaml.safe_load(fh)

steps = workflow["jobs"]["check"]["steps"]
run_gate_step = next(step for step in steps if step.get("name") == "Run gate:ci")
env = run_gate_step["env"]

assert env["HARNESS_EVENT_NAME"] == "${{ github.event_name }}"
assert env["RUN_RECORD_PATH"] == "${{ runner.temp }}/outstakev2-gate-ci.json"
assert run_gate_step["run"] == "bash script/harness/ci-gate-entrypoint.sh"
PY
}

run_gate_full_capture() {
    local name="$1"
    local changed_files="$2"
    local diff_file="$3"
    local fake_bin="$tmp_dir/$name.bin"
    local stdout="$tmp_dir/$name.stdout"
    local record="$tmp_dir/$name.record.json"
    local status
    local -a changed_file_args=()

    mapfile -t changed_file_args <"$changed_files"

    mkdir -p "$fake_bin"

    cat >"$fake_bin/forge" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/forge"

    cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/npm"

    cat >"$fake_bin/slither" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "success": true,
  "results": {
    "detectors": [
      {
        "check": "reentrancy-eth",
        "impact": "High",
        "confidence": "High",
        "first_markdown_element": "src/assets/base/OutrunERC20Upgradeable.sol#L1-L4",
        "description": "New detector finding"
      }
    ]
  }
}
JSON
exit 0
EOF
    chmod +x "$fake_bin/slither"

    set +e
    PATH="$fake_bin:$PATH" RUN_RECORD_PATH="$record" CHANGE_CLASSIFIER_DIFF_FILE="$diff_file" \
        bash script/harness/gate.sh --profile full --changed-files "${changed_file_args[@]}" >"$stdout" 2>&1
    status=$?
    set -e

    printf '%s\n%s\n%s\n' "$status" "$record" "$stdout"
}

run_gate_fast_capture() {
    local name="$1"
    local changed_files="$2"
    local diff_file="$3"
    local fake_bin="$tmp_dir/$name.bin"
    local stdout="$tmp_dir/$name.stdout"
    local record="$tmp_dir/$name.record.json"
    local capture_dir="$tmp_dir/$name.capture"
    local status
    local -a changed_file_args=()

    mapfile -t changed_file_args <"$changed_files"

    mkdir -p "$fake_bin" "$capture_dir"

    cat >"$fake_bin/forge" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

capture_dir="${HARNESS_CAPTURE_DIR:?}"
printf '%s\n' "$*" >>"$capture_dir/forge_calls"

if [ "${1-}" = "fmt" ] || [ "${1-}" = "build" ]; then
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--list" ] && [ "${3-}" = "--match-path" ]; then
    case "${4-}" in
        test/upgradeable/OracleSetterUpgradeable.t.sol)
            cat <<'LIST'
test/upgradeable/OracleSetterUpgradeable.t.sol
  OracleSetterUpgradeableTest
    testGetters_ReturnStoredAddresses
LIST
            ;;
        test/support/TokenHelper.t.sol)
            cat <<'LIST'
test/support/TokenHelper.t.sol
  TokenHelperTest
    testAction_MarksCallerAndTransfersToRecipient
LIST
            ;;
        *)
            echo "unexpected list path: ${4-}" >&2
            exit 1
            ;;
    esac
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--list" ] && [ "${3-}" = "--match-contract" ]; then
    cat <<'LIST'
test/upgradeable/OracleSetterUpgradeable.t.sol
  OracleSetterUpgradeableTest
    testGetters_ReturnStoredAddresses
test/support/TokenHelper.t.sol
  TokenHelperTest
    testAction_MarksCallerAndTransfersToRecipient
LIST
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--match-contract" ]; then
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--match-path" ]; then
    exit 0
fi

echo "unexpected forge invocation: $*" >&2
exit 1
EOF
    chmod +x "$fake_bin/forge"

    cat >"$fake_bin/npx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/npx"

    set +e
    PATH="$fake_bin:$PATH" HARNESS_CAPTURE_DIR="$capture_dir" RUN_RECORD_PATH="$record" CHANGE_CLASSIFIER_DIFF_FILE="$diff_file" \
        bash script/harness/gate.sh --profile fast --changed-files "${changed_file_args[@]}" >"$stdout" 2>&1
    status=$?
    set -e

    printf '%s\n%s\n%s\n%s\n' "$status" "$record" "$stdout" "$capture_dir"
}

assert_no_removed_fields() {
    local record="$1"
    jq -e '
      (has("risk_tier") | not) and
      (has("high-risk") | not) and
      (has("high_risk_paths") | not) and
      (has("high_risk_tokens") | not) and
      (has("high_risk_reasons") | not) and
      (has("review_matrix") | not) and
      (has("review_triggers") | not) and
      (has("doc_writer_roles") | not) and
      (has("selected_writer_roles") | not) and
      (has("writer_role") | not) and
      (has("selected_review_roles") | not) and
      (has("selected_review_roles_source") | not) and
      (has("pre_code_review_roles") | not) and
      (has("pre_code_review_roles_source") | not) and
      (has("post_code_review_roles") | not) and
      (has("post_code_review_roles_source") | not)
    ' "$record" >/dev/null
}

docs_changed="$(write_changed_files docs docs/foo.md)"
docs_record="$(run_classify docs "$docs_changed")"
jq -e '
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == [] and
  .code_review_roles == []
' "$docs_record" >/dev/null
assert_no_removed_fields "$docs_record"

readme_changed="$(write_changed_files readme README.md)"
readme_record="$(run_classify readme "$readme_changed")"
jq -e '
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated" and
  .candidate_orchestration_profile == "direct" and
  .requires_doc_editorial_attestation == true and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == [] and
  .code_review_roles == []
' "$readme_record" >/dev/null
assert_no_removed_fields "$readme_record"

spec_changed="$(write_changed_files spec docs/superpowers/specs/foo.md)"
spec_record="$(run_classify spec "$spec_changed")"
jq -e '
  .orchestration_profile == "delegated" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == [] and
  .code_review_roles == [] and
  .requires_spec_authorization_evidence == true
' "$spec_record" >/dev/null
assert_no_removed_fields "$spec_record"

test_changed="$(write_changed_files testsol test/upgradeable/OutrunOFTUpgradeable.t.sol)"
test_diff="$(write_diff testsol test/upgradeable/OutrunOFTUpgradeable.t.sol 'uint256 oldValue = 1;' 'uint256 newValue = 2;')"
test_record="$(run_classify testsol "$test_changed" "$test_diff")"
jq -e '
  .change_class == "test-semantic" and
  .orchestration_profile == "direct-review" and
  .harness_writer_roles == [] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  .code_review_roles == ["logic-reviewer"]
' "$test_record" >/dev/null
assert_no_removed_fields "$test_record"

src_changed="$(write_changed_files srcsol src/assets/base/OutrunERC20Upgradeable.sol)"
src_diff="$(write_diff srcsol src/assets/base/OutrunERC20Upgradeable.sol 'uint256 oldAmount = amount;' 'uint256 newAmount = amount + 1;')"
src_record="$(run_classify srcsol "$src_changed" "$src_diff")"
jq -e '
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"]
' "$src_record" >/dev/null
assert_no_removed_fields "$src_record"

planned_src_record="$(run_classify_with_changed_args plannedsrc 0 --planned-files src/assets/base/OutrunERC20Upgradeable.sol)"
jq -e '
  .changed_files == ["src/assets/base/OutrunERC20Upgradeable.sol"] and
  .file_input_mode == "planned-files" and
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  (.residual_risks[] | select(.rule_id == "planned-solidity-classification"))
' "$planned_src_record" >/dev/null
assert_no_removed_fields "$planned_src_record"

planned_test_record="$(run_classify_with_changed_args plannedtest 0 --planned-files test/upgradeable/OutrunOFTUpgradeable.t.sol)"
jq -e '
  .changed_files == ["test/upgradeable/OutrunOFTUpgradeable.t.sol"] and
  .file_input_mode == "planned-files" and
  .change_class == "test-semantic" and
  .orchestration_profile == "direct-review" and
  .harness_writer_roles == [] and
  .code_writer_roles == ["solidity-implementer"] and
  .code_review_roles == ["logic-reviewer"] and
  (.residual_risks[] | select(.rule_id == "planned-solidity-classification"))
' "$planned_test_record" >/dev/null
assert_no_removed_fields "$planned_test_record"

mixed_changed="$(write_changed_files mixed src/assets/base/OutrunERC20Upgradeable.sol docs/spec/position/state-machines.md)"
mixed_record="$(run_classify mixed "$mixed_changed" "$src_diff")"
jq -e '
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  .requires_spec_authorization_evidence == true
' "$mixed_record" >/dev/null
assert_no_removed_fields "$mixed_record"

mixed_non_spec_changed="$(write_changed_files mixednonspec src/assets/base/OutrunERC20Upgradeable.sol docs/TRACEABILITY.md)"
mixed_non_spec_record="$(run_classify mixednonspec "$mixed_non_spec_changed" "$src_diff")"
jq -e '
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  .requires_spec_authorization_evidence == false
' "$mixed_non_spec_record" >/dev/null
assert_no_removed_fields "$mixed_non_spec_record"

single_direct_record="$(run_classify_with_changed_args singledirect 0 --changed-files script/harness/gate.sh)"
jq -e '
  .changed_files == ["script/harness/gate.sh"] and
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated" and
  .final_verdict == "classified"
' "$single_direct_record" >/dev/null
assert_no_removed_fields "$single_direct_record"

multi_direct_record="$(run_classify_with_changed_args multidirect 0 --changed-files script/harness/gate.sh script/harness/test-orchestration.sh)"
jq -e '
  .changed_files == ["script/harness/gate.sh", "script/harness/test-orchestration.sh"] and
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated"
' "$multi_direct_record" >/dev/null
assert_no_removed_fields "$multi_direct_record"

subdir_repo_relative_record="$(run_classify_from_subdir subdirrepo docs 1 src/assets/base/OutrunERC20Upgradeable.sol)"
jq -e '
  .changed_files == ["src/assets/base/OutrunERC20Upgradeable.sol"] and
  .surfaces == "solidity_prod" and
  .change_class == "blocked" and
  .final_verdict == "blocked" and
  .semantic_prod_files == [] and
  .non_semantic_prod_files == [] and
  (.blocking_findings[] | select(.rule_id == "semantic-classification-requires-diff"))
' "$subdir_repo_relative_record" >/dev/null
assert_no_removed_fields "$subdir_repo_relative_record"

absolute_inside_record="$(run_classify_with_changed_args absinside 1 --changed-files "$repo_root/src/assets/base/OutrunERC20Upgradeable.sol")"
jq -e '
  .changed_files == ["src/assets/base/OutrunERC20Upgradeable.sol"] and
  .surfaces == "solidity_prod" and
  .change_class == "blocked" and
  .semantic_prod_files == [] and
  .non_semantic_prod_files == [] and
  .final_verdict == "blocked"
' "$absolute_inside_record" >/dev/null
assert_no_removed_fields "$absolute_inside_record"

mapfile -t absolute_outside_run < <(run_classify_capture absoutside /tmp/outstake-outside.sol)
[ "${absolute_outside_run[0]}" -eq 1 ]
grep -Fqx "[gate] ERROR: --changed-files path must be inside repo root: /tmp/outstake-outside.sol" "${absolute_outside_run[2]}"

pure_unknown_changed="$(write_changed_files pureunknown notes.txt)"
pure_unknown_record="$(run_classify pureunknown "$pure_unknown_changed" "" 1)"
jq -e '
  .change_class == "no-op" and
  .orchestration_profile == "blocked" and
  .final_verdict == "blocked" and
  (.blocking_findings[] | select(.rule_id == "unclassified-paths"))
' "$pure_unknown_record" >/dev/null
assert_no_removed_fields "$pure_unknown_record"

default_record="$(run_default_classify_in_scratch_repo default README.md)"
jq -e '
  .changed_files == ["README.md"] and
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated"
' "$default_record" >/dev/null
assert_no_removed_fields "$default_record"

assert_ci_workflow_expressions

zero_base_capture="$(run_ci_entrypoint_capture zero-base workflow_dispatch)"
grep -qx -- "run" "$zero_base_capture/argv"
grep -qx -- "gate:ci" "$zero_base_capture/argv"
grep -qx -- "--" "$zero_base_capture/argv"
grep -qx -- "--all" "$zero_base_capture/argv"
if grep -qx -- "--changed-files" "$zero_base_capture/argv"; then
    echo "zero-base CI path should not pass --changed-files" >&2
    exit 1
fi
[ ! -s "$zero_base_capture/diff_path" ]
[ ! -s "$zero_base_capture/changed_files_args" ]

diff_capture="$(run_ci_entrypoint_capture diff-based push)"
grep -qx -- "run" "$diff_capture/argv"
grep -qx -- "gate:ci" "$diff_capture/argv"
grep -qx -- "--" "$diff_capture/argv"
grep -qx -- "--all" "$diff_capture/argv"
if grep -qx -- "--changed-files" "$diff_capture/argv"; then
    echo "CI entrypoint must not pass --changed-files (it always runs --all)" >&2
    exit 1
fi
[ ! -s "$diff_capture/diff_path" ]

slither_changed="$(write_changed_files slither src/assets/base/OutrunERC20Upgradeable.sol)"
slither_diff="$(write_diff slither src/assets/base/OutrunERC20Upgradeable.sol 'uint256 oldAmount = amount;' 'uint256 newAmount = amount + 1;')"
mapfile -t slither_run < <(run_gate_full_capture slither "$slither_changed" "$slither_diff")
slither_status="${slither_run[0]}"
slither_record="${slither_run[1]}"
slither_stdout="${slither_run[2]}"
[ "$slither_status" -ne 0 ]
jq -e '
  .final_verdict == "fail" and
  .command_results.slither_when_required.status == "failed" and
  (.blocking_findings[] | select(.rule_id == "slither_when_required"))
' "$slither_record" >/dev/null
grep -Fq "new slither finding" "$slither_stdout"

if grep -Fq "review roles are the union" docs/TRACEABILITY.md; then
    echo "TRACEABILITY still contains old review union wording" >&2
    exit 1
fi
if grep -Fq "writer may be \`mixed\`" docs/TRACEABILITY.md; then
    echo "TRACEABILITY still contains old mixed writer wording" >&2
    exit 1
fi
grep -Fq 'The gate reports phase fields for `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.' docs/TRACEABILITY.md

contract_changed="$(write_changed_files contract-fast test/upgradeable/OracleSetterUpgradeable.t.sol test/support/TokenHelper.t.sol)"
contract_diff="$(write_multi_diff contract-fast \
  test/upgradeable/OracleSetterUpgradeable.t.sol 'function oldSplitter() external {}' 'function newSplitter() external {}' \
  test/support/TokenHelper.t.sol 'function oldTokenHelper() external {}' 'function newTokenHelper() external {}')"
mapfile -t contract_fast_run < <(run_gate_fast_capture contract-fast "$contract_changed" "$contract_diff")
contract_fast_status="${contract_fast_run[0]}"
contract_fast_record="${contract_fast_run[1]}"
contract_fast_stdout="${contract_fast_run[2]}"
contract_fast_capture="${contract_fast_run[3]}"
[ "$contract_fast_status" -eq 0 ]
jq -e '
  .final_verdict == "pass" and
  .command_results.targeted_tests.status == "passed" and
  (.commands_run.targeted_tests.command | contains("--match-contract"))
' "$contract_fast_record" >/dev/null
grep -Fqx "test --list --match-path test/upgradeable/OracleSetterUpgradeable.t.sol" "$contract_fast_capture/forge_calls"
grep -Fqx "test --list --match-path test/support/TokenHelper.t.sol" "$contract_fast_capture/forge_calls"
grep -Eq '^test --match-contract ' "$contract_fast_capture/forge_calls"
if grep -Eq '^test --match-path ' "$contract_fast_capture/forge_calls"; then
    echo "fast targeted tests should execute through --match-contract when validation succeeds" >&2
    exit 1
fi

echo "orchestration tests passed"
