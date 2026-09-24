// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RogueOracleAdapter} from "../../src/mocks/RogueOracleAdapter.sol";
import {MockOracleAdapter} from "../../src/mocks/MockOracleAdapter.sol";

contract RogueOracleAdapterTest is Test {
    RogueOracleAdapter internal adapter;

    address internal token = makeAddr("token");
    uint256 internal constant INITIAL_PRICE = 2_500e18;

    function setUp() public {
        adapter = new RogueOracleAdapter(token, INITIAL_PRICE);
    }

    function test_ConstructorSetsTokenAndPrice() public view {
        assertEq(adapter.token_(), token);
        assertEq(adapter.price18(), INITIAL_PRICE);
    }

    function test_Token() public view {
        assertEq(adapter.token(), token);
    }

    function test_AdapterType() public view {
        assertEq(adapter.adapterType(), "rogue-unlisted");
    }

    function test_GetPrice() public view {
        assertEq(adapter.getPrice(), INITIAL_PRICE);
    }

    function test_SetPrice() public {
        uint256 newPrice = 3_000e18;

        adapter.setPrice(newPrice);

        assertEq(adapter.price18(), newPrice);
        assertEq(adapter.getPrice(), newPrice);
    }

    function test_SetPriceMultipleTimes() public {
        adapter.setPrice(1_000e18);
        assertEq(adapter.getPrice(), 1_000e18);

        adapter.setPrice(4_200e18);
        assertEq(adapter.getPrice(), 4_200e18);

        adapter.setPrice(0);
        assertEq(adapter.getPrice(), 0);
    }

    function test_IsRogue() public view {
        assertTrue(adapter.IS_ROGUE());
    }

    function test_RogueHasDistinctCodehashFromMockOracleAdapter() public {
        MockOracleAdapter mock = new MockOracleAdapter(token, INITIAL_PRICE);

        assertTrue(
            address(adapter).codehash != address(mock).codehash
        );
    }

    function test_DifferentRogueInstancesShareCodehash() public {
        RogueOracleAdapter adapter2 =
            new RogueOracleAdapter(makeAddr("token2"), 1e18);

        assertEq(
            address(adapter).codehash,
            address(adapter2).codehash
        );
    }
}