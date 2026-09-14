// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title POLend global debt view — reserved interface
 * @notice Read-only reconciliation interface reserved for the Memeverse-side POLend (leveraged
 * genesis supply) subledger. Semantic reservation only: this repository declares the interface
 * shape but does not implement or deploy the view — the subledger that answers it lives in the
 * Memeverse stack.
 * @dev Consumers use it for the uAsset supply reconciliation's third line:
 * `POLend row == sum(globalDebtByUAsset) + open preRedeem backing`, where the preRedeem backing
 * is the genesis/preRedeem amount minted but not yet settled by a matching redemption. The
 * returned debt is outstanding principal only, in 18-decimal uAsset units; interest is not part
 * of this ledger.
 */
interface IPOLendGlobalDebt {
    /**
     * @notice Returns the outstanding POLend principal debt aggregated for one uAsset family.
     * @param uAsset_ Address of the uAsset family being queried.
     * @return totalPrincipalDebt Outstanding principal debt, 18-decimal uAsset units.
     */
    function globalDebtByUAsset(address uAsset_) external view returns (uint256 totalPrincipalDebt);
}
