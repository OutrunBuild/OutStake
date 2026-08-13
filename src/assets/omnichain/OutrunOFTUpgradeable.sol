// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// LayerZero Omnichain Fungible Token (OFT) base.
// Combines ERC20 with cross-chain transfer capability.
// Users can send tokens to other blockchains via LayerZero's messaging protocol.

// solhint-disable-next-line import-path-check
import {OFTCoreUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";
import {OFTFeeDetail, OFTLimit, OFTReceipt, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {OutrunERC20PausableUpgradeable} from "../base/OutrunERC20PausableUpgradeable.sol";
import {OutrunERC20Upgradeable} from "../base/OutrunERC20Upgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "./OutrunRateLimiterUpgradeable.sol";

abstract contract OutrunOFTUpgradeable is
    OutrunERC20PausableUpgradeable,
    OFTCoreUpgradeable,
    OutrunRateLimiterUpgradeable
{
    uint8 private immutable _localDecimals;

    error InvalidLayerZeroEndpoint();
    error InvalidWindowSeconds();

    event OutboundRateLimitSet(uint32 indexed eid, uint192 limit, uint64 window);
    event OutboundRateLimitRemoved(uint32 indexed eid);

    constructor(uint8 localDecimals_, address lzEndpoint) OFTCoreUpgradeable(localDecimals_, lzEndpoint) {
        if (lzEndpoint == address(0)) revert InvalidLayerZeroEndpoint();
        _localDecimals = localDecimals_;
        _disableInitializers();
    }

    /// @notice Initializes the OFT with ERC20, rate limiter, and OFT core.
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param decimals_ Token decimals
    /// @param owner_ Initial owner address
    // solhint-disable-next-line func-name-mixedcase
    function __OutrunOFT_init(string memory name_, string memory symbol_, uint8 decimals_, address owner_)
        internal
        onlyInitializing
    {
        __OutrunERC20Pausable_init(name_, symbol_, decimals_, owner_);
        __OutrunRateLimiter_init();
        __OFTCore_init(owner_);
    }

    /// @notice Returns the OFT token address. The OFT IS its own token.
    /// @return address(this)
    function token() public view returns (address) {
        return address(this);
    }

    /// @notice OFT transfers do not require ERC20 allowance approval.
    /// @return false — transfers are handled natively by the OFT protocol
    function approvalRequired() external pure virtual returns (bool) {
        return false;
    }

    /// @notice Returns the local decimal count for this OFT on this chain.
    /// @return Local decimals
    function localDecimals() public view returns (uint8) {
        return _localDecimals;
    }

    /// @notice Returns the rate-limited amount that can currently be sent to a destination.
    /// @param dstEid Destination endpoint ID
    /// @return currentAmountInFlight Tokens currently in-flight to the destination
    /// @return amountCanBeSent Remaining tokens that can be sent (rate limit remaining)
    function getAmountCanBeSent(uint32 dstEid)
        public
        view
        virtual
        override
        returns (uint256 currentAmountInFlight, uint256 amountCanBeSent)
    {
        RateLimit memory rl = rateLimits(dstEid);
        if (rl.window == 0) return (0, _maxOFTAmountLD());
        return _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
    }

    /// @notice Sets a transfer rate limit for a destination chain. Owner-only.
    /// @param dstEid Destination endpoint ID
    /// @param limit Maximum amount that can be in-flight at once
    /// @param window Time window (in seconds) over which the limit fully refills
    function setOutboundRateLimit(uint32 dstEid, uint192 limit, uint64 window) external onlyOwner {
        if (window == 0) revert InvalidWindowSeconds();
        RateLimitConfig[] memory configs = new RateLimitConfig[](1);
        configs[0] = RateLimitConfig({dstEid: dstEid, limit: limit, window: window});
        _setRateLimits(configs);
        emit OutboundRateLimitSet(dstEid, limit, window);
    }

    /// @notice Removes the outbound rate limit for a destination chain. Owner-only.
    /// @param dstEid Destination endpoint ID
    function removeOutboundRateLimit(uint32 dstEid) external onlyOwner {
        _deleteRateLimit(dstEid);
        emit OutboundRateLimitRemoved(dstEid);
    }

    /// @notice Returns rate-limited quote info for a send operation, including max amount and fees.
    /// @param _sendParam Parameters for the send operation (destination, amounts, etc.)
    /// @return oftLimit Min and max amounts that can be sent
    /// @return oftFeeDetails Fee breakdown (empty — no OFT fees)
    /// @return oftReceipt Expected amounts to be sent and received
    function quoteOFT(SendParam calldata _sendParam)
        external
        view
        virtual
        override
        returns (OFTLimit memory oftLimit, OFTFeeDetail[] memory oftFeeDetails, OFTReceipt memory oftReceipt)
    {
        uint256 maxAmountLD = _removeDust(_maxQuoteAmountLD(_sendParam.dstEid));
        oftLimit = OFTLimit({minAmountLD: 0, maxAmountLD: maxAmountLD});
        oftFeeDetails = new OFTFeeDetail[](0);
        (uint256 amountSentLD, uint256 amountReceivedLD) =
            _debitView(_sendParam.amountLD, _sendParam.minAmountLD, _sendParam.dstEid);
        oftReceipt = OFTReceipt({amountSentLD: amountSentLD, amountReceivedLD: amountReceivedLD});
    }

    /// @notice Outbound transfer: computes amounts, applies rate limit outflow, then burns tokens from sender.
    /// @param _from Sender address
    /// @param _amountLD Amount to send in local decimals
    /// @param _minAmountLD Minimum amount to send in local decimals (slippage protection)
    /// @param _dstEid Destination endpoint ID
    /// @return amountSentLD Actual amount sent in local decimals
    /// @return amountReceivedLD Expected amount received in local decimals
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        _outflow(_dstEid, amountSentLD);
        // Outbound transfer: (1) compute amounts, (2) apply rate limit outflow,
        // (3) burn tokens from sender. Must respect pause state.
        // _amountLD means "amount in local decimals".
        _update(_from, address(0), amountSentLD);
    }

    /// @notice Inbound transfer: mints tokens to the receiver, bypassing pause for cross-chain safety.
    /// @dev Uses direct parent _update to bypass pause — cross-chain delivery must not revert during pause.
    /// @param _to Receiver address (sends to 0xdead if address(0))
    /// @param _amountLD Amount to receive in local decimals
    /// @return amountReceivedLD Amount received in local decimals
    function _credit(address _to, uint256 _amountLD, uint32)
        internal
        virtual
        override
        returns (uint256 amountReceivedLD)
    {
        // Inbound transfer: mints tokens to receiver.
        // Uses direct parent _update to bypass pause — cross-chain delivery
        // must not revert during pause, otherwise tokens would be permanently lost.
        // Sends to dead address if receiver is zero.
        if (_to == address(0)) _to = address(0xdead);
        OutrunERC20Upgradeable._update(address(0), _to, _amountLD);
        return _amountLD;
    }

    /// @notice Returns the maximum quoted amount for a destination, capped by the rate limit.
    /// @param dstEid Destination endpoint ID
    /// @return Max amount that can be quoted (uint64 max * decimalConversionRate, or rate-limited)
    // slither-disable-next-line timestamp
    function _maxQuoteAmountLD(uint32 dstEid) internal view returns (uint256) {
        uint256 maxAmountLD = _maxOFTAmountLD();
        RateLimit memory rl = rateLimits(dstEid);
        if (rl.window == 0) return maxAmountLD;
        (, uint256 amountCanBeSent) = _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
        return amountCanBeSent < maxAmountLD ? amountCanBeSent : maxAmountLD;
    }

    /// @notice Returns the absolute maximum OFT transfer amount: uint64 max scaled by decimal conversion rate.
    /// @dev LayerZero encodes the transfer amount on the wire as a uint64 in Shared Decimals (SD)
    ///      (see OFTMsgCodec); _toSD reverts past type(uint64).max. Converting that SD ceiling to
    ///      Local Decimals (LD) gives type(uint64).max * decimalConversionRate.
    /// @return Maximum transferable amount in local decimals
    function _maxOFTAmountLD() internal view returns (uint256) {
        return uint256(type(uint64).max) * decimalConversionRate;
    }

    function _localDecimalsForValidation() internal view returns (uint8) {
        return _localDecimals;
    }
}
