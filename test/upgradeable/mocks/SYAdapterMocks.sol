// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IYieldProxy} from "../../../src/integrations/aster/interfaces/IYieldProxy.sol";

/// @notice Thrown when the caller tries to burn more scaled balance than they hold.
error NotEnoughAvailableUserBalance();

/// @notice Thrown when the computed scaled amount for a supply operation is zero.
error ScaledAmountIsZero();

/// @notice Minimal ERC-20 mock with a public `mint` helper.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) public virtual {
        _mint(to, amount);
    }
}

/// @notice Mock Aave aToken that tracks scaled balances with a configurable transfer index.
contract MockAToken is MockToken {
    uint256 private constant RAY = 1e27;

    address public immutable UNDERLYING_ASSET_ADDRESS;
    mapping(address => uint256) private scaledBalances;
    uint256 private scaledSupply;
    uint256 public transferIndex = RAY;

    constructor(address underlying_) MockToken("Aave aToken", "aTKN", 18) {
        UNDERLYING_ASSET_ADDRESS = underlying_;
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return scaledBalances[user];
    }

    function getScaledUserBalanceAndSupply(address user) external view returns (uint256, uint256) {
        return (scaledBalances[user], scaledSupply);
    }

    function scaledTotalSupply() external view returns (uint256) {
        return scaledSupply;
    }

    function getPreviousIndex(address) external pure returns (uint256) {
        return 0;
    }

    function mintScaled(address to, uint256 amount) external {
        scaledBalances[to] += amount;
        scaledSupply += amount;
        _mint(to, amount);
    }

    function mint(address to, uint256 amount) public override {
        scaledBalances[to] += _rayDiv(amount, transferIndex);
        scaledSupply += _rayDiv(amount, transferIndex);
        _mint(to, amount);
    }

    function burnScaled(address from, uint256 amount) external {
        uint256 balance = scaledBalances[from];
        if (balance < amount) revert NotEnoughAvailableUserBalance();
        scaledBalances[from] = balance - amount;
        scaledSupply -= amount;
        _burn(from, amount);
    }

    function setTransferIndex(uint256 index_) external {
        transferIndex = index_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool success = super.transfer(to, value);
        _moveScaled(msg.sender, to, _rayDiv(value, transferIndex));
        return success;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool success = super.transferFrom(from, to, value);
        _moveScaled(from, to, _rayDiv(value, transferIndex));
        return success;
    }

    function _moveScaled(address from, address to, uint256 scaledAmount) private {
        uint256 fromBalance = scaledBalances[from];
        if (fromBalance < scaledAmount) revert NotEnoughAvailableUserBalance();
        scaledBalances[from] = fromBalance - scaledAmount;
        scaledBalances[to] += scaledAmount;
    }

    function _rayDiv(uint256 amount, uint256 ray) private pure returns (uint256) {
        return (amount * RAY + ray / 2) / ray;
    }
}

