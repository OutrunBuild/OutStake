// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TokenHelper} from "../libraries/TokenHelper.sol";
import {IStandardizedYield} from "./interfaces/IStandardizedYield.sol";
import {OutrunERC20PausableUpgradeable} from "../assets/base/OutrunERC20PausableUpgradeable.sol";

/// @title Outrun Standardized Yield (SY) abstract base contract
/// @notice SY (Standardized Yield) is a wrapper token that represents a yield-bearing position. Users deposit
///      input tokens and receive SY shares. The exchange rate between SY and the underlying asset grows over
///      time as yield accrues.
abstract contract SYBaseUpgradeable is
    IStandardizedYield,
    OutrunERC20PausableUpgradeable,
    TokenHelper,
    UUPSUpgradeable
{
    /// @custom:storage-location erc7201:outrun.storage.SYBase
    // forge-lint: disable-next-line(pascal-case-struct)
    struct SYBaseStorage {
        // The external token that actually accrues yield (e.g., aToken for Aave, wstETH for Lido, weETH for EtherFi).
        address yieldBearingToken;
        // The only caller allowed to burn this contract's SY balance through redeem(..., true).
        address trustedRouter;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.SYBase")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SY_BASE_STORAGE_LOCATION =
        0x47ee1d05b1829703ec3dd61a22c784c3e0b2d5dbffb0a55782381dabc9c3eb00;

    event SetTrustedRouter(address indexed oldRouter, address indexed newRouter);
    event Sweep(address indexed token, address indexed to, uint256 amount);

    error SYUnauthorizedInternalRedeemer(address caller);
    error SYSweepInvalidToken(address token);
    error SYSweepZeroAddress();
    error SYSweepZeroAmount();

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Rescues stranded assets accidentally sent to this SY contract.
    /// @dev Only the owner can sweep. The yield-bearing token is blocked — any
    ///      balance of that token backs SY shares and must not be extracted.
    ///      The SY share token itself (address(this)) is also blocked for the
    ///      same reason: sweeping it would take shares that are pending burn
    ///      via the trusted-router path. Native assets use the NATIVE sentinel
    ///      (address(0)) as `token`, matching TokenHelper. Reentrancy is
    ///      blocked via nonReentrant because native transfers use a low-level call.
    /// @param token Token to rescue (NATIVE sentinel for native ETH/BNB).
    /// @param to Recipient of the rescued assets.
    /// @param amount Amount to rescue.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert SYSweepZeroAddress();
        if (amount == 0) revert SYSweepZeroAmount();
        // The yield-bearing token backs every SY share; sweeping it would steal
        // user backing and break the 1:1 share invariant enforced in deposit.
        if (token == yieldBearingToken()) revert SYSweepInvalidToken(token);
        // SY shares held by this contract are pending burn for the router path
        // (redeem with burnFromInternalBalance). Sweeping them would front-run
        // the router, so block the SY address itself as well.
        if (token == address(this)) revert SYSweepInvalidToken(token);
        _transferOut(token, to, amount);
        emit Sweep(token, to, amount);
    }

    /// @notice Sets the router allowed to redeem shares held by this SY contract.
    /// @dev Setting the zero address revokes the current router and closes the internal-balance path.
    /// @param newRouter The new trusted router, or zero to revoke the current router.
    function setTrustedRouter(address newRouter) external onlyOwner {
        SYBaseStorage storage $ = _getSYBaseStorage();
        address oldRouter = $.trustedRouter;
        $.trustedRouter = newRouter;
        emit SetTrustedRouter(oldRouter, newRouter);
    }

    /// @notice Initializes the SY base contract with name, symbol, yield-bearing token, and owner.
    /// @param name_ Token name for the ERC20 representation.
    /// @param symbol_ Token symbol for the ERC20 representation.
    /// @param yieldBearingToken_ The external token that accrues yield.
    /// @param owner_ Address that will be granted the owner role.
    /// @dev Reverts with SYZeroAddress when yieldBearingToken_ is the zero address; adapters may rely on
    ///      this base-enforced check instead of repeating it locally.
    function __SYBase_init(string memory name_, string memory symbol_, address yieldBearingToken_, address owner_)
        internal
        onlyInitializing
    {
        require(yieldBearingToken_ != address(0), SYZeroAddress());
        // SY decimals intentionally match the yield-bearing token's decimals: _deposit returns an amount in
        // the yield-bearing token's own domain and deposit mints that amount 1:1 as SY (see _deposit below).
        __OutrunERC20Pausable_init(name_, symbol_, IERC20Metadata(yieldBearingToken_).decimals(), owner_);
        _getSYBaseStorage().yieldBearingToken = yieldBearingToken_;
    }

    function _getSYBaseStorage() private pure returns (SYBaseStorage storage $) {
        assembly {
            $.slot := SY_BASE_STORAGE_LOCATION
        }
    }

    /// @notice Returns the external token that accrues yield (e.g., aToken, wstETH, weETH).
    /// @return The address of the yield-bearing token.
    function yieldBearingToken() public view returns (address) {
        return _getSYBaseStorage().yieldBearingToken;
    }

    /// @notice Returns the router currently allowed to redeem this contract's SY balance.
    /// @return The trusted router address, or zero when the internal-balance path is disabled.
    function trustedRouter() public view returns (address) {
        return _getSYBaseStorage().trustedRouter;
    }

    /// @notice Deposits an input token and mints SY shares to the receiver.
    /// @param receiver Address that receives the minted SY shares.
    /// @param tokenIn The token being deposited.
    /// @param amountTokenToDeposit Amount of tokenIn to deposit.
    /// @param minSharesOut Minimum SY shares the caller expects to receive (slippage protection).
    /// @return amountSharesOut Number of SY shares minted to the receiver.
    function deposit(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 amountSharesOut)
    {
        require(isValidTokenIn(tokenIn), SYInvalidTokenIn(tokenIn));
        require(amountTokenToDeposit != 0, SYZeroDeposit());

        // Pulls input token from caller, converts to SY shares via the adapter's _deposit, then mints shares to receiver.
        _transferIn(tokenIn, msg.sender, amountTokenToDeposit);

        amountSharesOut = _deposit(tokenIn, amountTokenToDeposit);
        require(amountSharesOut >= minSharesOut, SYInsufficientSharesOut(amountSharesOut, minSharesOut));
        // Zero-output guard: a dust deposit below the exchange-rate quantum would otherwise mint zero
        // shares while the input stays stranded in the downstream protocol.
        require(amountSharesOut != 0, SYZeroSharesOut());

        _mint(receiver, amountSharesOut);
        emit Deposit(msg.sender, receiver, tokenIn, amountTokenToDeposit, amountSharesOut);
    }

    /// @notice Burns SY shares and delivers the output token to the receiver.
    /// @param receiver Address that receives the output token.
    /// @param amountSharesToRedeem Number of SY shares to burn.
    /// @param tokenOut The token the caller wants to receive.
    /// @param minTokenOut Minimum output tokens expected (slippage protection).
    /// @param burnFromInternalBalance If true, burns shares from this contract's balance
    /// (used after the router transfers SY here). If false, burns from msg.sender directly.
    /// @return amountTokenOut Amount of tokenOut sent to the receiver.
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external nonReentrant whenNotPaused returns (uint256 amountTokenOut) {
        require(isValidTokenOut(tokenOut), SYInvalidTokenOut(tokenOut));
        require(amountSharesToRedeem != 0, SYZeroRedeem());
        if (burnFromInternalBalance && msg.sender != trustedRouter()) {
            revert SYUnauthorizedInternalRedeemer(msg.sender);
        }
        // Adapter redemption sends tokenOut before the SY shares are burned.
        // This is reverse-CEI (external transfer-out in _redeem before the _burn state update),
        // and is safe because nonReentrant blocks reentry into deposit/redeem during the
        // transfer-out, and _burn is a pure internal state change with no external call that
        // reverts atomically if the share balance is insufficient — rolling back the whole
        // redeem (the transfer included) if anything fails.
        amountTokenOut = _redeem(receiver, tokenOut, amountSharesToRedeem);

        if (burnFromInternalBalance) {
            // Router path: router already transferred SY into this contract, so burn this contract's balance.
            _burn(address(this), amountSharesToRedeem);
        } else {
            // Direct path: caller owns the SY shares being redeemed.
            _burn(msg.sender, amountSharesToRedeem);
        }

        // Slippage check stays after redemption because adapters report the actual amount produced.
        require(amountTokenOut >= minTokenOut, SYInsufficientTokenOut(amountTokenOut, minTokenOut));

        emit Redeem(msg.sender, receiver, tokenOut, amountSharesToRedeem, amountTokenOut);
    }

    /// @notice Adapter-specific deposit logic — converts input tokens into SY shares.
    /// @dev Unit convention every adapter must follow: the returned amount is minted 1:1 as SY ERC20 units
    ///      (deposit calls `_mint(receiver, amountSharesOut)`), so 1 SY unit == 1 unit of the yield-bearing
    ///      token's own domain — aToken scaled shares for Aave, wstETH for Lido, weETH for EtherFi, etc.
    ///      This 1:1 identity is a deliberate design invariant (SY decimals are wired to the yield-bearing
    ///      token's decimals in __SYBase_init), not a numerical coincidence, and each adapter's exchangeRate()
    ///      must quote the canonical asset per that same unit.
    /// @dev The input tokens are already held by this contract when this hook runs (`msg.value` has been validated
    ///      for native input). Convert those funds in place; do not pull them from `msg.sender` again.
    /// @param tokenIn The token being deposited.
    /// @param amountDeposited Amount of tokenIn deposited.
    /// @return amountSharesOut Number of SY shares to mint (numerically the yield-bearing-token-domain amount).
    function _deposit(address tokenIn, uint256 amountDeposited) internal virtual returns (uint256 amountSharesOut);

    /// @notice Adapter-specific redeem logic — converts SY shares into output tokens.
    /// @dev This hook MUST deliver the returned `amountTokenOut` to `receiver`; token-out delivery is owned by this
    ///      hook. The base `redeem` burns SY shares after this hook returns, and any burn or slippage failure reverts
    ///      the whole redeem atomically, including delivery performed here. This reverse-CEI ordering is protected by
    ///      the base `redeem` function's `nonReentrant` guard.
    /// @param receiver Address that receives the output tokens.
    /// @param tokenOut The token to deliver to the receiver.
    /// @param amountSharesToRedeem Number of SY shares to redeem (1 SY unit == 1 yield-bearing-token-domain
    ///      unit; see the unit convention on _deposit).
    /// @return amountTokenOut Amount of tokenOut delivered to receiver by this hook.
    function _redeem(address receiver, address tokenOut, uint256 amountSharesToRedeem)
        internal
        virtual
        returns (uint256 amountTokenOut);

    /// @notice Returns the current exchange rate between the canonical asset and SY, scaled by 1e18.
    /// @return res Exchange rate as a 1e18-scaled value (canonical asset amount per 1 SY).
    function exchangeRate() external view virtual override returns (uint256 res);

    /// @notice Simulates a deposit and returns the expected number of SY shares.
    /// @param tokenIn The token to simulate depositing.
    /// @param amountTokenToDeposit Amount of tokenIn to simulate.
    /// @return amountSharesOut Expected SY shares that would be minted.
    function previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        external
        view
        virtual
        returns (uint256 amountSharesOut)
    {
        require(isValidTokenIn(tokenIn), SYInvalidTokenIn(tokenIn));
        return _previewDeposit(tokenIn, amountTokenToDeposit);
    }

    /// @notice Simulates a redemption and returns the expected number of output tokens.
    /// @param tokenOut The token to simulate receiving.
    /// @param amountSharesToRedeem Number of SY shares to simulate redeeming.
    /// @return amountTokenOut Expected output tokens that would be received.
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        external
        view
        virtual
        returns (uint256 amountTokenOut)
    {
        require(isValidTokenOut(tokenOut), SYInvalidTokenOut(tokenOut));
        return _previewRedeem(tokenOut, amountSharesToRedeem);
    }

    /// @notice Adapter-specific preview of a deposit — returns expected SY shares without state changes.
    /// @param tokenIn The token to simulate depositing.
    /// @param amountTokenToDeposit Amount of tokenIn to simulate.
    /// @return amountSharesOut Expected SY shares.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        internal
        view
        virtual
        returns (uint256 amountSharesOut);

    /// @notice Adapter-specific preview of a redemption — returns expected output tokens without state changes.
    /// @param tokenOut The token to simulate receiving.
    /// @param amountSharesToRedeem Number of SY shares to simulate redeeming.
    /// @return amountTokenOut Expected output tokens.
    function _previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        internal
        view
        virtual
        returns (uint256 amountTokenOut);

    /// @notice Returns all tokens accepted for deposit by this SY adapter.
    /// @return res Array of token addresses accepted for deposit.
    function getTokensIn() public view virtual returns (address[] memory res);

    /// @notice Returns all tokens accepted for redemption by this SY adapter.
    /// @return res Array of token addresses accepted for redemption.
    function getTokensOut() public view virtual returns (address[] memory res);

    /// @notice Checks whether the given token is accepted for deposit.
    /// @param token The token address to check.
    /// @return True if the token is a valid deposit token.
    function isValidTokenIn(address token) public view virtual returns (bool);

    /// @notice Checks whether the given token is accepted for redemption.
    /// @param token The token address to check.
    /// @return True if the token is a valid redemption token.
    function isValidTokenOut(address token) public view virtual returns (bool);

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
