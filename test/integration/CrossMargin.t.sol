// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";

/// @notice Verifies the account-level cross-margin UX: one borrower can hold collateral and
///         debt across multiple markets simultaneously, while each individual Draw remains an
///         independently well-defined, independently liquidatable unit (see README design
///         notes on why liquidation resolves per-draw rather than on a blended position LTV).
contract CrossMarginTest is TestBase {
    address lenderWeth = makeAddr("lenderWeth");
    address lenderWbtc = makeAddr("lenderWbtc");
    address borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();
        _dealAndApprove(usdc, lenderWeth, 1_000_000e6);
        _dealAndApprove(usdc, lenderWbtc, 1_000_000e6);
        _dealAndApprove(weth, borrower, 1_000e18);
        _dealAndApprove(wbtc, borrower, 1_000e8);

        vm.prank(lenderWeth);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 50_000e6);
        vm.prank(lenderWbtc);
        pool.supply(wbtcMarketId, address(usdc), 6000, 7500, 50_000e6);
    }

    function test_oneAccount_holdsDrawsInTwoIndependentMarkets() public {
        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        wbtc.approve(address(pool), type(uint256).max);

        pool.depositCollateral(wethMarketId, 5e18); // $15,000
        pool.depositCollateral(wbtcMarketId, 1e8); // $60,000 (1 WBTC)

        pool.borrow(address(usdc), wethMarketId, 5_000e6);
        pool.borrow(address(usdc), wbtcMarketId, 20_000e6);
        vm.stopPrank();

        LendingPool.Draw memory wethDraw = pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);
        LendingPool.Draw memory wbtcDraw = pool.getDraw(borrower, wbtcMarketId, address(usdc), 60, 75);

        assertGt(wethDraw.borrowShares, 0);
        assertGt(wbtcDraw.borrowShares, 0);

        LendingPool.Draw[] memory all = pool.getDraws(borrower);
        assertEq(all.length, 2);
    }

    function test_priceCrashInOneMarket_onlyLiquidatesThatMarketsDraw() public {
        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        wbtc.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 5e18);
        pool.depositCollateral(wbtcMarketId, 1e8);
        pool.borrow(address(usdc), wethMarketId, 3_400e6); // ~68% LTV of WETH collateral, near max 70%
        pool.borrow(address(usdc), wbtcMarketId, 10_000e6); // well under WBTC's 60% LTV
        vm.stopPrank();

        wethOracle.setPrice(2000e18); // WETH crashes; WBTC untouched

        address liquidator = makeAddr("liquidator");
        _dealAndApprove(usdc, liquidator, 1_000_000e6);

        // WETH draw should now be liquidatable...
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) =
            pool.liquidate(borrower, wethMarketId, address(usdc), 7000, 8000, 1_000e6);
        assertGt(repaid, 0);
        assertGt(seized, 0);

        // ...while the WBTC draw, backed by an entirely different market and different
        // lender's bucket, is completely unaffected by the WETH crash.
        vm.prank(liquidator);
        vm.expectRevert(LendingPool.NotLiquidatable.selector);
        pool.liquidate(borrower, wbtcMarketId, address(usdc), 6000, 7500, 1_000e6);
    }

    function test_freeCollateralInOneMarket_cannotBackDrawInAnotherMarket() public {
        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 100e18); // huge WETH collateral, but no WBTC deposited

        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), wbtcMarketId, 1_000e6); // no free collateral in the WBTC market
        vm.stopPrank();
    }
}
