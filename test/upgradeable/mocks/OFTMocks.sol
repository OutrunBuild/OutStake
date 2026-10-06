// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {OutrunOFTUpgradeable} from "../../../src/assets/omnichain/OutrunOFTUpgradeable.sol";

/// @dev Partial mock: models only a slice of ILayerZeroEndpointV2. Modeled seams: the
///      configurable EID read by deploy-time validation, `setDelegate()` called by OApp
///      initialization, `quote()` returning a zero MessagingFee, and `send()` returning a
///      zero-value MessagingReceipt. Unmodeled seams: fee charging and refunds, guid/nonce
///      generation, packet delivery, and every other endpoint state transition.
contract MockLzEndpoint {
    address internal delegate;
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
        fee = MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    // The receipt width must match ILayerZeroEndpointV2.send's MessagingReceipt return:
    // callers ABI-decode the static 4-word return, and a shorter return reverts their decode.
    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: MessagingFee({nativeFee: 0, lzTokenFee: 0})});
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
