// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracleAdapter} from "../../src/mocks/MockOracleAdapter.sol";

/// @notice Bounded-random actor for invariant/stateful fuzzing of LendingPool. Deliberately
///         restricts the action space to a small fixed set of actors, tick choices, and one
///         market/loan-asset pair, so the invariant runner spends its budget exploring deep,
///         meaningful sequences (many interleaved supply/borrow/repay/withdraw/liquidate calls
///         against the SAME few buckets) rather than combinatorial setup noise across an
///         effectively infinite tick/market space.
contract Handler is Test {
    LendingPool public pool;
    MockERC20 public usdc;
    MockERC20 public weth;
    bytes32 public wethMarketId;
    MockOracleAdapter public wethOracle;

    address[] public actors;

    uint16[3] public ltvChoices = [7000, 8000, 9000];
    uint16[3] public lltvChoices = [8000, 9000, 9800];

    // ghost accounting, cross-checked against on-chain state by the invariant test
    uint256 public ghost_totalCollateralDeposited;
    uint256 public ghost_totalCollateralWithdrawn;

    constructor(LendingPool _pool, MockERC20 _usdc, MockERC20 _weth, bytes32 _wethMarketId, MockOracleAdapter _wethOracle) {
        pool = _pool;
        usdc = _usdc;
        weth = _weth;
        wethMarketId = _wethMarketId;
        wethOracle = _wethOracle;

        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string.concat("invariantActor", vm.toString(i)));
            actors.push(actor);
            usdc.mint(actor, 10_000_000e6);
            weth.mint(actor, 10_000e18);
            vm.prank(actor);
            usdc.approve(address(pool), type(uint256).max);
            vm.prank(actor);
            weth.approve(address(pool), type(uint256).max);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _tick(uint256 seed) internal view returns (uint16 ltv, uint16 lltv) {
        ltv = ltvChoices[seed % 3];
        lltv = lltvChoices[seed % 3];
    }

    function supply(uint256 actorSeed, uint256 tickSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        (uint16 ltv, uint16 lltv) = _tick(tickSeed);
        amount = bound(amount, 1e6, 1_000_000e6);

        vm.prank(actor);
        try pool.supply(wethMarketId, address(usdc), ltv, lltv, amount) {} catch {}
    }

    function withdraw(uint256 actorSeed, uint256 tickSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);
        (uint16 ltv, uint16 lltv) = _tick(tickSeed);
        uint256 shares = bound(sharesSeed, 1, 1_000_000e12);

        vm.prank(actor);
        try pool.withdraw(wethMarketId, address(usdc), ltv, lltv, shares) {} catch {}
    }

    function depositCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e15, 100e18);

        vm.prank(actor);
        try pool.depositCollateral(wethMarketId, amount) {
            ghost_totalCollateralDeposited += amount;
        } catch {}
    }

    function withdrawCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e15, 100e18);

        vm.prank(actor);
        try pool.withdrawCollateral(wethMarketId, amount) {
            ghost_totalCollateralWithdrawn += amount;
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e6, 100_000e6);

        vm.prank(actor);
        try pool.borrow(address(usdc), wethMarketId, amount) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 tickSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        (uint16 ltv, uint16 lltv) = _tick(tickSeed);
        amount = bound(amount, 1e6, 1_000_000e6);

        vm.prank(actor);
        try pool.repay(wethMarketId, address(usdc), ltv, lltv, amount) {} catch {}
    }

    function liquidate(uint256 liquidatorSeed, uint256 ownerSeed, uint256 tickSeed, uint256 repaySeed) external {
        address liquidator = _actor(liquidatorSeed);
        address owner = _actor(ownerSeed);
        (uint16 ltv, uint16 lltv) = _tick(tickSeed);
        uint256 repayAmount = bound(repaySeed, 1e6, 1_000_000e6);

        vm.prank(liquidator);
        try pool.liquidate(owner, wethMarketId, address(usdc), ltv, lltv, repayAmount) {} catch {}
    }

    function movePrice(uint256 priceSeed) external {
        uint256 newPrice = bound(priceSeed, 500e18, 6000e18);
        wethOracle.setPrice(newPrice);
    }

    function warp(uint256 secondsSeed) external {
        uint256 elapsed = bound(secondsSeed, 0, 60 days);
        vm.warp(block.timestamp + elapsed);
    }
}
