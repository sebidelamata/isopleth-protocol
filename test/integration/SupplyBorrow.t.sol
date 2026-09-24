// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";

contract SupplyBorrowTest is TestBase {
    address lenderA = makeAddr("lenderA"); // conservative: 70/80
    address lenderB = makeAddr("lenderB"); // riskier: 85/90
    address borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();
        _dealAndApprove(usdc, lenderA, 1_000_000e6);
        _dealAndApprove(usdc, lenderB, 1_000_000e6);
        _dealAndApprove(weth, borrower, 1_000e18);
    }

    function test_supply_createsShares1to1OnFirstDeposit() public {
        vm.prank(lenderA);
        uint256 shares = pool.supply(wethMarketId, address(usdc), 7000, 8000, 10_000e6);
        // First deposit into an empty bucket mints shares scaled by VIRTUAL_SHARES (see
        // MathLib) -- this is what neutralizes a first-depositor inflation attack.
        assertApproxEqRel(shares, 10_000e6 * 1_000_000, 0.001e18);
    }

    function test_borrow_drawsFromLowestLtvBucketFirst() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 5_000e6);
        vm.prank(lenderB);
        pool.supply(wethMarketId, address(usdc), 8500, 9000, 5_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18); // 10 WETH @ $3000 = $30,000
        pool.borrow(address(usdc), wethMarketId, 3_000e6); // small borrow, should fit entirely in lenderA's 70% bucket
        vm.stopPrank();

        LendingPool.Draw memory drawA = pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);
        assertGt(drawA.borrowShares, 0);

        // lenderB's bucket should be untouched since lenderA's cheaper bucket had enough room
        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(borrower, wethMarketId, address(usdc), 85, 90);
    }

    function test_borrow_spillsIntoHigherBucketWhenLowerExhausted() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 1_000e6); // thin conservative bucket
        vm.prank(lenderB);
        pool.supply(wethMarketId, address(usdc), 8500, 9000, 5_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18); // $30,000 collateral
        pool.borrow(address(usdc), wethMarketId, 3_000e6); // exceeds lenderA's 1000 available
        vm.stopPrank();

        LendingPool.Draw memory drawA = pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);
        LendingPool.Draw memory drawB = pool.getDraw(borrower, wethMarketId, address(usdc), 85, 90);
        assertGt(drawA.borrowShares, 0);
        assertGt(drawB.borrowShares, 0);
    }

    function test_borrow_revertsWhenLtvExceedsAllAvailableBuckets() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 100_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 1e18); // $3000 collateral, max 70% = $2100
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), wethMarketId, 2_500e6); // exceeds 70% LTV capacity, no higher bucket exists
        vm.stopPrank();
    }

    function test_lenderWhoDoesNotAcceptCollateral_isNeverDrawnFrom() public {
        // lenderA only supplies against WBTC market, not WETH
        vm.prank(lenderA);
        pool.supply(wbtcMarketId, address(usdc), 7000, 8000, 50_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), wethMarketId, 1_000e6); // no WETH-market lender exists at all
        vm.stopPrank();
    }

    function test_repay_fullyClearsDrawAndReleasesCollateral() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 10_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 3_000e6);

        usdc.mint(borrower, 100e6); // cover any accrued interest
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(wethMarketId, address(usdc), 7000, 8000, 3_100e6);
        vm.stopPrank();

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);

        // all collateral should be free again
        assertEq(pool.freeCollateral(borrower, wethMarketId), 10e18);
    }

    function test_withdraw_revertsIfExceedsAvailableLiquidity() public {
        vm.prank(lenderA);
        uint256 lenderShares = pool.supply(wethMarketId, address(usdc), 7000, 8000, 10_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 9_000e6);
        vm.stopPrank();

        vm.startPrank(lenderA);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdraw(wethMarketId, address(usdc), 7000, 8000, lenderShares); // only ~1000 left unborrowed
    }

    function test_interestAccrues_overTime() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 10_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 8_000e6); // 80% utilization -> right at kink
        vm.stopPrank();

        uint256 debtBefore = pool.previewDebt(wethMarketId, address(usdc), 70, 80, borrower);
        vm.warp(block.timestamp + 365 days);
        uint256 debtAfter = pool.previewDebt(wethMarketId, address(usdc), 70, 80, borrower);

        assertGt(debtAfter, debtBefore);
    }
}
