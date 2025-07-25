// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

interface IL2StETH {
    // Wrap L2WstETH to L2StETH
    function wrap(uint256 wrappableTokenAmount) external returns (uint256);

    // Unwrap L2StETH to L2WstETH
    function unwrap(uint256 wrapperTokenAmount) external returns (uint256);

    function getTokensByShares(uint256 sharesAmount) external view returns (uint256);

    function getSharesByTokens(uint256 tokenAmount) external view returns (uint256);
}