// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// solhint-disable-next-line import-path-check
import {OFTCoreUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";
import {OFTFeeDetail, OFTLimit, OFTReceipt, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {OutrunERC20PausableUpgradeable} from "../base/OutrunERC20PausableUpgradeable.sol";
import {OutrunERC20Upgradeable} from "../base/OutrunERC20Upgradeable.sol";
import {OutrunRateLimiterUpgradeable} from "./OutrunRateLimiterUpgradeable.sol";

/// @title LayerZero Omnichain Fungible Token (OFT) base
/// @notice Combines ERC20 with cross-chain transfer capability: users can send tokens to other blockchains via
///      LayerZero's messaging protocol.
abstract contract OutrunOFTUpgradeable is
    OutrunERC20PausableUpgradeable,
    OFTCoreUpgradeable,
    OutrunRateLimiterUpgradeable
{
    uint8 private immutable _localDecimals;

    error InvalidLayerZeroEndpoint();
    error InvalidDecimalConversionRate();
    error InvalidWindowSeconds();
    error AmountTooSmall();

    /// @notice Emitted when the outbound rate limit is set for a destination chain.
    /// @param eid Destination endpoint ID
    /// @param limit Maximum in-flight amount, in LD (local decimals), matching _debit's amountSentLD
    /// @param window Time window (in seconds) over which the limit fully refills
    event OutboundRateLimitSet(uint32 indexed eid, uint192 limit, uint64 window);
    event OutboundRateLimitRemoved(uint32 indexed eid);

    constructor(uint8 localDecimals_, address lzEndpoint) OFTCoreUpgradeable(localDecimals_, lzEndpoint) {
        if (lzEndpoint == address(0)) revert InvalidLayerZeroEndpoint();
        // Every uint64 shared-decimal amount must remain representable in local decimals.
        if (decimalConversionRate > type(uint256).max / type(uint64).max) {
            revert InvalidDecimalConversionRate();
        }
        _localDecimals = localDecimals_;
        _disableInitializers();
    }

    /// @notice Initializes the OFT with ERC20, rate limiter, and OFT core.
    /// @dev ERC20 `decimals()` derives from the constructor-frozen `localDecimals()` — decimals and OFT local
    ///      decimals are a single source of truth, so no separate decimals argument is accepted.
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param owner_ Initial owner address
    // solhint-disable-next-line func-name-mixedcase
    function __OutrunOFT_init(string memory name_, string memory symbol_, address owner_) internal onlyInitializing {
        __OutrunERC20Pausable_init(name_, symbol_, localDecimals(), owner_);
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
    /// @dev A configured rate limit can exceed the LayerZero uint64 shared-decimals wire envelope
    ///      (uint64.max * decimalConversionRate); the value is capped to that envelope and
    ///      dust-aligned so it is sendable in one message, mirroring quoteOFT via _maxQuoteAmountLD.
    /// @param dstEid Destination endpoint ID
    /// @return currentAmountInFlight Tokens currently in-flight to the destination
    /// @return amountCanBeSent Rate-limited remaining capacity, bounded by the shared-decimals wire
    ///         envelope (uint64.max * decimalConversionRate) and dust-aligned
    function getAmountCanBeSent(uint32 dstEid)
        public
        view
        virtual
        override
        returns (uint256 currentAmountInFlight, uint256 amountCanBeSent)
    {
        RateLimit memory rl = rateLimits(dstEid);
        if (rl.window == 0) return (0, _maxOFTAmountLD());
        (currentAmountInFlight, amountCanBeSent) =
            _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
        // A configured rate limit can exceed the LayerZero uint64 shared-decimals wire envelope
        // (uint64.max * decimalConversionRate); report the envelope-bounded, DCR-aligned capacity so
        // the value is sendable in one message, consistent with quoteOFT via _maxQuoteAmountLD.
        uint256 maxAmountLD = _maxOFTAmountLD();
        if (amountCanBeSent > maxAmountLD) amountCanBeSent = maxAmountLD;
        amountCanBeSent = _removeDust(amountCanBeSent);
        return (currentAmountInFlight, amountCanBeSent);
    }

    /// @notice Sets a transfer rate limit for a destination chain. Owner-only.
    /// @param dstEid Destination endpoint ID
    /// @param limit Maximum amount that can be in-flight at once, in LD (local decimals):
    ///         for an 18-dec OFT (DCR = 1e12) 1 token = 1e18. Do NOT pass shared-decimals (SD,
    ///         6-dec) magnitudes — an SD-style value such as 1e12 equals only 1 dust unit here.
    /// @param window Time window (in seconds) over which the limit fully refills
    function setOutboundRateLimit(uint32 dstEid, uint192 limit, uint64 window) external onlyOwner {
        // window == 0 is reserved by OutrunRateLimiterUpgradeable for the unconfigured/deleted
        // unlimited sentinel; reject it here so configured limits cannot be mistaken for that state.
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
        // Dust below one shared-decimal unit is rejected by _debit, so quote it as unsendable.
        oftLimit = OFTLimit({minAmountLD: decimalConversionRate, maxAmountLD: maxAmountLD});
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
        // Reject zero/dust outbound sends before they can touch the rate limiter.
        if (amountSentLD == 0) revert AmountTooSmall();
        _outflow(_dstEid, amountSentLD);
        // Outbound transfer: (1) compute amounts, (2) apply rate limit outflow,
        // (3) burn tokens from sender. Must respect pause state.
        // _amountLD means "amount in local decimals".
        // _debitView removes dust on the source chain: amountSentLD == amountReceivedLD ==
        // _removeDust(_amountLD), and that dust-free value is what gets SD-encoded onto the
        // wire. Dust stays in the sender's balance — never burned, never bridged — so the
        // target chain _credit must not remove dust again.
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
        // Sends to dead address if receiver is zero. Without the remap, _update(address(0), address(0), ...)
        // would first add then subtract totalSupply, silently destroying the bridged amount, so follow
        // the upstream OFT convention and remap to 0xdead.
        // Mints the wire amount unchanged: dust truncation happens once on the source chain
        // in _debitView, and _lzReceive passes _toLD(amountSD) = amountSD * decimalConversionRate
        // — already a DCR multiple — so no _removeDust here (re-applying it would be a no-op).
        if (_to == address(0)) _to = address(0xdead);
        OutrunERC20Upgradeable._update(address(0), _to, _amountLD);
        return _amountLD;
    }

    /// @notice Removes dust from a local-decimal amount using the same formula as OFTCoreUpgradeable,
    ///         but without checked overflow because floor(a / r) * r <= a always holds.
    function _removeDust(uint256 _amountLD) internal view virtual override returns (uint256 amountLD) {
        unchecked {
            // forge-lint: disable-next-line(divide-before-multiply)
            return (_amountLD / decimalConversionRate) * decimalConversionRate;
        }
    }

    /// @notice Returns the maximum quoted amount for a destination, capped by the rate limit.
    /// @param dstEid Destination endpoint ID
    /// @return Max amount that can be quoted (uint64 max * decimalConversionRate, or rate-limited)
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
}
