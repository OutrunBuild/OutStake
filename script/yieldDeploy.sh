source ../.env

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url sepolia \
#     --priority-gas-price 20000000 --with-gas-price 2000000000 \
#     --optimize --optimizer-runs 20000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url bsc_testnet \
    --with-gas-price 5000000000 \
    --optimize --optimizer-runs 20000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify \
    --slow

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url base_sepolia \
#     --with-gas-price 100000000 \
#     --optimize --optimizer-runs 20000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url arbitrum_sepolia \
#     --with-gas-price 300000000 \
#     --optimize --optimizer-runs 20000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify
    
# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url avalanche_fuji \
#     --priority-gas-price 1 --with-gas-price 2 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url polygon_amoy \
#     --priority-gas-price 140000000000 --with-gas-price 150000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url sonic_blaze \
#     --with-gas-price 1100000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1200000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url scroll_sepolia \
#     --priority-gas-price 100 --with-gas-price 50000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url monad_testnet \
#     --with-gas-price 52000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify --verifier sourcify \
#     --verifier-url 'https://sourcify-api-monad.blockvision.org'

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url bera_sepolia \
#     --with-gas-price 6000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verifier-url 'https://api.routescan.io/v2/network/testnet/evm/80069/etherscan'
#     --etherscan-api-key "verifyContract"

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url linea_sepolia \
#     --priority-gas-price 49000000 --with-gas-price 50000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url optimistic_sepolia \
#     --with-gas-price 1100000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script YieldDeployScript.s.sol:YieldDeployScript --rpc-url zksync_sepolia \
#     --with-gas-price 25000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify


