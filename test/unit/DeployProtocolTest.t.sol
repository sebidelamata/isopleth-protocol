// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployProtocol} from "../../script/DeployProtocol.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ProtocolConfig} from "../../src/governance/ProtocolConfig.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {LendingPool} from "../../src/core/LendingPool.sol";
import {ChainlinkOracleAdapter} from "../../src/oracles/ChainlinkOracleAdapter.sol";

contract DeployProtocolTest is Test {
    DeployProtocol internal deployer;
    DeployProtocol.Deployment internal d;

    // -------------------------------------------------------------------------
    // Default path: mock config, admin = DeployProtocol, privileged steps skipped
    // by the script then completed by the test.
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.chainId(31337);
        deployer = new DeployProtocol();
        d = deployer.run();
        _completeAdminSteps();
    }

    function _completeAdminSteps() internal {
        address admin = address(deployer);
        vm.startPrank(admin);
        if (d.config.lendingPool() == address(0)) {
            d.config.setLendingPool(address(d.pool));
        }
        bytes32 adapterCodehash = address(d.wethOracle).codehash;
        d.config.setAdapterCodehashAllowed(adapterCodehash, true);
        vm.stopPrank();

        d.wethMarketId = d.factory.createMarket(d.networkConfig.weth, address(d.wethOracle));
        d.wbtcMarketId = d.factory.createMarket(d.networkConfig.wbtc, address(d.wbtcOracle));
        d.pool.initLoanAsset(d.networkConfig.usdc, address(d.usdcOracle));
    }

    function test_CoreContractsDeployed() public view {
        assertTrue(address(d.config) != address(0));
        assertTrue(address(d.factory) != address(0));
        assertTrue(address(d.pool) != address(0));
        assertTrue(address(d.wethOracle) != address(0));
        assertTrue(address(d.wbtcOracle) != address(0));
        assertTrue(address(d.usdcOracle) != address(0));
    }

    function test_OracleAdaptersShareCodehash() public view {
        bytes32 h = address(d.wethOracle).codehash;
        assertEq(h, address(d.wbtcOracle).codehash);
        assertEq(h, address(d.usdcOracle).codehash);
        assertTrue(h != bytes32(0));
    }

    function test_LendingPoolWired() public view {
        assertEq(d.config.lendingPool(), address(d.pool));
    }

    function test_AdapterCodehashAllowlisted() public view {
        assertTrue(d.config.isAdapterAllowed(address(d.wethOracle)));
        assertTrue(d.config.isAdapterAllowed(address(d.wbtcOracle)));
        assertTrue(d.config.isAdapterAllowed(address(d.usdcOracle)));
    }

    function test_WethAndWbtcMarketsCreated() public view {
        assertTrue(d.wethMarketId != bytes32(0));
        assertTrue(d.wbtcMarketId != bytes32(0));
        assertTrue(d.wethMarketId != d.wbtcMarketId);
    }

    function test_MockNetworkConfigPopulated() public view {
        HelperConfig.NetworkConfig memory cfg = d.networkConfig;
        assertTrue(cfg.weth != address(0));
        assertTrue(cfg.wbtc != address(0));
        assertTrue(cfg.usdc != address(0));
        assertTrue(cfg.wethUsdFeed != address(0));
        assertTrue(cfg.wbtcUsdFeed != address(0));
        assertTrue(cfg.usdcUsdFeed != address(0));
        assertEq(cfg.admin, address(deployer));
        assertEq(cfg.feedStaleAfter, 365 days);
    }

    // -------------------------------------------------------------------------
    // Branch: script skips privileged steps when admin != msg.sender
    // (this is the path taken by setUp before _completeAdminSteps)
    // -------------------------------------------------------------------------

    function test_ScriptSkipsPrivilegedStepsWhenAdminIsNotCaller() public {
        // Fresh run without completing admin steps
        vm.chainId(31337);
        DeployProtocol fresh = new DeployProtocol();
        DeployProtocol.Deployment memory dep = fresh.run();

        // admin recorded by HelperConfig is the DeployProtocol instance
        assertEq(dep.networkConfig.admin, address(fresh));

        // Privileged work was skipped
        assertEq(dep.config.lendingPool(), address(0), "setLendingPool should have been skipped");
        assertTrue(dep.wethMarketId == bytes32(0), "createMarket should have been skipped");
        assertTrue(dep.wbtcMarketId == bytes32(0), "createMarket should have been skipped");
    }

    // -------------------------------------------------------------------------
    // Branch: admin == msg.sender so script does full wiring
    // We simulate this by pranking as the DeployProtocol address while calling run.
    // (run itself creates a new DeployProtocol via `new`, so we instead drive
    // HelperConfig + the privileged calls in a controlled way.)
    // -------------------------------------------------------------------------

    function test_FullWiringWhenAdminMatchesCaller() public {
        address admin = makeAddr("admin");
        vm.deal(admin, 100 ether);

        // HelperConfig uses vm.startBroadcast internally — must not be inside a prank
        HelperConfig helper = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = helper.getConfig();

        vm.startPrank(admin);

        ProtocolConfig config = new ProtocolConfig(admin);
        MarketFactory factory = new MarketFactory(address(config));
        LendingPool pool = new LendingPool(address(factory), address(config));

        config.setLendingPool(address(pool));

        ChainlinkOracleAdapter wethOracle =
            new ChainlinkOracleAdapter(cfg.weth, cfg.wethUsdFeed, cfg.feedStaleAfter);
        ChainlinkOracleAdapter wbtcOracle =
            new ChainlinkOracleAdapter(cfg.wbtc, cfg.wbtcUsdFeed, cfg.feedStaleAfter);
        ChainlinkOracleAdapter usdcOracle =
            new ChainlinkOracleAdapter(cfg.usdc, cfg.usdcUsdFeed, cfg.feedStaleAfter);

        bytes32 codehash = address(wethOracle).codehash;
        config.setAdapterCodehashAllowed(codehash, true);

        bytes32 wethId = factory.createMarket(cfg.weth, address(wethOracle));
        bytes32 wbtcId = factory.createMarket(cfg.wbtc, address(wbtcOracle));
        pool.initLoanAsset(cfg.usdc, address(usdcOracle));

        vm.stopPrank();

        assertEq(config.lendingPool(), address(pool));
        assertTrue(config.isAdapterAllowed(address(wethOracle)));
        assertTrue(wethId != bytes32(0));
        assertTrue(wbtcId != bytes32(0));
        assertTrue(wethId != wbtcId);
    }

    // -------------------------------------------------------------------------
    // HelperConfig: Arbitrum One path + caching
    // -------------------------------------------------------------------------

    function test_HelperConfig_ArbitrumOnePath() public {
        HelperConfig helper = new HelperConfig();

        HelperConfig.NetworkConfig memory cfg = helper.getConfigByChainId(42161);

        // Known real addresses from the script (verify they match your file)
        assertEq(cfg.weth, 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        assertEq(cfg.wbtc, 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
        assertEq(cfg.usdc, 0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
        assertEq(cfg.wethUsdFeed, 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        // TODOs still zero until filled in
        assertEq(cfg.wbtcUsdFeed, address(0));
        assertEq(cfg.usdcUsdFeed, address(0));
        assertEq(cfg.feedStaleAfter, 90 minutes);
        assertEq(cfg.admin, address(0));
    }

    function test_HelperConfig_Caching() public {
        HelperConfig helper = new HelperConfig();

        HelperConfig.NetworkConfig memory first = helper.getConfigByChainId(31337);
        HelperConfig.NetworkConfig memory second = helper.getConfigByChainId(31337);

        // Same cached addresses (mocks are not re-deployed)
        assertEq(first.weth, second.weth);
        assertEq(first.wbtc, second.wbtc);
        assertEq(first.usdc, second.usdc);
        assertEq(first.wethUsdFeed, second.wethUsdFeed);
    }

    function test_HelperConfig_SepoliaUsesMockPath() public {
        HelperConfig helper = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = helper.getConfigByChainId(421614);

        // Sepolia deliberately uses freshly deployed mocks
        assertTrue(cfg.weth != address(0));
        assertTrue(cfg.wbtc != address(0));
        assertTrue(cfg.usdc != address(0));
        assertEq(cfg.feedStaleAfter, 365 days);
        // admin is whoever called getConfigByChainId (this test contract)
        assertEq(cfg.admin, address(this));
    }
}