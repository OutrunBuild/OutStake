// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun SY Stake Manager interface
 * @notice Manages locked positions and the shared wrap pool backed by one canonical SY and one uAsset.
 */
interface IOutrunStakeManager {
    /**
     * @notice Locked position accounting record.
     * @dev `owner` controls draw and owner-redemption paths. `syStaked` is principal in SY units, and
     * `UAssetMinted` is this position's outstanding uAsset debt. `deadline` gates owner and keeper redemption.
     */
    struct Position {
        address owner;
        uint256 syStaked;
        uint256 UAssetMinted;
        uint128 startTime;
        uint128 deadline;
    }

    error ZeroInput();
    /// @dev Reverts when a non-zero input is so small that floor/pro-rata conversion rounds the
    /// resulting SY or uAsset amount down to zero (e.g. dust after a decimal downscale). Distinct from
    /// `ZeroInput`, which means the caller passed a zero amount or zero address.
    error DustRoundedToZero();
    error PermissionDenied();
    error LockTimeNotExpired(uint128 deadLine);
    /// @dev Reverts when `lockupDays` is so large that `block.timestamp + lockupDays * 1 days` no
    /// longer fits in uint128, which would let the deadline cast wrap into the past and bypass the lock.
    error LockupDaysOutOfRange(uint128 lockupDays);
    error MinStakeInsufficient(uint256 minStake);
    error PositionAccessDenied();
    error ExceedsPositionBalance(uint256 requested, uint256 available);
    error ExceedsPositionDebt(uint256 requested, uint256 available);
    /// @dev Reverts when a position's staked SY value is below its uAsset debt face value, so a keeper
    /// redemption would pay the keeper more SY than the position's proportional share covers.
    error InsufficientSyCollateral();
    error ExceedsWrapDebt(uint256 requested, uint256 available);
    error NothingToDraw();
    error PartialRedeemMustLeaveDebt();
    error InsufficientTokenOut(uint256 actual, uint256 minExpected);

    /**
     * @notice Returns the SY token handled by the staking manager.
     * @dev Router flows treat this as the canonical SY for this manager and do not accept a separate SY address.
     * @return Address of the standardized yield token.
     */
    function SY() external view returns (address);

    /**
     * @notice Returns the universal asset minted against stakes.
     * @dev The stake manager is the uAsset minter; mint cap and repay accounting remain minter-scoped in uAsset.
     * @return Address of the uAsset contract.
     */
    function uAsset() external view returns (address);

    /**
     * @notice Returns the total SY currently tracked across positions and wrap pool.
     * @dev Includes locked-position principal and wrap-pool principal; it is not only user-owned unlocked SY.
     * @return Total SY held as staking principal.
     */
    function syTotalStaking() external view returns (uint256);

    /**
     * @notice Returns the SY principal currently allocated to the wrap pool.
     * @dev This excludes SY locked only inside individual positions and is used with `wrapUAssetDebt` for harvest.
     * @return Total wrap pool SY balance tracked by the contract.
     */
    function syWrapStaking() external view returns (uint256);

    /**
     * @notice Returns the outstanding wrap-pool uAsset debt.
     * @dev Aggregate principal debt for the shared wrap pool; individual wrap users do not receive position ids.
     * @return Total uAsset debt minted against wrap stake deposits.
     */
    function wrapUAssetDebt() external view returns (uint256);

    /**
     * @notice Returns the keeper allowed to execute keeper-only redemptions.
     * @dev Keeper redemptions burn keeper-provided uAsset and split released SY; they are not owner redemptions.
     * @return Address with keeper privileges.
     */
    function keeper() external view returns (address);

    /**
     * @notice Returns the stored data for a staking position.
     * @dev A zero owner identifies a missing/deleted position in the current implementation.
     * @param positionId Identifier of the position to inspect.
     * @return owner Owner of the position.
     * @return syStaked SY principal currently staked in the position.
     * @return UAssetMinted Total uAsset minted against the position.
     * @return startTime Timestamp when the position was opened.
     * @return deadline Timestamp when the lockup expires.
     */
    function positions(uint256 positionId)
        external
        view
        returns (address owner, uint256 syStaked, uint256 UAssetMinted, uint128 startTime, uint128 deadline);

    /**
     * @notice Previews how much uAsset a direct stake would mint.
     * @dev Quote-only. Uses current `SY.exchangeRate()` and the same conversion direction as `stake`, but does
     * not reserve cap, transfer SY, create a position, or apply slippage protection.
     * @param amountInSY Amount of SY to stake.
     * @return UAssetMintable Amount of uAsset expected to be minted.
     */
    function previewStake(uint256 amountInSY) external view returns (uint256 UAssetMintable);

    /**
     * @notice Previews how much uAsset a wrap stake would mint.
     * @dev Quote-only. Uses current `SY.exchangeRate()` and the same conversion direction as `wrapStake`, but
     * does not reserve cap, transfer SY, or update wrap-pool debt.
     * @param amountInSY Amount of SY to add to the wrap pool.
     * @return UAssetMintable Amount of uAsset expected to be minted.
     */
    function previewWrapStake(uint256 amountInSY) external view returns (uint256 UAssetMintable);

