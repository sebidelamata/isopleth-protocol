// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TestBase} from "../utils/TestBase.sol";
import {Handler} from "./Handler.sol";

import {LendingPool} from "../../src/core/LendingPool.sol";
import {BucketMath} from "../../src/libraries/BucketMath.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {LiquidationAuction} from "../../src/libraries/LiquidationAuction.sol";
import {ProtocolConfig} from "../../src/governance/ProtocolConfig.sol";

interface VmInvariant {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
}

/// @notice Additional randomized liquidation actions.
/// @dev The existing Handler remains responsible for deposits, borrowing,
///      repayments, withdrawals, oracle movements, and time advancement.
contract LiquidationActions {
    LendingPool public immutable pool;
    Handler public immutable baseHandler;

    uint256 public ghost_totalCollateralSeized;
    uint256 public ghost_totalBadDebtSocialized;

    uint256 public socializationCalls;
    uint256 public socializationEligibleDrawsFound;
    uint256 public socializationSuccessful;
    uint256 public socializationReverted;

    constructor(LendingPool _pool, Handler _baseHandler) {
        pool = _pool;
        baseHandler = _baseHandler;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return baseHandler.actors(seed % baseHandler.actorsLength());
    }

    function _ticks(uint256 seed)
        internal
        pure
        returns (uint16 ltv, uint16 lltv)
    {
        if (seed % 3 == 0) return (70, 80);
        if (seed % 3 == 1) return (80, 90);
        return (90, 98);
    }

    /// @notice Crash the collateral price and attempt liquidation.
    function crashAndLiquidate(
        uint256 borrowerSeed,
        uint256 liquidatorSeed,
        uint256 tickSeed,
        uint256 priceSeed,
        uint256 repaySeed
    ) external {
        address borrower = _actor(borrowerSeed);
        address liquidator = _actor(liquidatorSeed);

        (uint16 ltv, uint16 lltv) = _ticks(tickSeed);

        // Force a broad range of collateral prices, including deep crashes.
        uint256 price = bound(priceSeed, 500e18, 6000e18);

        baseHandler.wethOracle().setPrice(price);

        // Advance auction time so the sequence explores both early and
        // late auction states.
        vmWarp(1 hours);

        uint256 repayAmount = bound(repaySeed, 1e6, 1_000_000e6);

        vmPrank(liquidator);

        try pool.liquidate(
            borrower,
            baseHandler.wethMarketId(),
            address(baseHandler.usdc()),
            ltv * 100,
            lltv * 100,
            repayAmount
        ) returns (uint256, uint256 seized) {
            ghost_totalCollateralSeized += seized;
        } catch {}
    }

    /// @notice Attempt liquidation at a randomly selected collateral price.
    function liquidateAtCurrentPrice(
        uint256 borrowerSeed,
        uint256 liquidatorSeed,
        uint256 tickSeed,
        uint256 repaySeed
    ) external {
        address borrower = _actor(borrowerSeed);
        address liquidator = _actor(liquidatorSeed);

        (uint16 ltv, uint16 lltv) = _ticks(tickSeed);

        uint256 repayAmount = bound(repaySeed, 1e6, 1_000_000e6);

        vmPrank(liquidator);

        try pool.liquidate(
            borrower,
            baseHandler.wethMarketId(),
            address(baseHandler.usdc()),
            ltv * 100,
            lltv * 100,
            repayAmount
        ) returns (uint256, uint256 seized) {
            ghost_totalCollateralSeized += seized;
        } catch {}
    }

    /// @notice Find an existing zero-collateral draw with debt and attempt
    ///         bad-debt socialization.
    function socializeBadDebt(
        uint256 borrowerSeed,
        uint256 tickSeed
    ) external {
        socializationCalls++;

        uint256 actorCount = baseHandler.actorsLength();
        uint256 startActor = borrowerSeed % actorCount;

        address selectedBorrower;
        uint16 selectedLtv;
        uint16 selectedLltv;

        uint256 eligibleCount;
        uint256 selection = tickSeed;

        // Search all actors in a seed-dependent cyclic order.
        for (uint256 offset; offset < actorCount; offset++) {
            address borrower =
                baseHandler.actors((startActor + offset) % actorCount);

            LendingPool.Draw[] memory draws = pool.getDraws(borrower);

            for (uint256 d; d < draws.length; d++) {
                LendingPool.Draw memory draw = draws[d];

                if (
                    draw.marketId == baseHandler.wethMarketId()
                        && draw.loanAsset == address(baseHandler.usdc())
                        && draw.collateralAmount == 0
                        && draw.borrowShares > 0
                ) {
                    // Deterministically select one eligible draw using
                    // reservoir sampling.
                    eligibleCount++;

                    if (selection % eligibleCount == 0) {
                        selectedBorrower = borrower;
                        selectedLtv = draw.ltvTick;
                        selectedLltv = draw.lltvTick;
                    }
                }
            }
        }

        // No eligible draw exists: this is a skipped action, not a revert.
        if (eligibleCount == 0) {
            return;
        }

        socializationEligibleDrawsFound++;

        // Keep the production function's eligibility checks unchanged.
        try pool.socializeBadDebt(
            selectedBorrower,
            baseHandler.wethMarketId(),
            address(baseHandler.usdc()),
            selectedLtv * 100,
            selectedLltv * 100
        ) {
            ghost_totalBadDebtSocialized++;
            socializationSuccessful++;
        } catch {
            socializationReverted++;
        }
    }

    /// @dev Cheatcode wrappers are implemented through the Foundry VM.
    function vmWarp(uint256 elapsed) internal {
        VmInvariant(address(uint160(uint256(keccak256("hevm cheat code")))))
            .warp(block.timestamp + elapsed);
    }

    function vmPrank(address account) internal {
        VmInvariant(address(uint160(uint256(keccak256("hevm cheat code")))))
            .prank(account);
    }

    function bound(uint256 x, uint256 min, uint256 max)
        internal
        pure
        returns (uint256)
    {
        if (x < min) return min + x % (max - min + 1);
        if (x > max) return min + x % (max - min + 1);
        return x;
    }
}

