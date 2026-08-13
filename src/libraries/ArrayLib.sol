// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

library ArrayLib {
    /// @notice Creates an address array with one element.
    /// @param a The element.
    /// @return res A new array of length 1.
    function create(address a) internal pure returns (address[] memory res) {
        res = new address[](1);
        res[0] = a;
    }

    /// @notice Creates an address array with two elements.
    /// @param a First element.
    /// @param b Second element.
    /// @return res A new array of length 2.
    function create(address a, address b) internal pure returns (address[] memory res) {
        res = new address[](2);
        res[0] = a;
        res[1] = b;
    }

    /// @notice Creates an address array with three elements.
    /// @param a First element.
    /// @param b Second element.
    /// @param c Third element.
    /// @return res A new array of length 3.
    function create(address a, address b, address c) internal pure returns (address[] memory res) {
        res = new address[](3);
        res[0] = a;
        res[1] = b;
        res[2] = c;
    }
}
