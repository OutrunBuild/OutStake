// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Stand-in for the canonical deterministic-deployment CREATE2 proxy
 * @dev Mirrors the canonical proxy's RAW calldata convention (Arachnid deterministic-deployment
 * proxy, upstream yul): it has NO `deploy(bytes,bytes32)` ABI function. Calldata is
 * `salt (first 32 bytes) ++ initcode`, the forwarded value endows the created contract
 * (`create2(callvalue(), ...)`), a zero deployed address reverts with EMPTY returndata, and
 * success returns the deployed address as 20 RAW bytes (right-aligned, `return(12, 20)`).
 * In tests it is etched at `OutstakeScript`'s `CANONICAL_CREATE2_FACTORY` address — the etch
 * address, not this code's identity, determines the CREATE2 result, so deployed addresses match
 * production exactly.
 */
contract DeterministicCreate2FactoryMock {
    /// @notice Deploys calldata[32:] via CREATE2 with salt = calldata[0:32], forwarding this call's value.
    fallback() external payable {
        assembly {
            // Calldata layout of the raw convention: salt is the first 32 bytes, initcode is the rest.
            let initcodesize := sub(calldatasize(), 32)
            // Copy initcode to the 32-byte scratch buffer at 0, exactly like the upstream yul.
            calldatacopy(0, 32, initcodesize)
            let deployed := create2(callvalue(), 0, initcodesize, calldataload(0))
            // Zero deployed address => revert with EMPTY returndata (upstream `revert(0, 0)`), so a
            // failed create2 bubbles up as a bare revert with no error selector.
            if iszero(deployed) {
                revert(0, 0)
            }
            // Success => the 20 RAW address bytes, right-aligned in the scratch word (upstream
            // `mstore(0, addr)` + `return(12, 20)`) — NOT an ABI-encoded 32-byte word.
            mstore(0, deployed)
            return(12, 20)
        }
    }
}
