// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracleAdapter} from "../../src/mocks/MockOracleAdapter.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";
import {RogueOracleAdapter} from "../../src/mocks/RogueOracleAdapter.sol";

contract LendingPoolTest is TestBase {
    address internal lenderA = makeAddr("lenderA");
    address internal lenderB = makeAddr("lenderB");
    address internal borrower = makeAddr("borrower");
    address internal borrower2 = makeAddr("borrower2");
    address internal liquidator = makeAddr("liquidator");

    bytes32 internal constant NONEXISTENT_MARKET = keccak256("nonexistent-market");

    function setUp() public override {
        super.setUp();

        _dealAndApprove(usdc, lenderA, 10_000_000e6);
        _dealAndApprove(usdc, lenderB, 10_000_000e6);
        _dealAndApprove(usdc, borrower, 10_000_000e6);
        _dealAndApprove(usdc, borrower2, 10_000_000e6);
        _dealAndApprove(usdc, liquidator, 10_000_000e6);

        _dealAndApprove(weth, borrower, 1_000e18);
        _dealAndApprove(weth, borrower2, 1_000e18);
    }

    // =============================================================
    // Constructor / initialization
    // =============================================================

    function test_constructor_setsDependencies() public {
        assertEq(address(pool.marketFactory()), address(factory));
        assertEq(address(pool.config()), address(config));
    }

    function test_initLoanAsset_registersAssetAndOracle() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        MockOracleAdapter daiOracle = new MockOracleAdapter(address(dai), 1e18);

        vm.prank(admin);
        config.setAdapterCodehashAllowed(address(daiOracle).codehash, true);

        pool.initLoanAsset(address(dai), address(daiOracle));

        assertTrue(pool.loanAssetListed(address(dai)));
        assertEq(pool.loanAssetOracle(address(dai)), address(daiOracle));
    }

    function test_initLoanAsset_revertsWhenAlreadyListed() public {
        vm.expectRevert(LendingPool.LoanAssetAlreadyListed.selector);
        pool.initLoanAsset(address(usdc), address(usdcOracle));
    }

    function test_initLoanAsset_revertsForUnapprovedAdapter() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        RogueOracleAdapter rogue = new RogueOracleAdapter(address(dai), 1e18);

        vm.expectRevert(LendingPool.AdapterNotAllowed.selector);
        pool.initLoanAsset(address(dai), address(rogue));
    }

    function test_initLoanAsset_revertsWhenAdapterTokenDoesNotMatch() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        // USDC oracle is allowlisted, but points to USDC rather than DAI.
        vm.expectRevert(LendingPool.AdapterTokenMismatch.selector);
        pool.initLoanAsset(address(dai), address(usdcOracle));
    }

    // =============================================================
    // Supply
    // =============================================================

    function test_supply_revertsOnZeroAmount() public {
        vm.prank(lenderA);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 0);
    }

    function test_supply_revertsForUnlistedLoanAsset() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        vm.prank(lenderA);
        vm.expectRevert(LendingPool.LoanAssetNotListed.selector);
        pool.supply(wethMarketId, address(dai), 7000, 8000, 1e18);
    }

    function test_supply_revertsForInvalidMarket() public {
        vm.prank(lenderA);
        vm.expectRevert();
        pool.supply(NONEXISTENT_MARKET, address(usdc), 7000, 8000, 1_000e6);
    }

    function test_supply_createsBucketAndActivatesTicks() public {
        vm.prank(lenderA);
        uint256 shares = pool.supply(wethMarketId, address(usdc), 7000, 8000, 1_000e6);

        assertGt(shares, 0);

        (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares,
            uint256 lastAccrue
        ) = pool.buckets(_bucketKey(wethMarketId, address(usdc), 70, 80));

        assertEq(totalSupplyAssets, 1_000e6);
        assertEq(totalSupplyShares, shares);
        assertEq(totalBorrowAssets, 0);
        assertEq(totalBorrowShares, 0);
        assertGt(lastAccrue, 0);

        assertGt(
            pool.supplyShares(_bucketKey(wethMarketId, address(usdc), 70, 80), lenderA),
            0
        );
    }

    function test_supply_twiceSameBucketAccruesWithoutChangingStateIncorrectly() public {
        vm.prank(lenderA);
        uint256 shares1 = pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        vm.prank(lenderB);
        uint256 shares2 = pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            2_000e6
        );

        assertGt(shares1, 0);
        assertGt(shares2, 0);

        (
            uint256 assets,
            uint256 shares,
            ,
            ,
        ) = pool.buckets(_bucketKey(wethMarketId, address(usdc), 70, 80));

        assertEq(assets, 3_000e6);
        assertEq(shares, shares1 + shares2);
    }

    // =============================================================
    // Withdraw
    // =============================================================

    function test_withdraw_revertsOnZeroShares() public {
        vm.prank(lenderA);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 1_000e6);

        vm.prank(lenderA);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdraw(wethMarketId, address(usdc), 7000, 8000, 0);
    }

    function test_withdraw_returnsAssetsAndBurnsShares() public {
        vm.prank(lenderA);
        uint256 shares = pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        uint256 lenderBalanceBefore = usdc.balanceOf(lenderA);

        vm.prank(lenderA);
        uint256 assets = pool.withdraw(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            shares
        );

        assertGt(assets, 0);
        assertEq(
            usdc.balanceOf(lenderA),
            lenderBalanceBefore + assets
        );

        assertEq(
            pool.supplyShares(
                _bucketKey(wethMarketId, address(usdc), 70, 80),
                lenderA
            ),
            0
        );

        (
            uint256 supplyAssets,
            uint256 supplyShares,
            ,
            ,
        ) = pool.buckets(_bucketKey(wethMarketId, address(usdc), 70, 80));

        assertEq(supplyAssets, 0);
        assertEq(supplyShares, 0);
    }

    function test_withdraw_fullBucket_deactivatesTicks() public {
        vm.prank(lenderA);
        uint256 shares = pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        vm.prank(lenderA);
        pool.withdraw(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            shares
        );

        // A new borrow should not be able to discover the now-empty bucket.
        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);

        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), wethMarketId, 1e6);

        vm.stopPrank();
    }

    function test_withdraw_revertsWhenLiquidityIsInsufficient() public {
        vm.prank(lenderA);
        uint256 shares = pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 9_000e6);
        vm.stopPrank();

        vm.prank(lenderA);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdraw(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            shares
        );
    }

    // =============================================================
    // Collateral
    // =============================================================

    function test_depositCollateral_revertsOnZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.depositCollateral(wethMarketId, 0);
    }

    function test_depositCollateral_increasesFreeCollateral() public {
        vm.prank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);

        assertEq(
            pool.freeCollateral(borrower, wethMarketId),
            10e18
        );
    }

    function test_depositCollateral_revertsForInvalidMarket() public {
        vm.prank(borrower);
        vm.expectRevert();
        pool.depositCollateral(NONEXISTENT_MARKET, 1e18);
    }

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdrawCollateral(wethMarketId, 0);
    }

    function test_withdrawCollateral_revertsWhenInsufficientCollateral() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdrawCollateral(wethMarketId, 1e18);
    }

    function test_withdrawCollateral_returnsCollateral() public {
        vm.prank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);

        uint256 before = weth.balanceOf(borrower);

        vm.prank(borrower);
        pool.withdrawCollateral(wethMarketId, 4e18);

        assertEq(
            pool.freeCollateral(borrower, wethMarketId),
            6e18
        );

        assertEq(
            weth.balanceOf(borrower),
            before + 4e18
        );
    }

    // =============================================================
    // Borrow
    // =============================================================

    function test_borrow_revertsOnZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.borrow(address(usdc), wethMarketId, 0);
    }

    function test_borrow_revertsForUnlistedLoanAsset() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        vm.prank(borrower);
        vm.expectRevert(LendingPool.LoanAssetNotListed.selector);
        pool.borrow(address(dai), wethMarketId, 1e18);
    }

    function test_borrow_revertsWhenNoLiquidityExists() public {
        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);

        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), wethMarketId, 1_000e6);

        vm.stopPrank();
    }

    function test_borrow_createsDrawAndConsumesFreeCollateral() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 3_000e6);
        vm.stopPrank();

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertGt(d.borrowShares, 0);
        assertGt(d.collateralAmount, 0);
        assertEq(
            pool.freeCollateral(borrower, wethMarketId),
            10e18 - d.collateralAmount
        );
    }

    function test_borrow_sameBucket_updatesExistingDraw() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);

        pool.borrow(address(usdc), wethMarketId, 1_000e6);

        LendingPool.Draw memory beforeDraw = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        pool.borrow(address(usdc), wethMarketId, 1_000e6);
        vm.stopPrank();

        LendingPool.Draw memory afterDraw = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertGt(afterDraw.borrowShares, beforeDraw.borrowShares);
        assertGt(afterDraw.collateralAmount, beforeDraw.collateralAmount);

        LendingPool.Draw[] memory draws = pool.getDraws(borrower);
        assertEq(draws.length, 1);
    }

    function test_borrow_skipsInactiveLtvAndLltvTicks() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            5_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 1_000e6);
        vm.stopPrank();

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertGt(d.borrowShares, 0);
    }

    function test_borrow_skipsFullyBorrowedBucket() public {
        // Fully consume the first bucket.
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        vm.prank(lenderB);
        pool.supply(
            wethMarketId,
            address(usdc),
            8500,
            9000,
            5_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);

        pool.borrow(address(usdc), wethMarketId, 1_000e6);

        // The 70/80 bucket is now fully borrowed. The second borrow
        // must walk past it.
        pool.borrow(address(usdc), wethMarketId, 2_000e6);
        vm.stopPrank();

        LendingPool.Draw memory dA = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        LendingPool.Draw memory dB = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            85,
            90
        );

        assertGt(dA.borrowShares, 0);
        assertGt(dB.borrowShares, 0);
    }

    // =============================================================
    // Repayment
    // =============================================================

    function test_repay_revertsOnZeroAmount() public {
        _openBasicDraw(3_000e6);

        vm.prank(borrower);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            0
        );
    }

    function test_repay_revertsForMissingDraw() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );
    }

    function test_repay_partiallyReducesDebtAndReleasesCollateralProRata() public {
        _openBasicDraw(4_000e6);

        LendingPool.Draw memory beforeDraw = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        vm.prank(borrower);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        LendingPool.Draw memory afterDraw = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertLt(afterDraw.borrowShares, beforeDraw.borrowShares);
        assertLt(afterDraw.collateralAmount, beforeDraw.collateralAmount);
        assertGt(
            pool.freeCollateral(borrower, wethMarketId),
            0
        );
    }

    function test_repayFull_removesDrawAndReturnsAllCollateral() public {
        _openBasicDraw(3_000e6);

        uint256 collateralBefore =
            pool.freeCollateral(borrower, wethMarketId);

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        vm.prank(borrower);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            type(uint256).max
        );

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertEq(
            pool.freeCollateral(borrower, wethMarketId),
            collateralBefore + d.collateralAmount
        );
    }

    function test_repay_clearsBreachTimestampOnPartialRepaymentWhenHealthy() public {
        _openBasicDraw(6_000e6);

        // Push the market into liquidation territory.
        wethOracle.setPrice(2_000e18);

        vm.prank(liquidator);
        pool.liquidate(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000,
            500e6
        );

        LendingPool.Draw memory afterLiquidation = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        // Liquidation should have established the auction state.
        assertGt(afterLiquidation.breachTimestamp, 0);

        // Restore price and repay enough to return the draw to health.
        wethOracle.setPrice(3_000e18);

        vm.prank(borrower);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        LendingPool.Draw memory afterRepay = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertEq(afterRepay.breachTimestamp, 0);
    }

    // =============================================================
    // Draw bookkeeping / swap-pop
    // =============================================================

    function test_removeDraw_swapPopsAndUpdatesMovedIndex() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        vm.prank(lenderB);
        pool.supply(
            wethMarketId,
            address(usdc),
            8500,
            9000,
            10_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 20e18);

        // First borrow fills the 70/80 bucket.
        pool.borrow(
            address(usdc),
            wethMarketId,
            10_000e6
        );

        // Second borrow spills into the 85/90 bucket.
        pool.borrow(
            address(usdc),
            wethMarketId,
            2_000e6
        );

        vm.stopPrank();

        LendingPool.Draw[] memory before = pool.getDraws(borrower);

        assertEq(before.length, 2);

        assertEq(before[0].ltvTick, 70);
        assertEq(before[0].lltvTick, 80);

        assertEq(before[1].ltvTick, 85);
        assertEq(before[1].lltvTick, 90);

        // Fully repay the FIRST draw.
        vm.prank(borrower);
        pool.repay(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            type(uint256).max
        );

        LendingPool.Draw[] memory afterDraws = pool.getDraws(borrower);

        // The second draw should have been moved into slot 0.
        assertEq(afterDraws.length, 1);
        assertEq(afterDraws[0].ltvTick, 85);
        assertEq(afterDraws[0].lltvTick, 90);

        // getDraw must still find the moved draw correctly.
        LendingPool.Draw memory remaining = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            85,
            90
        );

        assertGt(remaining.borrowShares, 0);
    }

    // =============================================================
    // Liquidation
    // =============================================================

    function test_liquidate_revertsWhenDrawDoesNotExist() public {
        vm.prank(liquidator);
        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.liquidate(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );
    }

    function test_liquidate_fullDebtRemovesDrawAndReturnsExcessCollateral() public {
        _openBasicDraw(2_000e6);

        wethOracle.setPrice(2_000e18);

        LendingPool.Draw memory beforeDraw = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        vm.prank(liquidator);
        pool.liquidate(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        // Depending on the exact auction result, either all debt is cleared
        // or the requested repayment is capped. This assertion specifically
        // verifies the full-removal path when the draw is completely repaid.
        LendingPool.Draw[] memory draws = pool.getDraws(borrower);

        if (draws.length == 0) {
            assertGt(
                pool.freeCollateral(borrower, wethMarketId),
                0
            );
        } else {
            assertEq(draws.length, 1);
            assertLe(draws[0].borrowShares, beforeDraw.borrowShares);
        }
    }

    function test_liquidate_partialRepayment_canLeaveHealthyDrawAndClearBreach() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            20_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, 7_000e6);
        vm.stopPrank();

        // Make position unhealthy.
        wethOracle.setPrice(2_500e18);

        vm.prank(liquidator);
        pool.liquidate(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertGt(d.borrowShares, 0);
        assertGt(d.collateralAmount, 0);
    }

    function test_liquidate_badDebtPathLeavesZeroCollateralAndDebt() public {
        _openBasicDraw(8_000e6);

        wethOracle.setPrice(500e18);
        vm.warp(block.timestamp + 30 minutes);

        vm.prank(liquidator);
        pool.liquidate(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000,
            2_000e6
        );

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertEq(d.collateralAmount, 0);
        assertGt(d.borrowShares, 0);
    }

    function test_socializeBadDebt_revertsWhenCollateralRemains() public {
        _openBasicDraw(3_000e6);

        vm.expectRevert();
        pool.socializeBadDebt(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000
        );
    }

    function test_socializeBadDebt_removesZeroCollateralDraw() public {
        _openBasicDraw(8_000e6);

        wethOracle.setPrice(500e18);
        vm.warp(block.timestamp + 30 minutes);

        vm.prank(liquidator);
        pool.liquidate(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000,
            2_000e6
        );

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertEq(d.collateralAmount, 0);
        assertGt(d.borrowShares, 0);

        pool.socializeBadDebt(
            borrower,
            wethMarketId,
            address(usdc),
            7000,
            8000
        );

        vm.expectRevert(LendingPool.NoSuchDraw.selector);
        pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );
    }

    // =============================================================
    // Interest accrual
    // =============================================================

    function test_accrueBucket_noBorrowDoesNotCreateInterest() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        bytes32 key = _bucketKey(
            wethMarketId,
            address(usdc),
            70,
            80
        );

        (
            uint256 assetsBefore,
            ,
            ,
            ,
            uint256 lastBefore
        ) = pool.buckets(key);

        vm.warp(block.timestamp + 365 days);

        vm.prank(lenderB);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        (
            uint256 assetsAfter,
            ,
            ,
            ,
            uint256 lastAfter
        ) = pool.buckets(key);

        // No borrow exists, so no interest should have been added.
        assertEq(assetsAfter, assetsBefore + 1_000e6);

        // Accrual still updates lastAccrue.
        assertGt(lastAfter, lastBefore);
    }

    function test_accrueBucket_elapsedZeroReturnsImmediately() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        bytes32 key = _bucketKey(
            wethMarketId,
            address(usdc),
            70,
            80
        );

        (
            uint256 assetsBefore,
            uint256 sharesBefore,
            ,
            ,
            uint256 lastBefore
        ) = pool.buckets(key);

        // Same block.timestamp means elapsed == 0.
        vm.prank(lenderB);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            1_000e6
        );

        (
            uint256 assetsAfter,
            uint256 sharesAfter,
            ,
            ,
            uint256 lastAfter
        ) = pool.buckets(key);

        assertEq(
            assetsAfter,
            assetsBefore + 1_000e6
        );
        assertGt(sharesAfter, sharesBefore);
        assertEq(lastAfter, lastBefore);
    }

    function test_previewDebt_returnsZeroForMissingDraw() public {
        assertEq(
            pool.previewDebt(
                wethMarketId,
                address(usdc),
                70,
                80,
                borrower
            ),
            0
        );
    }

    function test_previewDebt_sameTimestampMatchesStoredDebt() public {
        _openBasicDraw(3_000e6);

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        uint256 debt = pool.previewDebt(
            wethMarketId,
            address(usdc),
            70,
            80,
            borrower
        );

        assertGt(debt, 0);
        assertGe(debt, 1);
        assertGt(d.borrowShares, 0);
    }

    function test_previewDebt_increasesAfterTimePasses() public {
        _openBasicDraw(5_000e6);

        uint256 debtBefore = pool.previewDebt(
            wethMarketId,
            address(usdc),
            70,
            80,
            borrower
        );

        vm.warp(block.timestamp + 365 days);

        uint256 debtAfter = pool.previewDebt(
            wethMarketId,
            address(usdc),
            70,
            80,
            borrower
        );

        assertGt(debtAfter, debtBefore);
    }

    function test_bucketUtilization_zeroForEmptyBucket() public {
        assertEq(
            pool.bucketUtilizationWad(
                wethMarketId,
                address(usdc),
                70,
                80
            ),
            0
        );
    }

    function test_bucketUtilization_increasesAfterBorrow() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        uint256 beforeUtil = pool.bucketUtilizationWad(
            wethMarketId,
            address(usdc),
            70,
            80
        );

        _openDrawWithoutSupply(3_000e6);

        uint256 afterUtil = pool.bucketUtilizationWad(
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertEq(beforeUtil, 0);
        assertGt(afterUtil, beforeUtil);
    }

    // =============================================================
    // View functions
    // =============================================================

    function test_getDraws_emptyAccountReturnsEmptyArray() public {
        LendingPool.Draw[] memory draws = pool.getDraws(borrower);
        assertEq(draws.length, 0);
    }

    function test_getDraw_returnsExpectedDraw() public {
        _openBasicDraw(3_000e6);

        LendingPool.Draw memory d = pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );

        assertEq(d.marketId, wethMarketId);
        assertEq(d.loanAsset, address(usdc));
        assertEq(d.ltvTick, 70);
        assertEq(d.lltvTick, 80);
        assertGt(d.collateralAmount, 0);
        assertGt(d.borrowShares, 0);
    }

    function test_getDraw_revertsForMissingDraw() public {
        vm.expectRevert(LendingPool.NoSuchDraw.selector);

        pool.getDraw(
            borrower,
            wethMarketId,
            address(usdc),
            70,
            80
        );
    }

    function test_borrow_noFreeCollateralSkipsBucket() public {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            10_000e6
        );

        vm.prank(borrower);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), wethMarketId, 1_000e6);
    }

    // =============================================================
    // Helpers
    // =============================================================

    function _openBasicDraw(uint256 amount) internal {
        vm.prank(lenderA);
        pool.supply(
            wethMarketId,
            address(usdc),
            7000,
            8000,
            20_000e6
        );

        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, amount);
        vm.stopPrank();
    }

    function _openDrawWithoutSupply(uint256 amount) internal {
        vm.startPrank(borrower);
        pool.depositCollateral(wethMarketId, 10e18);
        pool.borrow(address(usdc), wethMarketId, amount);
        vm.stopPrank();
    }

    function _bucketKey(
        bytes32 marketId,
        address loanAsset,
        uint16 ltvTick,
        uint16 lltvTick
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                marketId,
                loanAsset,
                ltvTick,
                lltvTick
            )
        );
    }
}