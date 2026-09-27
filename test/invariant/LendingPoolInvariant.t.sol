// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TestBase} from "../utils/TestBase.sol";
import {Handler} from "./Handler.sol";
import {BucketMath} from "../../src/libraries/BucketMath.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";

contract LendingPoolInvariantTest is StdInvariant, TestBase {
    Handler handler;

    uint16[3] ltvChoices = [7000, 8000, 9000];
    uint16[3] lltvChoices = [8000, 9000, 9800];

    function setUp() public override {
        super.setUp();
        handler = new Handler(pool, usdc, weth, wethMarketId, wethOracle);
        targetContract(address(handler));
    }

    function invariant_bucketNeverLendsOutMoreThanSupplied() public view {
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                bytes32 bKey =
                    BucketMath.bucketKey(wethMarketId, address(usdc), ltvChoices[i] / 100, lltvChoices[j] / 100);
                (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,,) = pool.buckets(bKey);
                assertGe(totalSupplyAssets, totalBorrowAssets, "bucket lent out more than was supplied");
            }
        }
    }

    function invariant_everyOpenDrawHasNonZeroDebt() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            LendingPool.Draw[] memory draws = pool.getDraws(actor);
            for (uint256 d = 0; d < draws.length; d++) {
                assertGt(draws[d].borrowShares, 0, "draw persisted with zero debt");
            }
        }
    }

    function invariant_freeCollateralNeverExceedsNetGhostDeposits() public view {
        uint256 n = handler.actorsLength();
        uint256 totalFree;
        for (uint256 i = 0; i < n; i++) {
            totalFree += pool.freeCollateral(handler.actors(i), wethMarketId);
        }
        uint256 netDeposited = handler.ghost_totalCollateralDeposited() - handler.ghost_totalCollateralWithdrawn();
        assertLe(totalFree, netDeposited, "free collateral exceeds net deposits");
    }

    function invariant_bucketShareAssetEmptinessAgree() public view {
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                bytes32 bKey =
                    BucketMath.bucketKey(wethMarketId, address(usdc), ltvChoices[i] / 100, lltvChoices[j] / 100);
                (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,) = pool.buckets(bKey);
                if (totalBorrowShares == 0) {
                    assertEq(totalBorrowAssets, 0, "borrow shares zero but assets nonzero");
                }
            }
        }
    }

    function invariant_freePlusDrawCollateralDoesNotExceedNetDeposits() public view {
        uint256 n = handler.actorsLength();

        uint256 totalFree;
        uint256 totalDrawCollateral;

        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);

            totalFree += pool.freeCollateral(actor, wethMarketId);

            LendingPool.Draw[] memory draws = pool.getDraws(actor);

            for (uint256 d = 0; d < draws.length; d++) {
                if (draws[d].marketId == wethMarketId) {
                    totalDrawCollateral += draws[d].collateralAmount;
                }
            }
        }

        uint256 netDeposited = handler.ghost_totalCollateralDeposited() - handler.ghost_totalCollateralWithdrawn();

        assertLe(totalFree + totalDrawCollateral, netDeposited, "free plus allocated collateral exceeds net deposits");
    }

    /// @dev The specific property the mint/redeem formula mismatch bug violated: summing each
    ///      individual draw's debt (recomputed with the SAME toBorrowAssetsUp formula used for
    ///      minting) across every draw in a bucket must reconcile with that bucket's aggregate
    ///      totalBorrowAssets, give or take at most one wei of rounding per draw. If mint and
    ///      redeem ever use mismatched formulas again, this is what would catch it -- the
    ///      aggregate solvency invariants above do NOT catch this class of bug, since it
    ///      misallocates whose shares the debt is spread across without breaking aggregate
    ///      solvency.
    function invariant_sumOfDrawDebtsReconcilesWithBucketBorrowAssets()
        public
        view
    {
        uint256 n = handler.actorsLength();

        for (uint256 i = 0; i < 3; i++) {
            uint16 ltvTick = ltvChoices[i] / 100;
            uint16 lltvTick = lltvChoices[i] / 100;

            bytes32 bKey = BucketMath.bucketKey(
                wethMarketId,
                address(usdc),
                ltvTick,
                lltvTick
            );

            (
                ,
                ,
                uint256 totalBorrowAssets,
                uint256 totalBorrowShares,

            ) = pool.buckets(bKey);

            uint256 sumDrawDebts;
            uint256 drawCount;

            for (uint256 a = 0; a < n; a++) {
                address actor = handler.actors(a);
                LendingPool.Draw[] memory draws = pool.getDraws(actor);

                for (uint256 d = 0; d < draws.length; d++) {
                    if (
                        draws[d].marketId == wethMarketId
                        && draws[d].loanAsset == address(usdc)
                        && draws[d].ltvTick == ltvTick
                        && draws[d].lltvTick == lltvTick
                    ) {
                        sumDrawDebts += MathLib.toBorrowAssetsUp(
                            draws[d].borrowShares,
                            totalBorrowAssets,
                            totalBorrowShares
                        );

                        drawCount++;
                    }
                }
            }

            if (totalBorrowShares == 0) {
                assertEq(
                    totalBorrowAssets,
                    0,
                    "zero borrow shares but nonzero borrow assets"
                );

                assertEq(
                    drawCount,
                    0,
                    "zero borrow shares but draws remain"
                );
            } else {
                assertGt(drawCount, 0, "borrow shares exist without draws");

                assertGe(
                    sumDrawDebts + drawCount,
                    totalBorrowAssets,
                    "sum of per-draw debts is short of bucket borrow assets beyond rounding tolerance"
                );

                assertLe(
                    sumDrawDebts,
                    totalBorrowAssets + drawCount,
                    "sum of per-draw debts exceeds bucket borrow assets beyond rounding tolerance"
                );
            }
        }
    }

    function invariant_sumOfDrawSharesEqualsBucketBorrowShares()
        public
        view
    {
        for (uint256 i = 0; i < 3; i++) {
            uint16 ltvTick = ltvChoices[i] / 100;
            uint16 lltvTick = lltvChoices[i] / 100;

            bytes32 bKey = BucketMath.bucketKey(
                wethMarketId,
                address(usdc),
                ltvTick,
                lltvTick
            );

            (,,, uint256 totalBorrowShares,) = pool.buckets(bKey);

            uint256 sumDrawShares;
            uint256 n = handler.actorsLength();

            for (uint256 a = 0; a < n; a++) {
                LendingPool.Draw[] memory draws =
                    pool.getDraws(handler.actors(a));

                for (uint256 d = 0; d < draws.length; d++) {
                    if (
                        draws[d].marketId == wethMarketId
                            && draws[d].loanAsset == address(usdc)
                            && draws[d].ltvTick == ltvTick
                            && draws[d].lltvTick == lltvTick
                    ) {
                        sumDrawShares += draws[d].borrowShares;
                    }
                }
            }

            assertEq(
                sumDrawShares,
                totalBorrowShares,
                "draw shares do not reconcile with bucket shares"
            );
        }
    }
}