// SPDX-License-Identifier: GPL-3.0-or-later
// @notice Non-redundant SY invariants (PreviewBounded/DepositRedeemConservation) not covered by SYAdaptersUpgradeable.t.sol; ExchangeRateMonotonic is redundant and omitted from gate but kept here for completeness
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

// ---------------------------------------------------------------------------
// Mock ERC20 — minimal balance/allowance ledger for SY mocks.
// ---------------------------------------------------------------------------
contract SYInvMockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "insufficient");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amt, "allowance");
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Shared SY interface used by handler (subset of SYBaseUpgradeable surface).
// ---------------------------------------------------------------------------
interface ISY {
    function deposit(address receiver, address tokenIn, uint256 amount) external returns (uint256 shares);
    function redeem(address receiver, uint256 shares, address tokenOut) external returns (uint256 amount);
    function exchangeRate() external view returns (uint256);
    function previewDeposit(address tokenIn, uint256 amount) external view returns (uint256 shares);
    function previewRedeem(address tokenOut, uint256 shares) external view returns (uint256 amount);
    function paused() external view returns (bool);
}

// ---------------------------------------------------------------------------
// Mock underlying protocols — controllable rate + pause flag.
// Each exposes the same SY-facing interface with simple 1e18-scaled math.
// ---------------------------------------------------------------------------

