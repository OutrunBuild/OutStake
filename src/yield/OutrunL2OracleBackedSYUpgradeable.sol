// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.35;

import {ArrayLib} from "../libraries/ArrayLib.sol";
import {SYBaseUpgradeable} from "./SYBaseUpgradeable.sol";
import {IExchangeRateOracle} from "../libraries/oracle/interfaces/IExchangeRateOracle.sol";

/// @title Outrun L2 oracle-backed SY abstract base
/// @notice L2 SY abstract base where the yield-bearing token itself is the SY. Deposit and redeem are 1:1 with
///      the underlying token. The exchange rate comes from a configured oracle because yield accrues on
///      L1/Ethereum mainnet and the L2 token balance does not reflect it. Every exchange-rate reading is
///      checked against a committed rate anchor and reverts when it deviates beyond the allowed band
///      (see `_checkRateWithinBand`), so a compromised or miswired feed cannot silently reprice positions.
abstract contract OutrunL2OracleBackedSYUpgradeable is SYBaseUpgradeable {
    // Abstract contracts cannot use the `layout at` syntax (solc error 7587), so this base
    // sets its ERC-7201 location the classic way — same pattern as SYBaseUpgradeable.
    /// @custom:storage-location erc7201:outrun.storage.OutrunL2OracleBackedSY
    struct OutrunL2OracleBackedSYStorage {
        // Oracle reports the current L1 exchange rate (canonical asset per SY).
        // Needed because the L2 token balance is static — the oracle makes the rate
        // visible for position accounting.
        // Production deployments should choose staleness bounds per the underlying
        // asset's rate source and, where the rate depends on L2 sequencing, enable an
        // L2 sequencer uptime feed with a post-recovery grace period.
        // Example provenance: the Lido cross-chain token guide (basis for the wstETH
        // adapter) says stETH rate data should not be outdated by more than 2 days.
        // https://docs.lido.fi/token-guides/cross-chain-tokens-guide/
        address exchangeRateOracle;
        // The canonical asset lives on Ethereum mainnet (not deployed on this L2); these
        // fields describe it for position accounting and display purposes.
        address underlyingAssetOnEthAddr;
        uint8 underlyingAssetOnEthDecimals;
        // --- Rate-anchor deviation breaker (appended fields; never reorder the ones above) ---
        // Anchor exchange rate (1e18 scale) captured at the last anchor commit/reset. 1e18-scale
        // conversion rates sit far below 2^96, so the narrowing cast is exact in practice. Every
        // anchor-writing entry point (init, commit, reset) reverts with `RateAnchorOverflow` for
        // a reading above uint96 max BEFORE the cast: unguarded, a multiple of 2^96 would narrow
        // to anchor == 0 and silently disable the band via the anchor == 0 defensive skip.
        uint96 rateAnchor;
        // Chain timestamp of the last anchor commit/reset; drives the continuously accrued
        // rise allowance.
        uint64 rateAnchorTimestamp;
        // Maximum allowed drop from the anchor, in bps. The drop side gets NO time allowance:
        // conversion rates for these staking-class assets are monotonically non-decreasing, so
        // any immediate drop beyond this bound is anomalous.
        uint16 maxRateDropBps;
        // Rise allowance accrued per hour of elapsed time since the anchor timestamp, in bps.
        // Accrual is continuous (per second), not in whole-hour steps.
        uint16 rateRiseBpsPerHour;
        // Ceiling on the accumulated rise allowance, in bps.
        uint16 maxRateRiseCapBps;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunL2OracleBackedSY")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_L2_ORACLE_BACKED_SY_STORAGE_LOCATION =
        0x57aa7d79a56b64c6a75a8df5f30e533361d1c41ef1173e8a4529d9a05db56b00;

    // Deviation-breaker defaults. Staking-class conversion rates drift slowly (on the order of
    // 1 bps per day — e.g. ~0.85 bps/day for wstETH). The per-hour rise allowance (5 bps/hour
    // = 120 bps/day) carries ~140x headroom over that drift, while the drop bound is a noise
    // tolerance for round-to-round oracle jitter, not a drift allowance. The rise cap bounds the
    // band width since the LAST anchor write: an in-band commit re-bases the band, so repeated
    // commits can ratchet the anchor (rise at rateRiseBpsPerHour per hour, drop at maxRateDropBps
    // per commit). The anchor never exceeds an actual oracle reading, and cumulative drift stays
    // bounded by oracle trust plus monitoring.
    uint16 private constant DEFAULT_MAX_RATE_DROP_BPS = 10;
    uint16 private constant DEFAULT_RATE_RISE_BPS_PER_HOUR = 5;
    uint16 private constant DEFAULT_MAX_RATE_RISE_CAP_BPS = 200;

    function _getOutrunL2OracleBackedSYStorage() private pure returns (OutrunL2OracleBackedSYStorage storage $) {
        assembly {
            $.slot := OUTRUN_L2_ORACLE_BACKED_SY_STORAGE_LOCATION
        }
    }

    event SetExchangeRateOracle(address indexed oldOracle, address indexed newOracle);
    event RateAnchorCommitted(uint256 indexed anchor, uint256 timestamp);
    event RateAnchorReset(uint256 indexed oldAnchor, uint256 indexed newAnchor);
    /// @dev Deliberately left unindexed: three uint16 topics would only add log cost with no
    ///      filtering value.
    event SetRateBreakerParams(uint16 maxDropBps, uint16 riseBpsPerHour, uint16 maxRiseCapBps);

    error ZeroRateAnchor();
    error InvalidRateBreakerParams();
    /// @param newRate The oracle reading that fell outside the allowed band.
    /// @param anchorRate The committed anchor the reading was checked against.
    /// @param allowedBps The allowance that was breached: for an upper-band breach the
    ///        time-accrued rise allowance reported as a floored whole-bps value (the boundary
    ///        itself is judged against the exact, un-floored allowance — see `_checkRateWithinBand`),
    ///        or `maxRateDropBps` for a lower-band breach.
    error RateDeviationExceeded(uint256 newRate, uint256 anchorRate, uint256 allowedBps);
    /// @param reading The oracle reading that exceeds `type(uint96).max` and therefore cannot be
    ///        stored as a rate anchor.
    error RateAnchorOverflow(uint256 reading);

    /// @notice Initializes the shared L2 oracle-backed SY state.
    /// This helper is split from the child initialize signatures because each concrete
    /// adapter exposes its own external initializer (the wstETH adapter hardcodes its name
    /// and symbol), while the oracle and underlying-asset wiring is identical for every
    /// adapter in this family, so it lives here once.
    /// @dev `underlyingAssetOnEthDecimals_` is L1 canonical-asset decimals (e.g. 18 for stETH, 6 for USDC/USDS).
    /// L2 cannot verify it on-chain via `IERC20Metadata.decimals()` without a bridge; a misconfiguration
    /// (e.g. 18 vs 6) is silently cached by `OutrunStakingPositionUpgradeable.initialize` as
    /// `canonicalAssetDecimals` and systematically mis-scales position principal debt / `syToAsset` via
    /// `OutrunStakingPositionUpgradeable._scaleCanonicalAssetToUAsset`
    /// by `10**12`. Validate off-chain against L1 Etherscan / official docs and via
    /// `L2AssetValidation.validateL2OracleBackedParams` in deployment scripts before broadcasting;
    /// post-deploy the value is immutable (no setter) and requires SY + SP redeployment to fix.
    /// See `script/lib/L2AssetValidation.sol`.
    /// @param name_ Token name for the ERC20 representation.
    /// @param symbol_ Token symbol for the ERC20 representation.
    /// @param owner_ Address that will be granted the owner role.
    /// @param token_ The yield-bearing token on L2 (IS the SY — no wrapping needed).
    /// @param exchangeRateOracle_ Oracle that reports the canonical-asset-per-SY exchange rate.
    /// @param underlyingAssetOnEthAddr_ Address of the underlying asset on Ethereum mainnet.
    /// @param underlyingAssetOnEthDecimals_ Decimals of the underlying asset on Ethereum mainnet (must match L1 truth; see dev note).
    /// @dev The deviation-breaker anchor is seeded from the oracle's first reading: a zero first
    ///      reading reverts with `ZeroRateAnchor` so a broken feed cannot deploy behind a live
    ///      band, and the three breaker parameters start at their conservative defaults.
    function __L2OracleBackedSY_init(
        string memory name_,
        string memory symbol_,
        address owner_,
        address token_,
        address exchangeRateOracle_,
        address underlyingAssetOnEthAddr_,
        uint8 underlyingAssetOnEthDecimals_
    ) internal onlyInitializing {
        if (exchangeRateOracle_ == address(0) || underlyingAssetOnEthAddr_ == address(0)) revert SYZeroAddress();
        __SYBase_init(name_, symbol_, token_, owner_);
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        $.exchangeRateOracle = exchangeRateOracle_;
        $.underlyingAssetOnEthAddr = underlyingAssetOnEthAddr_;
        $.underlyingAssetOnEthDecimals = underlyingAssetOnEthDecimals_;
        uint256 initialRate = IExchangeRateOracle(exchangeRateOracle_).getExchangeRate();
        if (initialRate == 0) revert ZeroRateAnchor();
        _writeAnchor(initialRate);
        $.maxRateDropBps = DEFAULT_MAX_RATE_DROP_BPS;
        $.rateRiseBpsPerHour = DEFAULT_RATE_RISE_BPS_PER_HOUR;
        $.maxRateRiseCapBps = DEFAULT_MAX_RATE_RISE_CAP_BPS;
    }

    /// @notice Stores `rate` as the rate anchor with the current timestamp.
    /// @dev Single anchor-writing primitive shared by init, commit, and reset: reverts with
    ///      `RateAnchorOverflow` for a reading above uint96 max BEFORE the narrowing cast —
    ///      unguarded, a multiple of 2^96 would truncate to anchor == 0 and silently disable
    ///      the band via the anchor == 0 defensive skip in `_checkRateWithinBand`.
    /// @param rate The oracle reading to store as the anchor.
    function _writeAnchor(uint256 rate) internal {
        if (rate > type(uint96).max) revert RateAnchorOverflow(rate);
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        $.rateAnchor = uint96(rate);
        $.rateAnchorTimestamp = uint64(block.timestamp);
    }

    /// @notice Returns the address of the exchange rate oracle.
    /// @return The oracle address that reports the canonical-asset-per-SY exchange rate.
    function exchangeRateOracle() public view returns (address) {
        return _getOutrunL2OracleBackedSYStorage().exchangeRateOracle;
    }

    /// @notice Updates the exchange rate oracle address. Owner-only.
    /// @dev The stored rate anchor survives an oracle swap: the new oracle's readings must still
    ///      pass the deviation band against the OLD anchor, so a swap alone can never reprice
    ///      positions. Adopting a legitimately different-magnitude source requires the explicit
    ///      `resetRateAnchor()` after the swap. The swap itself is instant (no timelock).
    /// @param newOracle The new oracle address. Must not be zero.
    function setExchangeRateOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert SYZeroAddress();
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        address oldOracle = $.exchangeRateOracle;
        $.exchangeRateOracle = newOracle;
        emit SetExchangeRateOracle(oldOracle, newOracle);
    }

    /// @notice Advances the rate anchor to the oracle's current reading. Permissionless.
    /// @dev Anyone may advance the anchor, but only to a reading that is inside the current band
    ///      — the conservative direction, because a fresh anchor narrows the rise allowance back
    ///      to zero and re-bases the drop bound. A malicious caller cannot widen the band, only
    ///      tighten it. Reverts with `RateDeviationExceeded` when the current reading is outside
    ///      the band (including a zero reading), and with `RateAnchorOverflow` when the reading
    ///      exceeds `type(uint96).max` (checked before the band so a truncate-to-zero reading
    ///      can never become the anchor).
    function commitRateAnchor() external {
        uint256 rate = IExchangeRateOracle(exchangeRateOracle()).getExchangeRate();
        // Overflow guard first: an oversized reading is pathological regardless of the band, and
        // must surface as `RateAnchorOverflow` rather than a band breach — `_writeAnchor` below
        // enforces the same bound again before the cast.
        if (rate > type(uint96).max) revert RateAnchorOverflow(rate);
        _checkRateWithinBand(rate);
        _writeAnchor(rate);
        emit RateAnchorCommitted(rate, block.timestamp);
    }

    /// @notice Re-syncs the rate anchor to the oracle's current reading, unconditionally. Owner-only.
    /// @dev Recovery path after a legitimate feed-regime change (e.g. a new oracle whose correct
    ///      magnitude differs from the old anchor): the owner cannot inject an arbitrary anchor —
    ///      only adopt whatever the oracle currently reports, and never zero (`ZeroRateAnchor`)
    ///      nor above `type(uint96).max` (`RateAnchorOverflow`, guarding the narrowing cast).
    ///      Reads through `exchangeRate()` remain band-checked against the new anchor afterwards.
    /// @custom:events `RateAnchorReset(oldAnchor, newAnchor)` with the pre- and post-reset anchors.
    function resetRateAnchor() external onlyOwner {
        uint256 rate = IExchangeRateOracle(exchangeRateOracle()).getExchangeRate();
        if (rate == 0) revert ZeroRateAnchor();
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        uint256 oldAnchor = $.rateAnchor;
        _writeAnchor(rate);
        emit RateAnchorReset(oldAnchor, rate);
    }

    /// @notice Updates the deviation-band parameters. Owner-only.
    /// @dev Every parameter must satisfy `1 <= p <= 10000` bps. `0` is rejected because it pins
    ///      that band edge to the anchor itself — the tightest possible setting, rejecting every
    ///      deviation on that side (zero bandwidth). For `maxDropBps`, values above `10000` are
    ///      rejected because the drop-band term `10000 - maxDropBps` evaluated in
    ///      `_checkRateWithinBand` would underflow in checked arithmetic (Panic(0x11)) and revert
    ///      every rate reading; rise parameters above `10000` are rejected only as nonsensical
    ///      magnitudes (they merely widen the allowance). At the allowed upper edge, setting
    ///      `maxDropBps == 10000` collapses the minimum rate to zero, silently disabling drop
    ///      protection for every non-zero reading (only a zero reading still reverts).
    /// @param maxDropBps Maximum allowed drop from the anchor, in bps. At `10000` the drop side
    ///      stops rejecting non-zero readings (see dev note).
    /// @param riseBpsPerHour Rise allowance accrued per hour of elapsed time since the anchor, in bps.
    /// @param maxRiseCapBps Ceiling on the accrued rise allowance, in bps.
    function setRateBreakerParams(uint16 maxDropBps, uint16 riseBpsPerHour, uint16 maxRiseCapBps) external onlyOwner {
        if (
            maxDropBps == 0 || maxDropBps > 1e4 || riseBpsPerHour == 0 || riseBpsPerHour > 1e4 || maxRiseCapBps == 0
                || maxRiseCapBps > 1e4
        ) revert InvalidRateBreakerParams();
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        $.maxRateDropBps = maxDropBps;
        $.rateRiseBpsPerHour = riseBpsPerHour;
        $.maxRateRiseCapBps = maxRiseCapBps;
        emit SetRateBreakerParams(maxDropBps, riseBpsPerHour, maxRiseCapBps);
    }

    /// @notice Adapter-specific deposit logic — 1:1, the yield-bearing token IS the SY.
    function _deposit(address, uint256 amountDeposited) internal pure virtual override returns (uint256) {
        return amountDeposited;
    }

    /// @notice Adapter-specific redeem logic — transfers the yield-bearing token 1:1 to the receiver.
    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        virtual
        override
        returns (uint256)
    {
        _transferOut(tokenOut, receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    /// @notice Checks an oracle reading against the committed anchor and the stored band.
    /// @dev Rise side: the allowance accrues CONTINUOUSLY — `rateRiseBpsPerHour` scaled by the
    ///      elapsed seconds since the anchor timestamp, capped at `maxRateRiseCapBps` — so a
    ///      legitimate reading inches above the anchor at any sub-hour granularity. The cap and
    ///      the elapsed time share one bps-seconds scale and the bound uses a single final
    ///      division, so the boundary is exact down to the wei (no sub-bps truncation loss).
    ///      On an upper-band breach the revert's `allowedBps` reports the floored whole-bps
    ///      allowance (`cappedSecondsTerm / 3600`) while the boundary itself was judged against
    ///      the exact un-floored value. Drop side: no time allowance, since these conversion
    ///      rates are monotonically non-decreasing and any immediate drop beyond `maxRateDropBps`
    ///      is anomalous; `minRate` is computed only after the upper-band check so the breach
    ///      path skips it. A zero reading is treated as a lower-band breach. Purely a read:
    ///      enforcing never advances the anchor.
    function _checkRateWithinBand(uint256 rate) internal view {
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        uint256 anchor = $.rateAnchor;
        // Defensive: without a committed anchor there is no band to enforce. Unreachable after
        // a successful init, which always seeds the anchor.
        if (anchor == 0) return;
        uint256 maxDropBps = $.maxRateDropBps;
        if (rate == 0) revert RateDeviationExceeded(0, anchor, maxDropBps);
        // bps-seconds scale: riseBpsPerHour x elapsedSeconds vs maxRiseCapBps x 3600. Multiply
        // first, divide once at the end — keeps the boundary wei-exact and avoids truncating
        // the sub-hour allowance.
        uint256 elapsedSeconds = block.timestamp - $.rateAnchorTimestamp;
        uint256 uncappedTerm = uint256($.rateRiseBpsPerHour) * elapsedSeconds;
        uint256 capTerm = uint256($.maxRateRiseCapBps) * 3600;
        uint256 cappedSecondsTerm = uncappedTerm > capTerm ? capTerm : uncappedTerm;
        uint256 hourBpsScale = 3600 * 1e4;
        uint256 maxRate = anchor * (hourBpsScale + cappedSecondsTerm) / hourBpsScale;
        if (rate > maxRate) revert RateDeviationExceeded(rate, anchor, cappedSecondsTerm / 3600);
        uint256 minRate = anchor * (1e4 - maxDropBps) / 1e4;
        if (rate < minRate) revert RateDeviationExceeded(rate, anchor, maxDropBps);
    }

    /// @notice Returns the current exchange rate from the oracle (not from token balance).
    /// The L2 token balance does not grow with yield, so the oracle reports the canonical
    /// asset amount per SY as tracked on the source chain. The reading must pass the
    /// deviation band around the committed anchor, otherwise the call reverts with
    /// `RateDeviationExceeded` (fail-closed: positions are never priced off an out-of-band rate).
    /// @return The exchange rate, scaled by 1e18.
    function exchangeRate() public view virtual override returns (uint256) {
        _revertIfBackingBelowShares();
        uint256 rate = IExchangeRateOracle(exchangeRateOracle()).getExchangeRate();
        _checkRateWithinBand(rate);
        return rate;
    }

    /// @notice Adapter-specific preview of a deposit — returns the input amount (1:1, no wrapping).
    function _previewDeposit(address, uint256 amountTokenToDeposit) internal pure virtual override returns (uint256) {
        return amountTokenToDeposit;
    }

    /// @notice Adapter-specific preview of a redemption — returns the input amount (1:1, no unwrapping).
    function _previewRedeem(address, uint256 amountSharesToRedeem) internal pure virtual override returns (uint256) {
        return amountSharesToRedeem;
    }

    /// @notice Returns all tokens accepted for deposit — only the yield-bearing token.
    /// @return res Single-element array containing the yield-bearing token address.
    function getTokensIn() public view virtual override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @notice Returns all tokens accepted for redemption — only the yield-bearing token.
    /// @return res Single-element array containing the yield-bearing token address.
    function getTokensOut() public view virtual override returns (address[] memory res) {
        return ArrayLib.create(yieldBearingToken());
    }

    /// @notice Checks whether the given token is accepted for deposit.
    /// @param token The token address to check.
    /// @return True if the token equals the yield-bearing token.
    function isValidTokenIn(address token) public view virtual override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @notice Checks whether the given token is accepted for redemption.
    /// @param token The token address to check.
    /// @return True if the token equals the yield-bearing token.
    function isValidTokenOut(address token) public view virtual override returns (bool) {
        return token == yieldBearingToken();
    }

    /// @notice Reports the underlying asset details on Ethereum mainnet (for position accounting).
    /// The canonical asset lives on Ethereum mainnet, not on this L2.
    /// @return assetType Always AssetType.TOKEN.
    /// @return assetAddress Address of the underlying asset on Ethereum mainnet.
    /// @return assetDecimals Decimals of the underlying asset on Ethereum mainnet.
    function assetInfo()
        external
        view
        virtual
        returns (AssetType assetType, address assetAddress, uint8 assetDecimals)
    {
        OutrunL2OracleBackedSYStorage storage $ = _getOutrunL2OracleBackedSYStorage();
        return (AssetType.TOKEN, $.underlyingAssetOnEthAddr, $.underlyingAssetOnEthDecimals);
    }
}
