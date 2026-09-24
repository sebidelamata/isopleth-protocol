// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";

contract LiquidationTest is TestBase {
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    function setUp() public override {
        super.setUp();
        _dealAndApprove(usdc, lender, 1_000_000e6);
        _dealAndApprove(weth, borrower, 1_000e18);
        _dealAndApprove(usdc, liquidator, 1_000_000e6);

        vm.prank(lender);
        pool.supply(wethMarketId, address(usdc), 7500, 8300, 100_000e6); // 75% LTV / 83% LLTV

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18); // $30,000 @ $3000/WETH
        pool.borrow(address(usdc), wethMarketId, 22_000e6); // ~73.3% LTV, healthy (< 75% max, well under 83% LLTV)
        vm.stopPrank();
    }

    function test_healthyPosition_cannotBeLiquidated() public {
        vm.prank(liquidator);
        vm.expectRevert(LendingPool.NotLiquidatable.selector);
        pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 1_000e6);
    }

    function test_priceDropPastLltv_becomesLiquidatable() public {
        // Drop WETH price so debt/collateral > 83%. debt ~= 22,000. Need collateral value < 22000/0.83 = 26,506
        // collateral = 10 WETH, so price < 2650.6
        wethOracle.setPrice(2500e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 5_000e6);

        assertGt(repaid, 0);
        assertGt(seized, 0);
    }

    function test_liquidationBonus_ramps_soLaterLiquidatorsGetMoreCollateralPerDollar() public {
        wethOracle.setPrice(2500e18);

        vm.prank(liquidator);
        (uint256 repaid1, uint256 seized1) =
            pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 1_000e6);

        // fast forward through most of the auction ramp and liquidate more of the SAME draw
        vm.warp(block.timestamp + 25 minutes);
        vm.prank(liquidator);
        (uint256 repaid2, uint256 seized2) =
            pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 1_000e6);

        // collateral seized per dollar repaid should be higher once the auction has ramped up
        uint256 rate1 = (seized1 * 1e18) / repaid1;
        uint256 rate2 = (seized2 * 1e18) / repaid2;
        assertGt(rate2, rate1);
    }

    function test_liquidation_repaysBucketDebtAndReducesUtilization() public {
        wethOracle.setPrice(2500e18);

        uint256 utilBefore = pool.bucketUtilizationWad(wethMarketId, address(usdc), 75, 83);

        vm.prank(liquidator);
        pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 10_000e6);

        uint256 utilAfter = pool.bucketUtilizationWad(wethMarketId, address(usdc), 75, 83);
        assertLt(utilAfter, utilBefore);
    }

    function test_deepCrash_liquidatorCappedAtAvailableCollateral() public {
        // Crash price far enough that the full requested repay's bonus can't be covered by
        // the draw's remaining collateral -- liquidator is capped at what's actually there.
        wethOracle.setPrice(1500e18); // collateral now worth $15,000 vs ~$22,000+ debt
        vm.warp(block.timestamp + 30 minutes); // full auction bonus (12%)

        vm.prank(liquidator);
        (, uint256 seized) = pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 22_500e6);

        assertLe(seized, 10e18); // never seizes more than the draw ever held
    }

    function test_socializeBadDebt_writesDownBucketSupplyAndRemovesDraw() public {
        // Extreme crash: collateral (10 WETH @ $500 = $5,000) can't cover the bonus-adjusted
        // value of even a partial repay against the ~$22,000 debt, so the liquidator's seize
        // is capped at all remaining collateral while real debt remains outstanding -- classic
        // bad debt. (Requesting a repay smaller than total debt, unlike the "deep crash" test
        // above, is what actually leaves shares > 0 after the collateral-cap kicks in.)
        wethOracle.setPrice(500e18);
        vm.warp(block.timestamp + 30 minutes);

        vm.prank(liquidator);
        pool.liquidate(borrower, wethMarketId, address(usdc), 7500, 8300, 10_000e6);

        LendingPool.Draw memory d = pool.getDraw(borrower, wethMarketId, address(usdc), 75, 83);
        assertEq(d.collateralAmount, 0);
        assertGt(d.borrowShares, 0);

        pool.socializeBadDebt(borrower, wethMarketId, address(usdc), 7500, 8300);

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(borrower, wethMarketId, address(usdc), 75, 83);
    }

    function test_socializeBadDebt_revertsWhenDrawIsHealthyOrHasCollateral() public {
        vm.expectRevert(); // draw exists but is healthy / still has collateral
        pool.socializeBadDebt(borrower, wethMarketId, address(usdc), 7500, 8300);
    }
}
