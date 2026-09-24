// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @notice Functionally identical to MockOracleAdapter, but a SEPARATE implementation with
///         its own distinct runtime bytecode/codehash. Exists purely so tests can exercise the
///         "adapter implementation was never allowlisted" path: since ProtocolConfig allowlists
///         by codehash (deliberately, so many per-token MockOracleAdapter instances share one
///         allowlist entry -- see README), every instance of MockOracleAdapter itself is
///         automatically allowed the moment ANY one instance's codehash is allowlisted. A truly
///         "unlisted" adapter in tests therefore has to be a genuinely different contract, not
///         just a different instance -- this is that contract.
contract RogueOracleAdapter is IOracleAdapter {
    address public token_;
    uint256 public price18;
    bool public constant IS_ROGUE = true;

    constructor(address _token, uint256 _initialPrice18) {
        token_ = _token;
        price18 = _initialPrice18;
    }

    function token() external view returns (address) {
        return token_;
    }

    function adapterType() external pure returns (string memory) {
        return "rogue-unlisted";
    }

    function getPrice() external view returns (uint256) {
        return price18;
    }

    function setPrice(uint256 newPrice18) external {
        price18 = newPrice18;
    }
}