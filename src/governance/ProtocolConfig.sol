// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

/// @title ProtocolConfig
/// @notice Deliberately the ONLY governance surface in the protocol. Everything else
///         (which collaterals are listed, what LTV/LLTV lenders accept, how much capital
///         backs which risk tranche) is fully permissionless and user-directed.
///
///         Governance controls exactly three things:
///           1. Which oracle adapter *implementations* (by code hash) are trusted enough to
///              be used in a permissionlessly-created Market. This is a one-time infra
///              decision ("is this oracle design sound"), not an asset-by-asset listing vote.
///           2. Interest rate model parameters (base rate, slope1, slope2, kink) per loan
///              asset — the curve, not the market-clearing price, which is driven by the
///              bucket ladder itself.
///           3. The systemic liquidation Dutch-auction curve parameters (same for every
///              bucket in the protocol — never lender-configurable).
contract ProtocolConfig is AccessControl {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Allowlisted oracle adapter *bytecode hashes*. We allowlist by codehash (not by
    ///         instance address) so that any number of permissionless per-token adapter
    ///         instances can be deployed from a single trusted, audited adapter implementation
    ///         without governance having to approve each token individually.
    mapping(bytes32 codehash => bool allowed) public allowedAdapterCodehash;

    struct RateModelParams {
        uint256 baseRateWad; // rate at 0% utilization, 1e18 = 100% APR
        uint256 slope1Wad; // additional rate at kink utilization
        uint256 slope2Wad; // additional rate from kink to 100% utilization
        uint256 kindWad; // utilization kink point, 1e18 = 100%
        bool initialized;
    }

    /// @notice Per loan-asset IRM params. Any address may permissionlessly initialize an
    ///         asset with conservative defaults (see LendingPool.initLoanAsset); governance
    ///         may subsequently retune the curve.
    /// this should probably be marketID => RateModelParams
    mapping(address loanAsset => RateModelParams) public rateModelParams;

    struct LiquidationAuctionParams {
        uint256 startBonusWad; // bonus at the instant a draw becomes liquidatable
        uint256 maxBonusWad; // bonus asymptote / cap
        uint256 rampDuration; // seconds for bonus to go from start to ~max
    }

    LiquidationAuctionParams public liquidationParams;

    event AdapterCodehashAllowed(bytes32 indexed codehash, bool allowed);
    event RateModelUpdated(address indexed loanAsset, uint256 base, uint256 slope1, uint256 slope2, uint256 kink);
    event LiquidationParamsUpdated(uint256 startBonus, uint256 maxBonus, uint256 rampDuration);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);

        // Sensible, conservative systemic liquidation auction defaults.
        liquidationParams = LiquidationAuctionParams({
            startBonusWad: 0.005e18, // 0.5%
            maxBonusWad: 0.12e18, // 12%
            rampDuration: 30 minutes
        });
    }

    /// @notice Permissionlessly bootstrap a loan asset with conservative default IRM params if
    ///         it has none yet. Governance may retune afterwards via setRateModel. Callable by
    ///         LendingPool only, so a loan asset can't be "half-listed" outside the pool's flow.
    address public lendingPool;

    function setLendingPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(lendingPool == address(0), "already set");
        lendingPool = pool;
    }

    function initDefaultRateModel(address loanAsset) external {
        require(msg.sender == lendingPool, "only pool");
        if (rateModelParams[loanAsset].initialized) return;
        rateModelParams[loanAsset] = RateModelParams({
            baseRateWad: 0.01e18, // 1% APR base
            slope1Wad: 0.04e18, // +4% APR up to kink
            slope2Wad: 0.75e18, // +75% APR beyond kink (steep, discourages full-utilization squeeze)
            kindWad: 0.80e18, // 80% utilization kink
            initialized: true
        });
        emit RateModelUpdated(loanAsset, 0.01e18, 0.04e18, 0.75e18, 0.80e18);
    }

    function getRateModelParams(address loanAsset) external view returns (RateModelParams memory) {
        return rateModelParams[loanAsset];
    }

    function setAdapterCodehashAllowed(bytes32 codehash, bool allowed) external onlyRole(GOVERNANCE_ROLE) {
        allowedAdapterCodehash[codehash] = allowed;
        emit AdapterCodehashAllowed(codehash, allowed);
    }

    function setRateModel(address loanAsset, uint256 base, uint256 slope1, uint256 slope2, uint256 kink)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(kink > 0 && kink < 1e18, "bad kink");
        rateModelParams[loanAsset] =
            RateModelParams({baseRateWad: base, slope1Wad: slope1, slope2Wad: slope2, kindWad: kink, initialized: true});
        emit RateModelUpdated(loanAsset, base, slope1, slope2, kink);
    }

    function setLiquidationParams(uint256 startBonus, uint256 maxBonus, uint256 rampDuration)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(maxBonus >= startBonus, "bad bonus range");
        liquidationParams =
            LiquidationAuctionParams({startBonusWad: startBonus, maxBonusWad: maxBonus, rampDuration: rampDuration});
        emit LiquidationParamsUpdated(startBonus, maxBonus, rampDuration);
    }

    function isAdapterAllowed(address adapter) public view returns (bool) {
        return allowedAdapterCodehash[adapter.codehash];
    }

    function getLiquidationParams() external view returns (LiquidationAuctionParams memory) {
        return liquidationParams;
    }
}
