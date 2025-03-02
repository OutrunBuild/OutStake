source ../.env

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url bsc_testnet \
    --with-gas-price 3000000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url base_sepolia \
    --with-gas-price 100000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url arbitrum_sepolia \
    --with-gas-price 100000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url avalanche_fuji \
    --priority-gas-price 1000000001 --with-gas-price 1000000001 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url polygon_amoy \
    --with-gas-price 40000000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url sonic_blaze \
    --priority-gas-price 10 --with-gas-price 1000000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url optimistic_sepolia \
    --with-gas-price 1000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url zksync_sepolia \
    --with-gas-price 25000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url linea_sepolia \
    --with-gas-price 250000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url blast_sepolia \
    --priority-gas-price 300 --with-gas-price 1200000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url scroll_sepolia \
    --priority-gas-price 100 --with-gas-price 50000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

forge script OutrunDeployerScript.s.sol:OutrunDeployerScript --rpc-url monad_testnet \
    --with-gas-price 52000000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org'