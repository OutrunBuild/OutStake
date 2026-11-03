// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IUniversalAssets} from "../../../src/assets/interfaces/IUniversalAssets.sol";
import {OutrunOFTUpgradeable} from "../../../src/assets/omnichain/OutrunOFTUpgradeable.sol";
import {IOutrunStakeManager} from "../../../src/position/interfaces/IOutrunStakeManager.sol";
import {IStandardizedYield} from "../../../src/yield/interfaces/IStandardizedYield.sol";
import {IUSRVault} from "../../../src/usr/interfaces/IUSRVault.sol";
import {TokenHelper} from "../../../src/libraries/TokenHelper.sol";

/// @notice V2 upgrade mock for OutrunUniversalAssetsUpgradeable.
/// Standalone contract that replicates the production storage namespace so it
/// does not inherit from the production contract (which will use `layout at`).
/// Inherits the OFT chain for cross-chain view functions needed by upgrade validation.
contract MockUAssetUUPSV2 is OutrunOFTUpgradeable, UUPSUpgradeable {
    /// @dev Partial mirror of OutrunUniversalAssetsUpgradeable.OutrunUniversalAssetsStorage — mirrors only mintingStatusTable; does not mirror reserveMinters (appended mapping in same ERC-7201 namespace, so prior field slot is unchanged).
    struct OutrunUniversalAssetsStorage {
        mapping(address minter => IUniversalAssets.MintingStatus) mintingStatusTable;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunUniversalAssets")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OUTRUN_UNIVERSAL_ASSETS_STORAGE_LOCATION =
        0x2b82e9d5002467e1c5131297c0670c5f52b39ef4cd7112616d88ce4844484100;

    constructor(uint8 localDecimals, address lzEndpoint) OutrunOFTUpgradeable(localDecimals, lzEndpoint) {}

    function _getOutrunUniversalAssetsStorage() private pure returns (OutrunUniversalAssetsStorage storage $) {
        assembly {
            $.slot := OUTRUN_UNIVERSAL_ASSETS_STORAGE_LOCATION
        }
    }

    /// @notice Returns how many more uAsset the minter can mint before hitting its cap.
    ///      Called through the proxy after upgrade, so post-upgrade minter-ledger reads keep working.
    function checkMintableAmount(address minter) external view returns (uint256 amountInMintable) {
        IUniversalAssets.MintingStatus storage status = _getOutrunUniversalAssetsStorage().mintingStatusTable[minter];
        uint256 mintingCap = status.mintingCap;
        uint256 amountInMinted = status.amountInMinted;
        amountInMintable = mintingCap > amountInMinted ? mintingCap - amountInMinted : 0;
    }

    /// @notice Returns version 2 to confirm the upgrade took effect.
    function version() external pure returns (uint256) {
        return 2;
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @notice V2 upgrade mock with a different sharedDecimals override.
/// Used to test that the upgrade validator rejects a mismatched decimalConversionRate.
contract MockUAssetUUPSV2DifferentSharedDecimals is MockUAssetUUPSV2 {
    constructor(uint8 localDecimals, address lzEndpoint) MockUAssetUUPSV2(localDecimals, lzEndpoint) {}

    function sharedDecimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @notice V2 upgrade mock with different local decimals but the same conversion rate.
/// Used to isolate the local-decimals upgrade guard from the endpoint and conversion-rate guards.
contract MockUAssetUUPSV2DifferentLocalDecimals is MockUAssetUUPSV2 {
    constructor(uint8 localDecimals, address lzEndpoint) MockUAssetUUPSV2(localDecimals, lzEndpoint) {}

    function sharedDecimals() public pure override returns (uint8) {
        return 7;
    }
}

/// @notice V2 upgrade mock for OutrunStakingPositionUpgradeable.
/// Standalone UUPS target for the storage-layout tests: it must not inherit from the production
/// contract (which uses `layout at`), and the layout assertions read raw storage slots directly,
/// so it carries no state mirrors or accessors — only the upgrade authorization.
contract MockPositionUUPSV2 is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
}

/// @notice Full-logic V2 upgrade mock for OutrunStakingPositionUpgradeable: a standalone contract
/// that re-implements the v1 redeem/preview/view surface verbatim, bound to the production
/// ERC-7201 namespace, so post-upgrade semantic-continuity tests exercise real logic instead of a
/// bare stub. It must not inherit the production contract (concrete, `layout at`), so the storage
/// mirror replicates the frozen v1 field order at the identical base slot: slot0 packs SY +
/// canonicalAssetDecimals + uAssetDecimals, then uAsset, protocolTreasury, minStake, duty, rate,
/// rateLastSettledAt, genesisLauncher, and the positions mapping.
/// @dev Partial mock (by surface, not by modeled-path fidelity): models redeem, previewRedeem, the
///      rate/interest views and the position view with v1-exact semantics; does NOT model
///      stakeForGenesis, the owner setters, initialize, the decimals upgrade guard, or owner-gated
///      upgrade authorization (`_authorizeUpgrade` is permissive — these tests upgrade as owner).
contract MockPositionUUPSV2Continuous is TokenHelper, PausableUpgradeable, UUPSUpgradeable {
    // RAY fixed-point base (1e27) for `duty` and `rate`; mirrors production.
    uint256 private constant RAY = 1e27;

    /// @dev Field-order mirror of OutrunStakingPositionUpgradeable.OutrunStakingPositionStorage;
    ///      any reorder or insertion silently misreads live v1 state.
    struct PositionStorageMirror {
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
        mapping(uint256 positionId => IOutrunStakeManager.Position) positions;
    }

    /// @dev Binds the mirror to the production ERC-7201 namespace base slot
    ///      (keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunStakingPosition")) - 1)) & ~0xff).
    function _positionMirror() private pure returns (PositionStorageMirror storage $) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunStakingPosition")) - 1))
            & ~bytes32(uint256(0xff));
        assembly {
            $.slot := slot
        }
    }

    function _authorizeUpgrade(address) internal override {}

    /// @notice Marker proving the proxy runs this implementation after the upgrade.
    function version() external pure returns (uint256) {
        return 2;
    }

    /// @notice v1-exact redeem: two-leg repayment (interest to treasury first, principal burn
    ///         second) with settlement before the split and CEI before the external legs.
    function redeem(uint256 positionId, uint256 syRedeemed, address receiver, address tokenOut, uint256 minTokenOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 principalBurned, uint256 interestPaid, uint256 amountTokenOut)
    {
        if (receiver == address(0)) revert IOutrunStakeManager.ZeroInput();
        PositionStorageMirror storage $ = _positionMirror();
        IOutrunStakeManager.Position storage position = $.positions[positionId];
        if (position.owner == address(0) || position.owner != msg.sender) {
            revert IOutrunStakeManager.PositionAccessDenied();
        }
        uint256 syStaked = position.syStaked;
        _validateRedeemAmount(syStaked, syRedeemed);

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
        if (tokenOut == _SY && syRedeemed < minTokenOut) {
            revert IOutrunStakeManager.InsufficientTokenOut(syRedeemed, minTokenOut);
        }

        _applyPositionRedeem(positionId, position, syRedeemed, syStaked, principalBurned, interestPaid);
        _repayTwoLegs($.uAsset, $.protocolTreasury, interestPaid, principalBurned);
        amountTokenOut = _redeemTokenOut(_SY, receiver, tokenOut, syRedeemed, minTokenOut);

        emit IOutrunStakeManager.Redeem(
            positionId, msg.sender, syRedeemed, principalBurned, interestPaid, receiver, tokenOut, amountTokenOut
        );
    }

    /// @notice v1-exact quote-only mirror of redeem: same guards and the shared leg split.
    function previewRedeem(uint256 positionId, uint256 syRedeemed, address tokenOut)
        external
        view
        returns (uint256 principalPortion, uint256 interestPortion, uint256 amountTokenOut)
    {
        PositionStorageMirror storage $ = _positionMirror();
        IOutrunStakeManager.Position storage position = $.positions[positionId];
        if (position.owner == address(0)) revert IOutrunStakeManager.PositionAccessDenied();
        uint256 syStaked = position.syStaked;
        _validateRedeemAmount(syStaked, syRedeemed);

        (principalPortion, interestPortion) =
            _computeRedeemLegs(position.principalDebt, _extrapolatedInterest(position), syRedeemed, syStaked);
        amountTokenOut = _previewTokenOut($.SY, tokenOut, syRedeemed);
    }

    /// @notice v1-exact position record view (a zero owner identifies a missing/deleted position).
    function positions(uint256 positionId)
        external
        view
        returns (address owner, uint256 syStaked, uint256 principalDebt, uint256 accruedInterest, uint256 lastRate)
    {
        IOutrunStakeManager.Position storage position = _positionMirror().positions[positionId];
        return (position.owner, position.syStaked, position.principalDebt, position.accruedInterest, position.lastRate);
    }

    /// @notice v1-exact settled cumulative-rate view.
    function rate() external view returns (uint256) {
        return _positionMirror().rate;
    }

    /// @notice v1-exact current-timestamp extrapolation of the cumulative rate.
    function currentRate() public view returns (uint256) {
        PositionStorageMirror storage $ = _positionMirror();
        return _rmul(_rpow($.duty, block.timestamp - $.rateLastSettledAt), $.rate);
    }

    /// @notice v1-exact unsettled-interest extrapolation for one position.
    function pendingInterest(uint256 positionId) external view returns (uint256) {
        PositionStorageMirror storage $ = _positionMirror();
        return _unsettledIncrement($.positions[positionId], currentRate());
    }

    // ---- v1-exact interest and settlement helpers (verbatim ports; drift breaks continuity) ----

    function _settleRateToNow() private returns (uint256) {
        PositionStorageMirror storage $ = _positionMirror();
        uint256 deltaSeconds = block.timestamp - $.rateLastSettledAt;
        if (deltaSeconds != 0) {
            uint256 newRate = _rmul(_rpow($.duty, deltaSeconds), $.rate);
            if (newRate != $.rate) {
                $.rate = newRate;
            }
            $.rateLastSettledAt = block.timestamp;
        }
        return $.rate;
    }

    function _settlePositionInterest(IOutrunStakeManager.Position storage position, uint256 settledRate) private {
        if (settledRate != position.lastRate) {
            position.accruedInterest += _unsettledIncrement(position, settledRate);
            position.lastRate = settledRate;
        }
    }

    function _applyPositionRedeem(
        uint256 positionId,
        IOutrunStakeManager.Position storage position,
        uint256 syRedeemed,
        uint256 syStaked,
        uint256 principalPortion,
        uint256 interestPortion
    ) private {
        if (syRedeemed == syStaked) {
            delete _positionMirror().positions[positionId];
            return;
        }
        position.syStaked = syStaked - syRedeemed;
        position.principalDebt -= principalPortion;
        position.accruedInterest -= interestPortion;
    }

    function _repayTwoLegs(address uAsset_, address treasury_, uint256 interestPortion, uint256 principalPortion)
        private
    {
        // Interest first (circulating transfer), then the principal burn through the minter ledger;
        // both legs share the caller's allowance on this contract.
        if (interestPortion != 0) {
            _transferFrom(IERC20(uAsset_), msg.sender, treasury_, interestPortion);
        }
        IUniversalAssets(uAsset_).repay(msg.sender, principalPortion);
    }

    function _redeemTokenOut(address _SY, address receiver, address tokenOut, uint256 syRedeemed, uint256 minTokenOut)
        private
        returns (uint256 amountTokenOut)
    {
        if (tokenOut == _SY) {
            amountTokenOut = syRedeemed;
            _transferOut(_SY, receiver, syRedeemed);
        } else {
            amountTokenOut = IStandardizedYield(_SY).redeem(receiver, syRedeemed, tokenOut, minTokenOut, false);
        }
    }

    function _previewTokenOut(address _SY, address tokenOut, uint256 amountInSY)
        private
        view
        returns (uint256 amountTokenOut)
    {
        if (tokenOut == _SY) {
            amountTokenOut = amountInSY;
        } else {
            amountTokenOut = IStandardizedYield(_SY).previewRedeem(tokenOut, amountInSY);
        }
    }

    function _extrapolatedInterest(IOutrunStakeManager.Position storage position) private view returns (uint256) {
        return position.accruedInterest + _unsettledIncrement(position, currentRate());
    }

    function _unsettledIncrement(IOutrunStakeManager.Position storage position, uint256 rate_)
        private
        view
        returns (uint256)
    {
        return _interestDelta(position.principalDebt, rate_ - position.lastRate);
    }

    function _interestDelta(uint256 principalDebt, uint256 deltaRate) private pure returns (uint256) {
        return principalDebt * deltaRate / RAY;
    }

    function _computeRedeemLegs(uint256 principalDebt, uint256 interest, uint256 syRedeemed, uint256 syStaked)
        private
        pure
        returns (uint256 principalPortion, uint256 interestPortion)
    {
        if (syRedeemed == syStaked) {
            return (principalDebt, interest);
        }
        principalPortion = Math.mulDiv(principalDebt, syRedeemed, syStaked, Math.Rounding.Ceil);
        if (principalPortion >= principalDebt) revert IOutrunStakeManager.PartialRedeemMustLeaveDebt();
        interestPortion = Math.mulDiv(interest, syRedeemed, syStaked, Math.Rounding.Ceil);
    }

    function _validateRedeemAmount(uint256 syStaked, uint256 syRedeemed) private pure {
        if (syRedeemed == 0) revert IOutrunStakeManager.ZeroInput();
        if (syRedeemed > syStaked) revert IOutrunStakeManager.ExceedsPositionBalance(syRedeemed, syStaked);
    }

    function _rmul(uint256 x, uint256 y) private pure returns (uint256) {
        return (x * y) / RAY;
    }

    /// @dev MakerDAO `rpow` port (round-half-up intermediates, truncating outer multiply), verbatim
    ///      from v1 so upgraded quotes and settlements stay wei-identical.
    function _rpow(uint256 x, uint256 n) private pure returns (uint256 z) {
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

/// @notice Full-logic V2 upgrade mock for OutrunUSRVaultUpgradeable: inherits the abstract OZ
/// ERC20/ERC4626 upgradeable bases (whose ERC-7201 namespaces the production vault already
/// initialized, so balances, supply and the asset binding survive the code swap) and re-implements
/// the vault's own index core verbatim on a mirror of the frozen vault namespace
/// (ns+0 usrRate, ns+1 accrualIndex, ns+2 lastSettledAt). It must not inherit the production
/// contract (concrete, `layout at`).
/// @dev Partial mock (by surface): models the four settlement entries, the two conversion hooks,
///      the index projection/settlement core and the three state views with v1-exact semantics;
///      does NOT model initialize, fund, setUsrRate, or owner-gated upgrade authorization
///      (`_authorizeUpgrade` is permissive — these tests upgrade as owner).
contract MockVaultUUPSV2Continuous is TokenHelper, ERC4626Upgradeable, UUPSUpgradeable {
    /// @dev Year length in seconds (365-day convention); mirrors the production constant.
    uint256 private constant SECONDS_PER_YEAR = 31_536_000;
    /// @dev Deterministic saturation ceiling for the growth power (1e18-fold price multiplier);
    ///      mirrors the production constant so the exponentiation loop stays mulDiv-safe.
    uint256 private constant MAX_INDEX_FACTOR = 1e36;

    /// @dev Field-order mirror of OutrunUSRVaultUpgradeable.OutrunUSRVaultStorage; any reorder or
    ///      insertion silently reprices every live share.
    struct VaultStorageMirror {
        uint256 usrRate;
        uint256 accrualIndex;
        uint256 lastSettledAt;
    }

    /// @dev Binds the mirror to the production ERC-7201 namespace base slot
    ///      (keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunUSRVault")) - 1)) & ~0xff).
    function _vaultMirror() private pure returns (VaultStorageMirror storage $) {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("outrun.storage.OutrunUSRVault")) - 1)) & ~bytes32(uint256(0xff));
        assembly {
            $.slot := slot
        }
    }

    function _authorizeUpgrade(address) internal override {}

    /// @notice Marker proving the proxy runs this implementation after the upgrade.
    function version() external pure returns (uint256) {
        return 2;
    }

    /// @notice v1-exact settled per-share price index view.
    function accrualIndex() external view returns (uint256) {
        return _vaultMirror().accrualIndex;
    }

    /// @notice v1-exact family-rate view.
    function usrRate() external view returns (uint256) {
        return _vaultMirror().usrRate;
    }

    /// @notice v1-exact last-settled timestamp view.
    function lastSettledAt() external view returns (uint256) {
        return _vaultMirror().lastSettledAt;
    }

    // ---- v1-exact settlement entries: settle to the current second before pricing (verbatim) ----

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _settleIndex();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _settleIndex();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _settleIndex();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _settleIndex();
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, 1e18, _projectedIndex(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, _projectedIndex(), 1e18, rounding);
    }

    /// @dev v1-exact settlement write: emits only when the stored index actually changes.
    function _settleIndex() private {
        VaultStorageMirror storage $ = _vaultMirror();
        uint256 delta = block.timestamp - $.lastSettledAt;
        if (delta != 0) {
            uint256 oldIndex = $.accrualIndex;
            uint256 newIndex = _projectedIndex();
            if (newIndex != oldIndex) {
                emit IUSRVault.AccrualIndexSettled(oldIndex, newIndex);
                $.accrualIndex = newIndex;
            }
            $.lastSettledAt = block.timestamp;
        }
    }

    /// @dev v1-exact projection: extrapolation clamped by the budget cap
    ///      `balance * 1e18 / totalSupply()`, zero-supply suspension, monotonic floor.
    function _projectedIndex() private view returns (uint256) {
        VaultStorageMirror storage $ = _vaultMirror();
        uint256 currentIndex = $.accrualIndex;
        uint256 supply = totalSupply();
        if (supply == 0) return currentIndex;

        uint256 deltaSeconds = block.timestamp - $.lastSettledAt;
        uint256 factor = 1e18 + $.usrRate / SECONDS_PER_YEAR;
        uint256 projected = Math.mulDiv(currentIndex, _factorPow(factor, deltaSeconds), 1e18);
        if (projected == currentIndex) return currentIndex;
        uint256 cap = Math.mulDiv(IERC20(asset()).balanceOf(address(this)), 1e18, supply);
        uint256 clamped = projected < cap ? projected : cap;
        return clamped > currentIndex ? clamped : currentIndex;
    }

    /// @dev v1-exact MSB-first exponentiation-by-squaring of the per-second growth factor with the
    ///      deterministic saturation clamp.
    function _factorPow(uint256 factor, uint256 exponent) private pure returns (uint256 r) {
        if (exponent == 0) return 1e18;
        if (factor == 1e18) return 1e18;

        uint256 msb = Math.log2(exponent);

        r = factor;
        for (uint256 bit = msb; bit > 0; --bit) {
            r = Math.mulDiv(r, r, 1e18);
            if (((exponent >> (bit - 1)) & 1) == 1) {
                r = Math.mulDiv(r, factor, 1e18);
            }
            if (r > MAX_INDEX_FACTOR) {
                r = MAX_INDEX_FACTOR;
            }
        }
    }
}
