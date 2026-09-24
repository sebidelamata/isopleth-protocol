// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockV3Aggregator} from "chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

/// @title HelperConfig
/// @notice Returns a NetworkConfig for whatever chain the deploy script is currently running
///         against (keyed by block.chainid), so one DeployProtocol script works unmodified on
///         local Anvil, a local fork of Arbitrum, Arbitrum Sepolia, and Arbitrum One.
///
///         IMPORTANT -- read before a real deployment:
///         Arbitrum One's WBTC/USD and USDC/USD Chainlink feed addresses below are left as
///         explicit TODO placeholders. While researching this file, two different sources
///         reported two different addresses for the same Arbitrum BTC/USD feed -- rather than
///         guess, this file leaves them unset so a wrong, unverified oracle address can never
///         silently make it into a real deployment. Before deploying to Arbitrum One:
///           1. Go to https://docs.chain.link/data-feeds/price-feeds/addresses?network=arbitrum
///           2. Copy the exact proxy addresses for the feeds you need, confirm decimals (8 is
///              standard for USD pairs but verify) and the feed's heartbeat (sets a sane
///              staleAfter bound).
///           3. Fill in the TODOs in _getArbitrumOneConfig below.
///         The ETH/USD address below was corroborated by an official docs.chain.link source
///         and is more likely correct, but VERIFY IT YOURSELF against the link above before
///         trusting it with real funds regardless -- this repo's author cannot be the final
///         check on a live oracle address for a lending protocol.
contract HelperConfig is Script {
    uint256 internal constant ANVIL_CHAIN_ID = 31337;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;

    /// @dev A local mock feed is treated as fresh for a very long window so demo/test flows
    ///      that warp time forward don't spuriously hit staleness reverts. Real feeds use each
    ///      feed's actual heartbeat with a small buffer -- verify against Chainlink's docs.
    uint256 internal constant MOCK_STALE_AFTER = 365 days;

    struct NetworkConfig {
        address weth;
        address wbtc;
        address usdc;
        address wethUsdFeed;
        address wbtcUsdFeed;
        address usdcUsdFeed;
        uint256 feedStaleAfter;
        address admin;
    }

    NetworkConfig public activeConfig;

    /// @dev Deterministic addresses cached across multiple getConfig() calls within one script
    ///      run, so re-deploying mocks doesn't happen twice for the same broadcast.
    mapping(uint256 => NetworkConfig) private cachedConfigs;
    mapping(uint256 => bool) private isCached;

    constructor() {
        activeConfig = getConfig();
    }

    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (isCached[chainId]) return cachedConfigs[chainId];

        NetworkConfig memory config;
        if (chainId == ARBITRUM_ONE_CHAIN_ID) {
            config = _getArbitrumOneConfig();
        } else if (chainId == ARBITRUM_SEPOLIA_CHAIN_ID) {
            config = _getOrCreateMockConfig(); // see note in _getArbitrumSepoliaConfig below
        } else {
            // Anvil (local, or a local fork -- a fork of Arbitrum reports Arbitrum's real
            // chainid, not 31337, and is handled by the branches above instead)
            config = _getOrCreateMockConfig();
        }

        cachedConfigs[chainId] = config;
        isCached[chainId] = true;
        return config;
    }

    function _getArbitrumOneConfig() internal pure returns (NetworkConfig memory) {
        return NetworkConfig({
            weth: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH, Arbitrum One -- verify before use
            wbtc: 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f, // WBTC, Arbitrum One -- verify before use
            usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // native USDC, Arbitrum One -- verify before use
            wethUsdFeed: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612, // corroborated; VERIFY before mainnet use
            wbtcUsdFeed: address(0), // TODO: fill in from docs.chain.link -- see contract-level note
            usdcUsdFeed: address(0), // TODO: fill in from docs.chain.link -- see contract-level note
            feedStaleAfter: 90 minutes, // typical Arbitrum USD-feed heartbeat + buffer -- VERIFY per feed
            admin: address(0) // TODO: set to your actual governance/multisig address before mainnet use
        });
    }

    /// @dev Arbitrum Sepolia deliberately uses freshly-deployed mock tokens and feeds rather
    ///      than canonical testnet addresses. Testnet USDC/WETH addresses and their feeds
    ///      change over time and are easy to get subtly wrong (wrong decimals, deprecated
    ///      contract); since testnet tokens carry no real value, deploying your own removes
    ///      that whole class of risk and gives the seeding script full control to mint to any
    ///      demo wallet without depending on a faucet. Swap this for real addresses (verified
    ///      the same way as the Arbitrum One TODOs above) if you specifically need to interop
    ///      with other testnet protocols that expect canonical token addresses.
    function _getOrCreateMockConfig() internal returns (NetworkConfig memory) {
        vm.startBroadcast();
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        MockV3Aggregator wethFeed = new MockV3Aggregator(8, 3_000e8); // $3,000, 8 decimals like real Chainlink USD feeds
        MockV3Aggregator wbtcFeed = new MockV3Aggregator(8, 60_000e8); // $60,000
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8); // $1
        vm.stopBroadcast();

        return NetworkConfig({
            weth: address(weth),
            wbtc: address(wbtc),
            usdc: address(usdc),
            wethUsdFeed: address(wethFeed),
            wbtcUsdFeed: address(wbtcFeed),
            usdcUsdFeed: address(usdcFeed),
            feedStaleAfter: MOCK_STALE_AFTER,
            admin: msg.sender
        });
    }
}