/// @notice Mock Aave pool with configurable reserve index for testing ray-math rounding.
contract MockAavePool {
    uint256 private constant RAY = 1e27;

    address public underlying;
    MockAToken public aToken;
    uint256 public index = RAY;

    function setReserve(address underlying_, MockAToken aToken_, uint256 index_) external {
        underlying = underlying_;
        aToken = aToken_;
        index = index_;
        aToken_.setTransferIndex(index_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (address(aToken) == address(0)) return;
        uint256 scaledAmount = _rayDiv(amount, index);
        if (scaledAmount == 0) revert ScaledAmountIsZero();
        MockToken(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mintScaled(onBehalfOf, scaledAmount);
    }

    function withdraw(address asset, uint256 amount, address receiver) external returns (uint256) {
        if (address(aToken) == address(0)) return amount;
        uint256 scaledAmount = _rayDiv(amount, index);
        aToken.burnScaled(msg.sender, scaledAmount);
        MockToken(asset).transfer(receiver, amount);
        return amount;
    }

    function getReserveNormalizedIncome(address) external view returns (uint256) {
        return index;
    }

    function _rayDiv(uint256 amount, uint256 ray) private pure returns (uint256) {
        return (amount * RAY + ray / 2) / ray;
    }
}

/// @notice Minimal oracle mock returning a configurable exchange rate.
contract MockOracle {
    uint256 public rate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setExchangeRate(uint256 rate_) external {
        rate = rate_;
    }

    function getExchangeRate() external view returns (uint256) {
        return rate;
    }
}

/// @notice Mock liquidity pool with a configurable ETH-per-share rate.
/// @dev `shareRate` is the ETH value of one weETH share. Default 1e18 is identity (1:1).
/// Tests set a non-1e18 rate so preview and execution traverse genuinely different arithmetic.
contract MockLiquidityPool {
    uint256 public shareRate = 1e18;

    function setShareRate(uint256 rate_) external {
        shareRate = rate_;
    }

    function amountForShare(uint256 shares) external view returns (uint256) {
        return shares * shareRate / 1e18;
    }

    function sharesForAmount(uint256 amount) external view returns (uint256) {
        return amount * 1e18 / shareRate;
    }
}

/// @notice Mock Wrapped eETH that wraps/unwraps eETH <-> weETH at a configurable rate.
/// @dev `shareRate` must match MockLiquidityPool.shareRate so the adapter's preview path
/// (LiquidityPool.sharesForAmount) and execution path (weETH.wrap) stay consistent.
contract MockWeETH is MockToken {
    address public immutable EETH;
    uint256 public shareRate = 1e18;

    constructor(address eETH_) MockToken("Wrapped eETH", "weETH", 18) {
        EETH = eETH_;
    }

    function setShareRate(uint256 rate_) external {
        shareRate = rate_;
    }

    function wrap(uint256 amount) external returns (uint256) {
        MockToken(EETH).transferFrom(msg.sender, address(this), amount);
        uint256 weEthAmount = amount * 1e18 / shareRate;
        _mint(msg.sender, weEthAmount);
        return weEthAmount;
    }

    function unwrap(uint256 weEthAmount) external returns (uint256) {
        _burn(msg.sender, weEthAmount);
        uint256 eEthAmount = weEthAmount * shareRate / 1e18;
        MockToken(EETH).mint(msg.sender, eEthAmount);
        return eEthAmount;
    }
}

/// @notice Mock stETH with a configurable pooled-ETH-per-share rate.
/// @dev `pooledEthPerShare` must match MockWstETH.stEthPerTokenRate so the wstETH adapter's
/// preview (getSharesByPooledEth) and execution (wrap) paths stay consistent.
contract MockStETH is MockToken {
    uint256 public pooledEthPerShare = 1e18;

    constructor() MockToken("stETH", "stETH", 18) {}

    function setPooledEthPerShare(uint256 rate_) external {
        pooledEthPerShare = rate_;
    }

    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256) {
        return ethAmount * 1e18 / pooledEthPerShare;
    }

    function getPooledEthByShares(uint256 shares) external view returns (uint256) {
        return shares * pooledEthPerShare / 1e18;
    }

    function submit(address) external payable returns (uint256) {
        _mint(msg.sender, msg.value);
        return msg.value;
    }
}

/// @notice Mock wstETH that wraps/unwraps stETH <-> wstETH at a configurable rate.
/// @dev `stEthPerTokenRate` is stETH per one wstETH (mirrors real wstETH.stEthPerToken).
/// Must match MockStETH.pooledEthPerShare for preview/execution consistency.
contract MockWstETH is MockToken {
    address public immutable STETH;
    uint256 public stEthPerTokenRate = 1e18;

    constructor(address stETH_) MockToken("Wrapped stETH", "wstETH", 18) {
        STETH = stETH_;
    }

    function setStEthPerToken(uint256 rate_) external {
        stEthPerTokenRate = rate_;
    }

    function stEthPerToken() external view returns (uint256) {
        return stEthPerTokenRate;
    }

    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256) {
        return stEthAmount * 1e18 / stEthPerTokenRate;
    }

    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256) {
        return wstEthAmount * stEthPerTokenRate / 1e18;
    }

    function wrap(uint256 stEthAmount) external returns (uint256) {
        MockToken(STETH).transferFrom(msg.sender, address(this), stEthAmount);
        uint256 wstEthAmount = stEthAmount * 1e18 / stEthPerTokenRate;
        _mint(msg.sender, wstEthAmount);
        return wstEthAmount;
    }

    function unwrap(uint256 wstEthAmount) external returns (uint256) {
        _burn(msg.sender, wstEthAmount);
        uint256 stEthAmount = wstEthAmount * stEthPerTokenRate / 1e18;
        MockToken(STETH).mint(msg.sender, stEthAmount);
        return stEthAmount;
    }
}

