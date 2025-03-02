source ../.env

forge script OutstakeScript.s.sol:OutstakeScript --rpc-url bsc_testnet \
    --with-gas-price 3000000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

forge script OutstakeScript.s.sol:OutstakeScript --rpc-url base_sepolia \
    --with-gas-price 100000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

forge script OutstakeScript.s.sol:OutstakeScript --rpc-url blast_sepolia \
    --priority-gas-price 300 --with-gas-price 1200000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

forge script OutstakeScript.s.sol:OutstakeScript --rpc-url scroll_sepolia \
    --priority-gas-price 100 --with-gas-price 60000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify
