// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockSY, MockERC20, MockUAsset} from "./mocks/PositionTestMocks.sol";
import {OutrunStakingPositionUpgradeable} from "../../src/position/OutrunStakingPositionUpgradeable.sol";
import {ProxyTestHelper} from "./helpers/ProxyTestHelper.sol";

/**
 * @title Invariant Test Handler for OutrunStakingPosition
 * @dev Exercises the staking position system with random sequences of operations
 */
contract PositionHandler is Test {
    OutrunStakingPositionUpgradeable public position;
    MockSY public sy;
    MockUAsset public uAsset;
    MockERC20 public underlying;

    address public owner;
    address public keeper;
    address public revenuePool;

    address[3] public actors;
    uint256 public constant INITIAL_BALANCE = 10_000e18;
    uint256 public constant MIN_STAKE = 1e18;
    uint256 public constant MAX_AMOUNT = 1000e18;

    // Ghost variables for tracking state
    uint256[] public activePositionIds;
    mapping(uint256 => bool) public isPositionActive;
    uint256 public ghostTotalSyInPositions;
    uint256 public ghostTotalUAssetMintedInPositions;
    uint256 public ghostMaxDeadline;

    constructor(
        OutrunStakingPositionUpgradeable _position,
        MockSY _sy,
        MockUAsset _uAsset,
        MockERC20 _underlying,
        address _owner,
        address _keeper,
        address _revenuePool
    ) {
        position = _position;
        sy = _sy;
        uAsset = _uAsset;
        underlying = _underlying;
        owner = _owner;
        keeper = _keeper;
        revenuePool = _revenuePool;

        actors[0] = address(0x1);
        actors[1] = address(0x2);
        actors[2] = address(0x3);

        // Fund all actors with SY and uAsset
        for (uint256 i = 0; i < actors.length; i++) {
            sy.mintShares(actors[i], INITIAL_BALANCE);
            vm.prank(actors[i]);
            sy.approve(address(position), type(uint256).max);
            vm.prank(actors[i]);
            uAsset.approve(address(position), type(uint256).max);
        }

        // Fund the position contract with sufficient SY for redemptions
        sy.mintShares(address(position), INITIAL_BALANCE * 10);

        // Fund keeper
        sy.mintShares(keeper, INITIAL_BALANCE);
        vm.prank(keeper);
        sy.approve(address(position), type(uint256).max);
        vm.prank(keeper);
        uAsset.approve(address(position), type(uint256).max);
    }

    // Helper to get actor from index
    function _getActor(uint256 actorIndex) internal view returns (address) {
        return actors[bound(actorIndex, 0, actors.length - 1)];
    }

    // Helper to bound amount
    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return bound(amount, MIN_STAKE, MAX_AMOUNT);
    }

    /**
     * @notice Stake SY into a locked position
     * @dev Creates a new position with SY stake and mints uAsset
     */
    function stake(uint256 actorIndex, uint256 amountRaw, uint8 lockupDaysRaw) external {
        address actor = _getActor(actorIndex);
        uint256 amount = _boundAmount(amountRaw);
        uint128 lockupDays = uint128(bound(lockupDaysRaw, 1, 365));

        // Ensure actor has enough SY
        if (sy.balanceOf(actor) < amount) {
            sy.mintShares(actor, amount);
        }

        vm.prank(actor);
        (uint256 positionId, uint256 uAssetMinted) = position.stake(amount, lockupDays, actor, actor);

        // Track the new position
        activePositionIds.push(positionId);
        isPositionActive[positionId] = true;
        ghostTotalSyInPositions += amount;
        ghostTotalUAssetMintedInPositions += uAssetMinted;

        // Update max deadline
        (,,, uint128 deadline) = position.positions(positionId);
        if (deadline > ghostMaxDeadline) {
            ghostMaxDeadline = deadline;
        }

        // Ensure position contract has enough SY for future redemptions
        sy.mintShares(address(position), amount);
    }

    /**
     * @notice Draw additional uAsset from an existing position
     * @dev Only draws if there's appreciation (exchange rate increased)
     */
    function drawUAsset(uint256 actorIndex, uint256 positionIndexRaw) external {
        if (activePositionIds.length == 0) return;

        address actor = _getActor(actorIndex);
        uint256 positionIndex = bound(positionIndexRaw, 0, activePositionIds.length - 1);
        uint256 positionId = activePositionIds[positionIndex];

        // Check if actor owns this position
        (address positionOwner,,,) = position.positions(positionId);
        if (positionOwner != actor) return;

        // Try to draw - will revert if no appreciation
        vm.prank(actor);
        try position.drawUAsset(positionId, actor) returns (uint256 amountDrawn) {
            if (amountDrawn > 0) {
                ghostTotalUAssetMintedInPositions += amountDrawn;
            }
        } catch {
            // Nothing to draw is fine
        }
    }

    /**
     * @notice Add SY to the wrap pool and mint uAsset
     */
    function wrapStake(uint256 actorIndex, uint256 amountRaw) external {
        address actor = _getActor(actorIndex);
        uint256 amount = _boundAmount(amountRaw);

        // Ensure actor has enough SY
        if (sy.balanceOf(actor) < amount) {
            sy.mintShares(actor, amount);
        }

        vm.prank(actor);
        position.wrapStake(amount, actor);

        // Ensure position contract has enough SY for wrap redemptions
        sy.mintShares(address(position), amount);
    }

    /**
     * @notice Keeper redeems uAsset from the wrap pool (keeper-only keepWrapRedeem)
     * @dev Multi-participant wrap-redemption coverage is reduced because only the keeper can
     *      call keepWrapRedeem. The keeper must hold enough uAsset to burn; the handler tops it
     *      up from its mint authority (mirroring the keepRedeem handler). An undercollateralized
     *      pool reverts WrapPoolUndercollateralized (all-or-nothing), caught here.
     */
    function keepWrapRedeem(uint256 amountRaw) external {
        uint256 wrapDebt = position.wrapUAssetDebt();
        if (wrapDebt == 0) return;

        uint256 amount = bound(amountRaw, 1, wrapDebt);

        // Keeper must hold enough uAsset to burn on redemption.
        if (uAsset.balanceOf(keeper) < amount) {
            uAsset.mint(keeper, amount - uAsset.balanceOf(keeper) + 1e18);
        }

        vm.prank(keeper);
        try position.keepWrapRedeem(amount, keeper) {
        // Redemption succeeded
        }
            catch {
            // keepWrapRedeem can revert on dust rounding or when the pool is undercollateralized
            // (WrapPoolUndercollateralized — all-or-nothing semantics).
        }
    }

    /**
     * @notice Redeem from a matured position
     * @dev Warps time to ensure position is mature
     */
    function redeem(uint256 actorIndex, uint256 positionIndexRaw, uint256 percentRaw) external {
        if (activePositionIds.length == 0) return;

        address actor = _getActor(actorIndex);
        uint256 positionIndex = bound(positionIndexRaw, 0, activePositionIds.length - 1);
        uint256 positionId = activePositionIds[positionIndex];

        // Check if actor owns this position
        (address positionOwner, uint256 syStaked,,) = position.positions(positionId);
        if (positionOwner != actor || syStaked == 0) return;

        // Warp to ensure position is mature
        if (ghostMaxDeadline > block.timestamp) {
            vm.warp(ghostMaxDeadline + 1);
        }

        // Determine redemption amount (1% to 100% of position)
        uint256 percent = bound(percentRaw, 1, 100);
        uint256 syRedeemed = (syStaked * percent) / 100;

        // Ensure actor has enough uAsset to burn
        uint256 uAssetNeeded = _estimateUAssetBurn(positionId, syRedeemed);
        if (uAsset.balanceOf(actor) < uAssetNeeded) {
            // Mint more uAsset to actor for testing
            uAsset.mint(actor, uAssetNeeded - uAsset.balanceOf(actor) + 1e18);
        }

        vm.prank(actor);
        try position.redeem(positionId, syRedeemed, actor, address(sy), 0) returns (uint256 uAssetBurned, uint256) {
            // Update ghost state
            ghostTotalSyInPositions -= syRedeemed;
            ghostTotalUAssetMintedInPositions -= uAssetBurned;

            // Check if position is fully redeemed
            (, uint256 newSyStaked,,) = position.positions(positionId);
            if (newSyStaked == 0) {
                // Position deleted, remove from tracking
                _removePosition(positionId);
            }
        } catch {
            // Redemption can fail for various reasons
        }
    }

    /**
     * @notice Keeper redeems a matured position
     */
    function keepRedeem(uint256 positionIndexRaw, uint256 percentRaw) external {
        if (activePositionIds.length == 0) return;

        uint256 positionIndex = bound(positionIndexRaw, 0, activePositionIds.length - 1);
        uint256 positionId = activePositionIds[positionIndex];

        (address positionOwner, uint256 syStaked, uint256 uAssetMinted,) = position.positions(positionId);
        if (positionOwner == address(0) || syStaked == 0) return;

        // Warp to ensure position is mature
        if (ghostMaxDeadline > block.timestamp) {
            vm.warp(ghostMaxDeadline + 1);
        }

        // Determine amount (1% to 100% of uAssetMinted)
        uint256 percent = bound(percentRaw, 1, 100);
        uint256 amountInUAsset = (uAssetMinted * percent) / 100;

        // Ensure keeper has enough uAsset
        if (uAsset.balanceOf(keeper) < amountInUAsset) {
            uAsset.mint(keeper, amountInUAsset - uAsset.balanceOf(keeper) + 1e18);
        }

        vm.prank(keeper);
        try position.keepRedeem(positionId, amountInUAsset, keeper) returns (uint256, uint256, uint256) {
            // Update ghost state
            uint256 syRedeemed = (syStaked * amountInUAsset) / uAssetMinted;
            ghostTotalSyInPositions -= syRedeemed;
            ghostTotalUAssetMintedInPositions -= amountInUAsset;

            // Check if position is fully redeemed
            (, uint256 newSyStaked,,) = position.positions(positionId);
            if (newSyStaked == 0) {
                _removePosition(positionId);
            }
        } catch {
            // keepRedeem can fail for various reasons
        }
    }

    /**
     * @notice Change the exchange rate to test rate change scenarios
     */
    function changeExchangeRate(uint256 rateRaw) external {
        // Rate between 5e17 (0.5) and 5e18 (5.0)
        uint256 newRate = bound(rateRaw, 5e17, 5e18);
        sy.setExchangeRate(newRate);
    }

    /**
     * @notice Harvest wrap yield (owner only)
     */
    function harvestWrapYield() external {
        vm.prank(owner);
        position.harvestWrapYield(address(sy), 0);
    }

    // Helper to estimate uAsset burn for redemption
    function _estimateUAssetBurn(uint256 positionId, uint256 syRedeemed) internal view returns (uint256) {
        (, uint256 syStaked, uint256 uAssetMinted,) = position.positions(positionId);
        if (syRedeemed == syStaked) return uAssetMinted;

        uint256 uAssetBurned = Math.mulDiv(uAssetMinted, syRedeemed, syStaked, Math.Rounding.Ceil);
        return uAssetBurned >= uAssetMinted ? uAssetMinted : uAssetBurned;
    }

    // Helper to remove position from tracking
    function _removePosition(uint256 positionId) internal {
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            if (activePositionIds[i] == positionId) {
                activePositionIds[i] = activePositionIds[activePositionIds.length - 1];
                activePositionIds.pop();
                isPositionActive[positionId] = false;
                break;
            }
        }
    }

    // View functions for invariant checks
    function getActivePositionCount() external view returns (uint256) {
        return activePositionIds.length;
    }

    function getActivePositionId(uint256 index) external view returns (uint256) {
        return activePositionIds[index];
    }

    function getGhostTotalSyInPositions() external view returns (uint256) {
        return ghostTotalSyInPositions;
    }

    function getGhostTotalUAssetMinted() external view returns (uint256) {
        return ghostTotalUAssetMintedInPositions;
    }
}

/**
 * @title Invariant Tests for OutrunStakingPosition
 * @dev Verifies system-level invariants hold after any sequence of operations
 */
contract OutrunStakingPositionInvariantTest is StdInvariant, Test {
    PositionHandler public handler;
    OutrunStakingPositionUpgradeable public position;
    MockSY public sy;
    MockUAsset public uAsset;
    MockERC20 public underlying;

    address public owner = address(0xA11CE);
    address public keeper = address(0xB0B);
    address public revenuePool = address(0xFEE);

    function setUp() external {
        underlying = new MockERC20("Mock Asset", "mAST");
        sy = new MockSY(address(underlying));
        uAsset = new MockUAsset();

        position = OutrunStakingPositionUpgradeable(
            ProxyTestHelper.deploy(
                address(new OutrunStakingPositionUpgradeable()),
                abi.encodeCall(
                    OutrunStakingPositionUpgradeable.initialize,
                    (owner, 1, revenuePool, address(sy), address(uAsset), keeper)
                )
            )
        );

        uAsset.setMintingCap(address(position), type(uint256).max);

        handler = new PositionHandler(position, sy, uAsset, underlying, owner, keeper, revenuePool);
        uAsset.setMintingCap(address(handler), type(uint256).max);

        // Target the handler for invariant testing
        targetContract(address(handler));
    }

    /**
     * @notice Invariant 1: syTotalStaking equals sum of position SY + wrap pool SY
     * @dev This is the MOST CRITICAL invariant - ensures accounting consistency
     */
    function invariant_syTotalStakingMatchesSum() public view {
        uint256 totalPositionSY = 0;
        uint256 activeCount = handler.getActivePositionCount();

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 positionId = handler.getActivePositionId(i);
            (, uint256 syStaked,,) = position.positions(positionId);
            if (syStaked > 0) {
                totalPositionSY += syStaked;
            }
        }

        uint256 expectedTotal = totalPositionSY + position.syWrapStaking();
        assertEq(
            position.syTotalStaking(),
            expectedTotal,
            "Invariant violation: syTotalStaking != sum(positions.syStaked) + syWrapStaking"
        );
    }

    /**
     * @notice Invariant 2: Wrap pool accounting bounds (rate-independent)
     * @dev The wrap pool can be temporarily undercollateralized when the exchange rate drops.
     * keepWrapRedeem is keeper-only and reverts WrapPoolUndercollateralized on an
     * undercollateralized pool (all-or-nothing semantics), while harvestWrapYield
     * only removes excess SY above the debt ceiling. A collateral ratio is therefore NOT a
     * valid invariant (it tracks the external rate). We assert only that the two accounting
     * quantities stay within legal, non-wrapped-around bounds.
     */
    function invariant_wrapPoolAccountingBounded() public view {
        uint256 syWrap = position.syWrapStaking();
        uint256 wrapDebt = position.wrapUAssetDebt();

        // An underflow-wrapped syWrap approaches 2^256 and necessarily exceeds syTotalStaking.
        assertLe(syWrap, position.syTotalStaking(), "Invariant violation: syWrapStaking > syTotalStaking");

        // wrapUAssetDebt is part of the position contract's net minted amount (see invariant 4) and cannot exceed it.
        (, uint256 positionNetMinted) = uAsset.mintingStatusTable(address(position));
        assertLe(wrapDebt, positionNetMinted, "Invariant violation: wrapUAssetDebt > position net minted");
    }

    /**
     * @notice Invariant 3: Position IDs are monotonically increasing
     * @dev Each new position gets a higher ID than the previous one
     */
    function invariant_positionIdMonotonic() public view {
        uint256 currentId = position.idCounter();
        uint256 activeCount = handler.getActivePositionCount();

        // All active positions should have IDs <= current counter
        for (uint256 i = 0; i < activeCount; i++) {
            uint256 positionId = handler.getActivePositionId(i);
            assertLe(positionId, currentId, "Invariant violation: position ID exceeds counter");
        }
    }

    /**
     * @notice Invariant 4: uAsset supply accounting consistency
     * @dev Total uAsset minted equals sum of position debt + wrap debt
     */
    function invariant_uAssetSupplyConsistency() public view {
        uint256 totalPositionDebt = 0;
        uint256 activeCount = handler.getActivePositionCount();

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 positionId = handler.getActivePositionId(i);
            (,, uint256 uAssetMinted,) = position.positions(positionId);
            if (uAssetMinted > 0) {
                totalPositionDebt += uAssetMinted;
            }
        }

        // The position contract's net minted amount (per-minter ledger). Read mintingStatusTable[address(position)]
        // instead of totalSupply() — the handler mints uAsset directly to actor/keeper on redeem/keepRedeem
        // to top up burned balances, which would pollute totalSupply; the per-minter ledger isolates the position's net amount.
        (, uint256 positionNetMinted) = uAsset.mintingStatusTable(address(position));

        // The position contract's net minted amount must equal the currently outstanding position debt + wrap debt.
        assertEq(
            positionNetMinted,
            totalPositionDebt + position.wrapUAssetDebt(),
            "Invariant violation: position net minted != sum(position debt) + wrap debt"
        );
    }

    /**
     * @notice Invariant 5: No position has UAssetMinted == 0 with syStaked > 0
     * @dev A valid position always has UAssetMinted > 0 when syStaked > 0
     */
    function invariant_validPositionsHaveUAssetDebt() public view {
        uint256 activeCount = handler.getActivePositionCount();

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 positionId = handler.getActivePositionId(i);
            (address positionOwner, uint256 syStaked, uint256 uAssetMinted,) = position.positions(positionId);

            // If position is active (has owner), check consistency
            if (positionOwner != address(0) && syStaked > 0) {
                assertGt(uAssetMinted, 0, "Invariant violation: position with syStaked > 0 has no uAsset debt");
            }
        }
    }

    /**
     * @notice Invariant 6: Position owner consistency
     * @dev Active positions should have valid owners
     */
    function invariant_activePositionsHaveValidOwners() public view {
        uint256 activeCount = handler.getActivePositionCount();

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 positionId = handler.getActivePositionId(i);
            (address positionOwner, uint256 syStaked,,) = position.positions(positionId);

            // If position is tracked as active, it should either have a valid owner
            // or be deleted from tracking
            if (syStaked > 0) {
                assertTrue(positionOwner != address(0), "Invariant violation: active position has zero owner");
            }
        }
    }

    /**
     * @notice Invariant 7: Ghost state tracking matches contract state
     * @dev Ensures our handler's ghost variables accurately track contract state
     */
    function invariant_ghostStateMatchesContractState() public view {
        uint256 totalPositionSY = 0;
        uint256 totalPositionUAsset = 0;
        uint256 activeCount = handler.getActivePositionCount();

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 positionId = handler.getActivePositionId(i);
            (, uint256 syStaked, uint256 uAssetMinted,) = position.positions(positionId);
            if (syStaked > 0) {
                totalPositionSY += syStaked;
            }
            if (uAssetMinted > 0) {
                totalPositionUAsset += uAssetMinted;
            }
        }

        // Ghost state should match actual contract state
        assertEq(
            handler.getGhostTotalSyInPositions(), totalPositionSY, "Invariant violation: ghost SY tracking mismatch"
        );

        assertEq(
            handler.getGhostTotalUAssetMinted(),
            totalPositionUAsset,
            "Invariant violation: ghost uAsset tracking mismatch"
        );
    }
}
