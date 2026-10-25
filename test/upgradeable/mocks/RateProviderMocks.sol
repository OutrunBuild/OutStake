// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice Rate provider whose conversion-rate call always reverts.
/// @dev Models the failing-call seam of the Sky SSR rate provider: the L2 sUSDS SY adapter must
///      classify any provider revert as RateProviderCallFailed instead of propagating the raw error.
contract RevertingRateProvider {
    function getConversionRate() external pure returns (uint256) {
        revert();
    }
}

/// @notice Rate provider that reports a zero conversion rate.
/// @dev Models the zero-return seam: a zero rate carries no usable pricing information, so the
///      L2 sUSDS SY adapter must treat it as a failed provider call (fail-closed).
contract ZeroRateProvider {
    function getConversionRate() external pure returns (uint256) {
        return 0;
    }
}

/// @notice PSM3 stub whose rate-provider seam reports the zero address.
/// @dev Partial mock: models IPSM3.rateProvider() only. swapExactIn/previewSwapExactIn are
///      unmodeled because the L2 sUSDS SY initializer reverts on the zero provider before any swap.
contract ZeroProviderPSM3 {
    function rateProvider() external pure returns (address) {
        return address(0);
    }
}
