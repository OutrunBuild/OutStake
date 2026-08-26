script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

# 所有链必须使用同一 optimizer-runs：OutrunDeployer 的 CREATE2 地址依赖 initcode，
# 任一链编译参数不同都会导致同址部署失败（见 docs/deployment.md）。
optimizer_runs=20000

source "$repo_root/.env"
cd "$repo_root"

forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url bsc_testnet \
    --with-gas-price 100000000 \
    --optimize --optimizer-runs "$optimizer_runs" \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify \
    --slow

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url sepolia \
#     --priority-gas-price 500000000 --with-gas-price 1500000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url base_sepolia \
#     --with-gas-price 100000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

