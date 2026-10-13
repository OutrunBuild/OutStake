#!/usr/bin/env bash
# Yield (SY/SP) batch deploy wrapper.
#
#   ./yieldDeploy.sh <chain> <batch> [extra forge args...]
#
#   chain: bsc_testnet | sepolia | base_sepolia | arbitrum_sepolia
#   batch: wsteth susde slisbnb ausdc all   (support functions self-skip on non-matching chains)
#
# Optimizer tier 100000 via [profile.t100000] (see ops/deploy.sh). SP/SY are single-chain
# direct-new deployments (no CREATE3 / cross-chain same-address requirement).
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

if [ $# -lt 2 ]; then
    echo "usage: $0 <bsc_testnet|sepolia|base_sepolia|arbitrum_sepolia> <wsteth|susde|slisbnb|ausdc|all> [extra forge args...]" >&2
    exit 1
fi
chain="$1"; batch="$2"; shift 2

case "$batch" in
    wsteth|susde|slisbnb|ausdc|all) optimizer_runs=100000 ;;
    *) echo "unknown batch: $batch" >&2; exit 1 ;;
esac
profile="t$optimizer_runs"

case "$chain" in
    bsc_testnet) chain_flags=(--priority-gas-price 100000000 --with-gas-price 600000000 --slow) ;;
    sepolia) chain_flags=(--priority-gas-price 20000000 --with-gas-price 2000000000) ;;
    base_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 100000000) ;;
    arbitrum_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 100000000) ;;
    *) echo "unknown chain: $chain" >&2; exit 1 ;;
esac

source "$repo_root/.env"
export BATCH="$batch"

# Verification is ON by default (VERIFY=0 disables): forge --verify failures are non-fatal,
# and deploy-time verification shares this invocation's compile settings.
verify_flags=()
if [ "${VERIFY:-1}" = "1" ]; then verify_flags=(--verify); fi

# Freeze the exact compile + broadcast for post-hoc verification (see ops/deploy.sh).
snapshot () { # snapshot <chain-alias> <batch> <tier>
    local id snap bi bd base n
    case "$1" in
        bsc_testnet) id=97 ;; sepolia) id=11155111 ;;
        base_sepolia) id=84532 ;; arbitrum_sepolia) id=421614 ;; *) return 0 ;;
    esac
    base="$repo_root/deployments"
    snap="$base/nonce-${DEPLOYMENT_NONCE:-1}/$1/$2"
    mkdir -p "$snap"
    bi=$(ls -t "$repo_root/out/build-info/"*.json 2>/dev/null | head -1)
    if [ -n "$bi" ]; then
        jq -c '{input: .input, bytecodes: (.output.contracts | map_values(map_values(.evm.bytecode.object // "")))}' "$bi" \
            | gzip > "$snap/compile.json.gz"
    fi
    bd=$(ls -t "$repo_root/broadcast/"*/"$id"/run-latest.json 2>/dev/null | head -1)
    if [ -n "$bd" ]; then gzip -c "$bd" > "$snap/broadcast.json.gz"; fi
    {
        echo "chain=$1 chainid=$id batch=$2 tier=$3 nonce=${DEPLOYMENT_NONCE:-1}"
        echo "git_commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "time=$(date -u +%FT%TZ)"
        if [ -n "$bi" ]; then echo "compile=compile.json.gz"; fi
        if [ -n "$bd" ]; then echo "broadcast=broadcast.json.gz"; fi
    } > "$snap/MANIFEST"
    for n in "$base"/nonce-*; do
        if [ -d "$n" ] && [ "$n" != "$base/nonce-${DEPLOYMENT_NONCE:-1}" ]; then rm -rf "$n"; fi
    done
    echo "  [snapshot] deployments/nonce-${DEPLOYMENT_NONCE:-1}/$1/$2 frozen (older nonces pruned)"
}

cd "$repo_root"
forge_batch_rc=0
FOUNDRY_PROFILE="$profile" forge script script/deploy/YieldDeployScript.s.sol:YieldDeployScript --rpc-url "$chain" \
    "${chain_flags[@]}" \
    --broadcast --ffi -vvvv \
    "${verify_flags[@]}" \
    "$@" || forge_batch_rc=$?
# Snapshot even on failure: consumed salts demand the evidence survives the run.
snapshot "$chain" "$batch" "$optimizer_runs"
exit "$forge_batch_rc"
