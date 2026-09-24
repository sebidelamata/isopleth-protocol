// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BucketMath} from "../../src/libraries/BucketMath.sol";

/// @dev vm.expectRevert() only catches reverts in a sub-call (lower call depth); internal
///      library functions are inlined into the caller, so we route calls through this tiny
///      external harness to get a real CALL frame for the revert assertions below.
contract BucketMathHarness {
    function toTick(uint16 bps) external pure returns (uint16) {
        return BucketMath.toTick(bps);
    }

    function validateAndTick(uint16 ltvBps, uint16 lltvBps) external pure returns (uint16, uint16) {
        return BucketMath.validateAndTick(ltvBps, lltvBps);
    }
}

contract BucketMathTest is Test {
    BucketMathHarness harness;

    function setUp() public {
        harness = new BucketMathHarness();
    }
    function test_toTick_and_toBps_roundtrip() public pure {
        uint16 tick = BucketMath.toTick(7500);
        assertEq(tick, 75);
        assertEq(BucketMath.toBps(tick), 7500);
    }

    function test_toTick_revertsOnNonMultipleOfSpacing() public {
        vm.expectRevert(BucketMath.InvalidTick.selector);
        harness.toTick(7550);
    }

    function test_validateAndTick_happyPath() public pure {
        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(7500, 8300);
        assertEq(ltvTick, 75);
        assertEq(lltvTick, 83);
    }

    function test_validateAndTick_revertsBelowMinLtv() public {
        vm.expectRevert(BucketMath.LtvOutOfRange.selector);
        harness.validateAndTick(3900, 8300);
    }

    function test_validateAndTick_revertsAboveMaxLtv() public {
        vm.expectRevert(BucketMath.LtvOutOfRange.selector);
        harness.validateAndTick(9600, 9700);
    }

    function test_validateAndTick_revertsAboveMaxLltv() public {
        vm.expectRevert(BucketMath.LltvOutOfRange.selector);
        harness.validateAndTick(9500, 10000);
    }

    function test_validateAndTick_revertsInsufficientSpread() public {
        // ltv == lltv, spread of 0 < MIN_LTV_LLTV_SPREAD_BPS
        vm.expectRevert(BucketMath.InsufficientSpread.selector);
        harness.validateAndTick(7500, 7500);
    }

    function test_validateAndTick_exactMinimumSpreadPasses() public pure {
        (uint16 ltvTick, uint16 lltvTick) =
            BucketMath.validateAndTick(7500, 7500 + BucketMath.MIN_LTV_LLTV_SPREAD_BPS);
        assertEq(ltvTick, 75);
        assertEq(lltvTick, 76);
    }

    function test_bucketKey_isDeterministicAndUnique() public pure {
        bytes32 marketId = keccak256("market");
        address loanAsset = address(0x1234);

        bytes32 k1 = BucketMath.bucketKey(marketId, loanAsset, 75, 83);
        bytes32 k2 = BucketMath.bucketKey(marketId, loanAsset, 75, 83);
        bytes32 k3 = BucketMath.bucketKey(marketId, loanAsset, 75, 84);

        assertEq(k1, k2);
        assertTrue(k1 != k3);
    }

    function testFuzz_validateAndTick_nonMultipleLtvAlwaysReverts(uint16 ltvBps, uint16 lltvBps) public {
        vm.assume(ltvBps % 100 != 0);
        vm.expectRevert();
        harness.validateAndTick(ltvBps, lltvBps);
    }

    function testFuzz_validateAndTick_validInputsNeverRevert(uint16 ltvOffset, uint16 spreadTicks) public pure {
        uint16 maxOffset = (BucketMath.MAX_LTV_BPS - BucketMath.MIN_LTV_BPS) / BucketMath.TICK_SPACING_BPS;
        ltvOffset = ltvOffset % (maxOffset + 1);
        uint16 ltvBps = BucketMath.MIN_LTV_BPS + ltvOffset * BucketMath.TICK_SPACING_BPS;

        uint16 maxLltvTicks =
            (BucketMath.MAX_LLTV_BPS - ltvBps - BucketMath.MIN_LTV_LLTV_SPREAD_BPS) / BucketMath.TICK_SPACING_BPS;
        spreadTicks = maxLltvTicks == 0 ? 0 : spreadTicks % (maxLltvTicks + 1);
        uint16 lltvBps = ltvBps + BucketMath.MIN_LTV_LLTV_SPREAD_BPS + spreadTicks * BucketMath.TICK_SPACING_BPS;

        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(ltvBps, lltvBps);
        assertEq(BucketMath.toBps(ltvTick), ltvBps);
        assertTrue(lltvTick >= ltvTick);
    }
}
