// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MathLib} from "./MathLib.sol";
import {ProtocolConfig} from "../governance/ProtocolConfig.sol";

/// @title LiquidationAuction
/// @notice A single, protocol-wide (never lender-configurable) Dutch-auction liquidation
///         bonus. The bonus starts near-zero the instant a draw crosses its bucket's LLTV and
///         ramps toward a cap over `rampDuration`. This is deliberately systemic: a lender who
///         accepted a 95% LLTV bucket has almost no price cushion, and a bonus fixed at that
///         cushion (~5%) would frequently be unprofitable for a keeper to act on once gas and
///         slippage are priced in -- which in practice means liquidations simply don't fire
///         and the "small haircut" becomes real bad debt instead. Ramping the bonus over time
///         means the position's own shrinking cushion, not a per-bucket parameter, determines
///         how much risk that lender bears; it does not change WHETHER a liquidator eventually
///         finds it worth acting.
library LiquidationAuction {
    uint256 internal constant WAD = 1e18;

    /// @param secondsSinceBreach Time since the draw first became liquidatable (LTV > LLTV).
    function currentBonusWad(ProtocolConfig.LiquidationAuctionParams memory p, uint256 secondsSinceBreach)
        internal
        pure
        returns (uint256)
    {
        if (secondsSinceBreach >= p.rampDuration) return p.maxBonusWad;
        uint256 progress = MathLib.wadDiv(secondsSinceBreach * WAD, p.rampDuration * WAD);
        return p.startBonusWad + MathLib.wadMul(p.maxBonusWad - p.startBonusWad, progress);
    }
}
