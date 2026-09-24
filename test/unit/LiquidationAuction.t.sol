// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidationAuction} from "../../src/libraries/LiquidationAuction.sol";
import {ProtocolConfig} from "../../src/governance/ProtocolConfig.sol";

contract LiquidationAuctionTest is Test {
    ProtocolConfig.LiquidationAuctionParams params;

    function setUp() public {
        params = ProtocolConfig.LiquidationAuctionParams({
            startBonusWad: 0.005e18,
            maxBonusWad: 0.12e18,
            rampDuration: 30 minutes
        });
    }

    function test_bonusAtZeroTime_equalsStart() public view {
        assertEq(LiquidationAuction.currentBonusWad(params, 0), params.startBonusWad);
    }

    function test_bonusAtRampEnd_equalsMax() public view {
        assertEq(LiquidationAuction.currentBonusWad(params, params.rampDuration), params.maxBonusWad);
    }

    function test_bonusPastRampEnd_staysCappedAtMax() public view {
        assertEq(LiquidationAuction.currentBonusWad(params, params.rampDuration * 10), params.maxBonusWad);
    }

    function test_bonusAtHalfRamp_isApproximatelyMidpoint() public view {
        uint256 mid = LiquidationAuction.currentBonusWad(params, params.rampDuration / 2);
        uint256 expectedMid = (params.startBonusWad + params.maxBonusWad) / 2;
        assertApproxEqAbs(mid, expectedMid, 1e12);
    }

    function test_bonusIsMonotonicNonDecreasing() public view {
        uint256 b0 = LiquidationAuction.currentBonusWad(params, 0);
        uint256 b1 = LiquidationAuction.currentBonusWad(params, 5 minutes);
        uint256 b2 = LiquidationAuction.currentBonusWad(params, 15 minutes);
        uint256 b3 = LiquidationAuction.currentBonusWad(params, 30 minutes);
        assertLe(b0, b1);
        assertLe(b1, b2);
        assertLe(b2, b3);
    }

    function testFuzz_bonusNeverExceedsMax(uint256 t) public view {
        uint256 bonus = LiquidationAuction.currentBonusWad(params, t);
        assertLe(bonus, params.maxBonusWad);
    }

    function testFuzz_bonusNeverBelowStart(uint256 t) public view {
        t = bound(t, 0, params.rampDuration * 100);
        uint256 bonus = LiquidationAuction.currentBonusWad(params, t);
        assertGe(bonus, params.startBonusWad);
    }
}
