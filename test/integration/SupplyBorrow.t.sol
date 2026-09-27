// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";
import {BucketMath} from "../../src/libraries/BucketMath.sol";

contract SupplyBorrowTest is TestBase {
    address lenderA = makeAddr("lenderA"); // conservative: 70/80
    address lenderB = makeAddr("lenderB"); // riskier: 85/90
    address borrower = makeAddr("borrower");
    address borrowerB = makeAddr("borrowerB");

    function _getBucket(bytes32 bucketKey)
        internal
        view
        returns (LendingPool.Bucket memory b)
    {
        (
            b.totalSupplyAssets,
            b.totalSupplyShares,
            b.totalBorrowAssets,
            b.totalBorrowShares,
            b.lastAccrue
        ) = pool.buckets(bucketKey);
    }

    function setUp() public override {
        super.setUp();
        _dealAndApprove(usdc, lenderA, 1_000_000e6);
        _dealAndApprove(usdc, lenderB, 1_000_000e6);
        _dealAndApprove(weth, borrower, 1_000e18);
        _dealAndApprove(weth, borrowerB, 1_000e18);
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

    function test_multipleDrawsCannotReuseCollateral() public {
        // Force borrowing to spill across two distinct buckets.
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 1_000e6);

        vm.prank(lenderB);
        pool.supply(wethMarketId, address(usdc), 8500, 9000, 50_000e6);

        uint256 deposited = 10e18;

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, deposited);

        // Existing test demonstrates this creates draws in both buckets.
        pool.borrow(address(usdc), wethMarketId, 3_000e6);
        vm.stopPrank();

        LendingPool.Draw memory drawA =
            pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);

        LendingPool.Draw memory drawB =
            pool.getDraw(borrower, wethMarketId, address(usdc), 85, 90);

        assertGt(drawA.collateralAmount, 0, "draw A has no collateral");
        assertGt(drawB.collateralAmount, 0, "draw B has no collateral");

        uint256 free = pool.freeCollateral(borrower, wethMarketId);

        assertEq(
            free + drawA.collateralAmount + drawB.collateralAmount,
            deposited,
            "collateral is reused or unaccounted for"
        );

        // Try to borrow an amount that cannot be supported by the
        // remaining free collateral, even with the higher LTV bucket.
        uint256 freeBefore = free;
        uint256 drawABefore = drawA.collateralAmount;
        uint256 drawBBefore = drawB.collateralAmount;

        vm.startPrank(borrower);
        vm.expectRevert();
        pool.borrow(address(usdc), wethMarketId, 100_000e6);
        vm.stopPrank();

        // A reverted borrow must not change any collateral allocation.
        assertEq(pool.freeCollateral(borrower, wethMarketId), freeBefore);

        drawA = pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);
        drawB = pool.getDraw(borrower, wethMarketId, address(usdc), 85, 90);

        assertEq(drawA.collateralAmount, drawABefore);
        assertEq(drawB.collateralAmount, drawBBefore);

        assertEq(
            pool.freeCollateral(borrower, wethMarketId)
                + drawA.collateralAmount
                + drawB.collateralAmount,
            deposited,
            "failed borrow changed collateral accounting"
        );
    }

    function test_repayOneDrawDoesNotReleaseOtherDrawCollateral() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 1_000e6);

        vm.prank(lenderB);
        pool.supply(wethMarketId, address(usdc), 8500, 9000, 5_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 3_000e6);

        usdc.mint(borrower, 10_000e6);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        LendingPool.Draw memory drawBBefore =
            pool.getDraw(borrower, wethMarketId, address(usdc), 85, 90);

        assertGt(drawBBefore.collateralAmount, 0);

        uint256 freeBefore = pool.freeCollateral(borrower, wethMarketId);

        // Fully repay the draw in the 70/80 bucket.
        vm.prank(borrower);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            2_000e6
        );

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);

        LendingPool.Draw memory drawBAfter =
            pool.getDraw(borrower, wethMarketId, address(usdc), 85, 90);

        assertEq(
            drawBAfter.collateralAmount,
            drawBBefore.collateralAmount,
            "repayment changed collateral assigned to draw B"
        );

        uint256 freeAfter = pool.freeCollateral(borrower, wethMarketId);

        assertGt(freeAfter, freeBefore, "repaid collateral was not released");

        assertEq(
            freeAfter + drawBAfter.collateralAmount,
            10e18,
            "collateral conservation failed after repayment"
        );
    }

    function test_fullRepayOneBorrowerPreservesOtherBorrowerDebt()
        public
    {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        // Borrower A opens a draw.
        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 3_000e6);
        vm.stopPrank();

        // Borrower B opens a separate draw in the SAME bucket.
        vm.startPrank(borrowerB);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 3_000e6);
        vm.stopPrank();

        bytes32 bKey = BucketMath.bucketKey(
            wethMarketId,
            address(usdc),
            70,
            80
        );

        LendingPool.Bucket memory beforeRepay =
            _getBucket(bKey);

        LendingPool.Draw memory drawBBefore =
            pool.getDraw(
                borrowerB,
                wethMarketId,
                address(usdc),
                70,
                80
            );

        assertGt(beforeRepay.totalBorrowShares, 0);
        assertGt(beforeRepay.totalBorrowAssets, 0);
        assertGt(drawBBefore.borrowShares, 0);

        // Repay borrower A's entire debt.
        uint256 debtA = pool.previewDebt(
            wethMarketId,
            address(usdc),
            70,
            80,
            borrower
        );

        usdc.mint(borrower, debtA);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            debtA
        );
        vm.stopPrank();

        // Borrower A is gone.
        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        // Borrower B is untouched.
        LendingPool.Draw memory drawBAfter =
            pool.getDraw(
                borrowerB,
                wethMarketId,
                address(usdc),
                70,
                80
            );

        assertEq(
            drawBAfter.borrowShares,
            drawBBefore.borrowShares,
            "repayment changed borrower B shares"
        );

        LendingPool.Bucket memory afterRepay =
            _getBucket(bKey);

        assertGt(afterRepay.totalBorrowShares, 0);
        assertGt(afterRepay.totalBorrowAssets, 0);

        assertEq(
            afterRepay.totalBorrowShares,
            drawBAfter.borrowShares,
            "bucket shares do not equal remaining draw shares"
        );

        assertGe(
            afterRepay.totalBorrowAssets,
            pool.previewDebt(
                wethMarketId,
                address(usdc),
                70,
                80,
                borrowerB
            ),
            "aggregate bucket debt should cover remaining borrower debt"
        );
    }

    function test_finalRepayClearsBucketAfterInterestAndPartialRepay()
        public
    {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 8_000e6);
        vm.stopPrank();

        bytes32 bKey = BucketMath.bucketKey(
            wethMarketId,
            address(usdc),
            70,
            80
        );

        // Accrue interest.
        vm.warp(block.timestamp + 180 days);

        uint256 debtBefore = pool.previewDebt(
            wethMarketId,
            address(usdc),
            70,
            80,
            borrower
        );

        assertGt(debtBefore, 8_000e6);

        // Partial repayment.
        uint256 partialAmount = debtBefore / 3;

        usdc.mint(borrower, debtBefore);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);

        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            partialAmount
        );
        vm.stopPrank();

        LendingPool.Bucket memory afterPartial = _getBucket(bKey);

        LendingPool.Draw memory drawAfterPartial =
            pool.getDraw(
                borrower,
                wethMarketId,
                address(usdc),
                70,
                80
            );

        assertGt(drawAfterPartial.borrowShares, 0);
        assertGt(afterPartial.totalBorrowShares, 0);
        assertGt(afterPartial.totalBorrowAssets, 0);

        // Repay the entire remaining debt.
        uint256 remainingDebt = pool.previewDebt(
            wethMarketId,
            address(usdc),
            70,
            80,
            borrower
        );

        vm.prank(borrower);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            remainingDebt
        );

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        LendingPool.Bucket memory finalBucket = _getBucket(bKey);

        assertEq(
            finalBucket.totalBorrowShares,
            0,
            "borrow shares remain after final repayment"
        );

        assertEq(
            finalBucket.totalBorrowAssets,
            0,
            "borrow assets remain after final repayment"
        );

        assertEq(
            pool.freeCollateral(borrower, wethMarketId),
            10e18,
            "collateral was not fully released"
        );
    }

    

    function test_partialRepayOneBorrowerAfterAccrualPreservesOtherDraw() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 10_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 2_000e6);
        vm.stopPrank();

        vm.startPrank(borrowerB);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 2_000e6);
        vm.stopPrank();

        LendingPool.Draw memory drawBBefore =
            pool.getDraw(borrowerB, wethMarketId, address(usdc), 70, 80);

        vm.warp(block.timestamp + 90 days);
        uint256 debtA = pool.previewDebt(
            wethMarketId, address(usdc), 70, 80, borrower
        );
        uint256 partialAmount = debtA / 2;
        usdc.mint(borrower, debtA);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(
            wethMarketId, address(usdc), 7000, 8000, partialAmount
        );
        vm.stopPrank();

        LendingPool.Draw memory drawBAfter =
            pool.getDraw(borrowerB, wethMarketId, address(usdc), 70, 80);
        assertEq(
            drawBAfter.borrowShares,
            drawBBefore.borrowShares,
            "partial repayment changed the other borrower's shares"
        );
        assertGt(
            pool.previewDebt(wethMarketId, address(usdc), 70, 80, borrower),
            0,
            "partial repayment unexpectedly cleared borrower A"
        );

        // Fully repay A; B must remain independently outstanding.
        uint256 remainingA = pool.previewDebt(
            wethMarketId, address(usdc), 70, 80, borrower
        );
        usdc.mint(borrower, remainingA);
        vm.prank(borrower);
        pool.repay(
            wethMarketId, address(usdc), 7000, 8000, remainingA
        );

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(borrower, wethMarketId, address(usdc), 70, 80);

        LendingPool.Draw memory drawBFinal =
            pool.getDraw(borrowerB, wethMarketId, address(usdc), 70, 80);
        assertEq(
            drawBFinal.borrowShares,
            drawBBefore.borrowShares,
            "fully repaying A changed borrower B's shares"
        );
        assertGt(drawBFinal.borrowShares, 0);
    }

}
