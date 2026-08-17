#!/usr/bin/env bash
set -euo pipefail

profile="fast"
all_mode=0
classify_only=0
quiet=0
log_level="info"
output_format="auto"

declare -a cleanup_paths=()
declare -a changed_files_args=()
declare -a planned_files_args=()

usage() {
    cat >&2 <<'EOF'
Usage: bash ./script/harness/gate.sh [--profile fast|full|ci] [--changed-files <path> [<path> ...]] [--planned-files <path> [<path> ...]] [--all] [--classify-only] [--quiet] [--log-level error|warn|info|debug] [--output text|json]
EOF
}

die() {
    echo "[gate] ERROR: $*" >&2
    exit 1
}

resolved_output_format() {
    if [ "$output_format" != "auto" ]; then
        printf '%s' "$output_format"
        return
    fi

    if [ "$classify_only" -eq 1 ]; then
        printf 'json'
    else
        printf 'text'
    fi
}

emit_gate_summary() {
    local verdict="$1"
    local class="$2"
    local orchestration="$3"
    local dispatch="$4"

    printf '[gate] profile=%s verdict=%s change_class=%s orchestration_profile=%s dispatch=%s\n' \
        "$profile" "$verdict" "$class" "$orchestration" "$dispatch"
}

emit_blocking_findings() {
    local record_json="$1"

    jq -r '.blocking_findings[]? | "[gate] ERROR: " + (.summary // "blocking finding")' <<<"$record_json"
}

emit_text_record() {
    local record_json="$1"
    local verdict="$2"
    local class="$3"
    local orchestration="$4"
    local dispatch="$5"

    if [ "$quiet" -eq 1 ] && [ "$verdict" != "fail" ] && [ "$verdict" != "blocked" ]; then
        return
    fi

    case "$log_level" in
        debug)
            emit_gate_summary "$verdict" "$class" "$orchestration" "$dispatch"
            printf '%s\n' "$record_json"
            ;;
        info)
            emit_gate_summary "$verdict" "$class" "$orchestration" "$dispatch"
            if [ "$verdict" = "fail" ] || [ "$verdict" = "blocked" ]; then
                emit_blocking_findings "$record_json"
            fi
            ;;
        warn|error)
            if [ "$verdict" = "fail" ] || [ "$verdict" = "blocked" ]; then
                emit_gate_summary "$verdict" "$class" "$orchestration" "$dispatch"
                emit_blocking_findings "$record_json"
            fi
            ;;
        *)
            die "unsupported log level: $log_level"
            ;;
    esac
}

emit_gate_record() {
    local record_json="$1"
    local verdict="$2"
    local class="$3"
    local orchestration="$4"
    local dispatch="$5"
    local format

    format="$(resolved_output_format)"

    case "$format" in
        json)
            printf '%s\n' "$record_json"
            ;;
        text)
            emit_text_record "$record_json" "$verdict" "$class" "$orchestration" "$dispatch"
            ;;
        *)
            die "unsupported output format: $format"
            ;;
    esac
}

register_cleanup() {
    cleanup_paths+=("$1")
}

cleanup() {
    local path
    for path in "${cleanup_paths[@]}"; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        rm -f "$path"
    done
}

trap cleanup EXIT

json_array_from_values() {
    if [ "$#" -eq 0 ]; then
        printf '[]'
        return
    fi
    jq -cn '$ARGS.positional' --args "$@"
}

shell_join() {
    local arg
    local -a escaped=()
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        escaped+=("$arg")
    done
    local joined="${escaped[*]:-}"
    printf '%s' "$joined"
}

append_unique() {
    local array_name="$1"
    local value="$2"
    local -n array_ref="$array_name"
    local existing

    for existing in "${array_ref[@]}"; do
        if [ "$existing" = "$value" ]; then
            return
        fi
    done

    array_ref+=("$value")
}

