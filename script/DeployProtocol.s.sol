// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ProtocolConfig} from "../src/governance/ProtocolConfig.sol";
import {MarketFactory} from "../src/core/MarketFactory.sol";
import {LendingPool} from "../src/core/LendingPool.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";

/// @title DeployProtocol
/// @notice Deploys the full protocol -- ProtocolConfig, MarketFactory, LendingPool -- wires
///         them together, allowlists the ChainlinkOracleAdapter implementation's codehash,
///         deploys one adapter instance per configured asset, lists WETH and WBTC as markets,
///         and registers USDC as a loan asset. Chain-agnostic: HelperConfig supplies real or
///         mock addresses depending on block.chainid, so the same script runs unmodified
///         against local Anvil, a local fork, Arbitrum Sepolia, or Arbitrum One.
///
/// Usage:
///   Local (plain Anvil):
///     anvil                                             # separate terminal
///     forge script script/DeployProtocol.s.sol --rpc-url http://127.0.0.1:8545 \
///       --private-key $ANVIL_PRIVATE_KEY --broadcast
///
///   Local fork of Arbitrum One (to sanity-check against real state before a real deploy):
///     anvil --fork-url $ARBITRUM_ONE_RPC_URL
///     forge script script/DeployProtocol.s.sol --rpc-url http://127.0.0.1:8545 \
///       --private-key $ANVIL_PRIVATE_KEY --broadcast
///
///   Arbitrum Sepolia testnet:
///     forge script script/DeployProtocol.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
///       --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY
///
///   Arbitrum One (fill in HelperConfig's TODOs first -- see that file's contract-level note):
///     forge script script/DeployProtocol.s.sol --rpc-url $ARBITRUM_ONE_RPC_URL \
///       --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY
contract DeployProtocol is Script {
    struct Deployment {
        ProtocolConfig config;
        MarketFactory factory;
        LendingPool pool;
        ChainlinkOracleAdapter wethOracle;
        ChainlinkOracleAdapter wbtcOracle;
        ChainlinkOracleAdapter usdcOracle;
        bytes32 wethMarketId;
        bytes32 wbtcMarketId;
        HelperConfig.NetworkConfig networkConfig;
    }

    function run() external returns (Deployment memory d) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = helperConfig.getConfig();
        d.networkConfig = cfg;

        address admin = cfg.admin == address(0) ? msg.sender : cfg.admin;
        if (cfg.admin == address(0)) {
            console.log("WARNING: no admin configured for this chain, defaulting to deployer:", admin);
            console.log("Set NetworkConfig.admin explicitly before a real deployment.");
        }

        vm.startBroadcast();

        d.config = new ProtocolConfig(admin);
        d.factory = new MarketFactory(address(d.config));
        d.pool = new LendingPool(address(d.factory), address(d.config));

        // setLendingPool is admin-only and one-time; if `admin` isn't the broadcasting key
        // (e.g. a multisig on mainnet), this call must be submitted separately by that admin
        // after this script runs -- it will simply not have been wired yet.
        if (admin == msg.sender) {
            d.config.setLendingPool(address(d.pool));
        } else {
            console.log("Deployer is not the configured admin; setLendingPool was NOT called.");
            console.log("The admin must call config.setLendingPool(pool) separately before use.");
        }

        // One ChainlinkOracleAdapter instance per asset. All instances share one runtime
        // codehash (see README's `immutable` note), so a SINGLE allowlist entry covers all
        // three -- and any future asset's adapter too, without a new governance action.
        d.wethOracle = new ChainlinkOracleAdapter(cfg.weth, cfg.wethUsdFeed, cfg.feedStaleAfter);
        d.wbtcOracle = new ChainlinkOracleAdapter(cfg.wbtc, cfg.wbtcUsdFeed, cfg.feedStaleAfter);
        d.usdcOracle = new ChainlinkOracleAdapter(cfg.usdc, cfg.usdcUsdFeed, cfg.feedStaleAfter);

        bytes32 adapterCodehash = address(d.wethOracle).codehash;
        if (admin == msg.sender) {
            d.config.setAdapterCodehashAllowed(adapterCodehash, true);

            // Market creation and loan-asset registration are permissionless in production;
            // the deployer calling them here is just the first caller, not a privileged one.
            d.wethMarketId = d.factory.createMarket(cfg.weth, address(d.wethOracle));
            d.wbtcMarketId = d.factory.createMarket(cfg.wbtc, address(d.wbtcOracle));
            d.pool.initLoanAsset(cfg.usdc, address(d.usdcOracle));
        } else {
            console.log("Deployer is not the configured admin; adapter allowlisting, market");
            console.log("creation, and loan asset registration were NOT performed. Run those");
            console.log("steps separately once the admin has allowlisted the adapter codehash.");
        }

        vm.stopBroadcast();

        _logDeployment(d);
    }

    function _logDeployment(Deployment memory d) internal view {
        console.log("==================================================");
        console.log("Isopleth Protocol deployed");
        console.log("==================================================");
        console.log("chainid:              ", block.chainid);
        console.log("ProtocolConfig:       ", address(d.config));
        console.log("MarketFactory:        ", address(d.factory));
        console.log("LendingPool:          ", address(d.pool));
        console.log("WETH oracle adapter:  ", address(d.wethOracle));
        console.log("WBTC oracle adapter:  ", address(d.wbtcOracle));
        console.log("USDC oracle adapter:  ", address(d.usdcOracle));
        console.log("WETH market id:       ", vm.toString(d.wethMarketId));
        console.log("WBTC market id:       ", vm.toString(d.wbtcMarketId));
        console.log("WETH token:           ", d.networkConfig.weth);
        console.log("WBTC token:           ", d.networkConfig.wbtc);
        console.log("USDC token:           ", d.networkConfig.usdc);
        console.log("==================================================");
    }
}
