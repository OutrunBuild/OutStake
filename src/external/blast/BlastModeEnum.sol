// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface BlastModeEnum {
    enum YieldMode {
        AUTOMATIC,
        VOID,
        CLAIMABLE
    }

    enum GasMode {
        VOID,
        CLAIMABLE
    }
}