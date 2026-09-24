// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @notice Minimal subset of Chainlink's AggregatorV3Interface, declared locally to avoid an
///         external dependency on the Chainlink package for this reference implementation.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkOracleAdapter
/// @notice Wraps a single Chainlink feed for a single collateral token, normalizing to 1e18
///         and enforcing a staleness bound. One adapter instance = one token, permanently.
///         Anyone may deploy an instance; only instances *allowlisted by governance* (by type,
///         via ProtocolConfig) can back a permissionless Market — this contract does not
///         self-certify trust, it only standardizes the interface and enforces basic safety
///         invariants (staleness, non-negative price) so governance's review is cheap and
///         mechanical rather than asset-by-asset.
contract ChainlinkOracleAdapter is IOracleAdapter {
    // Deliberately NOT `immutable`. Governance allowlists adapters by RUNTIME CODEHASH so that
    // one audited implementation can permissionlessly back any number of per-token instances.
    // Solidity bakes `immutable` values directly into runtime bytecode, which would make each
    // instance's codehash unique to its constructor args and silently break that allowlist
    // model (every legitimate new token's adapter would need a fresh governance vote again --
    // exactly the asset-by-asset bottleneck this design is meant to avoid). Plain storage costs
    // a little extra gas per read but keeps runtime bytecode -- and therefore codehash --
    // identical across every instance of this contract.
    address public token_;
    IAggregatorV3 public feed;
    uint256 public staleAfter;
    uint8 private feedDecimals;

    error StalePrice(uint256 updatedAt, uint256 nowTs, uint256 staleAfter_);
    error InvalidPrice(int256 answer);

    constructor(address _token, address _feed, uint256 _staleAfter) {
        token_ = _token;
        feed = IAggregatorV3(_feed);
        staleAfter = _staleAfter;
        feedDecimals = IAggregatorV3(_feed).decimals();
    }

    function token() external view returns (address) {
        return token_;
    }

    function adapterType() external pure returns (string memory) {
        return "chainlink-v3";
    }

    function getPrice() external view returns (uint256 price18) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (block.timestamp > updatedAt + staleAfter) {
            revert StalePrice(updatedAt, block.timestamp, staleAfter);
        }

        uint256 raw = uint256(answer);
        if (feedDecimals < 18) {
            price18 = raw * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            price18 = raw / (10 ** (feedDecimals - 18));
        } else {
            price18 = raw;
        }
    }
}