array_contains() {
    local needle="$1"
    shift
    local value

    for value in "$@"; do
        if [ "$value" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

build_dispatch_summary() {
    local harness_writer_roles_json="$1"
    local code_writer_roles_json="$2"
    local code_review_roles_json="$3"

    jq -r -n \
        --argjson harness "$harness_writer_roles_json" \
        --argjson code "$code_writer_roles_json" \
        --argjson review "$code_review_roles_json" '
        def fmt_roles($items):
          if ($items | length) == 0 then "none" else ($items | join(",")) end;
        "harness=" + fmt_roles($harness)
        + ";code=" + fmt_roles($code)
        + ";code-review=" + fmt_roles($review)
        '
}

list_worktree_changed_files() {
    {
        git diff --cached --name-only --diff-filter=ACMRD
        git diff --name-only --diff-filter=ACMRD
        git ls-files --others --exclude-standard
    } | awk '{ sub(/\r$/, ""); if ($0 != "") print $0 }' | awk '!seen[$0]++'
}

normalize_changed_files_repo_path() {
    local value="$1"
    local absolute_repo_root="${repo_root%/}"

    case "$value" in
        /*)
            case "$value" in
                "$absolute_repo_root"/*)
                    printf '%s\n' "${value#"$absolute_repo_root"/}"
                    return
                    ;;
                "$absolute_repo_root")
                    printf '.\n'
                    return
                    ;;
                *)
                    die "--changed-files path must be inside repo root: $value"
                    ;;
            esac
            ;;
        *)
            printf '%s\n' "${value#./}"
            ;;
    esac
}

load_changed_files_from_args() {
    local raw_value
    local normalized_value
    changed_files=()
    for raw_value in "${changed_files_args[@]}"; do
        normalized_value="$(normalize_changed_files_repo_path "$raw_value")"
        append_unique changed_files "$normalized_value"
    done
}

load_planned_files_from_args() {
    local raw_value
    local normalized_value
    changed_files=()
    for raw_value in "${planned_files_args[@]}"; do
        normalized_value="$(normalize_changed_files_repo_path "$raw_value")"
        append_unique changed_files "$normalized_value"
    done
}



append_finding() {
    local target_name="$1"
    local source_role="$2"
    local summary="$3"
    local rule_id="${4-}"
    local severity="${5-}"
    local current="${!target_name}"
    local updated

    updated="$(jq -cn \
        --argjson existing "$current" \
        --arg source_role "$source_role" \
        --arg summary "$summary" \
        --arg rule_id "$rule_id" \
        --arg severity "$severity" \
        '
        $existing + [
          ({
            source_role: $source_role,
            summary: $summary
          }
          + (if $rule_id == "" then {} else {rule_id: $rule_id} end)
          + (if $severity == "" then {} else {severity: $severity} end))
        ]
        ')"

    printf -v "$target_name" '%s' "$updated"
}

record_command_run() {
    local id="$1"
    local command_string="$2"
    local reason="$3"
    local scope_json="$4"

    COMMAND_STRING["$id"]="$command_string"
    COMMAND_REASON["$id"]="$reason"
    COMMAND_SCOPE_JSON["$id"]="$scope_json"
}

record_command_result() {
    local id="$1"
    local status="$2"
    local exit_code="${3-}"
    local summary="${4-}"
    local attribution="${5-}"

    RESULT_STATUS["$id"]="$status"
    if [ -n "$exit_code" ]; then
        RESULT_EXIT_CODE["$id"]="$exit_code"
    else
        unset "RESULT_EXIT_CODE[$id]" 2>/dev/null || true
    fi

    if [ -n "$summary" ]; then
        RESULT_SUMMARY["$id"]="$summary"
    else
        unset "RESULT_SUMMARY[$id]" 2>/dev/null || true
    fi

    if [ -n "$attribution" ]; then
        RESULT_ATTRIBUTION["$id"]="$attribution"
    else
        unset "RESULT_ATTRIBUTION[$id]" 2>/dev/null || true
    fi
}

record_not_applicable_command() {
    local id="$1"
    local command_string="$2"
    local reason="$3"
    local scope_json="$4"
    local summary="$5"

    record_command_run "$id" "$command_string" "$reason" "$scope_json"
    record_command_result "$id" "passed" "" "$summary" "verifier"
}

record_blocked_command() {
    local id="$1"
    local command_string="$2"
    local reason="$3"
    local scope_json="$4"
    local summary="$5"

    record_command_run "$id" "$command_string" "$reason" "$scope_json"
    record_command_result "$id" "failed" "" "$summary" "main-orchestrator"
}

filter_command_output() {
    local output_file="$1"
    local exit_code="$2"
    local format

    format="$(resolved_output_format)"
    if [ "$format" = "json" ]; then
        return
    fi

    if [ "$exit_code" -eq 0 ]; then
        if [ "$quiet" -eq 1 ]; then
            return
        fi
        case "$log_level" in
            debug)
                cat "$output_file"
                ;;
            info|warn)
                grep -i -E '(warning|warn |error|✖)' "$output_file" || true
                ;;
            error)
                grep -i -E '(error|✖)' "$output_file" || true
                ;;
        esac
    else
        case "$log_level" in
            debug)
                cat "$output_file"
                ;;
            info|warn|error)
                # Strip Foundry successful-run noise: [PASS] lines, the
                # per-suite "Suite result: ok." summary, and the
                # "Compiler run successful!" compile banner. Keep everything else,
                # including "Suite result: FAILED.", the final "Ran N suites
                # in Xs:" line and its indented "tests passed, M failed"
                # summary, revert traces, and tool diagnostics (npm/solhint).
                # On the failure path everything remaining IS error-oriented
                # (diffs, source locations, traces, gas mismatches), so all log
                # levels share this behavior; the docs/VERIFICATION.md log_level
                # contract still holds on the success path above. Narrowing to
                # keyword anchors was found to silently drop real failure context
                # (forge fmt diffs, `--> file:line` pointers, traces). The old
                # `Ran ... 0 failed` branch was dead code: forge puts the count
                # on a separate indented line.
                local successful_output_regex='^[[:space:]]*\[PASS[^]]*\]|^[[:space:]]*Suite result: ok\.|^[[:space:]]*Compiler run successful!'
                grep -avE "$successful_output_regex" "$output_file" || true
                ;;
        esac
    fi
}

run_single_command() {
    local id="$1"
    local reason="$2"
    local scope_json="$3"
    shift 3
    local -a cmd=("$@")
    # Route any forge subcommand through forge-serialize.sh so gate's builds/tests
    # join the same flock queue as agent-invoked builds — prevents concurrent
    # compiles (gate vs agent, or multiple gates) from corrupting the via_ir
    # incremental cache. Only forge is intercepted; bash/npx/node/solhint untouched.
    if [ "${cmd[0]}" = "forge" ]; then
        cmd=("bash" "$repo_root/script/harness/forge-serialize.sh" "${cmd[@]:1}")
    fi
    local command_string
    local exit_code

    command_string="$(shell_join "${cmd[@]}")"
    record_command_run "$id" "$command_string" "$reason" "$scope_json"

    local _output_file
    _output_file="$(mktemp "$repo_root/.harness/tmp/cmd.XXXXXX")"
    register_cleanup "$_output_file"

    set +e
    "${cmd[@]}" > "$_output_file" 2>&1
    exit_code=$?
    set -e

    filter_command_output "$_output_file" "$exit_code"

    if [ "$exit_code" -eq 0 ]; then
        record_command_result "$id" "passed" "$exit_code" "command succeeded" "verifier"
        return
    fi

    verification_failed=1
    record_command_result "$id" "failed" "$exit_code" "command failed" "verifier"
    append_finding blocking_findings_json "verifier" "verification command failed: $id" "$id" "error"
}

run_looped_command() {
    local id="$1"
    local reason="$2"
    local scope_json="$3"
    local subcommand_label="$4"
    shift 4
    local -a scope=("$@")
    local -a command_strings=()
    local item
    local exit_code=0
    local loop_exit

    local _loop_output_file
    _loop_output_file="$(mktemp "$repo_root/.harness/tmp/cmd.XXXXXX")"
    register_cleanup "$_loop_output_file"

    for item in "${scope[@]}"; do
        local command_string
        command_string="$(shell_join "$subcommand_label" "$item")"
        command_strings+=("$command_string")
        set +e
        case "$id" in
            targeted_tests)
                bash "$repo_root/script/harness/forge-serialize.sh" test --match-path "$item" >> "$_loop_output_file" 2>&1
                ;;
            node_syntax_changed_js)
                node --check "$item" >> "$_loop_output_file" 2>&1
                ;;
            *)
                die "unsupported looped command id: $id"
                ;;
        esac
        loop_exit=$?
        set -e

        if [ "$loop_exit" -ne 0 ] && [ "$exit_code" -eq 0 ]; then
            exit_code="$loop_exit"
        fi
    done

    record_command_run "$id" "$(IFS=' && '; printf '%s' "${command_strings[*]}")" "$reason" "$scope_json"

    if [ "$exit_code" -eq 0 ]; then
        filter_command_output "$_loop_output_file" "0"
        record_command_result "$id" "passed" "0" "all scoped commands succeeded" "verifier"
        return
    fi

    filter_command_output "$_loop_output_file" "$exit_code"
    verification_failed=1
    record_command_result "$id" "failed" "$exit_code" "at least one scoped command failed" "verifier"
    append_finding blocking_findings_json "verifier" "verification command failed: $id" "$id" "error"
}

extract_test_contracts_from_list_output() {
    local output_file="$1"
    awk '
        /^  [^[:space:]].*$/ && $0 !~ /^    / {
            line = $0
            sub(/^  /, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
        }
    ' "$output_file"
}

escape_extended_regex() {
    sed -e 's/[][(){}.^$*+?|\\-]/\\&/g'
}

build_targeted_test_contract_regex() {
    local regex_var_name="$1"
    local contracts_var_name="$2"
    shift 2
    local -n regex_ref="$regex_var_name"
    local -n contracts_ref="$contracts_var_name"
    local test_file
    local list_exit_code
    local list_output_file
    local contract_name
    local escaped_name
    local -a escaped_contracts=()

    regex_ref=""
    contracts_ref=()

    for test_file in "$@"; do
        list_output_file="$(mktemp "$repo_root/.harness/tmp/cmd.XXXXXX")"
        register_cleanup "$list_output_file"

        set +e
        forge test --list --match-path "$test_file" > "$list_output_file" 2>&1
        list_exit_code=$?
        set -e

        if [ "$list_exit_code" -ne 0 ]; then
            return 1
        fi

        while IFS= read -r contract_name; do
            [ -n "$contract_name" ] || continue
            append_unique contracts_ref "$contract_name"
        done < <(extract_test_contracts_from_list_output "$list_output_file")
    done

    if [ "${#contracts_ref[@]}" -eq 0 ]; then
        return 1
    fi

    for contract_name in "${contracts_ref[@]}"; do
        escaped_name="$(printf '%s' "$contract_name" | escape_extended_regex)"
        escaped_contracts+=("$escaped_name")
    done

    regex_ref="^("
    regex_ref+="${escaped_contracts[0]}"
    for escaped_name in "${escaped_contracts[@]:1}"; do
        regex_ref+="|$escaped_name"
    done
    regex_ref+=")$"
}

validate_targeted_test_contract_regex() {
    local regex="$1"
    shift
    local expected_contracts=("$@")
    local validation_output_file
    local validation_exit_code
    local actual_sorted
    local expected_sorted

    validation_output_file="$(mktemp "$repo_root/.harness/tmp/cmd.XXXXXX")"
    register_cleanup "$validation_output_file"

    set +e
    forge test --list --match-contract "$regex" > "$validation_output_file" 2>&1
    validation_exit_code=$?
    set -e

    if [ "$validation_exit_code" -ne 0 ]; then
        return 1
    fi

    actual_sorted="$(
        extract_test_contracts_from_list_output "$validation_output_file" | awk '!seen[$0]++' | sort
    )"
    expected_sorted="$(
        printf '%s\n' "${expected_contracts[@]}" | awk '!seen[$0]++' | sort
    )"

    [ "$actual_sorted" = "$expected_sorted" ]
}

run_targeted_tests_command() {
    local id="$1"
    local reason="$2"
    local scope_json="$3"
    shift 3
    local -a scope=("$@")
    local targeted_regex
    local -a targeted_contracts=()

    if build_targeted_test_contract_regex targeted_regex targeted_contracts "${scope[@]}" \
        && validate_targeted_test_contract_regex "$targeted_regex" "${targeted_contracts[@]}"; then
        run_single_command "$id" "$reason" "$scope_json" forge test --match-contract "$targeted_regex"
        return
    fi

    run_looped_command "$id" "$reason" "$scope_json" "bash $repo_root/script/harness/forge-serialize.sh test --match-path" "${scope[@]}"
}

slither_baseline_path() {
    printf '%s/script/harness/slither-baseline.json' "$repo_root"
}

run_slither_with_baseline() {
    local id="$1"
    local reason="$2"
    local scope_json="$3"
    local slither_filter_paths="$4"
    local slither_exclude_detectors="$5"
    local baseline_file
    local command_string
    local raw_output_file
    local new_findings_file
    local exit_code
    local baseline_count
    local current_count
    local new_count
    local summary

    baseline_file="$(slither_baseline_path)"
    command_string="slither src --filter-paths $(shell_join "$slither_filter_paths") --exclude-dependencies --exclude $(shell_join "$slither_exclude_detectors") --json - --json-types detectors --fail-none --disable-color"
    record_command_run "$id" "$command_string | compare against $(shell_join "$baseline_file")" "$reason" "$scope_json"

    if [ ! -f "$baseline_file" ]; then
        verification_failed=1
        record_command_result "$id" "failed" "1" "slither baseline file is missing" "verifier"
        append_finding blocking_findings_json "verifier" "verification command failed: $id" "$id" "error"
        echo "[gate] ERROR: slither baseline file is missing: $baseline_file" >&2
        return
    fi

    if ! jq -e '.version == 1 and (.findings | type == "array")' "$baseline_file" >/dev/null 2>&1; then
        verification_failed=1
        record_command_result "$id" "failed" "1" "slither baseline file is invalid" "verifier"
        append_finding blocking_findings_json "verifier" "verification command failed: $id" "$id" "error"
        echo "[gate] ERROR: slither baseline file is invalid: $baseline_file" >&2
        return
    fi

    raw_output_file="$(mktemp "$repo_root/.harness/tmp/slither.XXXXXX.json")"
    new_findings_file="$(mktemp "$repo_root/.harness/tmp/slither-new.XXXXXX.json")"
    register_cleanup "$raw_output_file"
    register_cleanup "$new_findings_file"

    set +e
    slither src \
        --filter-paths "$slither_filter_paths" \
        --exclude-dependencies \
        --exclude "$slither_exclude_detectors" \
        --json - \
        --json-types detectors \
        --fail-none \
        --disable-color > "$raw_output_file" 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        filter_command_output "$raw_output_file" "$exit_code"
        verification_failed=1
        record_command_result "$id" "failed" "$exit_code" "slither command failed" "verifier"
        append_finding blocking_findings_json "verifier" "verification command failed: $id" "$id" "error"
        return
    fi

    if ! jq -e '.success == true and (.results.detectors | type == "array")' "$raw_output_file" >/dev/null 2>&1; then
        head -n 40 "$raw_output_file"
        verification_failed=1
        record_command_result "$id" "failed" "1" "slither did not emit valid detector JSON" "verifier"
        append_finding blocking_findings_json "verifier" "verification command failed: $id" "$id" "error"
        return
    fi

    jq --slurpfile baseline "$baseline_file" '
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
        ($baseline[0].findings | map(.key // .id) | unique) as $baseline_keys
        | [
            .results.detectors[]
            | normalize
            | select((.key // .id) as $key | $key == "" or ($baseline_keys | index($key) | not))
        ]
    ' "$raw_output_file" > "$new_findings_file"

    baseline_count="$(jq '.findings | length' "$baseline_file")"
    current_count="$(jq '.results.detectors | length' "$raw_output_file")"
    new_count="$(jq 'length' "$new_findings_file")"

    if [ "$new_count" -eq 0 ]; then
        summary="all $current_count slither findings matched baseline ($baseline_count entries)"
        if [ "$(resolved_output_format)" = "text" ] && [ "$quiet" -eq 0 ] && { [ "$log_level" = "info" ] || [ "$log_level" = "debug" ]; }; then
            echo "[gate] slither baseline: $summary"
        fi
        record_command_result "$id" "passed" "0" "$summary" "verifier"
        return
    fi

    if [ "$(resolved_output_format)" = "text" ]; then
        echo "[gate] slither baseline: detected $new_count new finding(s) beyond baseline"
        jq -r '.[] | "- [\(.impact)/\(.confidence)] \(.check) \(.location) :: \(.summary)"' "$new_findings_file"
    fi
    verification_failed=1
    summary="$new_count new slither finding(s) beyond baseline"
    record_command_result "$id" "failed" "1" "$summary" "verifier"
    append_finding blocking_findings_json "verifier" "$summary" "$id" "error"
}

match_path_against_patterns() {
    local candidate="$1"
    shift
    local pattern

    for pattern in "$@"; do
        if [[ "$candidate" =~ $pattern ]]; then
            return 0
        fi
    done

    return 1
}

expand_repo_glob() {
    local pattern="$1"
    local absolute_pattern="${repo_root}/${pattern}"
    local expanded_path
    local -a matches=()

    if [[ "$pattern" != *'*'* && "$pattern" != *'?'* && "$pattern" != *'['* ]]; then
        if [ -f "$absolute_pattern" ]; then
            printf '%s\n' "$pattern"
        fi
        return
    fi

    while IFS= read -r expanded_path; do
        [ -f "$expanded_path" ] || continue
        expanded_path="${expanded_path#"${repo_root}/"}"
        matches+=("$expanded_path")
    done < <(compgen -G "$absolute_pattern" || true)

    if [ "${#matches[@]}" -eq 0 ]; then
        return
    fi

    printf '%s\n' "${matches[@]}"
}

resolve_harness_schema_root() {
    local candidate="${repo_root}/.harness"

    if [ -f "$candidate/schemas/policy.schema.json" ]; then
        printf '%s' "$candidate"
        return
    fi

    die "unable to locate local .harness schemas"
}

resolve_schema_path() {
    local schema_value="$1"

    case "$schema_value" in
        /*) printf '%s' "$schema_value" ;;
        *) printf '%s/%s' "$harness_schema_root" "$schema_value" ;;
    esac
}

validate_json_file_against_schema() {
    local instance_file="$1"
    local schema_file="$2"

    python3 - "$instance_file" "$schema_file" <<'PY'
import json
import pathlib
import sys
import warnings

with warnings.catch_warnings():
    warnings.filterwarnings(
        "ignore",
        category=DeprecationWarning,
        message=r"jsonschema\.RefResolver is deprecated.*",
    )
    from jsonschema import Draft202012Validator, RefResolver

instance_path = pathlib.Path(sys.argv[1]).resolve()
schema_path = pathlib.Path(sys.argv[2]).resolve()

with schema_path.open("r", encoding="utf-8") as fh:
    schema = json.load(fh)
with instance_path.open("r", encoding="utf-8") as fh:
    instance = json.load(fh)

store = {}
policy_schema_path = schema_path.parent / "policy.schema.json"
if policy_schema_path.exists():
    with policy_schema_path.open("r", encoding="utf-8") as fh:
        policy_schema = json.load(fh)
    store["policy.schema.json"] = policy_schema
    store[str(policy_schema_path)] = policy_schema
    store[policy_schema_path.as_uri()] = policy_schema
    if "$id" in policy_schema:
        store[policy_schema["$id"]] = policy_schema

resolver = RefResolver(base_uri=schema_path.as_uri(), referrer=schema, store=store)
validator = Draft202012Validator(schema, resolver=resolver)
errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))

if errors:
    for error in errors:
        path = ".".join(str(part) for part in error.path) or "<root>"
        print(f"{path}: {error.message}", file=sys.stderr)
    sys.exit(1)
PY
}

validate_test_mapping_references() {
    local policy_file="$1"
    local repo_root="$2"
    local pointer
    local test_path
    local reason
    local reference_json
    local invalid=0

    while IFS=$'\t' read -r pointer test_path; do
        [ -n "$pointer" ] || continue
        reason=""

        if [[ "$test_path" != test/*.t.sol ||
              "$test_path" == *"*"* ||
              "$test_path" == *"?"* ||
              "$test_path" == *"["* ||
              "$test_path" == *"]"* ||
              "$test_path" == *"//"* ||
              "$test_path" == *"/./"* ||
              "$test_path" == *"/../"* ]]; then
            reason="must be a concrete repository test path ending in .t.sol"
        elif [ ! -f "$repo_root/$test_path" ]; then
            reason="file does not exist"
        fi

        [ -n "$reason" ] || continue
        reference_json="$(jq -cn --arg pointer "$pointer" --arg path "$test_path" --arg reason "$reason" \
            '{pointer: $pointer, path: $path, reason: $reason}')"
        printf '[gate] ERROR: invalid test_mapping reference %s\n' "$reference_json" >&2
        invalid=1
    done < <(jq -r '
        def pointer_token: tostring | gsub("~"; "~0") | gsub("/"; "~1");
        .test_mapping
        | to_entries[]
        | .key as $mapping_key
        | .value as $mapping
        | (
            ($mapping.tests // []
             | to_entries[]
             | {pointer: ("/test_mapping/" + ($mapping_key | pointer_token) + "/tests/" + (.key | tostring)), path: .value}),
            ($mapping.rules // []
             | to_entries[]
             | .key as $rule_index
             | .value as $rule
             | ($rule.change_tests // [])
             | to_entries[]
             | {pointer: ("/test_mapping/" + ($mapping_key | pointer_token) + "/rules/" + ($rule_index | tostring) + "/change_tests/" + (.key | tostring)), path: .value}),
            ($mapping.rules // []
             | to_entries[]
             | .key as $rule_index
             | .value as $rule
             | ($rule.evidence_tests // [])
             | to_entries[]
             | {pointer: ("/test_mapping/" + ($mapping_key | pointer_token) + "/rules/" + ($rule_index | tostring) + "/evidence_tests/" + (.key | tostring)), path: .value})
          )
        | [.pointer, .path]
        | @tsv
    ' "$policy_file")

    [ "$invalid" -eq 0 ]
}

validate_test_mapping_completeness() {
    local policy_file="$1"
    local repo_root="$2"
    local test_path
    local referenced_test_paths=()
    local invalid=0

    mapfile -t referenced_test_paths < <(jq -r '
        [
            (.test_mapping | to_entries[] | .value.tests[]?),
            (.test_mapping | to_entries[] | .value.rules[]? | .change_tests[]?),
            (.test_mapping | to_entries[] | .value.rules[]? | .evidence_tests[]?),
            (.testing_gaps[]?[]? | .paths[]?)
        ]
        | unique[]
    ' "$policy_file")

    while IFS= read -r test_path; do
        [ -n "$test_path" ] || continue
        test_path="test/${test_path}"
        if ! printf '%s\n' "${referenced_test_paths[@]}" | grep -Fxq -- "$test_path"; then
            printf '[gate] ERROR: test file not covered by test_mapping or testing_gaps: %s\n' "$test_path" >&2
            invalid=1
        fi
    done < <(find "$repo_root/test" -name '*.t.sol' -printf '%P\n' | sort)

    [ "$invalid" -eq 0 ]
}

diff_covers_changed_files() {
    local diff_file="$1"
    shift

    python3 - "$diff_file" "$@" <<'PY'
import pathlib
import re
import sys

diff_path = pathlib.Path(sys.argv[1])
expected = set(sys.argv[2:])

if not expected:
    sys.exit(0)
if not diff_path.is_file():
    sys.exit(1)

covered = set()
pattern = re.compile(r"^diff --git a/(.+?) b/(.+)$")

with diff_path.open("r", encoding="utf-8", errors="replace") as fh:
    for raw_line in fh:
        match = pattern.match(raw_line.rstrip("\n"))
        if not match:
            continue
        covered.add(match.group(1))
        covered.add(match.group(2))

missing = expected - covered
sys.exit(0 if not missing else 1)
PY
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            profile="$2"
            shift 2
            ;;
        --changed-files)
            shift
            if [ "$#" -eq 0 ] || [[ "$1" == -* ]]; then
                usage
                exit 1
            fi
            while [ "$#" -gt 0 ]; do
                if [[ "$1" == -* ]]; then
                    break
                fi
                changed_files_args+=("$1")
                shift
            done
            ;;
        --planned-files)
            shift
            if [ "$#" -eq 0 ] || [[ "$1" == -* ]]; then
                usage
                exit 1
            fi
            while [ "$#" -gt 0 ]; do
                if [[ "$1" == -* ]]; then
                    break
                fi
                planned_files_args+=("$1")
                shift
            done
            ;;
        --all)
            all_mode=1
            shift
            ;;
        --classify-only)
            classify_only=1
            shift
            ;;
        --quiet)
            quiet=1
            shift
            ;;
        --log-level)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            log_level="$2"
            shift 2
            ;;
        --output)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            output_format="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

case "$profile" in
    fast|full|ci) ;;
    *)
        die "--profile must be one of: fast, full, ci"
        ;;
esac

case "$log_level" in
    error|warn|info|debug) ;;
    *)
        die "--log-level must be one of: error, warn, info, debug"
        ;;
esac

case "$output_format" in
    auto|text|json) ;;
    *)
        die "--output must be one of: text, json"
        ;;
esac

if [ "$all_mode" -eq 1 ] && { [ "${#changed_files_args[@]}" -gt 0 ] || [ "${#planned_files_args[@]}" -gt 0 ]; }; then
    die "--all cannot be combined with --changed-files or --planned-files"
fi
if [ "${#changed_files_args[@]}" -gt 0 ] && [ "${#planned_files_args[@]}" -gt 0 ]; then
    die "--changed-files and --planned-files are mutually exclusive"
fi
if [ "${#planned_files_args[@]}" -gt 0 ] && [ "$classify_only" -ne 1 ]; then
    die "--planned-files can only be used with --classify-only"
fi

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v node >/dev/null 2>&1 || die "node is required"

original_cwd="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

harness_schema_root="$(resolve_harness_schema_root)"
policy_file="$repo_root/.harness/policy.json"
[ -f "$policy_file" ] || die "missing policy file: $policy_file"
policy_schema_file="$harness_schema_root/schemas/policy.schema.json"

if ! validate_json_file_against_schema "$policy_file" "$policy_schema_file"; then
    die "policy schema validation failed"
fi
if ! validate_test_mapping_references "$policy_file" "$repo_root"; then
    die "test_mapping reference validation failed"
fi
if ! validate_test_mapping_completeness "$policy_file" "$repo_root"; then
    die "test_mapping completeness validation failed"
fi

mapfile -t solidity_prod_patterns < <(jq -r '.surfaces.solidity_prod[]' "$policy_file")
mapfile -t solidity_test_patterns < <(jq -r '.surfaces.solidity_test[]' "$policy_file")
mapfile -t harness_control_patterns < <(jq -r '.surfaces.harness_control[]' "$policy_file")

declare -a selected_surfaces=()
declare -a unmatched_files=()
declare -a solidity_prod_files=()
declare -a solidity_test_files=()
declare -a harness_control_files=()
declare -a shell_files=()
declare -a js_files=()
declare -a package_trigger_files=()
declare -a existing_solidity_files=()
declare -a existing_src_solidity_files=()
declare -a existing_src_or_script_solidity_files=()
declare -a existing_test_solidity_files=()
declare -a existing_shell_files=()
declare -a existing_js_files=()
declare -a classification_solidity_files=()

if [ "$all_mode" -eq 1 ]; then
    # --all mode: enumerate ALL repo files matching surface patterns
    while IFS= read -r -d '' file; do
        rel="${file#"${repo_root}/"}"
        if match_path_against_patterns "$rel" "${solidity_prod_patterns[@]}"; then
            append_unique solidity_prod_files "$rel"
            append_unique selected_surfaces "solidity_prod"
            append_unique existing_solidity_files "$rel"
            append_unique existing_src_or_script_solidity_files "$rel"
            if [[ "$rel" =~ ^src/.*\.sol$ ]]; then
                append_unique existing_src_solidity_files "$rel"
            fi
        fi
    done < <(find "$repo_root" -name '*.sol' -not -path '*/lib/*' -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null)

    while IFS= read -r -d '' file; do
        rel="${file#"${repo_root}/"}"
        if match_path_against_patterns "$rel" "${solidity_test_patterns[@]}"; then
            append_unique solidity_test_files "$rel"
            append_unique selected_surfaces "solidity_test"
            append_unique existing_solidity_files "$rel"
            append_unique existing_test_solidity_files "$rel"
        fi
    done < <(find "$repo_root" -name '*.sol' -not -path '*/lib/*' -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null)

    while IFS= read -r -d '' file; do
        rel="${file#"${repo_root}/"}"
        if match_path_against_patterns "$rel" "${harness_control_patterns[@]}"; then
            append_unique harness_control_files "$rel"
            append_unique selected_surfaces "harness_control"

            case "$rel" in
                *.sh|.githooks/*)
                    append_unique shell_files "$rel"
                    append_unique existing_shell_files "$rel"
                    ;;
            esac

            case "$rel" in
                *.js|*.cjs|*.mjs)
                    append_unique js_files "$rel"
                    append_unique existing_js_files "$rel"
                    ;;
            esac

            case "$rel" in
                package.json|package-lock.json|npm-shrinkwrap.json)
                    append_unique package_trigger_files "$rel"
                    ;;
            esac
        fi
    done < <(find "$repo_root" -type f -not -path '*/.git/*' -not -path '*/lib/*' -not -path '*/node_modules/*' -print0 2>/dev/null)

    mapfile -t changed_files < <(printf '%s\n' "${solidity_prod_files[@]}" "${solidity_test_files[@]}" "${harness_control_files[@]}" | awk '!seen[$0]++')
else
    if [ "${#changed_files_args[@]}" -gt 0 ]; then
        load_changed_files_from_args
    elif [ "${#planned_files_args[@]}" -gt 0 ]; then
        load_planned_files_from_args
    elif [ "$profile" = "ci" ]; then
        die "--changed-files is required when --profile ci is used"
    else
        mapfile -t changed_files < <(list_worktree_changed_files)
    fi

for changed_file in "${changed_files[@]}"; do
    matched=0

    if match_path_against_patterns "$changed_file" "${solidity_prod_patterns[@]}"; then
        append_unique solidity_prod_files "$changed_file"
        append_unique selected_surfaces "solidity_prod"
        matched=1
        if [ -f "$changed_file" ]; then
            append_unique existing_solidity_files "$changed_file"
            append_unique existing_src_or_script_solidity_files "$changed_file"
        fi
        if [[ "$changed_file" =~ ^src/.*\.sol$ ]] && [ -f "$changed_file" ]; then
            append_unique existing_src_solidity_files "$changed_file"
        fi
    fi

    if match_path_against_patterns "$changed_file" "${solidity_test_patterns[@]}"; then
        append_unique solidity_test_files "$changed_file"
        append_unique selected_surfaces "solidity_test"
        matched=1
        if [ -f "$changed_file" ]; then
            append_unique existing_solidity_files "$changed_file"
            append_unique existing_test_solidity_files "$changed_file"
        fi
    fi

    if match_path_against_patterns "$changed_file" "${harness_control_patterns[@]}"; then
        append_unique harness_control_files "$changed_file"
        append_unique selected_surfaces "harness_control"
        matched=1
    fi

    if [ "$matched" -eq 0 ]; then
        append_unique unmatched_files "$changed_file"
    fi

    case "$changed_file" in
        *.sh|.githooks/*)
            if [ -f "$changed_file" ]; then
                append_unique shell_files "$changed_file"
                append_unique existing_shell_files "$changed_file"
            fi
            ;;
    esac

    case "$changed_file" in
        *.js|*.cjs|*.mjs)
            if [ -f "$changed_file" ]; then
                append_unique js_files "$changed_file"
                append_unique existing_js_files "$changed_file"
            fi
            ;;
    esac

    case "$changed_file" in
        package.json|package-lock.json|npm-shrinkwrap.json)
            append_unique package_trigger_files "$changed_file"
            ;;
    esac
done
fi

if [ "${#changed_files[@]}" -eq 0 ]; then
    changed_files_json="$(json_array_from_values "${changed_files[@]}")"
    no_op_record_json="$(jq -cn \
        --arg repo "$(jq -r '.repo' "$policy_file")" \
        --arg mode "$([ "$classify_only" -eq 1 ] && printf 'classify-only' || printf 'verify')" \
        --arg profile "$profile" \
        --argjson changed_files "$changed_files_json" \
        '{
          repo: $repo,
          mode: $mode,
          profile: $profile,
          changed_files: $changed_files,
          surfaces: "none",
          change_class: "no-op",
          surface_sensitivity: "none",
          orchestration_profile: "no-op",
          verification_profile: $profile,
          harness_writer_roles: [],
          code_writer_roles: [],
          code_review_roles: [],
          orchestration_reasons: ["change_class=no-op", "surface_sensitivity=none"],
          blocking_findings: [],
          residual_risks: [],
          final_verdict: "no-op",
          summary: "no changed files matched any surface pattern"
        }'
    )"
    if [ -n "${RUN_RECORD_PATH:-}" ]; then
        printf '%s\n' "$no_op_record_json" >"$RUN_RECORD_PATH"
    fi
    emit_gate_record "$no_op_record_json" "no-op" "no-op" "no-op" "harness=none;code=none;code-review=none"
    if [ "$quiet" -eq 0 ] && [ "$(resolved_output_format)" = "text" ] && [ "$log_level" = "info" ]; then
        echo "[gate] no changed files matched any surface pattern"
    fi
    exit 0
fi

selected_solidity_json="$(json_array_from_values "${existing_solidity_files[@]}")"
solidity_prod_json="$(json_array_from_values "${solidity_prod_files[@]}")"
solidity_test_json="$(json_array_from_values "${solidity_test_files[@]}")"

for classification_solidity_file in "${solidity_prod_files[@]}" "${solidity_test_files[@]}"; do
    append_unique classification_solidity_files "$classification_solidity_file"
done

declare -a harness_writer_roles=()
declare -a code_writer_roles=()
for selected_surface in "${selected_surfaces[@]}"; do
    selected_surface_writer_role="$(jq -r --arg surface "$selected_surface" '.write_roles[$surface]' "$policy_file")"
    if [ "$selected_surface_writer_role" != "null" ] && [ -n "$selected_surface_writer_role" ]; then
        case "$selected_surface" in
            harness_control)
                append_unique harness_writer_roles "$selected_surface_writer_role"
                ;;
            solidity_prod|solidity_test)
                append_unique code_writer_roles "$selected_surface_writer_role"
                ;;
        esac
    fi
done

dispatch_writer_roles=("${harness_writer_roles[@]}" "${code_writer_roles[@]}")

mkdir -p "$repo_root/.harness/tmp"
patch_file="$(mktemp "$repo_root/.harness/tmp/gate.XXXXXX")"
register_cleanup "$patch_file"
classification_requires_diff=0
diff_evidence_error=0
planned_solidity_classification=0

if [ "$all_mode" -eq 1 ]; then
    : >"$patch_file"
    classification_requires_diff=0
elif [ "${#classification_solidity_files[@]}" -gt 0 ]; then
    if [ "${#planned_files_args[@]}" -gt 0 ]; then
        planned_solidity_classification=1
        : >"$patch_file"
    elif [ "${#changed_files_args[@]}" -gt 0 ]; then
        if [ -n "${CHANGE_CLASSIFIER_DIFF_FILE:-}" ]; then
            if [ ! -r "${CHANGE_CLASSIFIER_DIFF_FILE}" ]; then
                diff_evidence_error=1
            else
                cp "${CHANGE_CLASSIFIER_DIFF_FILE}" "$patch_file"
                if [ ! -s "$patch_file" ]; then
                    diff_evidence_error=1
                elif ! diff_covers_changed_files "$patch_file" "${classification_solidity_files[@]}"; then
                    diff_evidence_error=1
                fi
            fi
        elif [ -n "${GATE_DIFF_BASE:-}" ]; then
            if ! git diff --unified=0 "${GATE_DIFF_BASE}" "${GATE_DIFF_HEAD:-HEAD}" -- "${classification_solidity_files[@]}" >"$patch_file"; then
                diff_evidence_error=1
            elif [ ! -s "$patch_file" ]; then
                diff_evidence_error=1
            fi
        else
            classification_requires_diff=1
            : >"$patch_file"
        fi
    else
        if [ -n "${CHANGE_CLASSIFIER_DIFF_FILE:-}" ] && [ -r "${CHANGE_CLASSIFIER_DIFF_FILE}" ]; then
            cp "${CHANGE_CLASSIFIER_DIFF_FILE}" "$patch_file"
        else
            git diff --cached --unified=0 -- "${classification_solidity_files[@]}" >"$patch_file" || true
        fi
    fi
else
    : >"$patch_file"
fi

blocking_findings_json='[]'
residual_risks_json='[]'
hard_blocked=0
verification_failed=0

while IFS= read -r hard_block_rule; do
    [ -n "$hard_block_rule" ] || continue

    hard_block_rule_id="$(jq -r '.id' <<<"$hard_block_rule")"
    hard_block_rule_message="$(jq -r '.message' <<<"$hard_block_rule")"
    rule_matched=0

    if jq -e '.mixed_surface_sets? != null' >/dev/null <<<"$hard_block_rule"; then
        if [ "$all_mode" -eq 1 ]; then
            append_finding residual_risks_json "verifier" "$hard_block_rule_message (suppressed in --all mode)" "$hard_block_rule_id" "info"
        else
            while IFS= read -r mixed_surface_set_json; do
            [ -n "$mixed_surface_set_json" ] || continue
            mixed_surface_match=1
            mapfile -t mixed_surface_set < <(jq -r '.[]' <<<"$mixed_surface_set_json")
            for mixed_surface in "${mixed_surface_set[@]}"; do
                if ! array_contains "$mixed_surface" "${selected_surfaces[@]}"; then
                    mixed_surface_match=0
                    break
                fi
            done
            if [ "$mixed_surface_match" -eq 1 ]; then
                hard_blocked=1
                rule_matched=1
                append_finding blocking_findings_json "main-orchestrator" "$hard_block_rule_message" "$hard_block_rule_id" "error"
                break
            fi
        done < <(jq -c '.mixed_surface_sets[]?' <<<"$hard_block_rule")
        fi
    fi

    # schema forbids tokens/commands/legacy_roots on blockRule, so no combined-rule exclusion is needed here
    if jq -e '.paths? != null' >/dev/null <<<"$hard_block_rule"; then
        mapfile -t hard_block_paths < <(jq -r '.paths[]' <<<"$hard_block_rule")
        for changed_file in "${changed_files[@]}"; do
            if match_path_against_patterns "$changed_file" "${hard_block_paths[@]}"; then
                hard_blocked=1
                rule_matched=1
                append_finding blocking_findings_json "main-orchestrator" "$hard_block_rule_message: $changed_file" "$hard_block_rule_id" "error"
                break
            fi
        done
    fi

    if jq -e '.surfaces? != null' >/dev/null <<<"$hard_block_rule"; then
        mapfile -t hard_block_surfaces < <(jq -r '.surfaces[]' <<<"$hard_block_rule")
        for hard_block_surface in "${hard_block_surfaces[@]}"; do
            if array_contains "$hard_block_surface" "${selected_surfaces[@]}"; then
                hard_blocked=1
                rule_matched=1
                append_finding blocking_findings_json "main-orchestrator" "$hard_block_rule_message: $hard_block_surface" "$hard_block_rule_id" "error"
                break
            fi
        done
    fi

    if jq -e '.writer_roles? != null' >/dev/null <<<"$hard_block_rule"; then
        mapfile -t hard_block_writer_roles < <(jq -r '.writer_roles[]' <<<"$hard_block_rule")
        for hard_block_writer_role in "${hard_block_writer_roles[@]}"; do
            if array_contains "$hard_block_writer_role" "${dispatch_writer_roles[@]}"; then
                hard_blocked=1
                rule_matched=1
                append_finding blocking_findings_json "main-orchestrator" "$hard_block_rule_message: $hard_block_writer_role" "$hard_block_rule_id" "error"
                break
            fi
        done
    fi
done < <(jq -c '.hard_blocks[]' "$policy_file")

if [ "$all_mode" -eq 0 ]; then
    if [ "${#changed_files_args[@]}" -gt 0 ] && { [ "${#solidity_prod_files[@]}" -gt 0 ] || [ "${#solidity_test_files[@]}" -gt 0 ]; } && [ "$classification_requires_diff" -eq 1 ]; then
        classification_requires_diff=1
        hard_blocked=1
        append_finding blocking_findings_json "main-orchestrator" "changed-files mode for Solidity changes requires CHANGE_CLASSIFIER_DIFF_FILE or GATE_DIFF_BASE to classify non-semantic diffs deterministically" "semantic-classification-requires-diff" "error"
    fi

    if [ "${#changed_files_args[@]}" -gt 0 ] && { [ "${#solidity_prod_files[@]}" -gt 0 ] || [ "${#solidity_test_files[@]}" -gt 0 ]; } && [ "$diff_evidence_error" -eq 1 ]; then
        hard_blocked=1
        append_finding blocking_findings_json "main-orchestrator" "changed-files mode provided unusable diff evidence for Solidity classification" "semantic-classification-diff-unusable" "error"
    fi
fi

if [ "$planned_solidity_classification" -eq 1 ]; then
    append_finding residual_risks_json "main-orchestrator" "planned Solidity classification has no diff evidence; Solidity files are conservatively treated as semantic for pre-edit routing" "planned-solidity-classification" "info"
fi

classification_json="$(
    PROD_FILES_JSON="$solidity_prod_json" \
    TEST_FILES_JSON="$solidity_test_json" \
    PATCH_FILE="$patch_file" \
    ALL_MODE="$all_mode" \
    PLANNED_SOLIDITY_CLASSIFICATION="$planned_solidity_classification" \
    DIFF_EVIDENCE_MISSING="$classification_requires_diff" \
    node <<'EOF'
const fs = require('fs');

const prodFiles = JSON.parse(process.env.PROD_FILES_JSON || '[]');
const testFiles = JSON.parse(process.env.TEST_FILES_JSON || '[]');
const patchPath = process.env.PATCH_FILE || '';
const allMode = process.env.ALL_MODE === '1';
const plannedSolidityClassification = process.env.PLANNED_SOLIDITY_CLASSIFICATION === '1';
const diffEvidenceMissing = process.env.DIFF_EVIDENCE_MISSING === '1';
const patch = patchPath && fs.existsSync(patchPath) ? fs.readFileSync(patchPath, 'utf8') : '';
const trackedFiles = [...prodFiles, ...testFiles];

function isCommentLine(line) {
  return /^\/\//.test(line) || /^\/\*/.test(line) || /^\*/.test(line) || /^\*\//.test(line) || /^SPDX-License-Identifier:/i.test(line);
}

function isPunctuationOnly(line) {
  return line.replace(/[{}\[\]();,]/g, '').trim() === '';
}

function isNonSemanticLine(line) {
  const trimmed = line.trim();
  return trimmed === '' || isCommentLine(trimmed) || isPunctuationOnly(trimmed);
}

const analysis = new Map(trackedFiles.map((file) => [file, { semantic: false, semanticLines: 0 }]));

if (diffEvidenceMissing) {
  // Leave all Solidity files unclassified; the shell layer blocks the record.
} else if (allMode) {
  for (const file of trackedFiles) {
    const entry = analysis.get(file);
    entry.semantic = true;
    entry.semanticLines = 1;
  }
} else if (plannedSolidityClassification) {
  for (const file of trackedFiles) {
    const entry = analysis.get(file);
    entry.semantic = true;
    entry.semanticLines = 1;
  }
} else if (patch !== '') {
  let currentFile = null;
  for (const rawLine of patch.split(/\r?\n/)) {
    if (rawLine.startsWith('diff --git ')) {
      const match = /^diff --git a\/(.+?) b\/(.+)$/.exec(rawLine);
      currentFile = match ? match[2] : null;
      continue;
    }
    if (rawLine.startsWith('+++ b/')) {
      currentFile = rawLine.slice('+++ b/'.length).trim();
      continue;
    }
    if (!currentFile || !analysis.has(currentFile)) continue;
    if (rawLine.startsWith('+++') || rawLine.startsWith('---') || rawLine.startsWith('@@')) continue;
    if (!(rawLine.startsWith('+') || rawLine.startsWith('-'))) continue;
    const content = rawLine.slice(1).trim();
    if (isNonSemanticLine(content)) continue;
    const fileEntry = analysis.get(currentFile);
    fileEntry.semantic = true;
    fileEntry.semanticLines += 1;
  }
}

const semanticProdFiles = diffEvidenceMissing ? [] : prodFiles.filter((file) => analysis.get(file)?.semantic);
const semanticTestFiles = diffEvidenceMissing ? [] : testFiles.filter((file) => analysis.get(file)?.semantic);
const nonSemanticProdFiles = diffEvidenceMissing ? [] : prodFiles.filter((file) => !analysis.get(file)?.semantic);
const nonSemanticTestFiles = diffEvidenceMissing ? [] : testFiles.filter((file) => !analysis.get(file)?.semantic);
const semanticProdLineCount = semanticProdFiles.reduce((sum, file) => sum + (analysis.get(file)?.semanticLines || 0), 0);
const semanticTestLineCount = semanticTestFiles.reduce((sum, file) => sum + (analysis.get(file)?.semanticLines || 0), 0);

let changeClass = 'no-op';
if (diffEvidenceMissing && trackedFiles.length > 0) {
  changeClass = 'blocked';
} else if (semanticProdFiles.length > 0) {
  changeClass = 'prod-semantic';
} else if (semanticTestFiles.length > 0) {
  changeClass = 'test-semantic';
} else if (trackedFiles.length > 0) {
  changeClass = 'non-semantic';
}

process.stdout.write(JSON.stringify({
  change_class: changeClass,
  semantic_prod_files: semanticProdFiles,
  semantic_test_files: semanticTestFiles,
  non_semantic_prod_files: nonSemanticProdFiles,
  non_semantic_test_files: nonSemanticTestFiles,
  semantic_prod_line_count: semanticProdLineCount,
  semantic_test_line_count: semanticTestLineCount
}));
EOF
)"

change_class="$(jq -r '.change_class' <<<"$classification_json")"
semantic_prod_line_count="$(jq -r '.semantic_prod_line_count' <<<"$classification_json")"

while IFS= read -r testing_gap; do
    [ -n "$testing_gap" ] || continue

    testing_gap_id="$(jq -r '.id' <<<"$testing_gap")"
    testing_gap_status="$(jq -r '.status' <<<"$testing_gap")"
    testing_gap_enforcement="$(jq -r '.enforcement' <<<"$testing_gap")"
    mapfile -t testing_gap_paths < <(jq -r '.paths[]' <<<"$testing_gap")

    gap_hit=0
    for changed_file in "${changed_files[@]}"; do
        for testing_gap_path in "${testing_gap_paths[@]}"; do
            if [ "$changed_file" = "$testing_gap_path" ]; then
                gap_hit=1
                break
            fi
        done
        [ "$gap_hit" -eq 1 ] && break
    done

    [ "$gap_hit" -eq 1 ] || continue

    if [ "$testing_gap_enforcement" = "full-review" ] && [ "$change_class" != "no-op" ]; then
        append_finding residual_risks_json "verifier" "testing gap '$testing_gap_id' requires full-review minimum ($testing_gap_status)" "$testing_gap_id" "medium"
    fi

    if [ "$testing_gap_enforcement" = "residual-risk" ]; then
        append_finding residual_risks_json "verifier" "testing gap '$testing_gap_id' applies ($testing_gap_status)" "$testing_gap_id" "medium"
    fi
done < <(jq -cr '.testing_gaps | to_entries[]? | .value[]?' "$policy_file")

if [ "$change_class" = "no-op" ] && [[ " ${selected_surfaces[*]:-} " == *" harness_control "* ]]; then
    change_class="non-semantic"
fi

if [ "$all_mode" -eq 0 ] && [ "${#unmatched_files[@]}" -gt 0 ]; then
    hard_blocked=1
    append_finding blocking_findings_json "main-orchestrator" "changed files do not match configured policy surfaces: ${unmatched_files[*]}" "unclassified-paths" "error"
fi

surface_sensitivity="none"
if [[ " ${selected_surfaces[*]:-} " == *" solidity_prod "* ]]; then
    surface_sensitivity="$(jq -r '.orchestration_rules.surface_sensitivity.solidity_prod // "sensitive"' "$policy_file")"
elif [[ " ${selected_surfaces[*]:-} " == *" solidity_test "* || " ${selected_surfaces[*]:-} " == *" harness_control "* ]]; then
    surface_sensitivity="normal"
fi

structural_escalation=false
risk_analysis_summary_required=false
requires_main_risk_analysis=false
requires_doc_editorial_attestation=false
requires_spec_authorization_evidence=false
semantic_escalation_json='null'
default_orchestration_profile=""
candidate_orchestration_profile=""
coverage_required_full_ci=false
slither_required_full_ci=false
orchestration_decision_state="final"
risk_analysis_record_required=false
declare -a orchestration_reasons=()
declare -a code_review_roles=()
harness_writer_roles_json='[]'
code_writer_roles_json='[]'
code_review_roles_json='[]'
doc_round_required=false

append_unique orchestration_reasons "change_class=$change_class"
append_unique orchestration_reasons "surface_sensitivity=$surface_sensitivity"

if [ "${#changed_files[@]}" -eq 1 ] && [ "${changed_files[0]}" = "README.md" ]; then
    requires_doc_editorial_attestation=true
    candidate_orchestration_profile="direct"
fi

mapfile -t spec_paths < <(jq -r '.orchestration_rules.spec_paths[]? // empty' "$policy_file")
if [ "${#spec_paths[@]}" -gt 0 ]; then
    for changed_file in "${changed_files[@]}"; do
        if match_path_against_patterns "$changed_file" "${spec_paths[@]}"; then
            requires_spec_authorization_evidence=true
            break
        fi
    done
fi

if [ "$change_class" = "prod-semantic" ] && [ "$surface_sensitivity" = "sensitive" ]; then
    coverage_required_full_ci=true
    if [ "${#existing_src_solidity_files[@]}" -gt 0 ]; then
        slither_required_full_ci=true
    fi
fi

if [ "$change_class" = "prod-semantic" ]; then
    max_prod_files="$(jq -r '.orchestration_rules.scope_escalation.prod_solidity_max_files_before_full_review // 1' "$policy_file")"
    max_semantic_lines="$(jq -r '.orchestration_rules.scope_escalation.prod_solidity_max_semantic_lines_before_full_review // 20' "$policy_file")"
    if [ "${#solidity_prod_files[@]}" -gt "$max_prod_files" ]; then
        structural_escalation=true
        append_unique orchestration_reasons "prod_solidity_file_count>${max_prod_files}"
    fi
    if [ "$semantic_prod_line_count" -gt "$max_semantic_lines" ]; then
        structural_escalation=true
        append_unique orchestration_reasons "prod_solidity_semantic_lines>${max_semantic_lines}"
    fi
    if [[ " ${selected_surfaces[*]:-} " == *" harness_control "* ]]; then
        structural_escalation=true
        append_unique orchestration_reasons "mixed_solidity_and_harness_control"
    fi
fi


# Doc round: prod-semantic changes implicitly require a product-doc round
# (AGENTS.md step 2-4). Surface-based writer derivation only fills
# process-implementer when docs/ are in the input, so a pure-code
# prod-semantic change would otherwise emit harness_writer_roles=[] and the
# main session could silently skip the doc round. Gate-emitted here to mirror
# risk_analysis_summary_required: the main session must run the doc round
# (grep docs/ + per-doc update/no-update) before any code writer. The gate
# does NOT compute affected_docs -- that semantic judgment stays with the main
# session.
if jq -e --arg class "$change_class" \
    'has("orchestration_rules") and (.orchestration_rules.doc_round.trigger_change_class // [] | index($class)) != null' \
    "$policy_file" >/dev/null 2>&1; then
    doc_round_required=true
    doc_round_writer_role="$(jq -r '.orchestration_rules.doc_round.writer_role // "process-implementer"' "$policy_file")"
    append_unique harness_writer_roles "$doc_round_writer_role"
    append_unique orchestration_reasons "doc_round_required"
fi

if [ "${#changed_files[@]}" -eq 0 ] && [ "$hard_blocked" -eq 0 ]; then
    surface_json='"no-op"'
    change_class="no-op"
    verification_profile="none"
    orchestration_profile="no-op"
    final_verdict="no-op"
else
    if [ "${#selected_surfaces[@]}" -eq 1 ]; then
        surface_json="$(jq -cn --arg surface "${selected_surfaces[0]}" '$surface')"
    elif [ "${#selected_surfaces[@]}" -gt 1 ]; then
        surface_json="$(json_array_from_values "${selected_surfaces[@]}")"
    else
        surface_json='"no-op"'
    fi

    verification_profile="$profile"

    if [ "$hard_blocked" -eq 1 ]; then
        orchestration_profile="blocked"
    elif [ "$change_class" = "prod-semantic" ]; then
        if [ "$structural_escalation" = true ]; then
            orchestration_profile="full-review"
            risk_analysis_summary_required=true
        else
            orchestration_profile="full-review"
            default_orchestration_profile="full-review"
            candidate_orchestration_profile="direct-review"
            requires_main_risk_analysis=true
            orchestration_decision_state="pending-main-session-risk-analysis"
            risk_analysis_record_required=true
        fi
    elif [[ " ${selected_surfaces[*]:-} " == *" harness_control "* ]]; then
        orchestration_profile="delegated"
    elif [ "$change_class" = "test-semantic" ]; then
        orchestration_profile="direct-review"
    elif [ "$change_class" = "non-semantic" ]; then
        orchestration_profile="direct"
    else
        orchestration_profile="direct"
    fi

    if [ "$orchestration_profile" = "direct-review" ]; then
        if [ "$change_class" = "prod-semantic" ]; then
            mapfile -t review_roles < <(jq -r '.orchestration_review_roles["prod-semantic-risk-analysis-passed"][]? // empty' "$policy_file")
        else
            mapfile -t review_roles < <(jq -r --arg class "$change_class" '.orchestration_review_roles[$class][]? // empty' "$policy_file")
        fi
        for review_role in "${review_roles[@]}"; do
            append_unique code_review_roles "$review_role"
        done
    elif [ "$orchestration_profile" = "full-review" ] || [ "$orchestration_profile" = "full-subagent" ]; then
        mapfile -t review_roles < <(jq -r --arg class "$change_class" '.full_review_matrix[$class][]? // empty' "$policy_file")
        for review_role in "${review_roles[@]}"; do
            append_unique code_review_roles "$review_role"
        done
    fi
fi

harness_writer_roles_json="$(json_array_from_values "${harness_writer_roles[@]}")"
code_writer_roles_json="$(json_array_from_values "${code_writer_roles[@]}")"
code_review_roles_json="$(json_array_from_values "${code_review_roles[@]}")"

orchestration_reasons_json="$(json_array_from_values "${orchestration_reasons[@]}")"
dispatch_summary="$(build_dispatch_summary "$harness_writer_roles_json" "$code_writer_roles_json" "$code_review_roles_json")"
file_input_mode="worktree"
if [ "$all_mode" -eq 1 ]; then
    file_input_mode="all"
elif [ "${#planned_files_args[@]}" -gt 0 ]; then
    file_input_mode="planned-files"
elif [ "${#changed_files_args[@]}" -gt 0 ]; then
    file_input_mode="changed-files"
fi

classification_record_json="$(jq -cn \
    --arg repo "$(jq -r '.repo' "$policy_file")" \
    --arg mode "$([ "$classify_only" -eq 1 ] && printf 'classify-only' || printf 'verify')" \
    --arg profile "$profile" \
    --arg file_input_mode "$file_input_mode" \
    --argjson changed_files "$(json_array_from_values "${changed_files[@]}")" \
    --argjson surfaces "$surface_json" \
    --arg change_class "$change_class" \
    --arg surface_sensitivity "$surface_sensitivity" \
    --argjson semantic_escalation "$semantic_escalation_json" \
    --argjson structural_escalation "$structural_escalation" \
    --argjson requires_main_risk_analysis "$requires_main_risk_analysis" \
    --arg orchestration_decision_state "$orchestration_decision_state" \
    --argjson risk_analysis_record_required "$risk_analysis_record_required" \
    --argjson risk_analysis_summary_required "$risk_analysis_summary_required" \
    --argjson requires_doc_editorial_attestation "$requires_doc_editorial_attestation" \
    --argjson doc_round_required "$doc_round_required" \
    --argjson requires_spec_authorization_evidence "$requires_spec_authorization_evidence" \
    --arg orchestration_profile "$orchestration_profile" \
    --arg default_orchestration_profile "$default_orchestration_profile" \
    --arg candidate_orchestration_profile "$candidate_orchestration_profile" \
    --arg verification_profile "$verification_profile" \
    --argjson harness_writer_roles "$harness_writer_roles_json" \
    --argjson code_writer_roles "$code_writer_roles_json" \
    --argjson code_review_roles "$code_review_roles_json" \
    --argjson orchestration_reasons "$orchestration_reasons_json" \
    --argjson blocking_findings "$blocking_findings_json" \
    --argjson residual_risks "$residual_risks_json" \
    --argjson coverage_required_full_ci "$coverage_required_full_ci" \
    --argjson slither_required_full_ci "$slither_required_full_ci" \
    --argjson semantic_prod_files "$(jq -c '.semantic_prod_files' <<<"$classification_json")" \
    --argjson semantic_test_files "$(jq -c '.semantic_test_files' <<<"$classification_json")" \
    --argjson non_semantic_prod_files "$(jq -c '.non_semantic_prod_files' <<<"$classification_json")" \
    --argjson non_semantic_test_files "$(jq -c '.non_semantic_test_files' <<<"$classification_json")" \
    --argjson semantic_prod_line_count "$semantic_prod_line_count" \
    '
    {
      repo: $repo,
      mode: $mode,
      profile: $profile,
      file_input_mode: $file_input_mode,
      changed_files: $changed_files,
      surfaces: $surfaces,
      change_class: $change_class,
      surface_sensitivity: $surface_sensitivity,
      semantic_escalation: $semantic_escalation,
      structural_escalation: $structural_escalation,
      requires_main_risk_analysis: $requires_main_risk_analysis,
      orchestration_decision_state: $orchestration_decision_state,
      risk_analysis_record_required: $risk_analysis_record_required,
      risk_analysis_record: null,
      risk_analysis_summary_required: $risk_analysis_summary_required,
      doc_editorial_attestation: null,
      requires_doc_editorial_attestation: $requires_doc_editorial_attestation,
      doc_round_required: $doc_round_required,
      requires_spec_authorization_evidence: $requires_spec_authorization_evidence,
      orchestration_profile: $orchestration_profile,
      verification_profile: $verification_profile,
      harness_writer_roles: $harness_writer_roles,
      code_writer_roles: $code_writer_roles,
      code_review_roles: $code_review_roles,
      orchestration_reasons: $orchestration_reasons,
      blocking_findings: $blocking_findings,
      residual_risks: $residual_risks,
      coverage_required_full_ci: $coverage_required_full_ci,
      slither_required_full_ci: $slither_required_full_ci,
      semantic_prod_files: $semantic_prod_files,
      semantic_test_files: $semantic_test_files,
      non_semantic_prod_files: $non_semantic_prod_files,
      non_semantic_test_files: $non_semantic_test_files,
      semantic_prod_line_count: $semantic_prod_line_count,
      final_verdict: (if $orchestration_profile == "blocked" then "blocked" elif $orchestration_profile == "no-op" then "no-op" else "classified" end)
    }
    + (if $default_orchestration_profile == "" then {} else {default_orchestration_profile: $default_orchestration_profile} end)
    + (if $candidate_orchestration_profile == "" then {} else {candidate_orchestration_profile: $candidate_orchestration_profile} end)
    ')"

if [ -n "${RUN_RECORD_PATH:-}" ]; then
    printf '%s\n' "$classification_record_json" >"$RUN_RECORD_PATH"
fi

if [ "$classify_only" -eq 1 ]; then
    emit_gate_record "$classification_record_json" "$(jq -r '.final_verdict' <<<"$classification_record_json")" "$change_class" "$orchestration_profile" "$dispatch_summary"
    if [ "$orchestration_profile" = "blocked" ]; then
        exit 1
    fi
    exit 0
fi

# Verify the generated per-scope .claude/rules/*.md files have not drifted from
# their single source of truth (the nested src/script/test AGENTS.md). Gate fails
# on drift so stale generated rules are never silently relied on. Runs in the
# real verification path (not classify-only) and applies to every change.
if [ "$hard_blocked" -eq 0 ] && [ -f "$repo_root/script/harness/sync-agent-docs.sh" ]; then
    sync_check_output="$(mktemp "$repo_root/.harness/tmp/sync-docs.XXXXXX")"
    register_cleanup "$sync_check_output"
    set +e
    bash "$repo_root/script/harness/sync-agent-docs.sh" --check > "$sync_check_output" 2>&1
    sync_check_exit=$?
    set -e
    if [ "$sync_check_exit" -ne 0 ]; then
        cat "$sync_check_output" >&2
        verification_failed=1
        append_finding blocking_findings_json "verifier" "generated .claude/rules/*.md drifted from the nested AGENTS.md source (run bash script/harness/sync-agent-docs.sh)" "sync-agent-docs" "error"
    fi
fi

declare -a targeted_test_files=()
if [ "$verification_profile" = "fast" ] && [ "$hard_blocked" -eq 0 ]; then
    for changed_test_file in "${solidity_test_files[@]}"; do
        if [ -f "$changed_test_file" ]; then
            append_unique targeted_test_files "$changed_test_file"
        fi
    done

    while IFS= read -r test_mapping_rule; do
        [ -n "$test_mapping_rule" ] || continue
        mapfile -t test_mapping_rule_paths < <(jq -r '.paths[]' <<<"$test_mapping_rule")
        rule_matches_prod=0

        for prod_file in "${solidity_prod_files[@]}"; do
            if match_path_against_patterns "$prod_file" "${test_mapping_rule_paths[@]}"; then
                rule_matches_prod=1
                break
            fi
        done

        [ "$rule_matches_prod" -eq 1 ] || continue

        mapping_entry_key="$(jq -r '.key' <<<"$test_mapping_rule")"
        rule_id="$(jq -r '.id' <<<"$test_mapping_rule")"
        mapfile -t mapped_tests < <(jq -r --arg key "$mapping_entry_key" --arg rule_id "$rule_id" '
            (
              (.test_mapping[$key].tests // [])
              + (.test_mapping[$key].rules[]? | select(.id == $rule_id) | .change_tests)
              + (.test_mapping[$key].rules[]? | select(.id == $rule_id) | .evidence_tests)
            )[]' "$policy_file")
        for mapped_test in "${mapped_tests[@]}"; do
            if [ -f "$mapped_test" ]; then
                append_unique targeted_test_files "$mapped_test"
            fi
        done
    done < <(jq -c '.test_mapping | to_entries[] | . as $entry | $entry.value.rules[]? | . + {key: $entry.key}' "$policy_file")
fi

declare -A COMMAND_STRING=()
declare -A COMMAND_REASON=()
declare -A COMMAND_SCOPE_JSON=()
declare -A RESULT_STATUS=()
declare -A RESULT_EXIT_CODE=()
declare -A RESULT_SUMMARY=()
declare -A RESULT_ATTRIBUTION=()

if [ "$verification_profile" = "none" ]; then
    required_command_ids=()
    profile_required_commands_json='[]'
else
    mapfile -t required_command_ids < <(jq -r --arg profile "$verification_profile" '.verification_profiles[$profile].required_commands[]' "$policy_file")
    # Skip Solidity-only commands (forge build/test, slither, coverage) when the change touches no .sol and no build-affecting config — docs/harness-rule changes must not trigger a full via_ir build.
    if [ "${#solidity_prod_files[@]}" -eq 0 ] && [ "${#solidity_test_files[@]}" -eq 0 ]; then
        needs_build_config=0
        for _f in "${changed_files[@]}"; do
            case "$_f" in
                foundry.toml|remappings.txt|.gitmodules|lib/*) needs_build_config=1; break ;;
            esac
        done
        if [ "$needs_build_config" -eq 0 ]; then
            mapfile -t required_command_ids < <(printf '%s\n' "${required_command_ids[@]}" | grep -vE '^(forge_build|forge_test_full|targeted_tests|slither_when_required|coverage_when_required)$' || true)
        fi
    fi
    profile_required_commands_json="$(json_array_from_values "${required_command_ids[@]}")"
fi

if [ "${#changed_files[@]}" -gt 0 ]; then
    for command_id in "${required_command_ids[@]}"; do
        case "$command_id" in
            fmt_changed_solidity)
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "forge fmt --check $(shell_join "${existing_solidity_files[@]}")" "format check selected Solidity files" "$selected_solidity_json" "command blocked before execution by policy hard-block"
                elif [ "${#existing_solidity_files[@]}" -gt 0 ]; then
                    run_single_command "$command_id" "format check selected Solidity files" "$selected_solidity_json" forge fmt --check "${existing_solidity_files[@]}"
                else
                    record_not_applicable_command "$command_id" "forge fmt --check" "format check selected Solidity files" "$selected_solidity_json" "no Solidity files in scope"
                fi
                ;;
            lint_changed_solidity)
                src_scope_json="$(json_array_from_values "${existing_src_solidity_files[@]}")"
                test_scope_json="$(json_array_from_values "${existing_test_solidity_files[@]}")"
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "npx solhint --disc --noPoster -c solhint.config.js <src-solidity> && npx solhint --disc --noPoster -c solhint-test.config.js <test-solidity>" "lint selected Solidity files" "$selected_solidity_json" "command blocked before execution by policy hard-block"
                elif [ "${#existing_src_solidity_files[@]}" -gt 0 ]; then
                    lint_command="npx solhint --disc --noPoster -c solhint.config.js $(shell_join "${existing_src_solidity_files[@]}")"
                    if [ "${#existing_test_solidity_files[@]}" -gt 0 ]; then
                        lint_command="$lint_command && npx solhint --disc --noPoster -c solhint-test.config.js $(shell_join "${existing_test_solidity_files[@]}")"
                        lint_scope_json="$(jq -cn --argjson src "$src_scope_json" --argjson test "$test_scope_json" '$src + $test')"
                    else
                        lint_scope_json="$src_scope_json"
                    fi
                    run_single_command "$command_id" "lint selected Solidity files" "$lint_scope_json" bash -lc "$lint_command"
                elif [ "${#existing_src_solidity_files[@]}" -eq 0 ] && [ "${#existing_test_solidity_files[@]}" -gt 0 ]; then
                    run_single_command "$command_id" "lint selected Solidity files" "$test_scope_json" npx solhint --disc --noPoster -c solhint-test.config.js "${existing_test_solidity_files[@]}"
                else
                    record_not_applicable_command "$command_id" "npx solhint --disc --noPoster -c solhint.config.js && npx solhint --disc --noPoster -c solhint-test.config.js" "lint selected Solidity files" "$selected_solidity_json" "no Solidity files in scope"
                fi
                ;;
            forge_build)
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "forge build" "compile the repository" '[]' "command blocked before execution by policy hard-block"
                else
                    run_single_command "$command_id" "compile the repository" '[]' forge build
                fi
                ;;
            targeted_tests)
                targeted_tests_json="$(json_array_from_values "${targeted_test_files[@]}")"
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "forge test --match-path <targeted-test>" "run changed and mapped targeted tests" "$targeted_tests_json" "command blocked before execution by policy hard-block"
                elif [ "${#targeted_test_files[@]}" -gt 0 ]; then
                    run_targeted_tests_command "$command_id" "run changed and mapped targeted tests" "$targeted_tests_json" "${targeted_test_files[@]}"
                else
                    record_not_applicable_command "$command_id" "forge test --match-path" "run changed and mapped targeted tests" "$targeted_tests_json" "no targeted tests selected"
                fi
                ;;
            forge_test_full)
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "forge test -vvv" "run the full Forge test suite" '[]' "command blocked before execution by policy hard-block"
                else
                    run_single_command "$command_id" "run the full Forge test suite" '[]' forge test -vvv
                fi
                ;;
            coverage_when_required)
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "forge coverage --report summary --ir-minimum" "run coverage for semantic production Solidity changes" '[]' "command blocked before execution by policy hard-block"
                elif [ "$coverage_required_full_ci" = true ]; then
                    run_single_command "$command_id" "run coverage for semantic production Solidity changes" '[]' forge coverage --report summary --ir-minimum
                else
                    record_not_applicable_command "$command_id" "forge coverage --report summary --ir-minimum" "run coverage for semantic production Solidity changes" '[]' "coverage not required for current change class and surface sensitivity"
                fi
                ;;
            slither_when_required)
                slither_filter_paths="$(jq -r '.risk_rules.slither_filter_paths // empty' "$policy_file")"
                slither_exclude_detectors="$(jq -r '.risk_rules.slither_exclude_detectors // empty' "$policy_file")"
                src_scope_json="$(json_array_from_values "${existing_src_solidity_files[@]}")"
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "slither src --filter-paths \"$slither_filter_paths\" --exclude-dependencies --exclude \"$slither_exclude_detectors\"" "run slither for changed src Solidity production scope" "$src_scope_json" "command blocked before execution by policy hard-block"
                elif [ "$slither_required_full_ci" = true ]; then
                    run_slither_with_baseline "$command_id" "run slither for changed src Solidity production scope" "$src_scope_json" "$slither_filter_paths" "$slither_exclude_detectors"
                else
                    record_not_applicable_command "$command_id" "slither src --filter-paths \"$slither_filter_paths\" --exclude-dependencies --exclude \"$slither_exclude_detectors\"" "run slither for changed src Solidity production scope" "$src_scope_json" "no changed src Solidity files require slither"
                fi
                ;;
            bash_syntax_changed_shell)
                shell_scope_json="$(json_array_from_values "${existing_shell_files[@]}")"
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "bash -n $(shell_join "${existing_shell_files[@]}")" "check Bash syntax for changed shell files" "$shell_scope_json" "command blocked before execution by policy hard-block"
                elif [ "${#existing_shell_files[@]}" -gt 0 ]; then
                    run_single_command "$command_id" "check Bash syntax for changed shell files" "$shell_scope_json" bash -n "${existing_shell_files[@]}"
                else
                    record_not_applicable_command "$command_id" "bash -n" "check Bash syntax for changed shell files" "$shell_scope_json" "no changed shell files in scope"
                fi
                ;;
            node_syntax_changed_js)
                js_scope_json="$(json_array_from_values "${existing_js_files[@]}")"
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "node --check <changed-js-file>" "check Node syntax for changed JavaScript files" "$js_scope_json" "command blocked before execution by policy hard-block"
                elif [ "${#existing_js_files[@]}" -gt 0 ]; then
                    run_looped_command "$command_id" "check Node syntax for changed JavaScript files" "$js_scope_json" "node --check" "${existing_js_files[@]}"
                else
                    record_not_applicable_command "$command_id" "node --check" "check Node syntax for changed JavaScript files" "$js_scope_json" "no changed JavaScript files in scope"
                fi
                ;;
            npm_ci_when_package_changes)
                package_scope_json="$(json_array_from_values "${package_trigger_files[@]}")"
                if [ "$hard_blocked" -eq 1 ]; then
                    record_blocked_command "$command_id" "npm ci" "refresh npm dependencies when package manifests change" "$package_scope_json" "command blocked before execution by policy hard-block"
                elif [ "${#package_trigger_files[@]}" -gt 0 ]; then
                    run_single_command "$command_id" "refresh npm dependencies when package manifests change" "$package_scope_json" npm ci
                else
                    record_not_applicable_command "$command_id" "npm ci" "refresh npm dependencies when package manifests change" "$package_scope_json" "package manifests unchanged"
                fi
                ;;
            *)
                die "unsupported command id: $command_id"
                ;;
        esac
    done
fi

commands_run_json='{}'
command_results_json='{}'
all_command_ids=(
    fmt_changed_solidity
    lint_changed_solidity
    forge_build
    targeted_tests
    forge_test_full
    coverage_when_required
    slither_when_required
    bash_syntax_changed_shell
    node_syntax_changed_js
    npm_ci_when_package_changes
)

for command_id in "${all_command_ids[@]}"; do
    if [ -n "${COMMAND_STRING[$command_id]:-}" ]; then
        commands_run_json="$(jq -cn \
            --argjson current "$commands_run_json" \
            --arg id "$command_id" \
            --arg command "${COMMAND_STRING[$command_id]}" \
            --arg reason "${COMMAND_REASON[$command_id]:-}" \
            --argjson scope "${COMMAND_SCOPE_JSON[$command_id]:-[]}" \
            '
            $current + {
              ($id): ({
                command: $command
              }
              + (if $reason == "" then {} else {reason: $reason} end)
              + (if ($scope | length) == 0 then {} else {scope: $scope} end))
            }
            ')"
    fi

    if [ -n "${RESULT_STATUS[$command_id]:-}" ]; then
        command_results_json="$(jq -cn \
            --argjson current "$command_results_json" \
            --arg id "$command_id" \
            --arg status "${RESULT_STATUS[$command_id]}" \
            --arg exit_code "${RESULT_EXIT_CODE[$command_id]:-}" \
            --arg summary "${RESULT_SUMMARY[$command_id]:-}" \
            --arg attribution "${RESULT_ATTRIBUTION[$command_id]:-}" \
            '
            $current + {
              ($id): ({
                status: $status
              }
              + (if $exit_code == "" then {} else {exit_code: ($exit_code | tonumber)} end)
              + (if $summary == "" then {} else {summary: $summary} end)
              + (if $attribution == "" then {} else {attribution: $attribution} end))
            }
            ')"
    fi
done

if [ "${#changed_files[@]}" -eq 0 ] && [ "$hard_blocked" -eq 0 ]; then
    final_verdict="no-op"
elif [ "$hard_blocked" -eq 1 ]; then
    final_verdict="blocked"
elif [ "$verification_failed" -eq 1 ]; then
    final_verdict="fail"
else
    final_verdict="pass"
fi

final_record_json="$(jq -cn \
    --argjson base "$classification_record_json" \
    --arg final_verdict "$final_verdict" \
    --argjson blocking_findings "$blocking_findings_json" \
    --argjson profile_required_commands "$profile_required_commands_json" \
    --argjson commands_run "$commands_run_json" \
    --argjson command_results "$command_results_json" \
    '
    $base
    + {
      final_verdict: $final_verdict,
      blocking_findings: $blocking_findings,
      profile_required_commands: $profile_required_commands,
      commands_run: $commands_run,
      command_results: $command_results
    }
    ')"

if [ -n "${RUN_RECORD_PATH:-}" ]; then
    printf '%s\n' "$final_record_json" >"$RUN_RECORD_PATH"
fi

emit_gate_record "$final_record_json" "$final_verdict" "$change_class" "$orchestration_profile" "$dispatch_summary"

case "$final_verdict" in
    pass|no-op)
        exit 0
        ;;
    fail|blocked)
        exit 1
        ;;
    *)
        die "unexpected final verdict: $final_verdict"
        ;;
esac