    /**
     * @notice Previews additional uAsset drawable from an existing position.
     * @dev Quote-only. Returns only the current value above the position's existing debt; it does not update
     * position debt or reserve uAsset mint cap.
     * @param positionId Identifier of the position to inspect.
     * @return UAssetMintable Additional uAsset currently drawable from the position.
     */
    function previewDrawUAsset(uint256 positionId) external view returns (uint256 UAssetMintable);

    /**
     * @notice Previews a position redemption into SY or another output token.
     * @dev Quote-only. Full redeem burns all remaining position debt; partial redeem uses ceiling rounding and
     * rejects any partial path that would consume all remaining debt. Token output is either direct SY or the
     * current `SY.previewRedeem` result for `tokenOut`.
     * @param positionId Identifier of the position being redeemed.
     * @param syRedeemed Amount of SY principal to redeem from the position.
     * @param tokenOut Token requested on redemption.
     * @return UAssetBurned Amount of uAsset expected to be burned.
     * @return amountTokenOut Amount of output token expected to be received.
     */
    function previewRedeem(uint256 positionId, uint256 syRedeemed, address tokenOut)
        external
        view
        returns (uint256 UAssetBurned, uint256 amountTokenOut);

    /**
     * @notice Previews a wrap-pool redemption into SY or another output token.
     * @dev Quote-only. Healthy pool: converts uAsset debt to SY at the current exchange rate.
     * Undercollateralized pool: rate-independent pro-rata (amountInUAsset × syWrapStaking / wrapUAssetDebt).
     * Then previews optional SY redemption into `tokenOut`.
     * @param amountInUAsset Amount of uAsset to redeem.
     * @param tokenOut Token requested on redemption.
     * @return amountTokenOut Amount of output token expected to be received.
     */
    function previewWrapRedeem(uint256 amountInUAsset, address tokenOut) external view returns (uint256 amountTokenOut);

    /**
     * @notice Previews the SY split for a keeper redemption of a matured position.
     * @dev Quote-only. Mirrors `keepRedeem`'s keeper/owner SY split and failure paths without checking keeper
     * permission, burning uAsset, or changing state. Reverts if the position is missing, not matured, the amount
     * is zero or exceeds position debt, the position is undercollateralized, or the proportional SY rounds to dust.
     * @param positionId Identifier of the position being redeemed.
     * @param amountInUAsset Amount of uAsset the keeper would burn.
     * @return keeperPrincipalSY Debt-equivalent SY the keeper would receive.
     * @return ownerExcessSY Excess SY the position owner would receive.
     */
    function previewKeepRedeem(uint256 positionId, uint256 amountInUAsset)
        external
        view
        returns (uint256 keeperPrincipalSY, uint256 ownerExcessSY);

    /**
     * @notice Stakes SY into a locked position and mints uAsset to a chosen receiver.
     * @dev Pulls SY from `msg.sender`, creates a locked position owned by `positionOwner`, and mints initial debt
     * to `uAssetReceiver`. The initial debt is current SY asset value, not a fixed 1:1 amount.
     * @param amountInSY Amount of SY to stake.
     * @param lockupDays Number of days the position remains locked. `0` creates an immediately
     * redeemable position. A value so large that the deadline would exceed uint128 reverts.
     * @param positionOwner Address that owns the created position.
     * @param uAssetReceiver Address receiving the initially minted uAsset.
     * @return positionId Identifier of the created position.
     * @return UAssetMinted Amount of uAsset minted for the new position.
     */
    function stake(uint256 amountInSY, uint128 lockupDays, address positionOwner, address uAssetReceiver)
        external
        returns (uint256 positionId, uint256 UAssetMinted);

    /**
     * @notice Mints newly drawable uAsset from an existing position.
     * @dev Position-owner path. Uses current SY asset value to mint only appreciation above existing position debt.
     * @param positionId Identifier of the position to draw against.
     * @param recipient Address receiving the minted uAsset.
     * @return amountInUAsset Amount of uAsset minted to the recipient.
     */
    function drawUAsset(uint256 positionId, address recipient) external returns (uint256 amountInUAsset);

    /**
     * @notice Adds SY to the wrap pool and mints uAsset to a recipient.
     * @dev Pulls SY from `msg.sender`, increases shared wrap-pool principal and debt, and does not create a
     * per-user position record.
     * @param amountInSY Amount of SY to add to the wrap pool.
     * @param uAssetRecipient Address receiving the minted uAsset.
     * @return UAssetAmount Amount of uAsset minted.
     */
    function wrapStake(uint256 amountInSY, address uAssetRecipient) external returns (uint256 UAssetAmount);

