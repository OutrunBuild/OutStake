// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IOutrunStakeManager} from "./interfaces/IOutrunStakeManager.sol";
import {IMemeverseLauncher} from "../router/interfaces/IMemeverseLauncher.sol";
import {IStandardizedYield} from "../yield/interfaces/IStandardizedYield.sol";
import {IUniversalAssets} from "../assets/interfaces/IUniversalAssets.sol";
import {SYUtils} from "../libraries/SYUtils.sol";
import {TokenHelper} from "../libraries/TokenHelper.sol";
import {AutoIncrementIdUpgradeable} from "../libraries/AutoIncrementIdUpgradeable.sol";
import {GenesisGateLib} from "../libraries/GenesisGateLib.sol";

/// @notice OutrunStakingPosition manages open-term CDP positions backed by one canonical SY and one
/// uAsset. The only mint entrypoint is `stakeForGenesis`: minted uAsset equals the collateral value
/// at the mint-time exchange rate (value-parity mint, two floored conversion stages, no LTV-style
/// scaling segment), and the mint can only reach the genesis launcher inside the opening
/// transaction (physical gate). Floating interest accrues virtually per second (timestamp-anchored,
/// never by minting) with the RAY value (1e27) as the legal zero-fee sentinel and v1 deployment
/// default; `redeem` repays debt in two legs (principal burn + interest transfer to the treasury)
/// at any time. There is no liquidation, no LTV surface, and no free-borrowing entrypoint.
/// SY = Standardized Yield token. uAsset = universal asset receipt token.
/// The contract converts between SY and uAsset using the SY's exchange rate, then rescales across
/// decimal domains.
// solhint-disable-next-line gas-small-strings
contract OutrunStakingPositionUpgradeable layout at erc7201("outrun.storage.OutrunStakingPosition")
    is
    IOutrunStakeManager,
    AutoIncrementIdUpgradeable,
    TokenHelper,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    struct OutrunStakingPositionStorage {
        address SY;
        uint8 canonicalAssetDecimals;
        uint8 uAssetDecimals;
        address uAsset;
        address protocolTreasury;
        uint256 minStake;
        uint256 duty;
        uint256 rate;
        uint256 rateLastSettledAt;
        address genesisLauncher;
        mapping(uint256 positionId => Position) positions;
    }

    // RAY fixed-point base (1e27) for `duty` and `rate`; RAY itself is the zero-fee sentinel.
    uint256 internal constant RAY = 1e27;
    // Absolute cap on `duty` (15% annual equivalent per-second rate).
    uint256 private constant DUTY_CAP = 1000000004431822129783699001;

    OutrunStakingPositionStorage private outrunStakingPositionStorage;

    // solhint-disable-next-line unwrapped-modifier-logic
    modifier onlyPositionOwner(uint256 positionId) {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        if (position.owner == address(0) || position.owner != msg.sender) revert PositionAccessDenied();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the staking position contract with the owner-governed parameter set.
    /// Conversion math assumes SY assetInfo() and uAsset decimals are immutable after initialization.
    /// @dev Init has no prior values, so no ratchet checks run — only the same bounds and zero-value
    /// guards the setters enforce. SY and uAsset are fixed after initialize.
    /// @param owner_ Owner address for the Ownable access-control module.
    /// @param sy_ Address of the Standardized Yield token accepted by this contract.
    /// @param uAsset_ Address of the universal asset receipt token.
    /// @param protocolTreasury_ Address receiving redeem interest legs.
    /// @param minStake_ Minimum SY amount per stake operation (must be > 0).
    /// @param duty_ Per-second rate in RAY within [1e27, DUTY_CAP]; 1e27 is the zero-fee sentinel
    /// and the v1 deployment default.
    /// @dev `genesisLauncher` is NOT an initialize parameter: it stays at the zero default
    /// (the `stakeForGenesis` entrypoint is disabled) and is wired post-deploy via
    /// `setGenesisLauncher`.
    function initialize(
        address owner_,
        address sy_,
        address uAsset_,
        address protocolTreasury_,
        uint256 minStake_,
        uint256 duty_
    ) external initializer {
        if (
            owner_ == address(0) || sy_ == address(0) || uAsset_ == address(0) || protocolTreasury_ == address(0)
                || minStake_ == 0
        ) {
            revert ZeroInput();
        }
        // Sub-RAY duty (a negative-rate domain, zero included) is rejected wholesale so the
        // cumulative rate can never move backwards; RAY itself is the zero-fee sentinel, a legal
        // offered rate and the v1 default (pause is the circuit breaker, not a zero fee).
        if (duty_ < RAY) revert ZeroInput();
        if (duty_ > DUTY_CAP) revert DutyCap(duty_);

        __AutoIncrementId_init();
        __Pausable_init();
        __Ownable_init(owner_);

        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        (,, uint8 canonicalAssetDecimals) = IStandardizedYield(sy_).assetInfo();
        $.SY = sy_;
        $.uAsset = uAsset_;
        $.canonicalAssetDecimals = canonicalAssetDecimals;
        $.uAssetDecimals = IERC20Metadata(uAsset_).decimals();
        $.protocolTreasury = protocolTreasury_;
        $.minStake = minStake_;
        $.duty = duty_;
        // The init timestamp is the first settlement baseline: the first touch after initialize
        // accrues from here, and the cumulative rate starts at RAY (1e27).
        $.rate = RAY;
        $.rateLastSettledAt = block.timestamp;
    }

    // --------------------------------------------------------------------------
    // State-changing user entrypoints
    // --------------------------------------------------------------------------

    /// @notice Opens a CDP position and hands the minted uAsset to the genesis launcher inside the
    /// same transaction (the physical genesis gate). This is the only mint entrypoint.
    /// @dev Value-parity pricing: the minted amount is the SY collateral converted
    /// SY -> canonical asset -> uAsset with both stages floored — no LTV scaling segment. The two
    /// floors are the sole construction source of the backing invariant: minted debt is strictly
    /// <= the collateral value at the mint-time exchange rate. The minted uAsset never leaves
    /// through the owner or any third party: it is minted to the SP itself, approved to
    /// `genesisLauncher` for exactly the minted amount, and consumed by
    /// `IMemeverseLauncher.genesis` within this transaction. The physical gate is the
    /// post-assertion: partial consumption, a transfer-back, or any residue reverts the whole
    /// transaction — the position and the mint vanish together. The mint draws on this contract's
    /// minter record (`ReachMintCap` propagates; no exemption), so `amountInMinted` grows by the
    /// minted amount. `verseId` is launcher-opaque and forwarded unchanged; a launcher-side revert
    /// is a dependency boundary and rolls everything back. After the gate the position is an
    /// ordinary CDP position (redeem two-leg repayment, per-second accrual — zero interest under
    /// the default duty).
    /// @param amountInSY SY amount to stake. Must be > 0 and >= minStake.
    /// @param positionOwner Address that will own the position (redeem rights) and the user
    /// credited by the launcher.
    /// @param verseId Opaque launcher-assigned identifier for the target verse; not validated.
    /// @param minUAssetMinted Minimum acceptable minted uAsset; `0` means no slippage protection.
    /// @return positionId The newly created position identifier.
    function stakeForGenesis(uint256 amountInSY, address positionOwner, uint256 verseId, uint256 minUAssetMinted)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        // Entry guards before any funds move or state changes. The launcher gate is the kill
        // switch: the zero default (or an owner reset to zero) disables this entrypoint entirely.
        address launcher = $.genesisLauncher;
        if (launcher == address(0)) revert GenesisLauncherNotSet();
        if (amountInSY == 0 || positionOwner == address(0)) revert ZeroInput();
        _validateMinStake(amountInSY);
        address _SY = $.SY;
        // Value-parity quote: both conversion stages floor, so the mint never exceeds the
        // collateral value (backing invariant) and dust inputs floor to zero here.
        uint256 mintedUAsset = _syToAsset(amountInSY, _currentExchangeRate(_SY));
        if (mintedUAsset == 0) revert DustRoundedToZero();
        // Caller floor and the launcher's uint128 amount domain, checked before any allowance is
        // granted (domain check lives in GenesisGateLib so both genesis gates share it).
        if (mintedUAsset < minUAssetMinted) revert InsufficientUAssetMinted(mintedUAsset, minUAssetMinted);
        GenesisGateLib.requireLauncherAmount(mintedUAsset);
        positionId = _openPosition(_SY, amountInSY, positionOwner, mintedUAsset);

        // Baseline snapshot before the mint keeps pre-existing donated dust outside the
        // post-assertion domain below (the gate asserts a return to THIS baseline, not to zero).
        address uAsset_ = $.uAsset;
        uint256 baseline = IERC20(uAsset_).balanceOf(address(this));
        // Normal minter-ledger accounting: amountInMinted grows by the minted amount and
        // ReachMintCap propagates — genesis mints get no PSM-style exemption.
        IUniversalAssets(uAsset_).mint(address(this), mintedUAsset);
        // Exact approval of exactly the minted amount: the launcher can pull at most this, never
        // any pre-existing SP balance, and a uint256.max infinite approval is impossible because
        // mintedUAsset is already bounded by type(uint128).max above.
        _safeApprove(uAsset_, launcher, mintedUAsset);
        IMemeverseLauncher(launcher).genesis(verseId, uint128(mintedUAsset), positionOwner);

        GenesisGateLib.assertFullConsumption(uAsset_, launcher, baseline);

        emit Stake(positionId, positionOwner, amountInSY, mintedUAsset);
        emit StakeForGenesis(positionId, positionOwner, verseId, mintedUAsset);
    }

    /// @notice Redeems SY collateral by repaying the position's debt in two legs, at any time.
    /// @dev Position-owner path, no maturity gate. Settlement touchpoint: pending interest is
    /// settled before the legs are split — in memory on a full redeem (the position is deleted
    /// right after, so a settle write would be paid and immediately cleared) and into
    /// accruedInterest on a partial redeem. Full redeem repays the exact remaining legs;
    /// partial redeem ceils both legs pro-rata and must leave principal debt. Repayment order
    /// (interest first): the interest leg transfers uAsset from the caller to the protocol treasury
    /// (skipped when zero; never burned, never touching the minter ledger), then the principal leg
    /// goes through `uAsset.repay(msg.sender, principalPortion)` which burns the caller's balance
    /// and reduces the SP minter's amountInMinted. Caller prerequisite: hold and approve this
    /// contract at least `principalPortion + interestPortion` uAsset — both legs share that
    /// allowance; shortfall reverts atomically with the dependency's error. Direct SY output
    /// enforces minTokenOut locally; other tokens go through SY.redeem. The direct-SY output path
    /// never reads the exchange rate: the owner exit channel stays oracle-independent.
    /// @param positionId The position identifier.
    /// @param syRedeemed Amount of SY collateral to redeem.
    /// @param receiver Address that receives the redemption proceeds.
    /// @param tokenOut Desired output token (SY itself or another token via SY.redeem).
    /// @param minTokenOut Minimum acceptable amount of tokenOut (slippage protection).
    /// @return principalBurned uAsset amount burned by the principal leg.
    /// @return interestPaid uAsset amount transferred to the treasury by the interest leg.
    /// @return amountTokenOut Amount of tokenOut delivered to the receiver.
    function redeem(uint256 positionId, uint256 syRedeemed, address receiver, address tokenOut, uint256 minTokenOut)
        external
        nonReentrant
        whenNotPaused
        onlyPositionOwner(positionId)
        returns (uint256 principalBurned, uint256 interestPaid, uint256 amountTokenOut)
    {
        if (receiver == address(0)) revert ZeroInput();
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        Position storage position = $.positions[positionId];
        uint256 syStaked = position.syStaked;
        _validateRedeemAmount(syStaked, syRedeemed);

        // Settlement touchpoint: accrue pending interest before splitting the two legs. A full
        // redeem deletes the position below, so the settle write would be paid and immediately
        // cleared; compute the identical settled interest in memory instead (the settled rate
        // equals `currentRate()` at this point, matching what `previewRedeem` quotes).
        uint256 settledRate = _settleRateToNow();
        uint256 settledInterest;
        if (syRedeemed == syStaked) {
            settledInterest = position.accruedInterest + _unsettledIncrement(position, settledRate);
        } else {
            _settlePositionInterest(position, settledRate);
            settledInterest = position.accruedInterest;
        }
        (principalBurned, interestPaid) =
            _computeRedeemLegs(position.principalDebt, settledInterest, syRedeemed, syStaked);

        address _SY = $.SY;
        // Direct SY redemption bypasses SY.redeem, so enforce minTokenOut here.
        if (tokenOut == _SY && syRedeemed < minTokenOut) revert InsufficientTokenOut(syRedeemed, minTokenOut);

        // CEI: reduce or delete the position before any external repayment/output call so external
        // observers never see repaid debt paired with stale position state.
        _applyPositionRedeem(positionId, position, syRedeemed, syStaked, principalBurned, interestPaid);

        // Repay both legs — interest to treasury first, then principal via repay (shared allowance).
        _repayTwoLegs(interestPaid, principalBurned);

        // Release SY directly or redeem through the SY adapter into tokenOut.
        amountTokenOut = _redeemTokenOut(_SY, receiver, tokenOut, syRedeemed, minTokenOut);

        emit Redeem(
            positionId, msg.sender, syRedeemed, principalBurned, interestPaid, receiver, tokenOut, amountTokenOut
        );
    }

    // --------------------------------------------------------------------------
    // Owner-governed parameter setters and circuit breaker
    // --------------------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Adjusts the per-second duty with segmented effect.
    /// @dev Validates first (sub-RAY and cap), then settles the cumulative rate to the current
    ///     timestamp under the old duty before storing the new one: seconds before this call accrue
    ///     at the old duty, later seconds at the new duty, and positions need no migration.
    ///     The RAY value (1e27) is the zero-fee sentinel — a legal, settable rate.
    function setDuty(uint256 newDuty) external onlyOwner {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        // Sub-RAY duty (negative-rate domain, zero included) is rejected wholesale so the
        // cumulative rate can never move backwards; RAY (the zero-fee sentinel) is legal.
        if (newDuty < RAY) revert ZeroInput();
        if (newDuty > DUTY_CAP) revert DutyCap(newDuty);
        uint256 currentDuty = $.duty;

        // Segment boundary: settle pending seconds at the old duty before the new duty applies.
        _settleRateToNow();
        emit SetDuty(currentDuty, newDuty);
        $.duty = newDuty;
    }

    /// @notice Updates the genesis launcher target of `stakeForGenesis`.
    /// @dev Owner-only; accepts any address including zero — zero is the deployment default and
    /// the kill-switch value that disables the entrypoint. No code-size validation runs here
    /// (dependency level mirrors `setProtocolTreasury`); runtime safety comes from the strict
    /// full-consumption post-condition inside `stakeForGenesis`.
    /// Operational invariant: `genesisLauncher` must equal `OutrunRouter.memeverseLauncher()` for the two genesis
    /// gates to target one launcher; a single-side rotation makes router path-B entries and previews revert
    /// fail-closed (`GenesisLauncherMismatch`), while the residual silent surface is router path-A (router launcher)
    /// versus direct-SP (SP launcher) targeting different launchers. Rotation must be atomic with
    /// `router.setMemeverseLauncher` in the same governance transaction and verified via
    /// `genesisLauncher() == router.memeverseLauncher()`.
    function setGenesisLauncher(address genesisLauncher_) external onlyOwner {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        emit SetGenesisLauncher($.genesisLauncher, genesisLauncher_);
        $.genesisLauncher = genesisLauncher_;
    }

    function setMinStake(uint256 minStake_) external onlyOwner {
        if (minStake_ == 0) revert ZeroInput();
        outrunStakingPositionStorage.minStake = minStake_;
        emit SetMinStake(minStake_);
    }

    /// @notice Updates the treasury receiving redeem interest legs.
    /// @dev Sole destination change path for interest; changing it never requires an upgrade.
    function setProtocolTreasury(address protocolTreasury_) external onlyOwner {
        if (protocolTreasury_ == address(0)) revert ZeroInput();
        outrunStakingPositionStorage.protocolTreasury = protocolTreasury_;
        emit SetProtocolTreasury(protocolTreasury_);
    }

    // --------------------------------------------------------------------------
    // Preview family (quote-only; mirrors executor failure surfaces)
    // --------------------------------------------------------------------------

    /// @notice Previews how much uAsset a genesis open would mint.
    /// @dev Quote-only: reads the exchange rate and runs the executor's exact value-parity pricing
    /// (two floored stages), but does not reserve mint cap, transfer SY, or create a position.
    /// Dust divergence is intentional: preview returns 0 where floor conversion zeroes the output
    /// while `stakeForGenesis` reverts `DustRoundedToZero` for the same input, so callers must not
    /// treat a 0 return as stakeable. A zero rate reverts `ZeroExchangeRate` at the rate-reading
    /// home. Genesis-specific executor guards (`minUAssetMinted`, uint128 bound, launcher gate,
    /// full-consumption assertion) are not visible here.
    /// @param amountInSY The SY amount to stake.
    /// @return UAssetMintable Quoted uAsset amount that would be minted; 0 if floor conversion
    /// zeroes it. Named distinctly from the executor's `mintedUAsset` return to keep quote and
    /// actual-minted separate at call sites.
    function previewStake(uint256 amountInSY) external view returns (uint256 UAssetMintable) {
        if (amountInSY == 0) revert ZeroInput();
        _validateMinStake(amountInSY);
        UAssetMintable = _syToAsset(amountInSY, _currentExchangeRate(SY()));
    }

    /// @notice Previews a position redemption's two repayment legs and token output.
    /// @dev Quote-only mirror of `redeem`: same existence/amount guards and the exact same leg
    /// split (the shared pure `_computeRedeemLegs`), with interest extrapolated to the current
    /// timestamp (no state writes). Direct-SY output never reads the exchange rate — the owner exit
    /// channel is oracle-independent by design. Caller identity is not checked (it is an executor
    /// guard).
    /// @param positionId The position identifier.
    /// @param syRedeemed Amount of SY collateral to redeem.
    /// @param tokenOut Desired output token (SY itself or another token via SY.redeem).
    /// @return principalPortion Principal leg that would be burned.
    /// @return interestPortion Interest leg that would be transferred to the treasury.
    /// @return amountTokenOut Token output the receiver would receive.
    function previewRedeem(uint256 positionId, uint256 syRedeemed, address tokenOut)
        external
        view
        returns (uint256 principalPortion, uint256 interestPortion, uint256 amountTokenOut)
    {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        Position storage position = $.positions[positionId];
        if (position.owner == address(0)) revert PositionAccessDenied();
        uint256 syStaked = position.syStaked;
        _validateRedeemAmount(syStaked, syRedeemed);

        (principalPortion, interestPortion) =
            _computeRedeemLegs(position.principalDebt, _extrapolatedInterest(position), syRedeemed, syStaked);
        amountTokenOut = _previewTokenOut($.SY, tokenOut, syRedeemed);
    }

    // --------------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------------

    /// @notice Returns the Standardized Yield token address.
    function SY() public view returns (address) {
        return outrunStakingPositionStorage.SY;
    }

    /// @notice Returns the universal asset receipt token address.
    function uAsset() public view returns (address) {
        return outrunStakingPositionStorage.uAsset;
    }

    /// @notice Returns the minimum SY amount required per stake operation.
    function minStake() public view returns (uint256) {
        return outrunStakingPositionStorage.minStake;
    }

    /// @notice Returns the treasury address receiving interest legs.
    function protocolTreasury() public view returns (address) {
        return outrunStakingPositionStorage.protocolTreasury;
    }

    /// @notice Returns the per-second duty in RAY (1e27 = zero-fee sentinel, the v1 default).
    function duty() public view returns (uint256) {
        return outrunStakingPositionStorage.duty;
    }

    /// @notice Returns the genesis launcher target of `stakeForGenesis`; zero means the
    /// entrypoint is disabled.
    function genesisLauncher() public view returns (address) {
        return outrunStakingPositionStorage.genesisLauncher;
    }

    /// @notice Returns the settled cumulative rate (stored value).
    function rate() public view returns (uint256) {
        return outrunStakingPositionStorage.rate;
    }

    /// @notice Returns the timestamp of the last rate settlement.
    function rateLastSettledAt() public view returns (uint256) {
        return outrunStakingPositionStorage.rateLastSettledAt;
    }

    /// @notice Returns the cumulative rate extrapolated to the current timestamp without writing state.
    /// @dev Same formula as the settlement touchpoints (shared `_rpow`/`_rmul`), so same-second
    ///      preview and execution agree. At the zero-fee duty (1e27) the stored rate never moves
    ///      and this always equals it.
    function currentRate() public view returns (uint256) {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        // block.timestamp >= rateLastSettledAt always holds (it is only ever set to the
        // then-current timestamp), so the delta is never negative.
        return _rmul(_rpow($.duty, block.timestamp - $.rateLastSettledAt), $.rate);
    }

    /// @notice Returns the stored data for a staking position.
    /// @param positionId The position identifier.
    /// @return owner Position owner address.
    /// @return syStaked SY collateral currently staked in the position.
    /// @return principalDebt Minted principal debt in uAsset units (= the genesis mint amount).
    /// @return accruedInterest Settled unpaid interest in uAsset units.
    /// @return lastRate Rate snapshot at the position's last settlement.
    function positions(uint256 positionId)
        public
        view
        returns (address owner, uint256 syStaked, uint256 principalDebt, uint256 accruedInterest, uint256 lastRate)
    {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        return (position.owner, position.syStaked, position.principalDebt, position.accruedInterest, position.lastRate);
    }

    /// @notice Returns the position's unsettled interest extrapolated to the current timestamp.
    /// @dev Read-only accrual; zero for a missing/deleted position id. Under the zero-fee duty
    ///      (1e27) the rate never advances, so this is identically zero.
    function pendingInterest(uint256 positionId) public view returns (uint256) {
        // Pure accrual since the last settlement snapshot; the settled accruedInterest balance
        // is excluded so this stays the unsettled increment only.
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        return _unsettledIncrement(position, currentRate());
    }

    /// @notice Returns the position's total debt: principal + settled interest + pending interest,
    ///      extrapolated to the current timestamp.
    function positionDebt(uint256 positionId) public view returns (uint256) {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        // principal + settled interest + unsettled increment: `_extrapolatedInterest` already
        // carries accruedInterest, so it must not be added a second time.
        return position.principalDebt + _extrapolatedInterest(position);
    }

    // --------------------------------------------------------------------------
    // Open-position, interest settlement and split helpers
    // --------------------------------------------------------------------------

    /// @dev Open-position core for `stakeForGenesis`: pull the SY from the caller, settle the
    ///      SP cumulative rate to the opening second, then write the five-field Position with
    ///      `principalDebt = mintedUAsset`. Guards, events, and the mint/gate tail stay with the
    ///      caller.
    function _openPosition(address _SY, uint256 amountInSY, address positionOwner, uint256 principalDebt)
        internal
        returns (uint256 positionId)
    {
        _transferIn(_SY, msg.sender, amountInSY);
        // Open-position settlement: advance the SP rate first, then snapshot it, so the new
        // position does not inherit interest accrued before it existed.
        uint256 settledRate = _settleRateToNow();
        positionId = _nextId();
        outrunStakingPositionStorage.positions[positionId] = Position({
            owner: positionOwner,
            syStaked: amountInSY,
            principalDebt: principalDebt,
            accruedInterest: 0,
            lastRate: settledRate
        });
    }

    /// @dev Advances the stored cumulative rate to the current timestamp and returns the settled value.
    ///      Idempotent within the same second (a zero delta skips the write) and on an unchanged
    ///      compounded value (the store is skipped so no same-value write is paid); the compounding
    ///      step is the shared `_rpow`/`_rmul` closed form, identical to the `currentRate`
    ///      extrapolation. At the zero-fee duty (1e27) `rpow` is the identity, so the rate never
    ///      moves.
    function _settleRateToNow() internal returns (uint256) {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        uint256 deltaSeconds = block.timestamp - $.rateLastSettledAt;
        if (deltaSeconds != 0) {
            // A same-value store costs 100 gas and changes no state: only the zero-fee duty can
            // compound to the stored value (any duty above 1e27 strictly raises the rate).
            uint256 newRate = _rmul(_rpow($.duty, deltaSeconds), $.rate);
            if (newRate != $.rate) {
                $.rate = newRate;
            }
            $.rateLastSettledAt = block.timestamp;
        }
        return $.rate;
    }

    /// @dev Adds the pending interest since the position's last snapshot to its accrued balance.
    /// @param position The position to settle (storage reference).
    /// @param settledRate The cumulative rate already settled to the current timestamp by the caller.
    function _settlePositionInterest(Position storage position, uint256 settledRate) internal {
        if (settledRate != position.lastRate) {
            position.accruedInterest += _unsettledIncrement(position, settledRate);
            position.lastRate = settledRate;
        }
    }

    /// @dev Applies the redemption to the position before any external call (CEI). Full redeem
    /// deletes the position (the id becomes an observable hole and is never reused); partial
    /// redeem reduces collateral and both debt fields, leaving interest to accrue on the new
    /// principal from the just-settled snapshot.
    function _applyPositionRedeem(
        uint256 positionId,
        Position storage position,
        uint256 syRedeemed,
        uint256 syStaked,
        uint256 principalPortion,
        uint256 interestPortion
    ) internal {
        if (syRedeemed == syStaked) {
            delete outrunStakingPositionStorage.positions[positionId];
            return;
        }
        position.syStaked = syStaked - syRedeemed;
        position.principalDebt -= principalPortion;
        position.accruedInterest -= interestPortion;
    }

    /// @dev Repays the two debt legs in the canonical order (interest first).
    /// Interest is a circulating transfer to the treasury (skipped when zero, never touches
    /// the minter ledger); principal is burned via `uAsset.repay` and reduces the SP minter's
    /// `amountInMinted`. Both legs share the caller's allowance on this contract. Caches
    /// `$.uAsset` for its two uses; `$.protocolTreasury` is read only when the interest leg
    /// is non-zero, so zero-interest redeems never pay the storage read.
    function _repayTwoLegs(uint256 interestPortion, uint256 principalPortion) internal {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        address uAsset_ = $.uAsset;
        if (interestPortion != 0) {
            _transferFrom(IERC20(uAsset_), msg.sender, $.protocolTreasury, interestPortion);
        }
        IUniversalAssets(uAsset_).repay(msg.sender, principalPortion);
    }

    function _redeemTokenOut(address _SY, address receiver, address tokenOut, uint256 syRedeemed, uint256 minTokenOut)
        internal
        returns (uint256 amountTokenOut)
    {
        if (tokenOut == _SY) {
            // The receiver asked for SY itself, so transfer the redeemed SY without adapter conversion.
            amountTokenOut = syRedeemed;
            _transferOut(_SY, receiver, syRedeemed);
        } else {
            // Any other tokenOut must be produced by the SY adapter's redeem path.
            amountTokenOut = IStandardizedYield(_SY).redeem(receiver, syRedeemed, tokenOut, minTokenOut, false);
        }
    }

    /// @notice UUPS upgrade guard that enforces decimals immutability.
    /// @dev Reverts with `DecimalsMismatch` if live `SY.assetInfo().assetDecimals` or `uAsset.decimals()` diverges from the values cached at `initialize`; such divergence would silently mis-scale every sy<->uAsset conversion by 10**delta and brick debt accounting. The divergence must be resolved by redeploying SY + position rather than upgrading in place.
    function _authorizeUpgrade(address) internal override onlyOwner {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        (,, uint8 liveCanonical) = IStandardizedYield($.SY).assetInfo();
        uint8 liveUAsset = IERC20Metadata($.uAsset).decimals();
        uint8 cachedCanonical = $.canonicalAssetDecimals;
        uint8 cachedUAsset = $.uAssetDecimals;
        if (liveCanonical != cachedCanonical || liveUAsset != cachedUAsset) {
            revert DecimalsMismatch(cachedCanonical, liveCanonical, cachedUAsset, liveUAsset);
        }
    }

    /// @dev Read-only counterpart of `_settlePositionInterest`: settled interest plus the
    /// extrapolated pending increment, without touching storage.
    function _extrapolatedInterest(Position storage position) internal view returns (uint256) {
        return position.accruedInterest + _unsettledIncrement(position, currentRate());
    }

    // --------------------------------------------------------------------------
    // Conversion helpers (mixed-decimals rescaling)
    // --------------------------------------------------------------------------

    // `canonicalAssetValue` follows `SY.assetInfo().assetDecimals`.
    // `uAssetDebtUnits` follows `uAsset.decimals()`.
    // These helpers convert using the caller-supplied exchange rate and then rescale across the two decimal domains.

    /// @notice Reads the SY exchange rate at a single place.
    /// @dev Every conversion site below obtains the rate through this function, so the zero-rate
    /// guard lives here (one home), and a future change to the rate-reading convention (caching)
    /// also has one home instead of inline copies. Oracle-backed SY variants propagate their own
    /// named rate-validation errors here unchanged (fail-closed) — with no LTV/liquidation surface,
    /// this stack is the only on-chain guard of backing integrity: an inflated rate would over-mint
    /// at value parity.
    /// Callers pass the already-resolved SY address to avoid re-reading the SY storage slot.
    /// @param _SY The Standardized Yield token address.
    function _currentExchangeRate(address _SY) internal view returns (uint256) {
        uint256 syRate = IStandardizedYield(_SY).exchangeRate();
        // Zero rate means the external SY is reporting a broken state; fail closed with a named
        // error here (the single rate-reading home) instead of leaking a division panic or a
        // misleading dust/nothing error into any conversion path.
        // Chain-side guard is only `syRate != 0`; drift monitoring is off-chain.
        if (syRate == 0) revert ZeroExchangeRate();
        return syRate;
    }

    /// @dev Converts SY collateral to uAsset-denominated value with both stages floored. The
    /// double floor is the construction source of the backing invariant: the minted debt never
    /// exceeds the collateral value at the mint-time rate.
    /// Domain: wad-only (1e18) via SYUtils.ONE; never WadRayMath.RAY (1e27) — ray is for AaveAdapterLib only.
    /// @param amountInSY The SY amount to convert.
    /// @param exchangeRate_ The SY exchange rate, 1e18-scaled, read once by the caller and passed in.
    function _syToAsset(uint256 amountInSY, uint256 exchangeRate_) internal view returns (uint256) {
        uint256 canonicalAssetValue = SYUtils.syToAsset(exchangeRate_, amountInSY);
        return _scaleCanonicalAssetToUAsset(canonicalAssetValue);
    }

    /// @dev Rescales from canonical asset decimals (e.g. 18 for ETH) to uAsset decimals (e.g. 6 for USDC-denominated uAsset).
    function _scaleCanonicalAssetToUAsset(uint256 amount) internal view returns (uint256) {
        (uint8 canonicalAssetDecimals, uint8 uAssetDecimals) = _cachedAssetDecimals();
        if (uAssetDecimals >= canonicalAssetDecimals) {
            return amount * 10 ** (uAssetDecimals - canonicalAssetDecimals);
        }
        return amount / 10 ** (canonicalAssetDecimals - uAssetDecimals);
    }

    function _cachedAssetDecimals() internal view returns (uint8 canonicalAssetDecimals, uint8 uAssetDecimals) {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        return ($.canonicalAssetDecimals, $.uAssetDecimals);
    }

    // --------------------------------------------------------------------------
    // Shared validation and output helpers
    // --------------------------------------------------------------------------

    function _validateMinStake(uint256 amountInSY) internal view {
        uint256 minStake_ = minStake();
        if (amountInSY < minStake_) revert MinStakeInsufficient(minStake_);
    }

    function _previewTokenOut(address _SY, address tokenOut, uint256 amountInSY)
        internal
        view
        returns (uint256 amountTokenOut)
    {
        if (tokenOut == _SY) {
            // Previewing direct SY output is just the same SY amount.
            amountTokenOut = amountInSY;
        } else {
            // Adapter preview handles non-SY token conversion.
            amountTokenOut = IStandardizedYield(_SY).previewRedeem(tokenOut, amountInSY);
        }
    }

    /// @dev Unsettled interest increment since the position's last rate snapshot, evaluated at a
    /// caller-supplied cumulative rate. Callers pass the already-resolved rate (`currentRate()` on
    /// read paths, the caller-settled rate on write paths) so each path resolves it exactly once.
    /// Adds no `accruedInterest` and writes no state; accumulation and snapshot writes stay with the
    /// caller.
    function _unsettledIncrement(Position storage position, uint256 rate_) internal view returns (uint256) {
        return _interestDelta(position.principalDebt, rate_ - position.lastRate);
    }

    /// @dev Interest increment on the RAY compounding delta: one full-precision product, then a
    /// single floored division by RAY (1e27, the compounding increment domain). Interest accrues
    /// on principal only — accrued interest never compounds and the minted principal is constant
    /// between partial redeems. Overflow envelope: principal is bounded by the genesis mint's
    /// uint128 domain (~3.4e38), and the rate delta is fail-closed upstream: the cumulative
    /// rate can never reach ~1.16e50 (a ~1.16e23 compounding factor over RAY) because advancing
    /// it through `rmul`/`rpow` reverts there first. The product stays below 2^256 outright only
    /// while principal is at or below RAY (1e27); beyond that, safety rests on the duty cap
    /// (~15% annualized) keeping that rate ceiling unreachable over any unsettled span — widening
    /// either bound invalidates this envelope and both must be re-checked together.
    function _interestDelta(uint256 principalDebt, uint256 deltaRate) internal pure returns (uint256) {
        return principalDebt * deltaRate / RAY;
    }

    /// @dev Splits the repayment legs for a redemption from already-settled values. Full redeem
    /// (syRedeemed == syStaked) returns the exact remaining legs; partial redeem ceils both legs
    /// pro-rata so rounded debt dust cannot stay stranded on the remaining position, and rejects
    /// any partial that would consume all remaining principal — such exits must go through a full
    /// redeem. Pure and by-value so `redeem` and `previewRedeem` share one split: the quote is the
    /// executor's math by construction, never a copy that can drift.
    function _computeRedeemLegs(uint256 principalDebt, uint256 interest, uint256 syRedeemed, uint256 syStaked)
        internal
        pure
        returns (uint256 principalPortion, uint256 interestPortion)
    {
        if (syRedeemed == syStaked) {
            return (principalDebt, interest);
        }
        principalPortion = Math.mulDiv(principalDebt, syRedeemed, syStaked, Math.Rounding.Ceil);
        if (principalPortion >= principalDebt) revert PartialRedeemMustLeaveDebt();
        // Ceil of a fraction of an integer with syRedeemed <= syStaked never exceeds that integer,
        // so the subtraction in _applyPositionRedeem cannot underflow.
        interestPortion = Math.mulDiv(interest, syRedeemed, syStaked, Math.Rounding.Ceil);
    }

    function _validateRedeemAmount(uint256 syStaked, uint256 syRedeemed) internal pure {
        if (syRedeemed == 0) revert ZeroInput();
        if (syRedeemed > syStaked) revert ExceedsPositionBalance(syRedeemed, syStaked);
    }

    /// @dev RAY multiplication with a single truncation: `x * y / RAY` floored once.
    function _rmul(uint256 x, uint256 y) private pure returns (uint256) {
        return (x * y) / RAY;
    }

    /// @dev Compounding factor `x^n` in RAY, ported from the MakerDAO `rpow` assembly routine:
    /// exponentiation-by-squaring where every intermediate multiply divides by RAY with
    /// round-half-up (`add(half)` with `half = RAY / 2` before `div`), while the outer `_rmul`
    /// applies a single truncation. Overflow and addition-carry checks revert on failure. At the
    /// zero-fee duty (1e27) this is the identity for every exponent.
    function _rpow(uint256 x, uint256 n) private pure returns (uint256 z) {
        // Zero-fee fast path: RAY is the identity for every exponent, so skip the loop.
        if (x == RAY) return RAY;
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := 1000000000000000000000000000 }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := 1000000000000000000000000000 }
                default { z := x }
                let half := div(1000000000000000000000000000, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, 1000000000000000000000000000)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if iszero(eq(div(zx, z), x)) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, 1000000000000000000000000000)
                    }
                }
            }
        }
    }
}
