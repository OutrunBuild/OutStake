source ../.env

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url bsc_testnet \
#     --with-gas-price 3000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

forge script OutstakeScript.s.sol:OutstakeScript --rpc-url base_sepolia \
    --with-gas-price 100000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url arbitrum_sepolia \
#     --with-gas-price 100000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url avalanche_fuji \
#     --priority-gas-price 1000000001 --with-gas-price 1000000001 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url polygon_amoy \
#     --with-gas-price 80000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url sonic_blaze \
#     --with-gas-price 1100000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1200000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url scroll_sepolia \
#     --priority-gas-price 100 --with-gas-price 50000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url monad_testnet \
#     --with-gas-price 52000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify --verifier sourcify \
#     --verifier-url 'https://sourcify-api-monad.blockvision.org'

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url linea_sepolia \
#     --priority-gas-price 49000000 --with-gas-price 50000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url optimistic_sepolia \
#     --with-gas-price 1100000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url bera_testnet \
#     --with-gas-price 40000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url zksync_sepolia \
#     --with-gas-price 25000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify


