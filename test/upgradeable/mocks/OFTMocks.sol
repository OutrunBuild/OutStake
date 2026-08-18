// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {
    MessagingFee,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {OutrunOFTUpgradeable} from "../../../src/assets/omnichain/OutrunOFTUpgradeable.sol";

/// @dev Mock LayerZero V2 endpoint for testing OFT cross-chain transfers.
contract MockLzEndpoint {
    address internal delegate;
    uint256 internal quoteNativeFee;
    uint32 public eid;

    constructor() {
        eid = 1001;
    }

    function setEid(uint32 eid_) external {
        eid = eid_;
    }

    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory fee) {
        fee = MessagingFee({nativeFee: quoteNativeFee, lzTokenFee: 0});
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteNativeFee, lzTokenFee: 0});
    }
}

/// @dev Test harness that inherits from OutrunOFTUpgradeable (not OutrunUniversalAssetsUpgradeable)
/// because `layout at erc7201(...)` prevents child contracts from declaring storage.
/// Minting cap / mint calls go through the real OutrunUniversalAssetsUpgradeable proxy.
contract OutrunUpgradeableOftHarness is OutrunOFTUpgradeable {
    uint256 public outflowCalls;

    constructor(uint8 localDecimals, address lzEndpoint) OutrunOFTUpgradeable(localDecimals, lzEndpoint) {}

    /// @dev Minimal initialize — only sets up OFT, not minting cap logic.
    ///      ERC20 `decimals()` derives from the constructor-frozen `localDecimals()`.
    function initialize(string calldata name_, string calldata symbol_, address owner_) external initializer {
        __OutrunOFT_init(name_, symbol_, owner_);
    }

    function exposedDebit(address from, uint256 amountLD, uint256 minAmountLD, uint32 dstEid)
        external
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        return _debit(from, amountLD, minAmountLD, dstEid);
    }

    function exposedCredit(address to, uint256 amountLD, uint32 srcEid) external returns (uint256 amountReceivedLD) {
        return _credit(to, amountLD, srcEid);
    }

    function _outflow(uint32 dstEid, uint256 amount) internal override {
        ++outflowCalls;
        super._outflow(dstEid, amount);
    }
}
