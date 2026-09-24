// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @notice Simple settable-price oracle adapter for tests. In production only vetted adapter
///         implementations (e.g. ChainlinkOracleAdapter) would have their codehash allowlisted;
///         this mock stands in for that adapter type in the test environment.
contract MockOracleAdapter is IOracleAdapter {
    // Deliberately NOT `immutable`: immutable values are baked into runtime bytecode, which
    // would make every per-token instance's codehash unique and defeat codehash-based
    // allowlisting (see ProtocolConfig / ChainlinkOracleAdapter for the same note).
    address public token_;
    uint256 public price18;

    constructor(address _token, uint256 _initialPrice18) {
        token_ = _token;
        price18 = _initialPrice18;
    }

    function token() external view returns (address) {
        return token_;
    }

    function adapterType() external pure returns (string memory) {
        return "mock-settable";
    }

    function getPrice() external view returns (uint256) {
        return price18;
    }

    function setPrice(uint256 newPrice18) external {
        price18 = newPrice18;
    }
}
