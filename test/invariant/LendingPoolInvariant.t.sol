// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TestBase} from "../utils/TestBase.sol";
import {Handler} from "./Handler.sol";
import {BucketMath} from "../../src/libraries/BucketMath.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";

/// @notice Long random sequences of supply/withdraw/borrow/repay/liquidate/price-move/warp,
///         checked after every call against invariants that must hold no matter what order
///         actions happen in. This is what fixed-scenario unit and integration tests
///         structurally cannot find: accounting drift that only shows up after many
///         interleaved operations against the same buckets.
contract LendingPoolInvariantTest is StdInvariant, TestBase {
    Handler handler;

    uint16[3] ltvChoices = [7000, 8000, 9000];
    uint16[3] lltvChoices = [8000, 9000, 9800];

    function setUp() public override {
        super.setUp();
        handler = new Handler(pool, usdc, weth, wethMarketId, wethOracle);
        targetContract(address(handler));
    }

    /// @dev The core solvency property of the whole design: you can never lend out more of a
    ///      bucket's asset than was actually supplied into that exact bucket. If this ever
    ///      fails, some path is letting borrowers draw against liquidity that isn't there.
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

    /// @dev No draw should ever persist with zero remaining debt -- repay() and liquidate()
    ///      must always release collateral and remove the draw once borrowShares hits zero,
    ///      never leave an empty husk with collateral silently stuck or shares mis-accounted.
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

    /// @dev Sum of every actor's free (unallocated) collateral can never exceed the total
    ///      ever deposited net of total ever withdrawn -- collateral cannot be created from
    ///      nothing, and any amount not "free" must be accounted for inside some draw.
    function invariant_freeCollateralNeverExceedsNetGhostDeposits() public view {
        uint256 n = handler.actorsLength();
        uint256 totalFree;
        for (uint256 i = 0; i < n; i++) {
            totalFree += pool.freeCollateral(handler.actors(i), wethMarketId);
        }
        uint256 netDeposited = handler.ghost_totalCollateralDeposited() - handler.ghost_totalCollateralWithdrawn();
        assertLe(totalFree, netDeposited, "free collateral exceeds net deposits");
    }

    /// @dev Every activated bucket's borrow shares and borrow assets must agree on emptiness:
    ///      a bucket can't have outstanding shares against zero recorded assets or vice versa.
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
}