/// @notice Mock L2 stETH that converts between shares and tokens via a configurable TOKENS_PER_SHARE ratio.
contract MockL2StETH is MockToken {
    address public immutable WSTETH;
    uint256 public immutable TOKENS_PER_SHARE;

    constructor(address wstETH_, uint256 tokensPerShare_) MockToken("L2 stETH", "stETH", 18) {
        WSTETH = wstETH_;
        TOKENS_PER_SHARE = tokensPerShare_;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return getTokensByShares(super.balanceOf(account));
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, getSharesByTokens(amount));
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, getSharesByTokens(amount));
        return true;
    }

    function wrap(uint256 sharesAmount) external returns (uint256) {
        MockToken(WSTETH).transferFrom(msg.sender, address(this), sharesAmount);
        uint256 tokenAmount = getTokensByShares(sharesAmount);
        _mint(msg.sender, sharesAmount);
        return tokenAmount;
    }

    function unwrap(uint256 tokenAmount) external returns (uint256) {
        uint256 sharesAmount = getSharesByTokens(tokenAmount);
        _burn(msg.sender, sharesAmount);
        MockToken(WSTETH).mint(msg.sender, sharesAmount);
        return sharesAmount;
    }

    function getTokensByShares(uint256 sharesAmount) public view returns (uint256) {
        return (sharesAmount * TOKENS_PER_SHARE) / 1 ether;
    }

    function getSharesByTokens(uint256 tokenAmount) public view returns (uint256) {
        return (tokenAmount * 1 ether) / TOKENS_PER_SHARE;
    }
}