    /**
     * @notice Redeems part or all of a position after lock expiry.
     * @dev Position-owner path. Burns uAsset from the caller via `repay`. Full redeem burns all remaining
     * position debt; partial redeem uses ceiling rounding and rejects any partial path that would consume all
     * remaining debt. Enforces `minTokenOut` on direct SY or downstream SY redemption.
     * @param positionId Identifier of the position to redeem from.
     * @param syRedeemed Amount of SY principal to redeem.
     * @param receiver Address receiving the redemption proceeds.
     * @param tokenOut Token requested on redemption.
     * @param minTokenOut Minimum acceptable token output from redemption.
     * @return UAssetBurned Amount of uAsset burned from the caller.
     * @return amountTokenOut Amount of output token delivered to the receiver.
     */
    function redeem(uint256 positionId, uint256 syRedeemed, address receiver, address tokenOut, uint256 minTokenOut)
        external
        returns (uint256 UAssetBurned, uint256 amountTokenOut);

    /**
     * @notice Redeems wrap-pool uAsset into SY or another token.
     * @dev Burns caller-provided uAsset through the stake manager minter account, reduces shared wrap debt and
     * principal, then sends direct SY or redeemed `tokenOut` to `receiver`.
     * @param amountInUAsset Amount of uAsset to redeem.
     * @param receiver Address receiving the redemption proceeds.
     * @param tokenOut Token requested on redemption.
     * @param minTokenOut Minimum acceptable token output from redemption.
     * @return amountTokenOut Amount of output token delivered to the receiver.
     */
    function wrapRedeem(uint256 amountInUAsset, address receiver, address tokenOut, uint256 minTokenOut)
        external
        returns (uint256 amountTokenOut);

    /**
     * @notice Lets the keeper redeem a matured position by burning keeper-provided uAsset.
     * @dev Keeper-only path. Burns keeper-provided uAsset, sends floor-converted debt-equivalent SY to
     * `receiver`, and sends any remaining released SY to the position owner. Reverts with
     * `InsufficientSyCollateral` if the position is undercollateralized or the keeper's debt-equivalent
     * share would exceed the proportional SY released (no capping).
     * @param positionId Identifier of the position being redeemed.
     * @param amountInUAsset Amount of uAsset the keeper burns.
     * @param receiver Address receiving the keeper principal in SY.
     * @return UAssetBurned Amount of uAsset burned by the keeper.
     * @return keeperPrincipalSY Debt-equivalent SY sent to the keeper receiver.
     * @return ownerExcessSY Excess SY sent back to the position owner.
     */
    function keepRedeem(uint256 positionId, uint256 amountInUAsset, address receiver)
        external
        returns (uint256 UAssetBurned, uint256 keeperPrincipalSY, uint256 ownerExcessSY);

    /**
     * @notice Harvests wrap-pool yield above outstanding wrap debt to the revenue pool.
     * @dev Owner-only path. Harvestable yield is wrap-pool SY exceeding debt-equivalent SY at the current
     * exchange rate; wrap uAsset debt is unchanged.
     * @param tokenOut Token requested for harvested yield.
     * @param minTokenOut Minimum acceptable token output from the SY redemption.
     * @return amountTokenOut Amount of harvested token sent to the revenue pool.
     */
    function harvestWrapYield(address tokenOut, uint256 minTokenOut) external returns (uint256 amountTokenOut);

    /**
     * @notice Updates the minimum SY stake required for opening a position.
     * @dev Only the owner may update this threshold.
     * @param minStake New minimum stake amount.
     */
    function setMinStake(uint256 minStake) external;

    /**
     * @notice Updates the revenue pool receiving harvested wrap yield.
     * @dev Only the owner may update this destination address.
     * @param revenuePool Address of the new revenue pool.
     */
    function setRevenuePool(address revenuePool) external;

    /**
     * @notice Updates the keeper address.
     * @dev Only the owner may grant keeper permissions.
     * @param keeper Address granted keeper permissions.
     */
    function setKeeper(address keeper) external;

    event Stake(
        uint256 indexed positionId,
        address indexed owner,
        uint256 amountInSY,
        uint256 principalValue,
        uint256 UAssetMinted,
        uint256 deadline
    );

    event DrawUAsset(uint256 indexed positionId, address indexed recipient, uint256 amountInUAsset);

    event Redeem(
        uint256 indexed positionId,
        address indexed owner,
        uint256 syRedeemed,
        uint256 UAssetBurned,
        address indexed receiver,
        address tokenOut,
        uint256 amountTokenOut
    );

    event WrapStake(uint256 amountInSY, uint256 amountInUAsset, address indexed uAssetRecipient);

    event WrapRedeem(
        address indexed receiver, uint256 amountInUAsset, uint256 amountTokenOut, address indexed tokenOut
    );

    event KeepRedeem(
        uint256 indexed positionId,
        address indexed owner,
        uint256 syRedeemed,
        uint256 UAssetBurned,
        address indexed receiver,
        uint256 keeperPrincipalSY,
        uint256 ownerExcessSY
    );

    event HarvestWrapYield(
        address indexed receiver, address indexed tokenOut, uint256 amountInSY, uint256 amountTokenOut
    );

    event SetMinStake(uint256 minStake);
    event SetRevenuePool(address indexed revenuePool);
    event SetKeeper(address indexed keeper);
}