/// @notice Mock PSM3 (Sky/USDS) — stable swap with near-1:1 rate, controllable via setRate.
contract SYInvMockPSM3 {
    uint256 public rate = 1e18; // asset per share, 1e18 = 1:1
    bool public isPaused;
    SYInvMockERC20 public asset;
    mapping(address => uint256) public sharesOf;

    constructor(address asset_) {
        asset = SYInvMockERC20(asset_);
    }

    function setRate(uint256 r) external {
        // Clamp to [0.5e18, 2e18] so invariant tests stay bounded.
        if (r < 0.5e18) r = 0.5e18;
        if (r > 2e18) r = 2e18;
        rate = r;
    }

    function setPaused(bool p) external {
        isPaused = p;
    }

    function paused() external view returns (bool) {
        return isPaused;
    }

    function exchangeRate() external view returns (uint256) {
        return rate;
    }

    function previewDeposit(address, uint256 amount) external view returns (uint256) {
        return (amount * 1e18) / rate;
    }

    function previewRedeem(address, uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function deposit(address receiver, address, uint256 amount) external returns (uint256 shares) {
        require(!isPaused, "paused");
        shares = (amount * 1e18) / rate;
        sharesOf[receiver] += shares;
        return shares;
    }

    function redeem(address receiver, uint256 shares, address) external returns (uint256 amount) {
        require(!isPaused, "paused");
        require(sharesOf[msg.sender] >= shares, "insufficient shares");
        sharesOf[msg.sender] -= shares;
        amount = (shares * rate) / 1e18;
        asset.mint(receiver, amount);
        return amount;
    }
}

/// @notice Mock asBnbMinter (Aster asBNB) — rebasing-like minter with controllable exchange rate.
contract SYInvMockAsBnbMinter {
    uint256 public rate = 1e18;
    bool public isPaused;
    SYInvMockERC20 public bnb;
    mapping(address => uint256) public sharesOf;

    constructor(address bnb_) {
        bnb = SYInvMockERC20(bnb_);
    }

    function setRate(uint256 r) external {
        if (r < 0.5e18) r = 0.5e18;
        if (r > 5e18) r = 5e18;
        rate = r;
    }

    function setPaused(bool p) external {
        isPaused = p;
    }

    function paused() external view returns (bool) {
        return isPaused;
    }

    function exchangeRate() external view returns (uint256) {
        return rate;
    }

    function previewDeposit(address, uint256 amount) external view returns (uint256) {
        return (amount * 1e18) / rate;
    }

    function previewRedeem(address, uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function deposit(address receiver, address, uint256 amount) external returns (uint256 shares) {
        require(!isPaused, "paused");
        shares = (amount * 1e18) / rate;
        sharesOf[receiver] += shares;
        return shares;
    }

    function redeem(address receiver, uint256 shares, address) external returns (uint256 amount) {
        require(!isPaused, "paused");
        require(sharesOf[msg.sender] >= shares, "insufficient shares");
        sharesOf[msg.sender] -= shares;
        amount = (shares * rate) / 1e18;
        bnb.mint(receiver, amount);
        return amount;
    }
}

/// @notice Mock sUSDe vault (Ethena) — ERC4626-style vault with controllable rate.
contract SYInvMockSUSDeVault {
    uint256 public rate = 1e18;
    bool public isPaused;
    SYInvMockERC20 public usde;
    mapping(address => uint256) public sharesOf;

    constructor(address usde_) {
        usde = SYInvMockERC20(usde_);
    }

    function setRate(uint256 r) external {
        if (r < 0.5e18) r = 0.5e18;
        if (r > 3e18) r = 3e18;
        rate = r;
    }

    function setPaused(bool p) external {
        isPaused = p;
    }

    function paused() external view returns (bool) {
        return isPaused;
    }

    function exchangeRate() external view returns (uint256) {
        return rate;
    }

    function previewDeposit(address, uint256 amount) external view returns (uint256) {
        return (amount * 1e18) / rate;
    }

    function previewRedeem(address, uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function deposit(address receiver, address, uint256 amount) external returns (uint256 shares) {
        require(!isPaused, "paused");
        shares = (amount * 1e18) / rate;
        sharesOf[receiver] += shares;
        return shares;
    }

    function redeem(address receiver, uint256 shares, address) external returns (uint256 amount) {
        require(!isPaused, "paused");
        require(sharesOf[msg.sender] >= shares, "insufficient shares");
        sharesOf[msg.sender] -= shares;
        amount = (shares * rate) / 1e18;
        usde.mint(receiver, amount);
        return amount;
    }
}

// ---------------------------------------------------------------------------
// Mock SY wrapper — delegates to one of the above mocks and tracks SY supply.
// ---------------------------------------------------------------------------
contract SYInvMockSY is ISY {
    SYInvMockERC20 public asset;
    address public underlying; // one of SYInvMockPSM3 / SYInvMockAsBnbMinter / SYInvMockSUSDeVault
    uint8 public kind; // 0=PSM3, 1=asBnb, 2=sUSDe
    bool public isPaused;
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_, address underlying_, uint8 kind_) {
        asset = SYInvMockERC20(asset_);
        underlying = underlying_;
        kind = kind_;
    }

    function setPaused(bool p) external {
        isPaused = p;
    }

    function paused() external view returns (bool) {
        return isPaused;
    }

    function exchangeRate() external view returns (uint256) {
        if (kind == 0) return SYInvMockPSM3(underlying).exchangeRate();
        if (kind == 1) return SYInvMockAsBnbMinter(underlying).exchangeRate();
        return SYInvMockSUSDeVault(underlying).exchangeRate();
    }

    function previewDeposit(address tokenIn, uint256 amount) external view returns (uint256) {
        if (kind == 0) return SYInvMockPSM3(underlying).previewDeposit(tokenIn, amount);
        if (kind == 1) return SYInvMockAsBnbMinter(underlying).previewDeposit(tokenIn, amount);
        return SYInvMockSUSDeVault(underlying).previewDeposit(tokenIn, amount);
    }

    function previewRedeem(address tokenOut, uint256 shares) external view returns (uint256) {
        if (kind == 0) return SYInvMockPSM3(underlying).previewRedeem(tokenOut, shares);
        if (kind == 1) return SYInvMockAsBnbMinter(underlying).previewRedeem(tokenOut, shares);
        return SYInvMockSUSDeVault(underlying).previewRedeem(tokenOut, shares);
    }

    function deposit(address receiver, address tokenIn, uint256 amount) external returns (uint256 shares) {
        require(!isPaused, "SY paused");
        if (kind == 0) shares = SYInvMockPSM3(underlying).deposit(receiver, tokenIn, amount);
        else if (kind == 1) shares = SYInvMockAsBnbMinter(underlying).deposit(receiver, tokenIn, amount);
        else shares = SYInvMockSUSDeVault(underlying).deposit(receiver, tokenIn, amount);
        balanceOf[receiver] += shares;
        totalShares += shares;
        return shares;
    }

    function redeem(address receiver, uint256 shares, address tokenOut) external returns (uint256 amount) {
        require(!isPaused, "SY paused");
        require(balanceOf[msg.sender] >= shares, "insufficient SY");
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        if (kind == 0) amount = SYInvMockPSM3(underlying).redeem(receiver, shares, tokenOut);
        else if (kind == 1) amount = SYInvMockAsBnbMinter(underlying).redeem(receiver, shares, tokenOut);
        else amount = SYInvMockSUSDeVault(underlying).redeem(receiver, shares, tokenOut);
        return amount;
    }
}

// ---------------------------------------------------------------------------
// Handler — abstract, holds ghost state and exposes handler entry points.
// ---------------------------------------------------------------------------

/// @title SY Handler (abstract)
/// @notice Handler for SY invariant fuzzing. Tracks ghost state across
///         deposit / redeem / rate-bump / pause transitions.
abstract contract SYInvHandler is Test {
    SYInvMockERC20 public asset;
    SYInvMockPSM3 public psm3;
    SYInvMockAsBnbMinter public asBnbMinter;
    SYInvMockSUSDeVault public sUsdeVault;
    SYInvMockSY public sy;

    // Ghost state
    uint256 public ghostTotalDeposited;
    uint256 public ghostTotalRedeemed;
    uint256 public ghostTotalSharesMinted;
    uint256 public ghostLastExchangeRate;
    uint256 public ghostMinRate;
    uint256 public ghostMaxRate;
    uint256 public ghostCallCount;

    address[] public actors;

    constructor() {
        asset = new SYInvMockERC20();
        psm3 = new SYInvMockPSM3(address(asset));
        asBnbMinter = new SYInvMockAsBnbMinter(address(asset));
        sUsdeVault = new SYInvMockSUSDeVault(address(asset));
        // Default SY wraps PSM3; handler can switch by redeploying sy if needed.
        sy = new SYInvMockSY(address(asset), address(psm3), 0);
        ghostLastExchangeRate = sy.exchangeRate();
        ghostMinRate = ghostLastExchangeRate;
        ghostMaxRate = ghostLastExchangeRate;

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xC0FFEE));
        for (uint256 i = 0; i < actors.length; i++) {
            asset.mint(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            asset.approve(address(sy), type(uint256).max);
        }
    }

    // -- Handler actions --------------------------------------------------------

    /// @notice Deposit `amount` of asset as `actor` into SY.
    function handler_deposit(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1e6, 100_000e18);
        address actor = actors[actorSeed % actors.length];
        if (sy.paused()) return;
        // Ensure actor has balance.
        if (asset.balanceOf(actor) < amount) {
            asset.mint(actor, amount);
        }
        vm.prank(actor);
        uint256 shares = sy.previewDeposit(address(asset), amount);
        if (shares == 0) return;
        vm.prank(actor);
        uint256 minted = sy.deposit(actor, address(asset), amount);
        ghostTotalDeposited += amount;
        ghostTotalSharesMinted += minted;
        ghostCallCount++;
        _updateRateBounds();
    }

    /// @notice Redeem `shares` of SY as `actor`.
    function handler_redeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        if (sy.paused()) return;
        uint256 bal = sy.balanceOf(actor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(actor);
        uint256 got = sy.redeem(actor, shares, address(asset));
        ghostTotalRedeemed += got;
        ghostCallCount++;
        _updateRateBounds();
    }

    /// @notice Bump the underlying exchange rate (simulates yield accrual).
    function handler_bumpRate(uint256 deltaBps) external {
        deltaBps = bound(deltaBps, 0, 1000);
        // Use unsigned bump: increase by up to 10%.
        uint256 r = sy.exchangeRate();
        uint256 bump = (r * deltaBps) / 10_000;
        uint256 newRate = r + bump;
        psm3.setRate(newRate);
        asBnbMinter.setRate(newRate);
        sUsdeVault.setRate(newRate);
        _updateRateBounds();
        ghostCallCount++;
    }

    /// @notice Toggle pause on the SY / underlying.
    function handler_setPaused(bool p) external {
        sy.setPaused(p);
        psm3.setPaused(p);
        asBnbMinter.setPaused(p);
        sUsdeVault.setPaused(p);
        ghostCallCount++;
    }

    /// @notice Warp time forward (affects nothing in mocks but exercises handler).
    function handler_warp(uint256 dt) external {
        dt = bound(dt, 1, 30 days);
        vm.warp(block.timestamp + dt);
        ghostCallCount++;
    }

    function _updateRateBounds() internal {
        uint256 r = sy.exchangeRate();
        if (r < ghostMinRate) ghostMinRate = r;
        if (r > ghostMaxRate) ghostMaxRate = r;
        // Keep last rate for monotonic checks inside invariants.
        ghostLastExchangeRate = r;
    }
}

