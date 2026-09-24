
 // SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter} from "../../src/oracles/ChainlinkOracleAdapter.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";

/// @notice Mock Chainlink AggregatorV3 feed for deterministic unit tests.
contract MockAggregatorV3 {
    uint8 public immutable decimals;

    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setRoundData(
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _roundId,
        uint80 _answeredInRound
    ) external {
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (
            roundId,
            answer,
            startedAt,
            updatedAt,
            answeredInRound
        );
    }
}

contract ChainlinkOracleAdapterTest is Test {
    ChainlinkOracleAdapter internal adapter;
    MockAggregatorV3 internal feed;

    address internal constant TOKEN = address(0x1234);

    uint256 internal constant STALE_AFTER = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockAggregatorV3(8);

        feed.setRoundData(
            2000e8,
            block.timestamp,
            block.timestamp,
            1,
            1
        );

        adapter = new ChainlinkOracleAdapter(
            TOKEN,
            address(feed),
            STALE_AFTER
        );
    }

    // ------------------------------------------------------------
    // Constructor and metadata
    // ------------------------------------------------------------

    function test_ConstructorStoresToken() public view {
        assertEq(adapter.token(), TOKEN);
        assertEq(adapter.token_(), TOKEN);
    }

    function test_ConstructorStoresFeed() public view {
        assertEq(address(adapter.feed()), address(feed));
    }

    function test_ConstructorStoresStaleAfter() public view {
        assertEq(adapter.staleAfter(), STALE_AFTER);
    }

    function test_AdapterType() public view {
        assertEq(adapter.adapterType(), "chainlink-v3");
    }

    function test_ImplementsOracleAdapterInterface() public view {
        IOracleAdapter oracle = IOracleAdapter(address(adapter));

        assertEq(oracle.token(), TOKEN);
        assertEq(oracle.adapterType(), "chainlink-v3");
        assertEq(oracle.getPrice(), 2000e18);
    }

    function test_ConstructorReadsFeedDecimals() public {
        MockAggregatorV3 feed6 = new MockAggregatorV3(6);

        feed6.setRoundData(
            1e6,
            block.timestamp,
            block.timestamp,
            1,
            1
        );

        ChainlinkOracleAdapter adapter6 =
            new ChainlinkOracleAdapter(
                TOKEN,
                address(feed6),
                STALE_AFTER
            );

        assertEq(adapter6.getPrice(), 1e18);
    }

    function test_InstancesHaveIdenticalRuntimeCodehash() public {
        MockAggregatorV3 anotherFeed = new MockAggregatorV3(18);

        ChainlinkOracleAdapter anotherAdapter =
            new ChainlinkOracleAdapter(
                address(0x5678),
                address(anotherFeed),
                2 days
            );

        assertEq(
            address(adapter).codehash,
            address(anotherAdapter).codehash
        );
    }

    // ------------------------------------------------------------
    // Price normalization
    // ------------------------------------------------------------

    function test_GetPriceWith8Decimals() public view {
        assertEq(adapter.getPrice(), 2000e18);
    }

    function test_GetPriceWith6Decimals() public {
        _assertPriceForDecimals(6, 123456789, 123456789e12);
    }

    function test_GetPriceWith18Decimals() public {
        _assertPriceForDecimals(18, 123456789e18, 123456789e18);
    }

    function test_GetPriceWith19Decimals() public {
        _assertPriceForDecimals(19, 1234567890, 123456789);
    }

    function test_GetPriceWith20Decimals() public {
        _assertPriceForDecimals(20, 12345678900, 123456789);
    }

    function test_GetPriceWith0Decimals() public {
        _assertPriceForDecimals(0, 123, 123e18);
    }

    function test_GetPriceWith36Decimals() public {
        _assertPriceForDecimals(36, 1e36, 1e18);
    }

    function test_GetPriceWithDecimalsAbove18Truncates() public {
        // 1.99 / 10 = 0.19 after integer truncation.
        _assertPriceForDecimals(19, 199, 19);
    }

    function test_GetPriceWithZeroAnswerReverts() public {
        feed.setRoundData(
            0,
            block.timestamp,
            block.timestamp,
            2,
            2
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleAdapter.InvalidPrice.selector,
                int256(0)
            )
        );

        adapter.getPrice();
    }

    function test_GetPriceWithNegativeAnswerReverts() public {
        feed.setRoundData(
            -1,
            block.timestamp,
            block.timestamp,
            2,
            2
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleAdapter.InvalidPrice.selector,
                int256(-1)
            )
        );

        adapter.getPrice();
    }

    function test_GetPriceWithMinimumPositiveAnswer() public {
        feed.setRoundData(
            1,
            block.timestamp,
            block.timestamp,
            2,
            2
        );

        assertEq(adapter.getPrice(), 1e10);
    }

    function test_GetPriceWithLargeAnswer() public {
        uint256 largeAnswer = 1e30;

        feed.setRoundData(
            int256(largeAnswer),
            block.timestamp,
            block.timestamp,
            2,
            2
        );

        assertEq(adapter.getPrice(), largeAnswer * 1e10);
    }

    // ------------------------------------------------------------
    // Staleness validation
    // ------------------------------------------------------------

    function test_GetPriceAtExactStaleBoundary() public {
        uint256 updatedAt = block.timestamp;

        vm.warp(updatedAt + STALE_AFTER);

        feed.setRoundData(
            2000e8,
            updatedAt,
            updatedAt,
            2,
            2
        );

        assertEq(adapter.getPrice(), 2000e18);
    }

    function test_GetPriceOneSecondPastStaleBoundaryReverts() public {
        uint256 updatedAt = block.timestamp;

        feed.setRoundData(
            2000e8,
            updatedAt,
            updatedAt,
            2,
            2
        );

        vm.warp(updatedAt + STALE_AFTER + 1);

        vm.expectPartialRevert(
            ChainlinkOracleAdapter.StalePrice.selector
        );

        adapter.getPrice();
    }

    function test_GetPriceWithFreshTimestamp() public {
        uint256 updatedAt = block.timestamp - 30 minutes;

        feed.setRoundData(
            2000e8,
            updatedAt,
            updatedAt,
            2,
            2
        );

        assertEq(adapter.getPrice(), 2000e18);
    }

    function test_GetPriceWithZeroStalenessAndCurrentTimestamp() public {
        ChainlinkOracleAdapter zeroStaleAdapter =
            new ChainlinkOracleAdapter(
                TOKEN,
                address(feed),
                0
            );

        feed.setRoundData(
            2000e8,
            block.timestamp,
            block.timestamp,
            2,
            2
        );

        assertEq(zeroStaleAdapter.getPrice(), 2000e18);
    }

    function test_GetPriceWithZeroStalenessAndPastTimestampReverts()
        public
    {
        ChainlinkOracleAdapter zeroStaleAdapter =
            new ChainlinkOracleAdapter(
                TOKEN,
                address(feed),
                0
            );

        uint256 updatedAt = block.timestamp - 1;

        feed.setRoundData(
            2000e8,
            updatedAt,
            updatedAt,
            2,
            2
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleAdapter.StalePrice.selector,
                updatedAt,
                block.timestamp,
                uint256(0)
            )
        );

        zeroStaleAdapter.getPrice();
    }

    function test_GetPriceWithFutureTimestampIsAccepted() public {
        uint256 futureTimestamp = block.timestamp + 1 days;

        feed.setRoundData(
            2000e8,
            futureTimestamp,
            futureTimestamp,
            2,
            2
        );

        assertEq(adapter.getPrice(), 2000e18);
    }

    // ------------------------------------------------------------
    // Error precedence
    // ------------------------------------------------------------

    function test_InvalidPriceCheckedBeforeStaleness() public {
        uint256 updatedAt =
            block.timestamp - STALE_AFTER - 1;

        feed.setRoundData(
            0,
            updatedAt,
            updatedAt,
            2,
            2
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleAdapter.InvalidPrice.selector,
                int256(0)
            )
        );

        adapter.getPrice();
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    function _assertPriceForDecimals(
        uint8 decimals_,
        uint256 rawAnswer,
        uint256 expectedPrice
    ) internal {
        MockAggregatorV3 localFeed =
            new MockAggregatorV3(decimals_);

        localFeed.setRoundData(
            int256(rawAnswer),
            block.timestamp,
            block.timestamp,
            1,
            1
        );

        ChainlinkOracleAdapter localAdapter =
            new ChainlinkOracleAdapter(
                TOKEN,
                address(localFeed),
                STALE_AFTER
            );

        assertEq(localAdapter.getPrice(), expectedPrice);
    }
}