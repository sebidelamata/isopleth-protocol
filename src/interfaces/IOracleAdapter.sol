// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IOracleAdapter
/// @notice Standard interface every price adapter must implement to be allowlisted by
///         governance and usable in a permissionless Market. Deliberately narrow: a market
///         is (collateralToken, oracleAdapter), and the adapter is hard-bound to ONE token so
///         a deployer cannot silently repoint an oracle after lenders have deposited against it.
interface IOracleAdapter {
    /// @notice The single collateral token this adapter is authorized to price.
    ///         The MarketFactory enforces marketToken == adapter.token() at creation time.
    function token() external view returns (address);

    /// @notice Returns the token price in terms of a common quote (18-decimal fixed point,
    ///         USD-denominated), and reverts if the price is stale or otherwise invalid.
    /// @return price18 Price of 1 whole token (10**tokenDecimals base units), scaled 1e18.
    function getPrice() external view returns (uint256 price18);

    /// @notice A human-readable tag for the adapter *type* (e.g. "chainlink-v3", "pyth-v2").
    ///         Governance allowlists by type-implementation address, this is informational
    ///         for indexers/UIs.
    function adapterType() external pure returns (string memory);
}
