// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract AutoIncrementIdUpgradeable is Initializable {
    /// @dev ERC-7201 namespace dedicated to the monotonically increasing id counter.
    /// @custom:storage-location erc7201:outrun.storage.AutoIncrementId
    struct AutoIncrementIdStorage {
        uint256 idCounter;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.AutoIncrementId")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AUTO_INCREMENT_ID_STORAGE_LOCATION =
        0xf89e69ccd0f0ce2bd1d8010b084ae175827f4bf65e4d8f8f0dcc892b62a15b00;

    function _getAutoIncrementIdStorage() private pure returns (AutoIncrementIdStorage storage $) {
        assembly {
            $.slot := AUTO_INCREMENT_ID_STORAGE_LOCATION
        }
    }

    /// @dev No initialization state: the counter slot starts at 0 and _nextId() pre-increments,
    /// so ids begin at 1. Kept as a convention placeholder in the init chain (same shape as
    /// OpenZeppelin's ContextUpgradeable) so derived contracts can chain it in initialize().
    function __AutoIncrementId_init() internal onlyInitializing {}

    /// @notice Returns the last issued id.
    /// @return The last issued id counter value.
    function idCounter() public view returns (uint256) {
        return _getAutoIncrementIdStorage().idCounter;
    }

    /// @notice Increments the counter then returns it, ids start at 1.
    /// @return The newly issued id.
    /// @dev Increments the counter before returning, so ids start at 1 and are monotonic.
    /// Uses unchecked arithmetic because overflow of a uint256 counter is practically impossible.
    function _nextId() internal returns (uint256) {
        AutoIncrementIdStorage storage $ = _getAutoIncrementIdStorage();
        unchecked {
            ++$.idCounter;
        }
        return $.idCounter;
    }
}
