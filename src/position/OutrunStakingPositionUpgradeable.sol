// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IOutrunStakeManager} from "./interfaces/IOutrunStakeManager.sol";
import {IStandardizedYield} from "../yield/interfaces/IStandardizedYield.sol";
import {IUniversalAssets} from "../assets/interfaces/IUniversalAssets.sol";
import {SYUtils} from "../libraries/SYUtils.sol";
import {TokenHelper} from "../libraries/TokenHelper.sol";
import {AutoIncrementIdUpgradeable} from "../libraries/AutoIncrementIdUpgradeable.sol";

/// @notice OutrunStakingPosition manages two staking paths:
/// (a) locked positions with ids and deadlines, and
/// (b) a shared wrap pool with no per-user records.
/// SY = Standardized Yield token.
/// uAsset = universal asset receipt token.
/// The contract converts between SY and uAsset using the SY's exchange rate,
/// then rescales across decimal domains.
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
        uint256 minStake;
        uint256 syTotalStaking;
        uint256 syWrapStaking;
        uint256 wrapUAssetDebt;
        address uAsset;
        address revenuePool;
        address keeper;
        mapping(uint256 positionId => Position) positions;
    }

    OutrunStakingPositionStorage private outrunStakingPositionStorage;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the staking position contract with required parameters.
    /// Conversion math assumes SY assetInfo() and uAsset decimals are immutable after initialization.
    /// @param owner_ Owner address for the Ownable access-control module.
    /// @param minStake_ Minimum SY amount per stake operation.
    /// @param revenuePool_ Address that receives harvested wrap-pool yield.
    /// @param sy_ Address of the Standardized Yield token accepted by this contract.
    /// @param uAsset_ Address of the universal asset receipt token.
    /// @param keeper_ Address authorized to call keeper-only `keepRedeem` on matured positions and
    ///        `keepWrapRedeem` for shared wrap-pool SY.
    function initialize(
        address owner_,
        uint256 minStake_,
        address revenuePool_,
        address sy_,
        address uAsset_,
        address keeper_
    ) external initializer {
        if (
            owner_ == address(0) || revenuePool_ == address(0) || sy_ == address(0) || uAsset_ == address(0)
                || keeper_ == address(0)
        ) {
            revert ZeroInput();
        }
        __AutoIncrementId_init();
        __Pausable_init();
        __Ownable_init(owner_);

        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        (,, uint8 canonicalAssetDecimals) = IStandardizedYield(sy_).assetInfo();
        $.SY = sy_;
        $.uAsset = uAsset_;
        // Conversion math assumes SY assetInfo() and uAsset decimals are immutable after initialization.
        $.canonicalAssetDecimals = canonicalAssetDecimals;
        $.uAssetDecimals = IERC20Metadata(uAsset_).decimals();
        $.minStake = minStake_;
        $.revenuePool = revenuePool_;
        $.keeper = keeper_;
    }

    // solhint-disable-next-line unwrapped-modifier-logic
    modifier onlyPositionOwner(uint256 positionId) {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        // Only the recorded owner can act on this position.
        if (position.owner == address(0) || position.owner != msg.sender) revert PositionAccessDenied();
        _;
    }

    /// @notice Returns the Standardized Yield token address.
    /// @return SY token address.
    function SY() public view returns (address) {
        return outrunStakingPositionStorage.SY;
    }

    /// @notice Returns the minimum SY amount required per stake operation.
    /// @return Minimum stake amount in SY.
    function minStake() public view returns (uint256) {
        return outrunStakingPositionStorage.minStake;
    }

    /// @notice Returns the total SY staked across all positions and the wrap pool.
    /// @return Total SY staked.
    function syTotalStaking() public view returns (uint256) {
        return outrunStakingPositionStorage.syTotalStaking;
    }

    /// @notice Returns the SY amount currently in the shared wrap pool.
    /// @return SY amount in the wrap pool.
    function syWrapStaking() public view returns (uint256) {
        return outrunStakingPositionStorage.syWrapStaking;
    }

    /// @notice Returns the outstanding uAsset debt incurred by the wrap pool.
    /// @return Wrap pool uAsset debt.
    function wrapUAssetDebt() public view returns (uint256) {
        return outrunStakingPositionStorage.wrapUAssetDebt;
    }

    /// @notice Returns the universal asset receipt token address.
    /// @return uAsset token address.
    function uAsset() public view returns (address) {
        return outrunStakingPositionStorage.uAsset;
    }

    /// @notice Returns the revenue pool address that receives harvested yield.
    /// @return Revenue pool address.
    function revenuePool() public view returns (address) {
        return outrunStakingPositionStorage.revenuePool;
    }

    /// @notice Returns the keeper address authorized to trigger `keepRedeem` and `keepWrapRedeem`.
    /// @return Keeper address.
    function keeper() public view returns (address) {
        return outrunStakingPositionStorage.keeper;
    }

    /// @notice Reads the stored position struct for a given position ID.
    /// @param positionId The position identifier.
    /// @return owner Position owner address.
    /// @return syStaked SY amount currently staked in the position.
    /// @return UAssetMinted Current outstanding uAsset debt recorded against this position.
    /// @return deadline Timestamp after which the position can be redeemed.
    function positions(uint256 positionId)
        public
        view
        returns (address owner, uint256 syStaked, uint256 UAssetMinted, uint128 deadline)
    {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        return (position.owner, position.syStaked, position.UAssetMinted, position.deadline);
    }

    /// @notice Previews the uAsset amount mintable from a given SY stake amount.
    /// Rounds down. Quote-only: does not check or reserve the uAsset mint cap.
    /// Returns 0 if floor conversion zeroes the output (tiny SY input after the decimal downscale,
    /// or an exchange rate below 1); an exactly-zero rate instead reverts ZeroExchangeRate at the
    /// rate-reading home. This is a quote-only signal: stake() reverts on zero-mintable
    /// inputs (DustRoundedToZero for dust, ZeroInput for zero input), so callers must not treat a 0
    /// return as a stakeable amount. Mirrors previewDrawUAsset, which also
    /// returns 0 where the matching executor reverts.
    /// @param amountInSY The SY amount to stake.
    /// @return UAssetMintable uAsset amount that would be minted; 0 if floor conversion zeroes it.
    function previewStake(uint256 amountInSY) external view returns (uint256 UAssetMintable) {
        _validateMinStake(amountInSY);
        address _SY = SY();
        UAssetMintable = _syToAsset(amountInSY, _currentExchangeRate(_SY));
    }

    /// @notice Previews the uAsset amount mintable from a given SY amount for a wrap stake.
    /// Rounds down. Quote-only: does not check or reserve the uAsset mint cap.
    /// @param amountInSY The SY amount to wrap stake.
    /// @return UAssetMintable uAsset amount that would be minted.
    function previewWrapStake(uint256 amountInSY) external view returns (uint256 UAssetMintable) {
        if (amountInSY == 0) revert ZeroInput();
        address _SY = SY();
        UAssetMintable = _syToAsset(amountInSY, _currentExchangeRate(_SY));
        // Floor conversion can make tiny SY inputs mint zero uAsset; reject them before quoting.
        // An exactly-zero rate never reaches this check: it reverts ZeroExchangeRate first, at the
        // rate-reading home inside _currentExchangeRate.
        if (UAssetMintable == 0) revert DustRoundedToZero();
    }

    /// @notice Previews additional uAsset drawable from a position based on accrued yield.
    /// Returns 0 if current value has not exceeded previously minted amounts; an exactly-zero
    /// exchange rate instead reverts ZeroExchangeRate at the rate-reading home.
    /// Quote-only: does not check or reserve the uAsset mint cap.
    /// Reverts LockTimeExpired once block.timestamp >= deadline (mirrors drawUAsset): draw is
    /// lockup-window-only, so a matured position previews only its redemption paths.
    /// @param positionId The position identifier.
    /// @return UAssetMintable Additional uAsset amount that can be drawn.
    function previewDrawUAsset(uint256 positionId) public view returns (uint256 UAssetMintable) {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        if (position.owner == address(0)) revert PositionAccessDenied();
        // From the deadline on, draw is closed and redeem opens: redeem/keepRedeem guard the early side
        // (< deadline) with LockTimeNotExpired, and this guard covers >= deadline exactly, so a matured
        // position has only the redeem paths to exit.
        uint128 deadline = position.deadline;
        if (block.timestamp >= deadline) revert LockTimeExpired(deadline);
        address _SY = SY();
        uint256 currentValueInUAsset = _syToAsset(position.syStaked, _currentExchangeRate(_SY));
        uint256 positionUAssetMinted = position.UAssetMinted;
        if (currentValueInUAsset <= positionUAssetMinted) return 0;
        UAssetMintable = currentValueInUAsset - positionUAssetMinted;
    }

    /// @notice Previews the outcome of redeeming SY from a matured position.
    /// Partial redeem debt uses ceil rounding so redeemed SY cannot leave rounded debt dust on the remaining position.
    /// Full redeem burns all remaining debt exactly.
    /// @param positionId The position identifier.
    /// @param syRedeemed Amount of SY to redeem from the position.
    /// @param tokenOut Desired output token address (SY itself or another token via SY.redeem).
    /// @return UAssetBurned uAsset amount that would be burned.
    /// @return amountTokenOut Amount of tokenOut that would be received.
    function previewRedeem(uint256 positionId, uint256 syRedeemed, address tokenOut)
        public
        view
        returns (uint256 UAssetBurned, uint256 amountTokenOut)
    {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        if (position.owner == address(0)) revert PositionAccessDenied();
        uint128 deadline = position.deadline;
        if (block.timestamp < deadline) revert LockTimeNotExpired(deadline);
        _validateRedeemAmount(position.syStaked, syRedeemed);

        // Partial redeem debt uses ceil so redeemed SY cannot leave rounded debt dust on the remaining position.
        UAssetBurned = _computeRedeemPositionDebt(position.UAssetMinted, syRedeemed, position.syStaked);
        amountTokenOut = _previewTokenOut(SY(), tokenOut, syRedeemed);
    }

    /// @notice Previews the SY a keeper would receive from keepWrapRedeem.
    /// @dev Quote-only. Face value is the SY amount represented by the burned uAsset debt at the current exchange
    /// rate; the payout rounds down and full-debt coverage rounds up. Undercollateralized: reverts
    /// WrapPoolUndercollateralized (mirrors keepWrapRedeem).
    /// @param amountInUAsset uAsset amount the keeper would burn.
    /// @return amountInSY SY amount the keeper would receive.
    function previewWrapRedeem(uint256 amountInUAsset) public view returns (uint256 amountInSY) {
        amountInSY = _validateWrapRedeemAmount(amountInUAsset, SY());
    }

    /// @notice Previews the SY split for a keeper redemption of a matured position.
    /// @dev Quote-only: does not check keeper permission, burn uAsset, or change state. Mirrors keepRedeem's
    /// keeper/owner SY split and every failure path (position existence, lockup, amount bounds, zero exchange
    /// rate at the shared rate-reading point, full-position solvency guard, dust, and per-amount defense).
    /// @param positionId The position identifier.
    /// @param amountInUAsset The uAsset amount the keeper would burn.
    /// @return keeperPrincipalSY Debt-equivalent SY the keeper would receive.
    /// @return ownerExcessSY Excess SY the position owner would receive.
    function previewKeepRedeem(uint256 positionId, uint256 amountInUAsset)
        external
        view
        returns (uint256 keeperPrincipalSY, uint256 ownerExcessSY)
    {
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        if (position.owner == address(0)) revert PositionAccessDenied();
        uint128 deadline = position.deadline;
        if (block.timestamp < deadline) revert LockTimeNotExpired(deadline);

        uint256 syStaked = position.syStaked;
        uint256 positionUAssetMinted = position.UAssetMinted;
        if (amountInUAsset == 0) revert ZeroInput();
        if (amountInUAsset > positionUAssetMinted) {
            revert ExceedsPositionDebt(amountInUAsset, positionUAssetMinted);
        }

        (, keeperPrincipalSY, ownerExcessSY) =
            _computeKeepRedeemShares(SY(), syStaked, positionUAssetMinted, amountInUAsset);
    }

    /// @notice Stakes SY tokens and creates a time-locked position, minting uAsset to the receiver.
    /// Rounds down when converting SY to uAsset to avoid over-minting.
    /// @dev The position is locked until deadline (block.timestamp + lockupDays * 1 day).
    /// Redeeming the staked SY requires the deadline to have passed.
    /// @param amountInSY SY amount to stake. Must be > 0 and >= minStake.
    /// @param lockupDays Number of days the position is locked after creation.
    /// @param positionOwner Address that will own the position and can draw/redeem it.
    /// @param uAssetReceiver Address that receives the minted uAsset.
    /// @return positionId The newly created position identifier.
    /// @return mintedUAsset The uAsset amount minted for this stake.
    function stake(uint256 amountInSY, uint128 lockupDays, address positionOwner, address uAssetReceiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId, uint256 mintedUAsset)
    {
        if (positionOwner == address(0) || uAssetReceiver == address(0) || amountInSY == 0) revert ZeroInput();
        address _SY = SY();
        address _uAsset = uAsset();
        // Step 1: validate minimum stake amount.
        _validateMinStake(amountInSY);
        // Step 2: convert SY principal to uAsset value at the current exchange rate.
        uint256 exchangeRate_ = _currentExchangeRate(_SY);
        uint256 uAssetDebt = _syToAsset(amountInSY, exchangeRate_);
        // Reject zero-debt stakes before pulling SY so dust cannot create a zero-value position or waste the SY transfer.
        if (uAssetDebt == 0) revert DustRoundedToZero();
        // Step 3: pull SY tokens from the staker.
        _transferIn(_SY, msg.sender, amountInSY);

        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        unchecked {
            // No overflow: the accumulator only grows by SY actually received in _transferIn above,
            // so it stays below SY total supply.
            $.syTotalStaking += amountInSY;
        }

        // Step 4: create a new position with lockup deadline.
        // Compute the deadline in full uint256 precision, then confirm it fits in uint128 before the
        // narrowing cast below. Without this check, a huge lockupDays would silently wrap the deadline
        // into a past timestamp and let the position be redeemed before its declared lockup ends.
        // slither-disable-next-line timestamp
        uint256 deadline256 = block.timestamp + uint256(lockupDays) * 1 days;
        if (deadline256 > type(uint128).max) revert LockupDaysOutOfRange(lockupDays);

        positionId = _nextId();
        mintedUAsset = uAssetDebt;
        $.positions[positionId] = Position({
            owner: positionOwner,
            syStaked: amountInSY,
            UAssetMinted: mintedUAsset,
            // Safe: deadline256 was checked to fit in uint128 immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            deadline: uint128(deadline256)
        });

        // Step 5: mint uAsset to the designated receiver.
        // Minting draws on this contract's own uAsset minter record: it increases this contract's
        // outstanding mint debt (amountInMinted) and reverts with ReachMintCap if its configured
        // mintingCap is exhausted.
        IUniversalAssets(_uAsset).mint(uAssetReceiver, mintedUAsset);
        emit Stake(positionId, positionOwner, amountInSY, mintedUAsset, deadline256);
    }

    /// @notice Mints extra uAsset from a position after the staked SY becomes more valuable.
    /// Only the position owner can call this. Reverts if the position has no extra value to mint against.
    /// Draw is lockup-window-only: reverts LockTimeExpired once block.timestamp >= deadline —
    /// a matured position exits through redemption instead.
    /// @param positionId The position identifier.
    /// @param uAssetReceiver Address that receives the newly minted uAsset.
    /// @return mintedUAsset Additional uAsset amount minted.
    function drawUAsset(uint256 positionId, address uAssetReceiver)
        external
        nonReentrant
        whenNotPaused
        onlyPositionOwner(positionId)
        returns (uint256 mintedUAsset)
    {
        if (uAssetReceiver == address(0)) revert ZeroInput();
        Position storage position = outrunStakingPositionStorage.positions[positionId];

        // From the deadline on, draw is closed and redeem opens: redeem/keepRedeem guard the early side
        // (< deadline) with LockTimeNotExpired, and this guard covers >= deadline exactly, so a matured
        // position has only the redeem paths to exit.
        uint128 deadline = position.deadline;
        if (block.timestamp >= deadline) revert LockTimeExpired(deadline);

        address _SY = SY();
        uint256 currentValueInUAsset = _syToAsset(position.syStaked, _currentExchangeRate(_SY));
        uint256 positionUAssetMinted = position.UAssetMinted;
        if (currentValueInUAsset <= positionUAssetMinted) revert NothingToDraw();

        mintedUAsset = currentValueInUAsset - positionUAssetMinted;
        // Increase the position debt first so the newly minted uAsset is recorded against this position.
        position.UAssetMinted = currentValueInUAsset;

        address _uAsset = uAsset();
        // Minting draws on this contract's own uAsset minter record: it increases this contract's
        // outstanding mint debt (amountInMinted) and reverts with ReachMintCap if its configured
        // mintingCap is exhausted.
        IUniversalAssets(_uAsset).mint(uAssetReceiver, mintedUAsset);
        emit DrawUAsset(positionId, uAssetReceiver, mintedUAsset);
    }

    /// @notice Stakes SY into the shared wrap pool without creating a position, minting uAsset immediately.
    /// No lockup period applies to the deposited SY principal.
    /// Rounds down when converting SY to uAsset to avoid over-minting.
    /// @dev Increments both syTotalStaking and syWrapStaking, and also increments wrapUAssetDebt.
    /// @param amountInSY SY amount to wrap stake. Must be > 0.
    /// @param uAssetReceiver Address that receives the minted uAsset.
    /// @return mintedUAsset uAsset amount minted.
    function wrapStake(uint256 amountInSY, address uAssetReceiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 mintedUAsset)
    {
        if (uAssetReceiver == address(0) || amountInSY == 0) revert ZeroInput();
        address _SY = SY();
        // Minted uAsset is tracked as shared pool debt, not position-specific debt.
        uint256 exchangeRate_ = _currentExchangeRate(_SY);
        uint256 uAssetDebt = _syToAsset(amountInSY, exchangeRate_);
        // Reject zero-debt stakes before pulling SY so rounded dust cannot change pool accounting or balances.
        if (uAssetDebt == 0) revert DustRoundedToZero();

        address _uAsset = uAsset();
        // The shared wrap pool receives SY directly from the caller; no position owner or deadline is stored.
        _transferIn(_SY, msg.sender, amountInSY);

        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        unchecked {
            // No overflow: the SY accumulators only grow by tokens actually received in _transferIn above
            // (bounded by SY total supply), and wrapUAssetDebt only grows when the mint below succeeds —
            // uAsset mintingCap overruns revert the whole transaction with ReachMintCap.
            $.syTotalStaking += amountInSY;
            $.syWrapStaking += amountInSY;
            $.wrapUAssetDebt += uAssetDebt;
        }

        mintedUAsset = uAssetDebt;
        // Minting draws on this contract's own uAsset minter record: it increases this contract's
        // outstanding mint debt (amountInMinted) and reverts with ReachMintCap if its configured
        // mintingCap is exhausted.
        IUniversalAssets(_uAsset).mint(uAssetReceiver, mintedUAsset);
        emit WrapStake(amountInSY, mintedUAsset, uAssetReceiver);
    }

    // slither-disable-next-line reentrancy-no-eth,timestamp
    /// @notice Redeems SY from a matured position, repaying uAsset debt and sending tokenOut to the receiver.
    /// Only the position owner can call. The position deadline must have passed.
    /// @dev Debt is repaid proportionally: if all SY is redeemed, all remaining uAsset debt is burned.
    /// Partial redeems use ceil rounding for debt so no stranded debt remains on the position.
    /// Direct SY tokenOut transfers SY 1:1 without an adapter burn; all other tokenOut paths go through SY.redeem.
    /// @param positionId The position identifier.
    /// @param syRedeemed Amount of SY to redeem from the position.
    /// @param receiver Address that receives the tokenOut.
    /// @param tokenOut Desired output token (SY itself or another token via SY.redeem).
    /// @param minTokenOut Minimum acceptable amount of tokenOut (slippage protection).
    /// @return UAssetBurned uAsset amount burned as debt repayment.
    /// @return amountTokenOut Amount of tokenOut sent to the receiver.
    function redeem(uint256 positionId, uint256 syRedeemed, address receiver, address tokenOut, uint256 minTokenOut)
        external
        nonReentrant
        whenNotPaused
        onlyPositionOwner(positionId)
        returns (uint256 UAssetBurned, uint256 amountTokenOut)
    {
        if (receiver == address(0)) revert ZeroInput();
        address _SY = SY();
        Position storage position = outrunStakingPositionStorage.positions[positionId];

        uint128 deadline = position.deadline;
        if (block.timestamp < deadline) revert LockTimeNotExpired(deadline);

        uint256 syStaked = position.syStaked;
        uint256 positionUAssetMinted = position.UAssetMinted;
        _validateRedeemAmount(syStaked, syRedeemed);

        // Matured position debt is computed before any state change so the burn amount is deterministic.
        UAssetBurned = _computeRedeemPositionDebt(positionUAssetMinted, syRedeemed, syStaked);
        // Direct SY redemption bypasses SY.redeem, so enforce minTokenOut here.
        if (tokenOut == _SY && syRedeemed < minTokenOut) revert InsufficientTokenOut(syRedeemed, minTokenOut);
        // Reduce or delete the position before burning uAsset so external observers never see repaid debt
        // paired with stale position debt.
        _applyPositionRedeem(positionId, position, syRedeemed, UAssetBurned, syStaked, positionUAssetMinted);
        // Repay burns uAsset from the caller and reduces this stake manager's outstanding mint debt.
        IUniversalAssets(uAsset()).repay(msg.sender, UAssetBurned);
        // Release SY directly or redeem through the SY adapter into tokenOut.
        amountTokenOut = _redeemTokenOut(_SY, receiver, tokenOut, syRedeemed, minTokenOut);

        emit Redeem(positionId, msg.sender, syRedeemed, UAssetBurned, receiver, tokenOut, amountTokenOut);
    }

    // slither-disable-next-line reentrancy-no-eth
    /// @notice Keeper burns its own uAsset to redeem wrap-pool SY at face value. Face value is the SY amount
    /// represented by the burned uAsset debt at the current exchange rate; the payout rounds down and full-debt
    /// coverage rounds up. Reverts if the pool is undercollateralized.
    /// @dev Keeper-only path, mirroring keepRedeem's trust model. Replaces the former public wrapRedeem,
    /// which was removed in favor of this keeper-only all-or-nothing redemption.
    /// Reverts WrapPoolUndercollateralized on an undercollateralized pool — the keeper is trusted and must not bear a
    /// loss-making redemption. Consistent with keepRedeem, which also reverts (InsufficientSyCollateral) on an
    /// undercollateralized position.
    /// @param amountInUAsset uAsset amount the keeper burns. Must be > 0 and <= wrapUAssetDebt.
    /// @param receiver Address receiving the SY.
    /// @return amountInSY SY amount sent to the receiver.
    function keepWrapRedeem(uint256 amountInUAsset, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountInSY)
    {
        if (msg.sender != keeper()) revert PermissionDenied();
        if (receiver == address(0) || amountInUAsset == 0) revert ZeroInput();

        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        address _SY = SY();
        address _uAsset = uAsset();
        // Named return: the SY amount is paid directly with no downstream SY.redeem conversion.
        amountInSY = _validateWrapRedeemAmount(amountInUAsset, _SY);

        unchecked {
            // No underflow: _validateWrapRedeemAmount enforces amountInUAsset <= wrapUAssetDebt and
            // amountInSY = _assetToSy(amountInUAsset) <= _assetToSyUp(amountInUAsset) <=
            // _assetToSyUp(wrapUAssetDebt) <= syWrapStaking (floor <= ceil at the same exchange rate), and
            // syTotalStaking >= syWrapStaking keeps the total ledger above the same bound.
            $.syTotalStaking -= amountInSY;
            $.syWrapStaking -= amountInSY;
            $.wrapUAssetDebt -= amountInUAsset;
        }

        // Burn keeper-provided uAsset; repay decrements the stake manager's minter debt.
        IUniversalAssets(_uAsset).repay(msg.sender, amountInUAsset);

        _transferOut(_SY, receiver, amountInSY);

        emit KeepWrapRedeem(msg.sender, receiver, amountInUAsset, amountInSY);
    }

    // slither-disable-next-line reentrancy-no-eth,timestamp
    /// @notice Keeper burns uAsset to trigger redemption of a matured position.
    /// Debt-equivalent SY goes to receiver; any excess SY above debt goes back to position owner.
    /// @dev Reverts with InsufficientSyCollateral if the position's staked SY value is below its debt face
    /// value (full-position guard) or if the keeper's debt-equivalent share exceeds the proportional SY share.
    /// @param positionId Identifier of the position being redeemed.
    /// @param amountInUAsset Amount of uAsset the keeper burns.
    /// @param receiver Address receiving the keeper principal in SY.
    /// @return UAssetBurned Amount of uAsset burned by the keeper.
    /// @return keeperPrincipalSY Debt-equivalent SY sent to the keeper receiver.
    /// @return ownerExcessSY Excess SY sent back to the position owner.
    function keepRedeem(uint256 positionId, uint256 amountInUAsset, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 UAssetBurned, uint256 keeperPrincipalSY, uint256 ownerExcessSY)
    {
        // Keeper-only entrypoint guard.
        if (msg.sender != keeper()) revert PermissionDenied();
        if (receiver == address(0)) revert ZeroInput();
        address _SY = SY();
        address _uAsset = uAsset();
        Position storage position = outrunStakingPositionStorage.positions[positionId];
        address positionOwner = position.owner;
        if (positionOwner == address(0)) revert PositionAccessDenied();
        uint128 deadline = position.deadline;
        if (block.timestamp < deadline) revert LockTimeNotExpired(deadline);

        uint256 syStaked = position.syStaked;
        uint256 positionUAssetMinted = position.UAssetMinted;
        if (amountInUAsset == 0) revert ZeroInput();
        if (amountInUAsset > positionUAssetMinted) {
            revert ExceedsPositionDebt(amountInUAsset, positionUAssetMinted);
        }

        // Step 1: compute the keeper split (full-position guard, proportional SY, keeper principal, owner excess).
        uint256 syRedeemed;
        (syRedeemed, keeperPrincipalSY, ownerExcessSY) =
            _computeKeepRedeemShares(_SY, syStaked, positionUAssetMinted, amountInUAsset);

        // Step 2: burn uAsset from the caller (keeper provides uAsset).
        UAssetBurned = amountInUAsset;
        IUniversalAssets(_uAsset).repay(msg.sender, UAssetBurned);

        // Step 3: apply position reduction and transfer SY to both parties.
        _applyPositionRedeem(positionId, position, syRedeemed, UAssetBurned, syStaked, positionUAssetMinted);
        _transferOut(_SY, receiver, keeperPrincipalSY);
        _transferOut(_SY, positionOwner, ownerExcessSY);

        emit KeepRedeem(positionId, positionOwner, UAssetBurned, receiver, keeperPrincipalSY, ownerExcessSY);
    }

    function harvestWrapYield(address tokenOut, uint256 minTokenOut)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (uint256 amountTokenOut)
    {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        address _SY = SY();
        uint256 wrapPoolSY = $.syWrapStaking;
        // Ceil conversion: only SY above the full debt-equivalent is harvestable.
        // Rounding up the debt means enough SY stays in the wrap pool to cover all remaining debt.
        uint256 exchangeRate_ = _currentExchangeRate(_SY);
        uint256 wrapDebtInSY = _assetToSyUp($.wrapUAssetDebt, exchangeRate_);
        // If no excess SY exists, return 0 without reverting.
        if (wrapPoolSY <= wrapDebtInSY) return 0;

        uint256 amountInSY = wrapPoolSY - wrapDebtInSY;
        unchecked {
            // Harvesting removes only excess SY; the wrap debt-equivalent amount stays in the pool.
            // No underflow: amountInSY was derived above from syWrapStaking (amountInSY <= syWrapStaking),
            // and syTotalStaking >= syWrapStaking, so both subtractions stay non-negative.
            $.syTotalStaking -= amountInSY;
            $.syWrapStaking -= amountInSY;
        }

        if (tokenOut == _SY) {
            // Direct SY payout avoids adapter redemption and therefore needs its own minTokenOut check.
            if (amountInSY < minTokenOut) revert InsufficientTokenOut(amountInSY, minTokenOut);
            amountTokenOut = amountInSY;
            _transferOut(_SY, $.revenuePool, amountInSY);
        } else {
            // Non-SY payout converts excess SY through the adapter and sends proceeds to revenuePool.
            amountTokenOut = IStandardizedYield(_SY).redeem($.revenuePool, amountInSY, tokenOut, minTokenOut, false);
        }

        emit HarvestWrapYield($.revenuePool, tokenOut, amountInSY, amountTokenOut);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setMinStake(uint256 minStake_) external onlyOwner {
        outrunStakingPositionStorage.minStake = minStake_;
        emit SetMinStake(minStake_);
    }

    function setRevenuePool(address revenuePool_) external onlyOwner {
        if (revenuePool_ == address(0)) revert ZeroInput();
        outrunStakingPositionStorage.revenuePool = revenuePool_;
        emit SetRevenuePool(revenuePool_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroInput();
        outrunStakingPositionStorage.keeper = keeper_;
        emit SetKeeper(keeper_);
    }

    function _validateMinStake(uint256 amountInSY) internal view {
        uint256 minStake_ = minStake();
        if (amountInSY < minStake_) revert MinStakeInsufficient(minStake_);
    }

    // `canonicalAssetValue` follows `SY.assetInfo().assetDecimals`.
    // `uAssetDebtUnits` follows `uAsset.decimals()`.
    // These helpers convert using the caller-supplied exchange rate and then rescale across the two decimal domains.

    /// @notice Reads the SY exchange rate at a single place.
    /// @dev Every conversion site below obtains the rate through this function, so the zero-rate guard
    /// lives here (one home), and a future change to the rate-reading convention (caching) also has one
    /// home instead of nine inline copies.
    /// Callers pass the already-resolved SY address to avoid re-reading the SY storage slot.
    /// @param _SY The Standardized Yield token address.
    function _currentExchangeRate(address _SY) internal view returns (uint256) {
        uint256 rate = IStandardizedYield(_SY).exchangeRate();
        // Zero rate means the external SY is reporting a broken state; fail closed with a named
        // error here (the single rate-reading home) instead of leaking a division panic or a
        // misleading dust/nothing error into any conversion path.
        if (rate == 0) revert ZeroExchangeRate();
        return rate;
    }

    /// @dev Converts SY principal to uAsset value. Rounds down to avoid over-minting.
    /// @param amountInSY The SY amount to convert.
    /// @param exchangeRate_ The SY exchange rate, 1e18-scaled, read once by the caller and passed in.
    function _syToAsset(uint256 amountInSY, uint256 exchangeRate_) internal view returns (uint256) {
        uint256 canonicalAssetValue = SYUtils.syToAsset(exchangeRate_, amountInSY);
        return _scaleCanonicalAssetToUAsset(canonicalAssetValue);
    }

    /// @dev Converts uAsset debt to SY for repayment. Rounds down to avoid releasing too much SY.
    /// @param amountInUAsset The uAsset amount to convert.
    /// @param exchangeRate_ The SY exchange rate, 1e18-scaled, read once by the caller and passed in.
    function _assetToSy(uint256 amountInUAsset, uint256 exchangeRate_) internal view returns (uint256) {
        uint256 canonicalAssetValue = _scaleUAssetToCanonicalAsset(amountInUAsset, Math.Rounding.Floor);
        return SYUtils.assetToSy(exchangeRate_, canonicalAssetValue);
    }

    /// @dev Converts uAsset debt to SY for coverage checks. Rounds up to leave enough SY covering all debt.
    /// @param amountInUAsset The uAsset amount to convert.
    /// @param exchangeRate_ The SY exchange rate, 1e18-scaled, read once by the caller and passed in.
    function _assetToSyUp(uint256 amountInUAsset, uint256 exchangeRate_) internal view returns (uint256) {
        uint256 canonicalAssetValue = _scaleUAssetToCanonicalAsset(amountInUAsset, Math.Rounding.Ceil);
        return SYUtils.assetToSyUp(exchangeRate_, canonicalAssetValue);
    }

    /// @dev Rescales from canonical asset decimals (e.g. 18 for ETH) to uAsset decimals (e.g. 6 for USDC-denominated uAsset).
    function _scaleCanonicalAssetToUAsset(uint256 amount) internal view returns (uint256) {
        (uint8 canonicalAssetDecimals, uint8 uAssetDecimals) = _cachedAssetDecimals();
        if (uAssetDecimals >= canonicalAssetDecimals) {
            return amount * 10 ** (uAssetDecimals - canonicalAssetDecimals);
        }
        return amount / 10 ** (canonicalAssetDecimals - uAssetDecimals);
    }

    /// @dev Rescales from uAsset decimals back to canonical asset decimals.
    function _scaleUAssetToCanonicalAsset(uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        (uint8 canonicalAssetDecimals, uint8 uAssetDecimals) = _cachedAssetDecimals();
        if (canonicalAssetDecimals >= uAssetDecimals) {
            return amount * 10 ** (canonicalAssetDecimals - uAssetDecimals);
        }

        uint256 factor = 10 ** (uAssetDecimals - canonicalAssetDecimals);
        // Ceil rounding: (amount - 1) / factor + 1 ensures rounding up even for amounts not evenly divisible by the factor.
        if (rounding == Math.Rounding.Ceil && amount != 0) {
            return (amount - 1) / factor + 1;
        }
        return amount / factor;
    }

    function _cachedAssetDecimals() internal view returns (uint8 canonicalAssetDecimals, uint8 uAssetDecimals) {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        return ($.canonicalAssetDecimals, $.uAssetDecimals);
    }

    /// @dev Shared keeper-redeem accounting: full-position solvency guard, proportional SY release,
    /// keeper principal conversion, keeper dust guard, per-amount defense, and owner excess. Quote-only;
    /// makes no state change and no external call other than reading `SY.exchangeRate()`.
    /// @param _SY The Standardized Yield token address.
    /// @param syStaked The position's staked SY amount.
    /// @param positionUAssetMinted The position's outstanding uAsset debt.
    /// @param amountInUAsset The uAsset amount the keeper burns.
    /// @return syRedeemed Proportional SY released from the position.
    /// @return keeperPrincipalSY Debt-equivalent SY the keeper receives.
    /// @return ownerExcessSY Excess SY returned to the position owner.
    function _computeKeepRedeemShares(
        address _SY,
        uint256 syStaked,
        uint256 positionUAssetMinted,
        uint256 amountInUAsset
    ) internal view returns (uint256 syRedeemed, uint256 keeperPrincipalSY, uint256 ownerExcessSY) {
        // Full-position guard: reject any keepRedeem when the whole position is undercollateralized.
        // Up rounding ensures the position is only treated as solvent when SY covers the full debt face.
        uint256 exchangeRate_ = _currentExchangeRate(_SY);
        if (_assetToSyUp(positionUAssetMinted, exchangeRate_) > syStaked) revert InsufficientSyCollateral();

        // Proportional SY share, rounded down: SY must leave the position no faster than debt is
        // repaid, so the remaining position stays at least as collateralized as the whole under the
        // full-position guard above (mirror of the ceil debt burn in _computeRedeemPositionDebt).
        syRedeemed = Math.mulDiv(syStaked, amountInUAsset, positionUAssetMinted);
        // Dust uAsset inputs that round to zero SY must not burn debt without reducing staked SY.
        if (syRedeemed == 0) revert DustRoundedToZero();

        // Convert burned uAsset to SY at the current exchange rate (keeperPrincipalSY).
        keeperPrincipalSY = _assetToSy(amountInUAsset, exchangeRate_);
        // Dust burns whose debt-equivalent SY floors to zero must not pay the keeper nothing while the
        // whole split goes to the owner; symmetric with the zero-output guard in _validateWrapRedeemAmount.
        if (keeperPrincipalSY == 0) revert DustRoundedToZero();
        // Provably unreachable under the full-position guard (solvent positions always satisfy
        // keeperPrincipalSY <= syRedeemed); kept as defense-in-depth against future refactors that could
        // otherwise reintroduce an ownerExcessSY underflow.
        if (keeperPrincipalSY > syRedeemed) revert InsufficientSyCollateral();
        // The position owner receives any remaining SY above the keeper's share.
        ownerExcessSY = syRedeemed - keeperPrincipalSY;
    }

    function _applyPositionRedeem(
        uint256 positionId,
        Position storage position,
        uint256 syRedeemed,
        uint256 UAssetBurned,
        uint256 syStaked,
        uint256 positionUAssetMinted
    ) internal {
        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        if (syRedeemed > syStaked) revert ExceedsPositionBalance(syRedeemed, syStaked);
        if (UAssetBurned > positionUAssetMinted) {
            revert ExceedsPositionDebt(UAssetBurned, positionUAssetMinted);
        }
        uint256 remainingSY;
        uint256 remainingUAsset;

        unchecked {
            // Total staked SY falls by the amount leaving the position.
            // Safe: remainingSY and remainingUAsset bounds were checked immediately above; for the ledger,
            // syTotalStaking = sum(position.syStaked) + syWrapStaking >= syStaked >= syRedeemed.
            $.syTotalStaking -= syRedeemed;
            remainingSY = syStaked - syRedeemed;
            remainingUAsset = positionUAssetMinted - UAssetBurned;
        }

        if (remainingSY == 0) {
            // Full redeem clears the position so the id can no longer be used.
            delete $.positions[positionId];
            return;
        }

        // Partial redeem keeps the same position id with reduced SY and reduced debt.
        position.syStaked = remainingSY;
        position.UAssetMinted = remainingUAsset;
    }

    /// @dev Validates a wrap redemption amount and computes the SY amount to release at face value, meaning the
    /// burned uAsset debt's SY equivalent at the current exchange rate.
    /// Reverts WrapPoolUndercollateralized when the wrap pool's SY is below its uAsset debt face value —
    /// keepWrapRedeem is keeper-only and the keeper must not bear a loss-making redemption (all-or-nothing
    /// semantics; no pro-rata partial payout). The exchange rate is read once after the debt check.
    /// @param amountInUAsset The uAsset amount to redeem.
    /// @param _SY The Standardized Yield token address.
    /// @return amountInSY The SY amount to release.
    function _validateWrapRedeemAmount(uint256 amountInUAsset, address _SY) internal view returns (uint256 amountInSY) {
        if (amountInUAsset == 0) revert ZeroInput();

        OutrunStakingPositionStorage storage $ = outrunStakingPositionStorage;
        // Read the wrap debt once into a local: the exchangeRate() call below prevents the
        // compiler from caching this slot across calls, so re-reading it per use wastes gas.
        uint256 wrapUAssetDebt_ = $.wrapUAssetDebt;
        if (amountInUAsset > wrapUAssetDebt_) revert ExceedsWrapDebt(amountInUAsset, wrapUAssetDebt_);

        uint256 exchangeRate_ = _currentExchangeRate(_SY);

        // Healthy pool guard: SY must cover the full debt face value. Same solvency check as harvest
        // (debt-equivalent SY uses ceil so the pool stays covered). Undercollateralized → revert; the
        // keeper is trusted and must not bear a loss-making redemption (all-or-nothing semantics).
        if (_assetToSyUp(wrapUAssetDebt_, exchangeRate_) > $.syWrapStaking) {
            revert WrapPoolUndercollateralized();
        }
        // Floor conversion: keepWrapRedeem never releases more SY than the repaid debt accounts for.
        amountInSY = _assetToSy(amountInUAsset, exchangeRate_);
        // Dust uAsset inputs that round to zero SY must not burn debt without reducing staked SY.
        if (amountInSY == 0) revert DustRoundedToZero();
    }

    function _validateRedeemAmount(uint256 syStaked, uint256 syRedeemed) internal pure {
        if (syRedeemed == 0) revert ZeroInput();
        if (syRedeemed > syStaked) revert ExceedsPositionBalance(syRedeemed, syStaked);
    }

    /// @dev Partial redeem uses ceil rounding so remaining SY cannot leave orphaned debt on the position.
    /// Full redeem (all SY) burns all remaining debt exactly — no rounding needed.
    function _computeRedeemPositionDebt(uint256 positionUAssetMinted, uint256 syRedeemed, uint256 syStaked)
        internal
        pure
        returns (uint256 UAssetBurned)
    {
        if (syRedeemed == syStaked) return positionUAssetMinted;

        // Partial redeem rounds debt up so remaining SY cannot strand unburned debt on the position.
        UAssetBurned = Math.mulDiv(positionUAssetMinted, syRedeemed, syStaked, Math.Rounding.Ceil);
        if (UAssetBurned >= positionUAssetMinted) revert PartialRedeemMustLeaveDebt();
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

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
