// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.38;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

library ProxyTestHelper {
    function deploy(address implementation, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }
}
