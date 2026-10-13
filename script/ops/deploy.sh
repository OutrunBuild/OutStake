#!/usr/bin/env bash
# OutStake batch deploy wrapper.
#
#   ./deploy.sh <chain> <batch> [extra forge args...]
#
#   chain: bsc_testnet | sepolia | base_sepolia | arbitrum_sepolia
#   batch: deployer check uasset router psm usr polend mocks mocksy mocksp   (see OutstakeScript.run())
#
# The optimizer tier is derived from the batch and applied via [profile.t<N>] in
# foundry.toml (FOUNDRY_PROFILE) — deploy, rebuild and verification share one settings source.
# (uAsset impl exceeds EIP-170 above 15000; the OutrunDeployer creation bytecode is
# byte-identical across 15000..100000, so its CREATE2 address never moves with the tier.)
# DEPLOYMENT_NONCE (default 1) passes through as the deployment generation.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

if [ $# -lt 2 ]; then
    echo "usage: $0 <bsc_testnet|sepolia|base_sepolia|arbitrum_sepolia> <deployer|check|uasset|router|psm|usr|polend|mocks|mocksy|mocksp> [extra forge args...]" >&2
    exit 1
fi
chain="$1"; batch="$2"; shift 2

case "$batch" in
    uasset) optimizer_runs=15000 ;;
    deployer|check|router|psm|usr|polend|mocks|mocksy|mocksp) optimizer_runs=100000 ;;
    *) echo "unknown batch: $batch" >&2; exit 1 ;;
esac
profile="t$optimizer_runs"

case "$chain" in
    bsc_testnet) chain_flags=(--priority-gas-price 100000000 --with-gas-price 100000000 --slow) ;;
    sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 1100000) ;;
    base_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 6000000) ;;
    arbitrum_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 100000000) ;;
    *) echo "unknown chain: $chain" >&2; exit 1 ;;
esac

source "$repo_root/.env"
export BATCH="$batch"

# Verification is ON by default (VERIFY=0 disables): forge --verify failures are non-fatal,
# and deploy-time verification shares this invocation's compile settings.
# OFF by default: forge --verify exits non-zero on any verify failure (would abort the
# run post-salts); post-hoc verification belongs to verify-contracts.sh
verify_flags=()
if [ "${VERIFY:-0}" = "1" ]; then verify_flags=(--verify); fi

# Freeze the exact compile + broadcast for post-hoc verification (VERIFY-ROOT-CAUSE-RESOLVED.md):
# build-info holds the exact solc input (tier included); snapshots survive later source edits.
# Retention: only the LATEST generation's snapshots are kept on disk (never in git).
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
FOUNDRY_PROFILE="$profile" forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url "$chain" \
    "${chain_flags[@]}" \
    --broadcast --ffi -vvvv \
    "${verify_flags[@]}" \
    "$@" || forge_batch_rc=$?
# Snapshot even on failure: consumed CREATE3 salts demand the evidence survives the run.
# check is assert-only (deploys nothing, runs on EVERY deploy-all invocation) — snapshot
# would be pure noise written once per run.
if [ "$batch" != "check" ]; then
    snapshot "$chain" "$batch" "$optimizer_runs"
fi
exit "$forge_batch_rc"
