// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MathLib} from "./MathLib.sol";
import {ProtocolConfig} from "../governance/ProtocolConfig.sol";

/// @title InterestRateModel
/// @notice Standard two-slope (kinked) rate model, applied independently to each bucket's own
///         utilization. Governance sets base/slope1/slope2/kink PER LOAN ASSET ONLY -- this is
///         intentionally the one governance-tuned curve in the system. In practice, because
///         capital is rationed across the LTV ladder (thin at high LTV, deep at low LTV) the
///         *bucket a borrower must reach into* does most of the work of pricing risk; the
///         kink mainly absorbs demand shocks within whichever bucket is currently marginal.
library InterestRateModel {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Instantaneous borrow APR (1e18-scaled) for a bucket at a given utilization.
    function getBorrowRateWad(ProtocolConfig.RateModelParams memory p, uint256 utilizationWad)
        internal
        pure
        returns (uint256)
    {
        if (!p.initialized) return 0;

        if (utilizationWad <= p.kindWad) {
            // base + slope1 * (u / kink)
            uint256 slope = MathLib.wadDiv(utilizationWad, p.kindWad);
            return p.baseRateWad + MathLib.wadMul(p.slope1Wad, slope);
        } else {
            // base + slope1 + slope2 * ((u - kink) / (1 - kink))
            uint256 excess = utilizationWad - p.kindWad;
            uint256 slope = MathLib.wadDiv(excess, WAD - p.kindWad);
            return p.baseRateWad + p.slope1Wad + MathLib.wadMul(p.slope2Wad, slope);
        }
    }

    /// @notice Converts an annual rate (1e18-scaled APR) and an elapsed-seconds duration into
    ///         a linear per-period growth factor (1e18-scaled, e.g. 1.0001e18 = +0.01%).
    ///         Linear (non-compounding) accrual is used deliberately for simplicity/gas; buckets
    ///         are expected to be touched frequently enough that the compounding error is
    ///         negligible, and it removes any risk of overflow from repeated compounding math.
    function growthFactorWad(uint256 annualRateWad, uint256 elapsedSeconds) internal pure returns (uint256) {
        return WAD + MathLib.wadMul(annualRateWad, MathLib.wadDiv(elapsedSeconds * WAD, SECONDS_PER_YEAR * WAD));
    }

    function utilizationWad(uint256 totalBorrowed, uint256 totalSupplied) internal pure returns (uint256) {
        if (totalSupplied == 0) return 0;
        if (totalBorrowed >= totalSupplied) return WAD;
        return MathLib.wadDiv(totalBorrowed, totalSupplied);
    }
}
