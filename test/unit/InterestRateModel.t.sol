// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {ProtocolConfig} from "../../src/governance/ProtocolConfig.sol";

contract InterestRateModelTest is Test {
    ProtocolConfig.RateModelParams params;

    function setUp() public {
        params = ProtocolConfig.RateModelParams({
            baseRateWad: 0.01e18,
            slope1Wad: 0.04e18,
            slope2Wad: 0.75e18,
            kindWad: 0.80e18,
            initialized: true
        });
    }

    function test_rateAtZeroUtilization_equalsBase() public view {
        uint256 rate = InterestRateModel.getBorrowRateWad(params, 0);
        assertEq(rate, params.baseRateWad);
    }

    function test_rateAtKink_equalsBasePlusSlope1() public view {
        uint256 rate = InterestRateModel.getBorrowRateWad(params, params.kindWad);
        assertApproxEqAbs(rate, params.baseRateWad + params.slope1Wad, 1);
    }

    function test_rateAtFullUtilization_equalsBasePlusSlope1PlusSlope2() public view {
        uint256 rate = InterestRateModel.getBorrowRateWad(params, 1e18);
        assertApproxEqAbs(rate, params.baseRateWad + params.slope1Wad + params.slope2Wad, 1);
    }

    function test_rateIsMonotonicIncreasing() public view {
        uint256 r0 = InterestRateModel.getBorrowRateWad(params, 0.1e18);
        uint256 r1 = InterestRateModel.getBorrowRateWad(params, 0.5e18);
        uint256 r2 = InterestRateModel.getBorrowRateWad(params, 0.85e18);
        uint256 r3 = InterestRateModel.getBorrowRateWad(params, 0.99e18);
        assertLt(r0, r1);
        assertLt(r1, r2);
        assertLt(r2, r3);
    }

    function test_slopeSteepensAfterKink() public view {
        // rate delta per 1% utilization should be much bigger post-kink than pre-kink
        uint256 preA = InterestRateModel.getBorrowRateWad(params, 0.70e18);
        uint256 preB = InterestRateModel.getBorrowRateWad(params, 0.71e18);
        uint256 postA = InterestRateModel.getBorrowRateWad(params, 0.90e18);
        uint256 postB = InterestRateModel.getBorrowRateWad(params, 0.91e18);

        uint256 preDelta = preB - preA;
        uint256 postDelta = postB - postA;
        assertGt(postDelta, preDelta);
    }

    function test_uninitializedModel_returnsZeroRate() public pure {
        ProtocolConfig.RateModelParams memory empty;
        uint256 rate = InterestRateModel.getBorrowRateWad(empty, 0.5e18);
        assertEq(rate, 0);
    }

    function test_growthFactor_oneYearAtRateEqualsOnePlusRate() public pure {
        uint256 gf = InterestRateModel.growthFactorWad(0.1e18, 365 days);
        assertApproxEqAbs(gf, 1.1e18, 1e9);
    }

    function test_growthFactor_zeroElapsedIsIdentity() public pure {
        uint256 gf = InterestRateModel.growthFactorWad(0.5e18, 0);
        assertEq(gf, 1e18);
    }

    function test_utilization_zeroSupplyReturnsZero() public pure {
        assertEq(InterestRateModel.utilizationWad(0, 0), 0);
        assertEq(InterestRateModel.utilizationWad(100, 0), 0);
    }

    function test_utilization_capsAtOneHundredPercent() public pure {
        assertEq(InterestRateModel.utilizationWad(200, 100), 1e18);
    }

    function test_utilization_halfUtilized() public pure {
        assertEq(InterestRateModel.utilizationWad(50, 100), 0.5e18);
    }

    function testFuzz_rateNeverExceedsBasePlusSlope1PlusSlope2(uint256 util) public view {
        util = bound(util, 0, 1e18);
        uint256 rate = InterestRateModel.getBorrowRateWad(params, util);
        assertLe(rate, params.baseRateWad + params.slope1Wad + params.slope2Wad + 1);
    }
}
