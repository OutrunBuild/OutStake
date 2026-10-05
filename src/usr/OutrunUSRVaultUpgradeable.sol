// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IUSRVault} from "./interfaces/IUSRVault.sol";
import {TokenHelper} from "../libraries/TokenHelper.sol";

/// @title Outrun USR savings vault (suToken)
/// @notice ERC4626 savings layer for one family uAsset: depositors receive suToken shares whose
///      per-share price index grows second by second (timestamp-anchored) at the owner-set family
///      rate `usrRate`. Deposits and withdrawals are always open at the current index; the vault
///      holds no debt, no liquidation role, and no cross-chain role.
/// @dev Interest is paid exclusively out of the real uAsset balance (owner `fund` injections plus
///      non-recoverable stray transfers): every settlement clamps the index at
///      `balance * 1e18 / totalSupply()`, so the share liability `totalSupply() * accrualIndex / 1e18`
///      can never exceed the assets actually held and no interest is ever minted into existence.
///      There is no owner extraction surface — no sweep, no rescue, no pause: the owner entries are
///      `fund`, `setUsrRate`, and the UUPS upgrade. Share/asset conversions never call
///      `totalAssets()` or `totalSupply()` directly, but the interest-index projection is clamped
///      at `balance * 1e18 / totalSupply()`: while the extrapolation stays below that cap (funded
///      domain) the price is independent of the balance, so the classic ERC4626 donation/inflation
///      attack is structurally removed; once the extrapolation passes the cap (cap-binding domain,
///      i.e. stalled or still-transient states) the cap is the effective price, and a direct
///      transfer in immediately raises the effective price quoted by previews and written by the
///      next settlement, by at most the unsettled extrapolation gap. A depositor's post-deposit
///      per-share backing is still at least the executed index — donations only socialize toward
///      existing shareholders; there is no value-extraction side. `totalAssets()` keeps its plain
///      balance semantics as an informational view and is consumed by nothing in the pricing path.
contract OutrunUSRVaultUpgradeable layout at erc7201("outrun.storage.OutrunUSRVault")
    is
    IUSRVault,
    TokenHelper,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @custom:storage-location erc7201:outrun.storage.OutrunUSRVault
    struct OutrunUSRVaultStorage {
        // IMMUTABLE STORAGE LAYOUT: the contract-level layout at erc7201("outrun.storage.OutrunUSRVault")
        // allocates this contract's own variables from the namespace base slot in declaration order, and this
        // struct is the only own variable, so it sits at the base slot, one whole slot per field:
        //   ns+0 = usrRate | ns+1 = accrualIndex | ns+2 = lastSettledAt
        // accrualIndex is the per-share price for every depositor, so any reorder or insertion silently
        // reprices all shares. Field ORDER and count are frozen; new storage is only allowed as a tail
        // append. The layout is pinned by raw-slot assertions in
        // test/upgradeable/OutrunUSRVaultStorageLayout.t.sol.
        // Family annualized rate in 18-dec point terms (10% = 1e17). Zero means accrual is off.
        uint256 usrRate;
        // Per-share price index in 1e18 terms; starts at par (1e18) and only moves at settlement.
        uint256 accrualIndex;
        // Timestamp the index was last settled to; accrual is measured from here.
        uint256 lastSettledAt;
    }

    OutrunUSRVaultStorage private outrunUSRVaultStorage;

    /// @dev Year length in seconds (365-day convention) for this vault's own annualized-to-per-second
    ///      conversion: the per-second growth term is derived as `usrRate / SECONDS_PER_YEAR`.
    ///      Calendar-time anchoring keeps the rate semantics identical on every chain regardless of
    ///      block cadence, so there is no per-chain conversion parameter to misconfigure.
    uint256 private constant SECONDS_PER_YEAR = 31_536_000;
    /// @dev Absolute rate ceiling for `setUsrRate`: 10% annualized in 18-dec point terms.
    uint256 private constant MAX_USR_RATE = 1e17;
    /// @dev Deterministic saturation ceiling for the growth power: 1e36 in the 1e18 domain, i.e. a
    ///      1e18-fold per-share price multiplier. This point sits far beyond any real budget domain —
    ///      the settlement cap (balance * 1e18 / totalSupply) binds orders of magnitude earlier — so
    ///      saturating only removes the mulDiv overflow revert path: with a near-ceiling rate and a
    ///      long unsettled gap, an unclamped power would otherwise overflow mid-loop and brick all
    ///      six settlement entries and every preview, irreversibly locking the deposits. Saturation
    ///      is deterministic and monotonicity-preserving; a saturated value stays saturated.
    uint256 private constant MAX_INDEX_FACTOR = 1e36;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault behind the proxy, binding the family uAsset, the suToken
    ///      metadata, and the owner.
    /// @dev Deployment-time parameters are immutable-style: none has a setter after initialization.
    ///      A non-18-dec `asset_` reverts UAssetDecimalsMismatch — the 1e18 index domain assumes
    ///      an 18-dec asset and would silently mis-scale conversions otherwise.
    ///      The accrual clock is `block.timestamp` scaled by the internal SECONDS_PER_YEAR
    ///      constant, so no per-chain cadence parameter exists. A zero `owner_` is rejected by the
    ///      Ownable initializer.
    /// @param asset_ Family uAsset deposited into this vault (the ERC4626 asset)
    /// @param name_ suToken name
    /// @param symbol_ suToken symbol
    /// @param owner_ Initial owner address
    function initialize(address asset_, string calldata name_, string calldata symbol_, address owner_)
        external
        initializer
    {
        if (asset_ == address(0) || bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert ZeroInput();
        }
        uint8 assetDecimals = IERC20Metadata(asset_).decimals();
        if (assetDecimals != 18) {
            revert UAssetDecimalsMismatch(18, assetDecimals);
        }

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(asset_));
        __Ownable_init(owner_);

        OutrunUSRVaultStorage storage $ = outrunUSRVaultStorage;
        $.accrualIndex = 1e18;
        $.lastSettledAt = block.timestamp;
    }

    /// @notice Owner-only interest budget injection: pulls `amount` of the uAsset from the owner
    ///      into the vault. This is the only owner fund-moving entry and it is one-directional (in).
    /// @dev Mints no shares — the injected budget only backs future index growth. Settlement runs
    ///      before the pull, so pending seconds accrue against the pre-injection budget first.
    ///      Reverts ZeroInput for a zero amount.
    /// @param amount uAsset amount to pull from the owner (requires the owner's prior approval)
    function fund(uint256 amount) external override nonReentrant onlyOwner {
        if (amount == 0) revert ZeroInput();

        // Event before the external calls (CEI): a reverted pull reverts the event with it, so the
        // emit can never orphan.
        emit UsrFunded(amount);

        _settleIndex();
        // Explicit transferFrom: a 2-arg _transferIn call would bind to OZ's overload, not TokenHelper's 3-arg helper.
        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), amount);
    }

    /// @notice Sets the family annualized rate. Owner-only.
    /// @dev Settlement runs before the write, so every unsettled second keeps the old rate — the
    ///      new rate applies only from the current timestamp onward (forward effect). Bound:
    ///      `newRate` must not exceed 1e17 and a nonzero `newRate` must be at least
    ///      SECONDS_PER_YEAR (zero disables accrual); anything in between floors to no growth.
    /// @param newRate New annualized rate in 18-dec point terms
    function setUsrRate(uint256 newRate) external override onlyOwner {
        if (newRate > MAX_USR_RATE) revert UsrRateTooHigh();
        // Per-second term floors at `newRate / SECONDS_PER_YEAR`; reject nonzero rates that accrue nothing.
        if (newRate != 0 && newRate < SECONDS_PER_YEAR) revert UsrRateBelowResolution();

        OutrunUSRVaultStorage storage $ = outrunUSRVaultStorage;
        uint256 oldRate = $.usrRate;

        // Event before the state changes (CEI); a later failure reverts the emit with the call.
        emit UsrRateSet(oldRate, newRate);

        // Pending seconds settle at the old rate before the new one takes effect.
        _settleIndex();
        $.usrRate = newRate;
    }

    /// @dev Settles the accrual index to the current second before the entry prices the operation,
    ///      so the preview conversion and the hook-side settlement both observe the same-second
    ///      settled state and the projection is computed once per transaction.
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _settleIndex();
        return super.deposit(assets, receiver);
    }

    /// @dev Same-second settlement entry; rationale documented at deposit.
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _settleIndex();
        return super.mint(shares, receiver);
    }

    /// @dev Same-second settlement entry; rationale documented at deposit.
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _settleIndex();
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev Same-second settlement entry; rationale documented at deposit.
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _settleIndex();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Returns the family annualized rate in 18-dec point terms (zero = accrual off).
    /// @return Current rate applied to each settled second
    function usrRate() external view override returns (uint256) {
        return outrunUSRVaultStorage.usrRate;
    }

    /// @notice Returns the settled per-share price index in 1e18 terms (1e18 = par).
    /// @dev Settled accounting value; the preview/convert views extrapolate it to the current
    ///      timestamp separately from this accessor.
    /// @return Settled index
    function accrualIndex() external view override returns (uint256) {
        return outrunUSRVaultStorage.accrualIndex;
    }

    /// @notice Returns the timestamp the index was last settled to.
    /// @return Last settled timestamp
    function lastSettledAt() external view override returns (uint256) {
        return outrunUSRVaultStorage.lastSettledAt;
    }

    /// @dev This hook carries the nonReentrant guard for the deposit/mint fund-moving path. Index
    ///      settlement to the current second happens in the four external entry overrides before
    ///      conversion (one projection per transaction), so the hook needs no settle of its own —
    ///      the same-second delta is always zero by the time it runs.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw/redeem counterpart of `_deposit`: the nonReentrant guard for the payout path;
    ///      settlement happens in the external entry overrides (see `_deposit`).
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Validates upgrade authorization; only the owner may upgrade the implementation.
    /// @dev The rate/index state lives in namespaced storage and survives upgrades.
    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @dev Share conversion is a pure index formula — `assets * 1e18 / index` — on the
    ///      current-timestamp projection; the projection is the same value settlement writes,
    ///      which keeps preview and execution consistent; its balance/supply coupling through the
    ///      cap clamp and the funded vs cap-binding donation behavior are specified at the
    ///      contract level.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, 1e18, _projectedIndex(), rounding);
    }

    /// @dev Asset conversion mirrors `_convertToShares`: `shares * index / 1e18` on the same
    ///      current-timestamp projection.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, _projectedIndex(), 1e18, rounding);
    }

    /// @dev Settles the index to the current timestamp: writes the projected (clamped) index and
    ///      moves the accounting timestamp forward. Idempotent within the same second (a zero
    ///      delta leaves the index unchanged) and safe in the zero-supply suspended state (index
    ///      unchanged, accounting timestamp still moves). Emits AccrualIndexSettled only when the
    ///      stored index actually changes.
    function _settleIndex() private {
        OutrunUSRVaultStorage storage $ = outrunUSRVaultStorage;
        uint256 delta = block.timestamp - $.lastSettledAt;
        if (delta != 0) {
            uint256 oldIndex = $.accrualIndex;
            uint256 newIndex = _projectedIndex();
            // Silent when the projection matches: same-second, zero-supply, zero-rate, and
            // cap-pinned settlements move time but mint no event.
            if (newIndex != oldIndex) {
                // File convention: emit before the writes; a reverted call reverts the emit with it.
                emit AccrualIndexSettled(oldIndex, newIndex);
                $.accrualIndex = newIndex;
            }
            $.lastSettledAt = block.timestamp;
        }
    }

    /// @dev Projects the index to the current timestamp: extrapolation clamped by the hard budget
    ///      cap `balance * 1e18 / totalSupply()`. Single source of pricing truth — the view
    ///      conversions (preview) and the settlement write both call this function on the same
    ///      state, so they cannot diverge.
    ///      Zero-supply suspension: with no real shares outstanding, accrual is suspended and the
    ///      settled index is returned unchanged (this also removes the cap denominator's
    ///      division-by-zero edge). A zero balance with shares outstanding is defensively treated
    ///      as cap zero (no growth). The final `max(current, min(extrapolated, cap))` clamp keeps
    ///      the index monotonic.
    function _projectedIndex() private view returns (uint256) {
        OutrunUSRVaultStorage storage $ = outrunUSRVaultStorage;
        uint256 currentIndex = $.accrualIndex;
        uint256 supply = totalSupply();
        if (supply == 0) return currentIndex;

        uint256 deltaSeconds = block.timestamp - $.lastSettledAt;
        // Per-second growth factor: floor(annualized rate / seconds per year) added to par.
        uint256 factor = 1e18 + $.usrRate / SECONDS_PER_YEAR;
        uint256 projected = Math.mulDiv(currentIndex, _factorPow(factor, deltaSeconds), 1e18);
        if (projected == currentIndex) return currentIndex;
        uint256 cap = Math.mulDiv(IERC20(asset()).balanceOf(address(this)), 1e18, supply);
        uint256 clamped = projected < cap ? projected : cap;
        return clamped > currentIndex ? clamped : currentIndex;
    }

    /// @dev Exponentiation-by-squaring of the per-second growth factor: `factor ** exponent` in
    ///      the 1e18 domain, MSB-first — start with r = factor at the exponent's most significant
    ///      bit, then for each lower bit square r (reduced mod 1e18 through mulDiv immediately) and
    ///      multiply by factor when the bit is set. Deterministic and O(log exponent) with no
    ///      full-precision intermediates; exponent zero yields 1e18 (no growth). Rounding happens
    ///      only in each step's immediate reduction, never on accumulated values. Results saturate
    ///      at MAX_INDEX_FACTOR, which keeps every intermediate inside the mulDiv-safe domain (see
    ///      the constant's rationale); the saturation point is unreachable under any real budget.
    ///      Degenerate inputs return early: exponent zero yields 1e18 (no growth), and an identity
    ///      factor of 1e18 (usrRate below the per-second resolution) yields 1e18 for any exponent,
    ///      so the unactivated (zero-rate) state never pays the exponentiation loop.
    function _factorPow(uint256 factor, uint256 exponent) private pure returns (uint256 r) {
        if (exponent == 0) return 1e18;
        if (factor == 1e18) return 1e18;

        // Highest bit index of the exponent: floor(log2(exponent)).
        uint256 msb = Math.log2(exponent);

        r = factor;
        for (uint256 bit = msb; bit > 0; --bit) {
            r = Math.mulDiv(r, r, 1e18);
            if (((exponent >> (bit - 1)) & 1) == 1) {
                r = Math.mulDiv(r, factor, 1e18);
            }
            // Saturation clamp after each step: entering values stay <= 1e36, so no squaring or
            // scaling step can ever push a mulDiv quotient past the uint256 domain.
            if (r > MAX_INDEX_FACTOR) {
                r = MAX_INDEX_FACTOR;
            }
        }
    }
}
