// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPSM} from "./interfaces/IPSM.sol";
import {IUniversalAssets} from "../assets/interfaces/IUniversalAssets.sol";
import {IERC20, TokenHelper} from "../libraries/TokenHelper.sol";

/// @title Outrun Peg Stability Module (PSM)
/// @notice 1:1 face-value swap venue between one bound reserve asset and one family uAsset: `mint` takes
///      reserve and mints uAsset, `redeem` takes uAsset and pays out reserve. The 1:1 face-value rate is a
///      structural constant (hardcoded, no oracle, no setter, no slippage parameter) — the only discount is
///      the fees `tin`/`tout`.
/// @dev The single reserve is bound at initialization (ERC20 or the native currency via the NATIVE
///      sentinel, address(0)); the binding is immutable — there is no setter and no registry. The
///      only binding-time reserve check is the initialization `decimals()` read (skipped for the
///      native leg, must not exceed 18); there is otherwise no code check. Every reserve taken in stays in this contract: there is no
///      pause and no owner extraction surface — the only outflow besides swaps is the permissionless
///      `sweepFees` fee-balance exit paid to the immutable `feeRecipient` — the owner only touches
///      parameters and upgrades.
///      The uAsset-side pause is the circuit breaker for both swap directions (reserveMint/reserveBurn are
///      whenNotPaused on the uAsset).
///      Accounting invariant: PSM reserve balance == net uAsset face value minted + accumulated fees —
///      exact only while every redeemed uAsset was minted by this instance. Redemptions of
///      foreign-minted uAsset (e.g. from the CDP path) pay out reserve without reducing net minted
///      below zero (it saturates), so under mixed foreign redemptions the exact identity degrades to
///      the inequality `reserve balance >= net uAsset face value minted`, with the payout hard-bounded
///      by the reserve balance actually held. Fees are derived as input face value minus the user
///      amount, so floor-rounding loss stays in the contract and keeps the identity exact within the
///      local-mint-only flow; the accumulated surplus (plus any saturation-domain principal left
///      behind by foreign redemptions) leaves only through `sweepFees`, which never touches
///      `netUAssetMinted`.
///      The uAsset minter debt ledger is not used: this contract is registered as a uAsset reserve minter
///      and its mintingStatusTable stays zero.
contract OutrunPSMUpgradeable layout at erc7201("outrun.storage.OutrunPSM")
    is
    IPSM,
    TokenHelper,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    struct OutrunPSMStorage {
        // IMMUTABLE STORAGE LAYOUT: the contract-level layout at erc7201("outrun.storage.OutrunPSM") allocates
        // this contract's own variables from the namespace base slot in declaration order, and this struct is
        // the only own variable, so it sits at the base slot, one whole slot per field:
        //   ns+0 = uAsset | ns+1 = reserveToken | ns+2 = feeRecipient | ns+3 = tin | ns+4 = tout
        //   ns+5 = stockCap | ns+6 = netUAssetMinted
        // Field ORDER and count are frozen (a reorder or insertion would silently rewire the swap route, the
        // fees, and the stock cap); new storage is only allowed as a tail append. The layout is pinned by
        // raw-slot assertions in test/upgradeable/OutrunPSMStorageLayout.t.sol.
        // Family uAsset bound at initialization; minted on mint, burned on redeem.
        address uAsset;
        // The single reserve bound at initialization; the NATIVE sentinel (address(0)) is the native leg.
        address reserveToken;
        // Recipient of sweepFees payouts; bound at initialization, immutable with no setter.
        address feeRecipient;
        // Mint-side fee, 18-dec point value (1e18 = 100%).
        uint256 tin;
        // Redeem-side fee, 18-dec point value.
        uint256 tout;
        // Stock cap: net minted face value (cumulative mint minus cumulative burn) must not exceed this.
        uint256 stockCap;
        // Net minted face value in 18 decimals: cumulative reserveMint output minus cumulative reserveBurn
        // input, saturating at zero when foreign-minted uAsset burns exceed local mints.
        uint256 netUAssetMinted;
    }

    OutrunPSMStorage private outrunPSMStorage;

    /// @dev Fee ceiling: 1% in 18-dec point terms (1e18 = 100%).
    uint256 private constant MAX_FEE = 1e16;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the PSM, binding the family uAsset, the single reserve, the owner, the
    ///      fee sweep recipient, and initial parameters.
    /// @dev Same bounds as the runtime setters: the stock cap must be > 0 and fees must sit in [0, 1%].
    ///      Reverts with `UAssetDecimalsMismatch` if the bound uAsset does not use 18 decimals — PSM
    ///      face-value math hardcodes 18-dec face value and would silently mis-scale swaps otherwise.
    ///      The reserve leg reads `decimals()` once (the NATIVE sentinel skips the read) and reverts
    ///      with `UAssetDecimalsMismatch` when it exceeds 18; a non-ERC20 reserve reverts on the read.
    /// @param uAsset_ Family uAsset swapped against the bound reserve
    /// @param reserveToken_ The single reserve this instance serves (NATIVE sentinel for the native currency)
    /// @param owner_ Initial owner address
    /// @param feeRecipient_ Recipient of sweepFees payouts; immutable after initialization (no setter)
    /// @param stockCap_ Initial stock cap (18-dec face value)
    /// @param tin_ Initial mint-side fee
    /// @param tout_ Initial redeem-side fee
    function initialize(
        address uAsset_,
        address reserveToken_,
        address owner_,
        address feeRecipient_,
        uint256 stockCap_,
        uint256 tin_,
        uint256 tout_
    ) external initializer {
        if (uAsset_ == address(0) || owner_ == address(0) || feeRecipient_ == address(0) || stockCap_ == 0) {
            revert ZeroInput();
        }
        uint8 uAssetDecimals = IERC20Metadata(uAsset_).decimals();
        if (uAssetDecimals != 18) {
            revert UAssetDecimalsMismatch(18, uAssetDecimals);
        }
        // Immutable binding with no setter: a >18-dec reserve would underflow `_faceValueScale`
        // and an EOA/non-ERC20 reserve would revert on `decimals()` at swap time — fail closed
        // here instead of bricking every swap after deployment.
        if (reserveToken_ != NATIVE) {
            uint8 reserveDecimals = IERC20Metadata(reserveToken_).decimals();
            if (reserveDecimals > 18) {
                revert UAssetDecimalsMismatch(18, reserveDecimals);
            }
        }
        _requireFeesInRange(tin_, tout_);

        __Ownable_init(owner_);

        OutrunPSMStorage storage $ = outrunPSMStorage;
        $.uAsset = uAsset_;
        $.reserveToken = reserveToken_;
        $.feeRecipient = feeRecipient_;
        $.stockCap = stockCap_;
        $.tin = tin_;
        $.tout = tout_;
    }

    /// @notice Updates both swap fees. Owner-only.
    /// @param tin_ New mint-side fee (18-dec point value)
    /// @param tout_ New redeem-side fee (18-dec point value)
    function setFees(uint256 tin_, uint256 tout_) external override onlyOwner {
        _requireFeesInRange(tin_, tout_);

        OutrunPSMStorage storage $ = outrunPSMStorage;
        $.tin = tin_;
        $.tout = tout_;

        emit SetFees(tin_, tout_);
    }

    /// @notice Updates the stock cap. Owner-only.
    /// @dev A zero stock cap has no "cap off" meaning here — it would freeze all mints — so caps stay > 0.
    /// @param stockCap_ New stock cap (18-dec face value)
    function setStockCap(uint256 stockCap_) external override onlyOwner {
        if (stockCap_ == 0) revert ZeroInput();
        outrunPSMStorage.stockCap = stockCap_;

        emit SetStockCap(stockCap_);
    }

    /// @notice Swaps the bound reserve for uAsset at 1:1 face value, net of the mint fee `tin`.
    /// @dev Fee math: `amountOut = faceValue(amountIn) * (1e18 - tin) / 1e18`, floor-rounded (protocol-
    ///      favored side); `feeIn` is exported as the difference `faceValue - amountOut`, never computed
    ///      separately. Reserves with more than 18 decimals are outside the PSM domain — the decimal
    ///      rescale reverts (checked arithmetic) rather than silently mispricing the swap.
    ///      There is no per-swap flow cap and no time-window limit: the effective single-swap ceiling is
    ///      the remaining stock-cap headroom (`stockCap - netUAssetMinted`), so order splitting is
    ///      unrestricted.
    /// @param to Receiver of the minted uAsset
    /// @param amountIn Reserve amount to swap in, in the bound reserve token's own decimals
    /// @return amountOut uAsset minted to `to`, in 18 decimals
    function mint(address to, uint256 amountIn) external payable override nonReentrant returns (uint256 amountOut) {
        OutrunPSMStorage storage $ = outrunPSMStorage;
        address reserveToken_ = $.reserveToken;
        if (to == address(0) || amountIn == 0) revert ZeroInput();

        uint256 faceValue;
        (faceValue, amountOut) = _mintOutput(reserveToken_, amountIn);
        // Dust guard: a sub-unit face value that floors to zero after the fee must not take reserve in
        // while minting nothing; reverting ZeroInput fails closed.
        if (amountOut == 0) revert ZeroInput();
        uint256 netMinted = $.netUAssetMinted;
        if (netMinted + amountOut > $.stockCap) revert StockCapExceeded();

        // All checks passed; pull the reserve (native: msg.value == amountIn, ERC20: msg.value == 0).
        _transferIn(reserveToken_, msg.sender, amountIn);

        // Ledger update before the external uAsset mint keeps C-E-I ordering.
        $.netUAssetMinted = netMinted + amountOut;
        IUniversalAssets($.uAsset).reserveMint(to, amountOut);

        emit SwapMintForUAsset(reserveToken_, to, amountIn, amountOut, faceValue - amountOut);
    }

    /// @notice Swaps uAsset for the bound reserve at 1:1 face value, net of the redeem fee `tout`.
    /// @dev Fee math: the payout is `amountIn * (1e18 - tout) / 1e18` (floor) rescaled back to the
    ///      reserve's decimals with the same floor; sub-unit rescale dust stays in the PSM and counts as
    ///      fee. `feeOut` is exported as `amountIn - faceValue(payout)`, difference-derived like `feeIn`.
    ///      The native currency is an output leg only: the non-payable signature structurally rejects any
    ///      msg.value (the compiler's implicit callvalue guard reverts before the body runs), so excess
    ///      native cannot strand in the contract and break the reserve conservation identity.
    ///      There is no per-swap flow cap: the hard bound on a single redeem is the reserve balance
    ///      actually held by this PSM (an insufficient balance fails the payout transfer).
    /// @param to Receiver of the reserve payout
    /// @param amountIn uAsset amount to burn, in 18 decimals
    /// @return amountOut Reserve amount paid to `to`, in the bound reserve token's own decimals
    function redeem(address to, uint256 amountIn) external override nonReentrant returns (uint256 amountOut) {
        OutrunPSMStorage storage $ = outrunPSMStorage;
        address reserveToken_ = $.reserveToken;
        if (to == address(0) || amountIn == 0) revert ZeroInput();

        uint256 faceValueOut;
        uint256 scale;
        (faceValueOut, scale, amountOut) = _redeemOutput(reserveToken_, amountIn);
        // Dust guard, symmetric with mint: a payout that floors to zero reserve units must not burn the
        // caller's uAsset for nothing.
        if (amountOut == 0) revert ZeroInput();

        // Both bindings are init-only (no setters); one storage read each serves the pull and the burn.
        address uAsset_ = $.uAsset;
        // Pull the caller's uAsset, then burn it from this contract's own balance (account == msg.sender,
        // so no allowance branch applies on the uAsset side).
        _transferFrom(IERC20(uAsset_), msg.sender, address(this), amountIn);
        IUniversalAssets(uAsset_).reserveBurn(address(this), amountIn);

        // Foreign-minted uAsset (e.g., from the CDP path) can be redeemed here, so cumulative burns may
        // exceed cumulative mints; net minted then saturates at zero — the stock cap bounds net issuance
        // from above and has no floor semantics.
        uint256 netMinted = $.netUAssetMinted;
        $.netUAssetMinted = netMinted > amountIn ? netMinted - amountIn : 0;

        // Fee = burned face value minus the face value paid out (amountOut * scale): the tout fee plus
        // the sub-unit rescale dust that stays in the contract. Difference-derived, never computed apart.
        uint256 feeOut = (amountIn - faceValueOut) + (faceValueOut % scale);
        _transferOut(reserveToken_, to, amountOut);

        emit SwapRedeemForReserve(reserveToken_, to, amountIn, amountOut, feeOut);
    }

    /// @notice Pays out the current accumulated fee surplus to the immutable `feeRecipient`.
    /// @dev Permissionless — anyone may call it; the recipient is fixed at initialization (no
    ///      setter, no parameters). The sweepable amount is the bound-reserve face value held minus
    ///      this instance's net minted uAsset face value — the authoritative measure under mixed
    ///      foreign redemptions: once `netUAssetMinted` saturates to zero, principal left behind by
    ///      foreign redemptions becomes sweepable together with the fees. Net minted can never
    ///      exceed held face value (mints take reserve in 1:1, and payouts/saturation only shrink
    ///      the net side), so the zero-surplus guard below is a fail-closed ZeroInput, not an
    ///      accounting branch. The sweep only drains the surplus: `netUAssetMinted` and the
    ///      stock-cap headroom are untouched, so reserve cover stays >= 100% of net minted.
    ///      Reverts ZeroInput when the sweepable amount floors to zero and NativeTransferFailed
    ///      when a native payout call fails.
    /// @return amountOut Reserve amount paid to `feeRecipient`, in the bound reserve token's own decimals
    function sweepFees() external override nonReentrant returns (uint256 amountOut) {
        OutrunPSMStorage storage $ = outrunPSMStorage;
        address reserveToken_ = $.reserveToken;
        amountOut = _sweepableFees(reserveToken_);
        // Zero guard, symmetric with the swap dust guards: a zero payout must not emit a hollow
        // FeesSwept event; sub-unit face dust (6-dec reserves) that floors to zero stays behind.
        if (amountOut == 0) revert ZeroInput();

        // No ledger write happens here — the payout only drains the fee surplus — so the event is
        // emitted before the external transfer with no state left to manipulate.
        address to = $.feeRecipient;
        emit FeesSwept(reserveToken_, to, amountOut);

        _transferOut(reserveToken_, to, amountOut);
    }

    /// @notice Returns the family uAsset bound to this instance at initialization.
    /// @return uAsset address of the bound uAsset
    function uAsset() external view override returns (address) {
        return outrunPSMStorage.uAsset;
    }

    /// @notice Returns the single reserve token bound to this instance at initialization.
    /// @return reserveToken address of the bound reserve (NATIVE sentinel for the native currency)
    function reserveToken() external view override returns (address) {
        return outrunPSMStorage.reserveToken;
    }

    /// @notice Returns the recipient of `sweepFees` payouts, bound at initialization.
    /// @return feeRecipient address of the fee sweep recipient
    function feeRecipient() external view override returns (address) {
        return outrunPSMStorage.feeRecipient;
    }

    /// @notice Returns the mint-side fee.
    /// @return tin Current mint fee as an 18-dec point value
    function tin() external view override returns (uint256) {
        return outrunPSMStorage.tin;
    }

    /// @notice Returns the redeem-side fee.
    /// @return tout Current redeem fee as an 18-dec point value
    function tout() external view override returns (uint256) {
        return outrunPSMStorage.tout;
    }

    /// @notice Returns the stock cap on this instance's net minted face value.
    /// @return stockCap Current stock cap in 18-dec face value
    function stockCap() external view override returns (uint256) {
        return outrunPSMStorage.stockCap;
    }

    /// @notice Returns this instance's net minted face value (18 decimals).
    /// @return netUAssetMinted Current net minted amount
    function netUAssetMinted() external view override returns (uint256) {
        return outrunPSMStorage.netUAssetMinted;
    }

    /// @notice Deterministic preview of the mint output for a reserve amount.
    /// @dev Fee math only: caps are intentionally excluded so the quote depends solely on the input, the
    ///      fee, and the bound reserve decimals — never on time or reserves held (zero-oracle property).
    /// @param amountIn Reserve amount to preview, in the bound reserve token's own decimals
    /// @return amountOut uAsset the swap would mint, in 18 decimals
    function quoteMint(uint256 amountIn) external view override returns (uint256 amountOut) {
        (, amountOut) = _mintOutput(outrunPSMStorage.reserveToken, amountIn);
    }

    /// @notice Deterministic preview of the redeem payout for a uAsset amount.
    /// @dev Fee math only, same determinism contract as quoteMint.
    /// @param amountIn uAsset amount to preview burning, in 18 decimals
    /// @return amountOut Reserve amount the swap would pay out, in the bound reserve token's own decimals
    function quoteRedeem(uint256 amountIn) external view override returns (uint256 amountOut) {
        (,, amountOut) = _redeemOutput(outrunPSMStorage.reserveToken, amountIn);
    }

    /// @notice Deterministic preview of the `sweepFees` payout: the fee surplus currently sweepable.
    /// @dev Identity with execution: `sweepFees` pays out exactly this amount. Returns 0 where
    ///      `sweepFees` would revert ZeroInput — callers must treat a 0 quote as non-executable.
    ///      A positive quote does not by itself guarantee execution — the payout additionally
    ///      requires `feeRecipient` to accept the bound reserve; a native-leg feeRecipient that
    ///      rejects native receipt reverts `NativeTransferFailed` on every sweep (permanent — the
    ///      recipient is immutable).
    /// @return amountOut Sweepable reserve amount, floored to whole reserve units
    function sweepableFees() external view override returns (uint256 amountOut) {
        amountOut = _sweepableFees(outrunPSMStorage.reserveToken);
    }

    /// @notice Validates upgrade authorization; only the owner may upgrade the implementation.
    /// @dev Both bindings live in namespaced storage and survive upgrades.
    ///      Reverts with `UAssetDecimalsMismatch` if the bound uAsset no longer uses 18 decimals — an
    ///      upgrade-time drift would silently mis-scale every swap after the upgrade.
    function _authorizeUpgrade(address) internal view override onlyOwner {
        uint8 liveDecimals = IERC20Metadata(outrunPSMStorage.uAsset).decimals();
        if (liveDecimals != 18) {
            revert UAssetDecimalsMismatch(18, liveDecimals);
        }
    }

    /// @dev Mint quote helper: shared by `mint` (executor) and `quoteMint` (preview) so the
    ///      quoted amount cannot drift from execution. Fee math is `faceValue * (1e18 - tin) / 1e18`
    ///      with floor rounding; `faceValue` is `amountIn * _faceValueScale`.
    function _mintOutput(address reserveToken_, uint256 amountIn)
        internal
        view
        returns (uint256 faceValue, uint256 amountOut)
    {
        faceValue = amountIn * _faceValueScale(reserveToken_);
        amountOut = Math.mulDiv(faceValue, 1e18 - outrunPSMStorage.tin, 1e18);
    }

    /// @dev Redeem quote helper: shared by `redeem` (executor) and `quoteRedeem` (preview).
    ///      The payout is `amountIn * (1e18 - tout) / 1e18` (floor) rescaled to reserve decimals.
    function _redeemOutput(address reserveToken_, uint256 amountIn)
        internal
        view
        returns (uint256 faceValueOut, uint256 scale, uint256 amountOut)
    {
        faceValueOut = Math.mulDiv(amountIn, 1e18 - outrunPSMStorage.tout, 1e18);
        scale = _faceValueScale(reserveToken_);
        amountOut = faceValueOut / scale;
    }

    /// @dev Scale factor converting a reserve amount to 18-dec face value. The native leg is 18-dec
    ///      (identity). Non-standard reserves without a `decimals()` accessor revert on the call below
    ///      and reserves with more than 18 decimals revert on the subtraction — both fail closed instead
    ///      of silently mispricing the swap.
    function _faceValueScale(address reserveToken_) private view returns (uint256) {
        if (reserveToken_ == NATIVE) return 1;
        return 10 ** (18 - IERC20Metadata(reserveToken_).decimals());
    }

    /// @dev Sweepable-amount helper shared by `sweepFees` (executor) and `sweepableFees` (preview)
    ///      so the quoted amount cannot drift from execution: held bound-reserve face value minus
    ///      net minted uAsset face value, floored to whole reserve units. Net minted never exceeds
    ///      the held face value, so the comparison below only guards the zero-surplus state.
    function _sweepableFees(address reserveToken_) private view returns (uint256) {
        uint256 scale = _faceValueScale(reserveToken_);
        uint256 faceHeld = _selfBalance(reserveToken_) * scale;
        uint256 netMinted = outrunPSMStorage.netUAssetMinted;
        // Sub-unit face dust below one reserve unit floors to zero and stays in the PSM.
        return faceHeld > netMinted ? (faceHeld - netMinted) / scale : 0;
    }

    /// @dev Fees are 18-dec point values (1e18 = 100%); each must sit in [0, 1e16] (0..1%).
    function _requireFeesInRange(uint256 tin_, uint256 tout_) private pure {
        if (tin_ > MAX_FEE || tout_ > MAX_FEE) revert FeeOutOfRange();
    }
}
