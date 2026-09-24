// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "../utils/TestBase.sol";

/// @notice Characterizes borrow() gas cost in its worst realistic case: liquidity spread thin
///         across many distinct lender buckets (different LTV/LLTV choices), forcing a single
///         borrow to walk and draw from all of them before it's filled. The happy-path tests
///         elsewhere only incidentally exercise a one- or two-bucket walk; this test exists
///         specifically to put a real, reproducible number on "what does it cost once there
///         are lots of lenders with different risk preferences on the same collateral."
contract GasStressTest is TestBase {
    function test_gas_borrowSpanningManyThinBuckets() public {
        address borrower = makeAddr("borrower");
        _dealAndApprove(weth, borrower, 1_000e18);

        uint256 numBuckets = 20;
        for (uint256 i = 0; i < numBuckets; i++) {
            address lender = makeAddr(string.concat("stressLender", vm.toString(i)));
            uint16 ltv = uint16(4000 + i * 100); // 40%, 41%, 42%, ... one distinct tick each
            uint16 lltv = ltv + 500;
            _dealAndApprove(usdc, lender, 1_000e6);
            vm.prank(lender);
            pool.supply(wethMarketId, address(usdc), ltv, lltv, 500e6); // thin: 500 USDC each
        }

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 50e18); // ample collateral headroom, not the constraint here
        uint256 gasBefore = gasleft();
        pool.borrow(address(usdc), wethMarketId, numBuckets * 500e6); // forces walking every bucket
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("gas used: borrow spanning 20 distinct buckets", gasUsed);
        // Deliberately no hard ceiling assertion here -- this test's purpose is to surface the
        // real number via `forge test --gas-report` / the emitted log for engineering and
        // pitch/diligence purposes, not to gate CI on a specific constant that would need
        // constant updating as the contract evolves.
    }

    function test_gas_borrowSingleBucket_forComparison() public {
        address lender = makeAddr("singleLender");
        address borrower = makeAddr("singleBorrower");
        _dealAndApprove(usdc, lender, 100_000e6);
        _dealAndApprove(weth, borrower, 100e18);

        vm.prank(lender);
        pool.supply(wethMarketId, address(usdc), 7000, 8000, 50_000e6);

        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(wethMarketId, 10e18);
        uint256 gasBefore = gasleft();
        pool.borrow(address(usdc), wethMarketId, 5_000e6);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("gas used: borrow filled from a single bucket", gasUsed);
    }
}
