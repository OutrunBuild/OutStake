#!/usr/bin/env bash
# OutStake batch deploy wrapper.
#
#   ./deploy.sh <chain> <batch> [extra forge args...]
#
#   chain: bsc_testnet | sepolia | base_sepolia | arbitrum_sepolia
#   batch: deployer check uasset router psm usr polend mocks mocksy mocksp   (see OutstakeScript.run())
#
# The optimizer tier is derived from the batch (uAsset impl exceeds EIP-170 above 15000; the
# OutrunDeployer creation bytecode is byte-identical across 15000..100000, so its CREATE2
# address never moves with the tier). DEPLOYMENT_NONCE (default 1) passes through from the
# environment as the deployment generation.
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

case "$chain" in
    bsc_testnet) chain_flags=(--priority-gas-price 100000000 --with-gas-price 100000000 --slow) ;;
    sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 1100000) ;;
    base_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 6000000) ;;
    arbitrum_sepolia) chain_flags=(--priority-gas-price 1000000 --with-gas-price 100000000) ;;
    *) echo "unknown chain: $chain" >&2; exit 1 ;;
esac

source "$repo_root/.env"
export BATCH="$batch"

# Verification is opt-in (VERIFY=1): a post-broadcast etherscan hiccup must not abort an
# orchestrated run after the CREATE3 salts are already consumed and before pins are backfilled.
verify_flags=()
if [ "${VERIFY:-0}" = "1" ]; then verify_flags=(--verify); fi

cd "$repo_root"
forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url "$chain" \
    --optimize --optimizer-runs "$optimizer_runs" \
    --via-ir \
    "${chain_flags[@]}" \
    --broadcast --ffi -vvvv \
    "${verify_flags[@]}" \
    "$@"
