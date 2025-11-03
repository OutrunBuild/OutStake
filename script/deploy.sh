source ../.env

forge script OutstakeScript.s.sol:OutstakeScript --rpc-url flow_testnet \
    --with-gas-price 1000000 \
    --optimize --optimizer-runs 20000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify --verifier blockscout \
    --verifier-url 'https://evm-testnet.flowscan.io/api/' \
    --slow
