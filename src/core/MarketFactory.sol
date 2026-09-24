// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {ProtocolConfig} from "../governance/ProtocolConfig.sol";

/// @title MarketFactory
/// @notice Anyone may permissionlessly create a Market = (collateralToken, oracleAdapter).
///         There is no asset listing vote. The only gate is that the oracle adapter's
///         bytecode must come from a governance-allowlisted, standardized adapter
///         implementation (see ProtocolConfig) -- this closes the "attach an arbitrary lying
///         oracle to a legitimate token" hole while keeping asset selection fully open.
contract MarketFactory {
    ProtocolConfig public immutable config;

    struct Market {
        address collateralToken;
        address oracleAdapter;
        bool exists;
    }

    mapping(bytes32 marketId => Market) public markets;

    event MarketCreated(bytes32 indexed marketId, address indexed collateralToken, address indexed oracleAdapter);

    error AdapterNotAllowed();
    error AdapterTokenMismatch();
    error MarketAlreadyExists();
    error MarketDoesNotExist();

    constructor(address _config) {
        config = ProtocolConfig(_config);
    }

    function computeMarketId(address collateralToken, address oracleAdapter) public pure returns (bytes32) {
        return keccak256(abi.encode(collateralToken, oracleAdapter));
    }

    /// @notice Permissionlessly create a market. Reverts if the oracle adapter's bytecode
    ///         is not on the governance allowlist, or if the adapter is not hard-bound to
    ///         the exact collateral token being listed (prevents mismatched pricing).
    function createMarket(address collateralToken, address oracleAdapter) external returns (bytes32 marketId) {
        if (!config.isAdapterAllowed(oracleAdapter)) revert AdapterNotAllowed();
        if (IOracleAdapter(oracleAdapter).token() != collateralToken) revert AdapterTokenMismatch();

        marketId = computeMarketId(collateralToken, oracleAdapter);
        if (markets[marketId].exists) revert MarketAlreadyExists();

        markets[marketId] = Market({collateralToken: collateralToken, oracleAdapter: oracleAdapter, exists: true});
        emit MarketCreated(marketId, collateralToken, oracleAdapter);
    }

    function getMarket(bytes32 marketId) external view returns (Market memory m) {
        m = markets[marketId];
        if (!m.exists) revert MarketDoesNotExist();
    }

    function priceOf(bytes32 marketId) external view returns (uint256 price18) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketDoesNotExist();
        price18 = IOracleAdapter(m.oracleAdapter).getPrice();
    }
}
