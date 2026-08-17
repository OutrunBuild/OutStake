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

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url arbitrum_sepolia \
#     --with-gas-price 300000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url avalanche_fuji \
#     --priority-gas-price 1 --with-gas-price 2 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url polygon_amoy \
#     --priority-gas-price 55000000000 --with-gas-price 60000000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url sonic_testnet \
#     --with-gas-price 1100000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1200000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url scroll_sepolia \
#     --priority-gas-price 100 --with-gas-price 50000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url monad_testnet \
#     --with-gas-price 52000000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify --verifier sourcify \
#     --verifier-url 'https://sourcify-api-monad.blockvision.org'

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url bera_sepolia \
#     --with-gas-price 6000000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verifier-url 'https://api.routescan.io/v2/network/testnet/evm/80069/etherscan'
#     --etherscan-api-key "verifyContract"

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url linea_sepolia \
#     --priority-gas-price 49000000 --with-gas-price 50000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url optimistic_sepolia \
#     --with-gas-price 1100000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script script/deploy/OutstakeScript.s.sol:OutstakeScript --rpc-url zksync_sepolia \
#     --with-gas-price 25000000 \
#     --optimize --optimizer-runs "$optimizer_runs" \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

