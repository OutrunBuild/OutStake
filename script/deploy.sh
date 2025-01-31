source ../.env

# forge script OutstakeScriptOnBlast.s.sol:OutstakeScriptOnBlast --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1200000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url bsc_testnet \
#     --with-gas-price 3000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url base_sepolia \
#     --with-gas-price 100000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

forge script MemeverseScript.s.sol:MemeverseScript --rpc-url scroll_sepolia \
    --priority-gas-price 100 --with-gas-price 50000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1200000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script OutstakeScript.s.sol:OutstakeScript --rpc-url mantle_sepolia \
#     --with-gas-price 200000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 
