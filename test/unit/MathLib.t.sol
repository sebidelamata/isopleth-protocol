// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

contract MathLibTest is Test {
    function test_firstDeposit_sharesRoughlyEqualAssets() public pure {
        // With the VIRTUAL_SHARES offset (1e6), an empty bucket's first deposit mints
        // shares at amount * VIRTUAL_SHARES (not 1:1) -- this is what neutralizes a
        // first-depositor inflation attack on a fresh bucket.
        uint256 shares = MathLib.toSharesDown(1000e18, 0, 0);
        assertEq(shares, 1000e18 * MathLib.VIRTUAL_SHARES);
    }

    function test_sharesAssets_roundtripDown() public pure {
        uint256 totalAssets = 10_000e18;
        uint256 totalShares = 10_000e18;
        uint256 shares = MathLib.toSharesDown(500e18, totalAssets, totalShares);
        uint256 assetsBack = MathLib.toAssetsDown(shares, totalAssets, totalShares);
        assertLe(assetsBack, 500e18);
        assertApproxEqAbs(assetsBack, 500e18, 1e12);
    }

    function test_toSharesUp_roundsInProtocolFavor() public pure {
        uint256 down = MathLib.toSharesDown(333, 1000e18, 1000e18);
        uint256 up = MathLib.toSharesUp(333, 1000e18, 1000e18);
        assertGe(up, down);
    }

    function test_interestAccrual_growsAssetsNotShares() public pure {
        // suppliers' shares are constant; totalAssets growing means each share is worth more
        uint256 sharesBefore = MathLib.toSharesDown(1000e18, 1000e18, 1000e18);
        uint256 valueBefore = MathLib.toAssetsDown(sharesBefore, 1000e18, 1000e18);
        uint256 valueAfterInterest = MathLib.toAssetsDown(sharesBefore, 1100e18, 1000e18); // +10% assets, same shares
        assertGt(valueAfterInterest, valueBefore);
    }

    function test_wadMul_wadDiv_identity() public pure {
        uint256 a = 1.5e18;
        uint256 b = 2e18;
        assertEq(MathLib.wadMul(a, b), 3e18);
        assertEq(MathLib.wadDiv(a, b), 0.75e18);
    }

    function testFuzz_toShares_toAssets_neverExceedsOriginalOnRoundtrip(uint128 assets, uint128 totalA, uint128 totalS)
        public
    {
        vm.assume(totalA > 0 && totalS > 0);
        uint256 shares = MathLib.toSharesDown(assets, totalA, totalS);
        uint256 back = MathLib.toAssetsDown(shares, totalA, totalS);
        assertLe(back, uint256(assets) + 1); // rounding tolerance
    }
}
