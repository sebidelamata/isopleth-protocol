// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracleAdapter} from "../../src/mocks/MockOracleAdapter.sol";
import {ProtocolConfig} from "../../src/governance/ProtocolConfig.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";

contract TestBase is Test {
    address internal admin = makeAddr("admin");

    ProtocolConfig internal config;
    MarketFactory internal factory;
    LendingPool internal pool;

    MockERC20 internal usdc; // 6 decimals, loan asset
    MockERC20 internal weth; // 18 decimals, collateral
    MockERC20 internal wbtc; // 8 decimals, collateral

    MockOracleAdapter internal usdcOracle;
    MockOracleAdapter internal wethOracle;
    MockOracleAdapter internal wbtcOracle;

    bytes32 internal wethMarketId;
    bytes32 internal wbtcMarketId;

    function setUp() public virtual {
        vm.startPrank(admin);
        config = new ProtocolConfig(admin);
        factory = new MarketFactory(address(config));
        pool = new LendingPool(address(factory), address(config));
        config.setLendingPool(address(pool));
        vm.stopPrank();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        usdcOracle = new MockOracleAdapter(address(usdc), 1e18); // $1
        wethOracle = new MockOracleAdapter(address(weth), 3000e18); // $3000
        wbtcOracle = new MockOracleAdapter(address(wbtc), 60000e18); // $60000

        // Allowlist the mock adapter's codehash (stand-in for a vetted adapter type).
        vm.prank(admin);
        config.setAdapterCodehashAllowed(address(usdcOracle).codehash, true);

        // Permissionless: anyone lists the loan asset...
        pool.initLoanAsset(address(usdc), address(usdcOracle));

        // ...and anyone creates markets.
        wethMarketId = factory.createMarket(address(weth), address(wethOracle));
        wbtcMarketId = factory.createMarket(address(wbtc), address(wbtcOracle));
    }

    function _dealAndApprove(MockERC20 token, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(pool), type(uint256).max);
    }
}