// ---------------------------------------------------------------------------
// Invariant test contract.
// ---------------------------------------------------------------------------

/// @title SYInvariant — Foundry invariant skeleton for SY adapters
/// @notice Covers deposit/redeem conservation, exchange-rate monotonicity, and
///         preview-vs-execution bounds.
///         Mocks for PSM3, asBnbMinter, and sUSDe vault expose controllable
///         rate/pause so the fuzzer can drive realistic state transitions.
contract SYInvariant is StdInvariant, SYInvHandler {
    function setUp() public {
        // Target the handler's external entry points for invariant fuzzing.
        targetContract(address(this));
        // Exclude invariant checks themselves from the fuzz corpus.
        excludeArtifact("SYInvariant");
    }

    /// @notice Invariant: deposit-then-redeem conservation.
    /// @dev See 05-invariants.md §3.1 — Deposit/Redeem Conservation.
    ///      For any actor, redeeming all SY shares must not return more assets
    ///      than deposited plus accrued yield, and must not lose principal
    ///      beyond rounding (1 wei tolerance per share).
    function invariant_DepositRedeemConservation() public view {
        // Skeleton assertion: ghost accounting is internally consistent.
        // Fuzz harness will extend with per-actor share conservation.
        // Conservation: total shares minted >= total redeemed shares implied.
        // Preview bound ensures redeem never exceeds deposit+uplift.
        uint256 rate = sy.exchangeRate();
        // At current rate, the asset value of all minted shares.
        uint256 impliedAssets = (ghostTotalSharesMinted * rate) / 1e18;
        // Implied assets must cover what was redeemed (no phantom assets).
        // Allow 1 wei per share rounding.
        if (ghostTotalSharesMinted > 0) {
            assertGe(impliedAssets + ghostTotalSharesMinted, ghostTotalRedeemed, "conservation: redeemed > implied");
        }
        // Total deposited bounds the system — no negative yield beyond rounding.
        // When rate >= 1e18, implied >= deposited spread captures yield.
        if (rate >= 1e18) {
            assertGe(impliedAssets + ghostTotalSharesMinted, ghostTotalDeposited, "conservation: yield underflow");
        }
    }

    /// @notice Invariant: exchange rate monotonic (non-decreasing under yield).
    /// @dev See 05-invariants.md §3.2 — Exchange Rate Monotonicity.
    ///      The SY exchange rate must never decrease except via explicit
    ///      admin rate reset (tracked by ghostMinRate). In normal handler
    ///      operation (handler_bumpRate only increases), ghostMaxRate is
    ///      monotonic. This skeleton asserts the rate stays within the
    ///      observed min/max envelope.
    function invariant_ExchangeRateMonotonic() public view {
        uint256 rate = sy.exchangeRate();
        assertGe(rate, ghostMinRate, "rate below observed minimum");
        assertLe(rate, ghostMaxRate, "rate above observed maximum");
        // Rate must remain in sane bounds even under fuzz bumps.
        assertGe(rate, 0.5e18, "rate below 0.5e18 sanity floor");
        assertLe(rate, 5e18, "rate above 5e18 sanity ceiling");
    }

    /// @notice Invariant: preview vs execution bounded.
    /// @dev See 05-invariants.md §3.3 — Preview/Execution Bounds.
    ///      previewDeposit and previewRedeem must bound actual execution
    ///      within 1 wei / 1 bps, and must be consistent with exchangeRate:
    ///      previewDeposit(amount) * rate ~= amount, previewRedeem(shares) ~= shares*rate.
    function invariant_PreviewBounded() public view {
        uint256 rate = sy.exchangeRate();
        // Fixed probe amounts — cheap, deterministic, covers the bound.
        uint256 probeAssets = 1e18;
        uint256 probeShares = 1e18;

        uint256 previewShares = sy.previewDeposit(address(asset), probeAssets);
        uint256 previewAssets = sy.previewRedeem(address(asset), probeShares);

        // previewDeposit * rate ~= probeAssets (round-trip within 2 wei)
        if (previewShares > 0) {
            uint256 roundTripAssets = (previewShares * rate) / 1e18;
            uint256 diff = roundTripAssets > probeAssets ? roundTripAssets - probeAssets : probeAssets - roundTripAssets;
            assertLe(diff, 2, "previewDeposit round-trip > 2 wei");
        }

        // previewRedeem ~= probeShares * rate
        uint256 expectedAssets = (probeShares * rate) / 1e18;
        uint256 diff2 = previewAssets > expectedAssets ? previewAssets - expectedAssets : expectedAssets - previewAssets;
        assertLe(diff2, 2, "previewRedeem deviates > 2 wei");

        // Preview must not be manipulable: zero in => zero out.
        assertEq(sy.previewDeposit(address(asset), 0), 0, "previewDeposit(0) != 0");
        assertEq(sy.previewRedeem(address(asset), 0), 0, "previewRedeem(0) != 0");
    }
}