/// @notice Mock ERC-4626 vault with a configurable asset-per-share rate.
/// @dev `assetsPerShare` is the asset value of one vault share. Default 1e18 is identity.
/// Tests set a non-1e18 rate so previewDeposit and deposit traverse genuinely different arithmetic.
contract MockVault is MockToken, IERC4626 {
    address public immutable ASSET;
    uint256 public assetsPerShare = 1e18;

    constructor(address asset_) MockToken("Vault", "vTKN", 18) {
        ASSET = asset_;
    }

    function setAssetsPerShare(uint256 rate_) external {
        assetsPerShare = rate_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function totalAssets() external view returns (uint256) {
        return totalSupply() * assetsPerShare / 1e18;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * 1e18 / assetsPerShare;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * assetsPerShare / 1e18;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _mint(receiver, shares);
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        _mint(receiver, shares);
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _burn(owner, shares);
        MockToken(ASSET).mint(receiver, assets);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _burn(owner, shares);
        assets = convertToAssets(shares);
        MockToken(ASSET).mint(receiver, assets);
    }
}

/// @notice Mock PSM3 that swaps tokens at a configurable rate around one appreciating share token.
/// @dev `shareToken` is the vault token that appreciates vs the underlying (e.g. sUSDS). Swaps into
/// the share divide by `rate`; swaps out of the share multiply by `rate`; underlying<->underlying is 1:1.
contract MockPSM3 {
    address public shareToken;
    uint256 public rate = 1e18;

    function setRate(address shareToken_, uint256 rate_) external {
        shareToken = shareToken_;
        rate = rate_;
    }

    function _convert(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenOut == shareToken) return amountIn * 1e18 / rate;
        if (tokenIn == shareToken) return amountIn * rate / 1e18;
        return amountIn;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address receiver, uint256)
        external
        returns (uint256)
    {
        MockToken(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = _convert(tokenIn, tokenOut, amountIn);
        MockToken(tokenOut).mint(receiver, amountOut);
        return amountOut;
    }

    function previewSwapExactIn(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        return _convert(tokenIn, tokenOut, amountIn);
    }
}

/// @notice Mock Lista stake manager with a configurable BNB-per-slisBNB rate and real deposit minting.
/// @dev `rate` is BNB per slisBNB and must stay >= 1e18 (Lista init parity check). When `slisBnbToken`
/// is set, deposit() mints slisBNB so the native deposit branch is exercisable; otherwise it is a no-op.
contract MockListaStakeManager {
    uint256 public rate = 1e18;
    MockToken public slisBnbToken;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setSlisBnbToken(MockToken token_) external {
        slisBnbToken = token_;
    }

    function deposit() external payable {
        if (address(slisBnbToken) != address(0)) {
            slisBnbToken.mint(msg.sender, convertBnbToSnBnb(msg.value));
        }
    }

    function convertSnBnbToBnb(uint256 amount) public view returns (uint256) {
        return amount * rate / 1e18;
    }

    function convertBnbToSnBnb(uint256 amount) public view returns (uint256) {
        return amount * 1e18 / rate;
    }
}

/// @notice Mock yield proxy that stores a stake manager reference and a toggleable activity flag.
/// @dev The activity flag lets tests exercise the Aster queued-mint branch.
contract MockYieldProxy {
    address public stakeManager;
    bool public activitiesOnGoing;

    constructor(address stakeManager_) {
        stakeManager = stakeManager_;
    }

    function setActivitiesOnGoing(bool ongoing_) external {
        activitiesOnGoing = ongoing_;
    }
}

/// @notice Mock asBNB minter with a configurable asBNB-per-slisBNB rate and queue-aware minting.
/// @dev `rate` is slisBNB per asBNB (convertToAsBnb divisor). mintAsBnb returns 0 while the yield
/// proxy reports ongoing activities, modelling Aster's queued-request behaviour.
contract MockAsBnbMinter {
    address public immutable asBnb;
    address public immutable token;
    address public immutable yieldProxy;
    uint256 public rate = 1e18;

    constructor(address asBnb_, address token_, address yieldProxy_) {
        asBnb = asBnb_;
        token = token_;
        yieldProxy = yieldProxy_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function mintAsBnb() external payable returns (uint256) {
        if (IYieldProxy(yieldProxy).activitiesOnGoing()) return 0;
        return msg.value * 1e18 / rate;
    }

    function mintAsBnb(uint256 amount) external returns (uint256) {
        if (IYieldProxy(yieldProxy).activitiesOnGoing()) return 0;
        return amount * 1e18 / rate;
    }

    function convertToTokens(uint256 asBnbAmount) external view returns (uint256) {
        return asBnbAmount * rate / 1e18;
    }

    function convertToAsBnb(uint256 tokenAmount) external view returns (uint256) {
        return tokenAmount * 1e18 / rate;
    }
}

/// @notice Mock EtherFi deposit adapter: native ETH -> weETH at a configurable rate.
/// @dev `shareRate` must match MockLiquidityPool.shareRate so the adapter's native preview path
/// and the deposit execution path stay consistent.
contract MockDepositAdapter {
    uint256 public shareRate = 1e18;

    function setShareRate(uint256 rate_) external {
        shareRate = rate_;
    }

    function depositETHForWeETH(address) external payable returns (uint256) {
        return msg.value * 1e18 / shareRate;
    }
}