contract LiquidationInvariantTest is StdInvariant, TestBase {
    Handler internal handler;
    LiquidationActions internal liquidationActions;

    uint16[3] internal ltvChoices = [7000, 8000, 9000];
    uint16[3] internal lltvChoices = [8000, 9000, 9800];

    function setUp() public override {
        super.setUp();

        handler = new Handler(
            pool,
            usdc,
            weth,
            wethMarketId,
            wethOracle
        );

        liquidationActions = new LiquidationActions(
            pool,
            handler
        );

        targetContract(address(handler));
        targetContract(address(liquidationActions));
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _bucketKey(uint256 i) internal view returns (bytes32) {
        return BucketMath.bucketKey(
            wethMarketId,
            address(usdc),
            ltvChoices[i] / 100,
            lltvChoices[i] / 100
        );
    }

    function _sumDrawShares(uint256 bucketIndex)
        internal
        view
        returns (uint256 total)
    {
        for (uint256 a; a < handler.actorsLength(); a++) {
            LendingPool.Draw[] memory draws =
                pool.getDraws(handler.actors(a));

            for (uint256 d; d < draws.length; d++) {
                LendingPool.Draw memory draw = draws[d];

                if (
                    draw.marketId == wethMarketId
                    && draw.loanAsset == address(usdc)
                    && draw.ltvTick == ltvChoices[bucketIndex] / 100
                    && draw.lltvTick == lltvChoices[bucketIndex] / 100
                ) {
                    total += draw.borrowShares;
                }
            }
        }
    }

    function _sumDrawDebt(uint256 bucketIndex)
        internal
        view
        returns (uint256 total, uint256 drawCount)
    {
        bytes32 key = _bucketKey(bucketIndex);

        (
            ,
            ,
            uint256 borrowAssets,
            uint256 borrowShares,

        ) = pool.buckets(key);

        for (uint256 a; a < handler.actorsLength(); a++) {
            LendingPool.Draw[] memory draws =
                pool.getDraws(handler.actors(a));

            for (uint256 d; d < draws.length; d++) {
                LendingPool.Draw memory draw = draws[d];

                if (
                    draw.marketId == wethMarketId
                    && draw.loanAsset == address(usdc)
                    && draw.ltvTick == ltvChoices[bucketIndex] / 100
                    && draw.lltvTick == lltvChoices[bucketIndex] / 100
                    && draw.borrowShares > 0
                ) {
                    total += MathLib.toBorrowAssetsUp(
                        draw.borrowShares,
                        borrowAssets,
                        borrowShares
                    );

                    drawCount++;
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // 1. Bucket accounting after liquidation
    // ---------------------------------------------------------------

    function invariant_liquidationNeverCreatesBorrowShares()
        public
        view
    {
        for (uint256 i; i < 3; i++) {
            assertEq(
                _sumDrawShares(i),
                _bucketBorrowShares(i),
                "draw shares != bucket borrow shares"
            );
        }
    }

    function _bucketBorrowShares(uint256 i)
        internal
        view
        returns (uint256 shares)
    {
        (,,, shares,) = pool.buckets(_bucketKey(i));
    }

    function invariant_drawDebtReconcilesAfterLiquidation()
        public
        view
    {
        for (uint256 i; i < 3; i++) {
            (
                uint256 totalBorrowAssets,
                uint256 drawCount
            ) = _sumDrawDebt(i);

            (,, uint256 bucketAssets, uint256 bucketShares,) =
                pool.buckets(_bucketKey(i));

            if (bucketShares == 0) {
                assertEq(bucketAssets, 0);
                assertEq(drawCount, 0);
            } else {
                assertGt(drawCount, 0);

                assertGe(
                    totalBorrowAssets + drawCount,
                    bucketAssets,
                    "draw debt sum below bucket assets"
                );

                assertLe(
                    totalBorrowAssets,
                    bucketAssets + drawCount,
                    "draw debt sum above bucket assets"
                );
            }
        }
    }

    function invariant_bucketNeverLendsMoreThanSupplied()
        public
        view
    {
        for (uint256 i; i < 3; i++) {
            (
                uint256 supplyAssets,
                ,
                uint256 borrowAssets,
                ,

            ) = pool.buckets(_bucketKey(i));

            assertGe(
                supplyAssets,
                borrowAssets,
                "bucket insolvent after liquidation"
            );
        }
    }

    // ---------------------------------------------------------------
    // 2. Collateral conservation
    // ---------------------------------------------------------------

    function invariant_freeCollateralNeverExceedsNetDeposits()
        public
        view
    {
        uint256 totalFree;

        for (uint256 a; a < handler.actorsLength(); a++) {
            totalFree += pool.freeCollateral(
                handler.actors(a),
                wethMarketId
            );
        }

        uint256 netDeposited =
            handler.ghost_totalCollateralDeposited()
            - handler.ghost_totalCollateralWithdrawn();

        assertLe(
            totalFree,
            netDeposited,
            "free collateral exceeds deposits"
        );
    }

    // ---------------------------------------------------------------
    // 3. Draw lifecycle
    // ---------------------------------------------------------------

    function invariant_noOpenDrawHasZeroDebt()
        public
        view
    {
        for (uint256 a; a < handler.actorsLength(); a++) {
            LendingPool.Draw[] memory draws =
                pool.getDraws(handler.actors(a));

            for (uint256 d; d < draws.length; d++) {
                assertGt(
                    draws[d].borrowShares,
                    0,
                    "zero-debt draw persists"
                );
            }
        }
    }

    function invariant_zeroCollateralDrawHasDebt()
        public
        view
    {
        for (uint256 a; a < handler.actorsLength(); a++) {
            LendingPool.Draw[] memory draws =
                pool.getDraws(handler.actors(a));

            for (uint256 d; d < draws.length; d++) {
                if (
                    draws[d].marketId == wethMarketId
                    && draws[d].collateralAmount == 0
                ) {
                    assertGt(
                        draws[d].borrowShares,
                        0,
                        "zero collateral draw has no debt"
                    );
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // 4. Auction bonus bounds
    // ---------------------------------------------------------------

    function invariant_auctionBonusAlwaysWithinBounds()
        public
        view
    {
        ProtocolConfig.LiquidationAuctionParams memory params =
            ProtocolConfig.LiquidationAuctionParams({
                startBonusWad: 0.005e18,
                maxBonusWad: 0.12e18,
                rampDuration: 30 minutes
            });

        uint256 previousBonus;

        for (uint256 i; i <= 30; i++) {
            uint256 elapsed = i * 1 minutes;

            uint256 bonus =
                LiquidationAuction.currentBonusWad(
                    params,
                    elapsed
                );

            assertGe(
                bonus,
                params.startBonusWad,
                "bonus below start"
            );

            assertLe(
                bonus,
                params.maxBonusWad,
                "bonus exceeds maximum"
            );

            assertGe(
                bonus,
                previousBonus,
                "auction bonus is not monotonic"
            );

            previousBonus = bonus;
        }
    }

    function invariant_collateralConservedIncludingLiquidations() public view {
        uint256 freeCollateralTotal;
        uint256 drawCollateralTotal;

        for (uint256 a; a < handler.actorsLength(); a++) {
            address actor = handler.actors(a);
            freeCollateralTotal += pool.freeCollateral(actor, wethMarketId);

            LendingPool.Draw[] memory draws = pool.getDraws(actor);
            for (uint256 d; d < draws.length; d++) {
                if (draws[d].marketId == wethMarketId) {
                    drawCollateralTotal += draws[d].collateralAmount;
                }
            }
        }

        uint256 netDeposited = handler.ghost_totalCollateralDeposited() - handler.ghost_totalCollateralWithdrawn();

        uint256 accountedCollateral = freeCollateralTotal + drawCollateralTotal
            + handler.ghost_totalCollateralSeized() // <-- the missing term
            + liquidationActions.ghost_totalCollateralSeized();

        assertEq(accountedCollateral, netDeposited, "collateral conservation failure");
    }

    function invariant_badDebtSocializationCountersReconcile()
        public
        view
    {
        assertEq(
            liquidationActions.ghost_totalBadDebtSocialized(),
            liquidationActions.socializationSuccessful(),
            "socialization success counters diverged"
        );

        assertLe(
            liquidationActions.socializationSuccessful()
                + liquidationActions.socializationReverted(),
            liquidationActions.socializationEligibleDrawsFound(),
            "socialization outcomes exceed eligible attempts"
        );

        assertLe(
            liquidationActions.socializationEligibleDrawsFound(),
            liquidationActions.socializationCalls(),
            "eligible socializations exceed calls"
        );
    }
}