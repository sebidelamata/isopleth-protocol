// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracleAdapter} from "../../src/mocks/MockOracleAdapter.sol";
import {RogueOracleAdapter} from "../../src/mocks/RogueOracleAdapter.sol";

/// @notice Covers MarketFactory in isolation: permissionless creation, the oracle-allowlist
///         gate, and the token/adapter binding check. TestBase's setUp() already creates
///         wethMarketId/wbtcMarketId as an implicit "happy path" fixture; these tests exercise
///         the edges and failure modes around that flow directly.
contract MarketInitializationTest is TestBase {
    function test_createMarket_isPermissionless_anyCallerCanCreate() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        MockOracleAdapter newOracle = new MockOracleAdapter(address(newToken), 100e18);

        vm.prank(admin);
        config.setAdapterCodehashAllowed(address(newOracle).codehash, true);

        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        bytes32 marketId = factory.createMarket(address(newToken), address(newOracle));

        MarketFactory.Market memory m = factory.getMarket(marketId);
        assertEq(m.collateralToken, address(newToken));
        assertEq(m.oracleAdapter, address(newOracle));
        assertTrue(m.exists);
    }

    function test_computeMarketId_matchesIdReturnedByCreateMarket() public view {
        bytes32 expected = factory.computeMarketId(address(weth), address(wethOracle));
        assertEq(expected, wethMarketId);
    }

    function test_computeMarketId_isPure_sameInputsAlwaysSameOutput() public view {
        bytes32 a = factory.computeMarketId(address(weth), address(wethOracle));
        bytes32 b = factory.computeMarketId(address(weth), address(wethOracle));
        assertEq(a, b);
    }

    function test_differentMarkets_haveDifferentIds() public view {
        assertTrue(wethMarketId != wbtcMarketId);
    }

    function test_createMarket_revertsIfAdapterCodehashNotAllowlisted() public {
        MockERC20 newToken = new MockERC20("Unlisted", "UNL", 18);
        // RogueOracleAdapter is a genuinely different implementation (different runtime
        // codehash) from the already-allowlisted MockOracleAdapter -- using another
        // MockOracleAdapter instance here would NOT test this path, since every instance of
        // the same implementation shares one allowlist entry by design (see README).
        RogueOracleAdapter neverAllowlisted = new RogueOracleAdapter(address(newToken), 1e18);

        vm.expectRevert(MarketFactory.AdapterNotAllowed.selector);
        factory.createMarket(address(newToken), address(neverAllowlisted));
    }

    function test_createMarket_revertsOnTokenAdapterMismatch() public {
        // wethOracle is hard-bound to WETH; attempting to list it against WBTC must fail
        // even though wethOracle's codehash is separately allowlisted, since MockOracleAdapter
        // shares one runtime codehash across all instances (see README's `immutable` note) and
        // the allowlist alone is not sufficient -- the explicit token-binding check is what
        // actually prevents a legitimate-looking oracle being mismatched to the wrong asset.
        vm.expectRevert(MarketFactory.AdapterTokenMismatch.selector);
        factory.createMarket(address(wbtc), address(wethOracle));
    }

    function test_createMarket_revertsOnDuplicateMarket() public {
        vm.expectRevert(MarketFactory.MarketAlreadyExists.selector);
        factory.createMarket(address(weth), address(wethOracle));
    }

    function test_getMarket_revertsForNonexistentMarket() public {
        bytes32 fakeMarketId = keccak256("does not exist");
        vm.expectRevert(MarketFactory.MarketDoesNotExist.selector);
        factory.getMarket(fakeMarketId);
    }

    function test_priceOf_returnsUnderlyingAdapterPrice() public {
        assertEq(factory.priceOf(wethMarketId), 3000e18);
        wethOracle.setPrice(3500e18);
        assertEq(factory.priceOf(wethMarketId), 3500e18);
    }

    function test_priceOf_revertsForNonexistentMarket() public {
        bytes32 fakeMarketId = keccak256("does not exist");
        vm.expectRevert(MarketFactory.MarketDoesNotExist.selector);
        factory.priceOf(fakeMarketId);
    }

    function test_sameToken_twoDifferentOracleAdapters_createTwoDistinctMarkets() public {
        // A key property of "market = (collateral, oracle)" rather than "market = collateral":
        // two lenders who trust different price feeds for the SAME token are choosing
        // different markets, not competing for the same bucket ladder.
        MockOracleAdapter altWethOracle = new MockOracleAdapter(address(weth), 2900e18);
        vm.prank(admin);
        config.setAdapterCodehashAllowed(address(altWethOracle).codehash, true);

        bytes32 altMarketId = factory.createMarket(address(weth), address(altWethOracle));

        assertTrue(altMarketId != wethMarketId);
        MarketFactory.Market memory original = factory.getMarket(wethMarketId);
        MarketFactory.Market memory alt = factory.getMarket(altMarketId);
        assertEq(original.collateralToken, alt.collateralToken);
        assertTrue(original.oracleAdapter != alt.oracleAdapter);
    }

    function test_revokingAdapterAllowlist_doesNotRetroactivelyBreakExistingMarkets() public {
        // Existing markets keep functioning even if governance later revokes the adapter type
        // from the allowlist -- createMarket is gated at creation time, not read time. (Whether
        // this is the right tradeoff for a live incident is a governance/product decision, not
        // a contract bug; this test documents the actual current behavior.)
        vm.prank(admin);
        config.setAdapterCodehashAllowed(address(wethOracle).codehash, false);

        // existing market still queryable and pricing still works
        MarketFactory.Market memory m = factory.getMarket(wethMarketId);
        assertTrue(m.exists);
        assertEq(factory.priceOf(wethMarketId), 3000e18);

        // but no NEW market can be created with that now-disallowed adapter codehash
        MockERC20 anotherToken = new MockERC20("Another", "ANT", 18);
        MockOracleAdapter anotherOracle = new MockOracleAdapter(address(anotherToken), 1e18);
        // anotherOracle shares wethOracle's codehash (same MockOracleAdapter bytecode), so it's
        // also now disallowed
        vm.expectRevert(MarketFactory.AdapterNotAllowed.selector);
        factory.createMarket(address(anotherToken), address(anotherOracle));
    }
}
