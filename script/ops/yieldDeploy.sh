#!/usr/bin/env bash
# Yield (SY/SP) batch deploy wrapper.
#
#   ./yieldDeploy.sh <chain> <batch> [extra forge args...]
#
#   chain: bsc_testnet | sepolia | base_sepolia | arbitrum_sepolia
#   batch: wsteth susde slisbnb ausdc all   (support functions self-skip on non-matching chains)
#
# Optimizer tier 100000 — all SY/SP contracts fit the code size limit there. SP/SY are
# single-chain direct-new deployments (no CREATE3 / cross-chain same-address requirement).
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

case "$chain" in
    bsc_testnet) chain_flags=(--priority-gas-price 100000000 --with-gas-price 600000000 --slow) ;;
    sepolia) chain_flags=(--priority-gas-price 20000000 --with-gas-price 2000000000) ;;
    base_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 100000000) ;;
    arbitrum_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 100000000) ;;
    *) echo "unknown chain: $chain" >&2; exit 1 ;;
esac

source "$repo_root/.env"
export BATCH="$batch"

# Verification is opt-in (VERIFY=1), same rationale as deploy.sh: a post-broadcast etherscan
# hiccup must not abort an orchestrated run after the salts are already consumed.
verify_flags=()
if [ "${VERIFY:-0}" = "1" ]; then verify_flags=(--verify); fi

cd "$repo_root"
forge script script/deploy/YieldDeployScript.s.sol:YieldDeployScript --rpc-url "$chain" \
    --optimize --optimizer-runs "$optimizer_runs" \
    --via-ir \
    "${chain_flags[@]}" \
    --broadcast --ffi -vvvv \
    "${verify_flags[@]}" \
    "$@"
