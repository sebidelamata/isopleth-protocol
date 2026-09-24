// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BucketMath
/// @notice Discretizes lender-chosen (maxBorrowLTV, liquidationLTV) pairs into fixed "ticks",
///         analogous to Uniswap v3 price ticks. Each (marketId, ltvTick, lltvTick) triple
///         identifies one bucket of fungible lender capital.
/// @dev LTV values are expressed in basis points (bps), 0-10_000 (0%-100%).
library BucketMath {
    /// @notice Granularity of the LTV ladder. 100 bps = 1% steps.
    uint16 internal constant TICK_SPACING_BPS = 100;

    /// @notice Minimum allowed max-borrow-LTV a lender can offer (40%).
    uint16 internal constant MIN_LTV_BPS = 4_000;

    /// @notice Maximum allowed max-borrow-LTV a lender can offer (95%). Hard ceiling.
    uint16 internal constant MAX_LTV_BPS = 9_500;

    /// @notice Maximum allowed liquidation-LTV a lender can offer (99%). Hard ceiling.
    uint16 internal constant MAX_LLTV_BPS = 9_900;

    /// @notice Minimum spread (in bps) required between a bucket's LTV tick and its LLTV tick.
    ///         Prevents zero-cushion buckets that can never be liquidated profitably.
    uint16 internal constant MIN_LTV_LLTV_SPREAD_BPS = 100;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    error InvalidTick();
    error LtvOutOfRange();
    error LltvOutOfRange();
    error InsufficientSpread();

    /// @notice Validates and converts a raw bps value into a tick index.
    function toTick(uint16 bps) internal pure returns (uint16 tick) {
        if (bps % TICK_SPACING_BPS != 0) revert InvalidTick();
        tick = bps / TICK_SPACING_BPS;
    }

    function toBps(uint16 tick) internal pure returns (uint16 bps) {
        bps = tick * TICK_SPACING_BPS;
    }

    /// @notice Validates a lender-submitted (ltvBps, lltvBps) pair and returns their ticks.
    function validateAndTick(uint16 ltvBps, uint16 lltvBps)
        internal
        pure
        returns (uint16 ltvTick, uint16 lltvTick)
    {
        if (ltvBps < MIN_LTV_BPS || ltvBps > MAX_LTV_BPS) revert LtvOutOfRange();
        if (lltvBps > MAX_LLTV_BPS) revert LltvOutOfRange();
        if (lltvBps < ltvBps + MIN_LTV_LLTV_SPREAD_BPS) revert InsufficientSpread();

        ltvTick = toTick(ltvBps);
        // lltv is rounded down to the nearest tick so it never silently exceeds what the lender approved
        lltvTick = lltvBps / TICK_SPACING_BPS;
    }

    /// @notice Packs (marketId, ltvTick, lltvTick) into a single bucket key.
    function bucketKey(bytes32 marketId, address loanAsset, uint16 ltvTick, uint16 lltvTick)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
    }
}
