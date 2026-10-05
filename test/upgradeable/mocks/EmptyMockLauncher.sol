// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @dev Minimal contract used as a placeholder launcher address for OutrunRouter tests.
///      Registration accepts any launcher address without a code check; codeless launchers
///      fail closed at runtime, where the strict consumption assertion reverts because the
///      launcher consumed none of the minted uAsset.
contract EmptyMockLauncher {}
