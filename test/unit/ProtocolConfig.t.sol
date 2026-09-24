
 // SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../../src/governance/ProtocolConfig.sol";

contract ProtocolConfigTest is Test {
    ProtocolConfig internal config;

    address internal admin = makeAddr("admin");
    address internal governance = makeAddr("governance");
    address internal pool = makeAddr("lendingPool");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal loanAsset = makeAddr("loanAsset");
    address internal loanAsset2 = makeAddr("loanAsset2");

    uint256 internal constant WAD = 1e18;

    bytes32 internal constant GOVERNANCE_ROLE =
        keccak256("GOVERNANCE_ROLE");

    bytes32 internal constant DEFAULT_ADMIN_ROLE =
        bytes32(0);

    function setUp() public {
        config = new ProtocolConfig(admin);

        // Give a separate governance address the governance role.
        vm.prank(admin);
        config.grantRole(GOVERNANCE_ROLE, governance);
    }

    // ============================================================
    // Constructor and initial configuration
    // ============================================================

    function test_ConstructorGrantsAdminRole() public view {
        assertTrue(config.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_ConstructorGrantsGovernanceRole() public view {
        assertTrue(config.hasRole(GOVERNANCE_ROLE, admin));
    }

    function test_ConstructorDoesNotGrantRolesToOthers() public view {
        assertFalse(config.hasRole(DEFAULT_ADMIN_ROLE, alice));
        assertFalse(config.hasRole(GOVERNANCE_ROLE, alice));
    }

    function test_ConstructorSetsLiquidationDefaults() public view {
        ProtocolConfig.LiquidationAuctionParams memory params =
            config.getLiquidationParams();

        assertEq(params.startBonusWad, 0.005e18);
        assertEq(params.maxBonusWad, 0.12e18);
        assertEq(params.rampDuration, 30 minutes);
    }

    function test_ConstructorSetsLendingPoolToZero() public view {
        assertEq(config.lendingPool(), address(0));
    }

    function test_ConstructorRateModelInitiallyUninitialized()
        public
        view
    {
        ProtocolConfig.RateModelParams memory params =
            config.getRateModelParams(loanAsset);

        assertEq(params.baseRateWad, 0);
        assertEq(params.slope1Wad, 0);
        assertEq(params.slope2Wad, 0);
        assertEq(params.kindWad, 0);
        assertFalse(params.initialized);
    }

    function test_ConstructorDoesNotAllowArbitraryAdapter()
        public
        view
    {
        assertFalse(
            config.allowedAdapterCodehash(
                keccak256("untrusted adapter")
            )
        );
    }

    // ============================================================
    // setLendingPool
    // ============================================================

    function test_SetLendingPool() public {
        vm.prank(admin);
        config.setLendingPool(pool);

        assertEq(config.lendingPool(), pool);
    }

    function test_SetLendingPoolOnlyAdmin() public {
        vm.prank(governance);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                governance,
                DEFAULT_ADMIN_ROLE
            )
        );

        config.setLendingPool(pool);
    }

    function test_SetLendingPoolRevertsForUnauthorizedUser()
        public
    {
        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                alice,
                DEFAULT_ADMIN_ROLE
            )
        );

        config.setLendingPool(pool);
    }

    function test_SetLendingPoolCannotBeCalledTwice() public {
        vm.startPrank(admin);
        config.setLendingPool(pool);

        vm.expectRevert(
            bytes("already set")
        );

        config.setLendingPool(address(0xBEEF));
        vm.stopPrank();

        assertEq(config.lendingPool(), pool);
    }

    function test_SetLendingPoolCannotBeResetToZero() public {
        vm.startPrank(admin);
        config.setLendingPool(pool);

        vm.expectRevert(bytes("already set"));
        config.setLendingPool(address(0));

        vm.stopPrank();

        assertEq(config.lendingPool(), pool);
    }

    // ============================================================
    // initDefaultRateModel
    // ============================================================

    function test_InitDefaultRateModelBeforePoolConfigured() public {
        // lendingPool is address(0) before configuration.
        // Calling as the test contract should fail the only-pool check.
        vm.expectRevert(
            abi.encodeWithSignature("Error(string)", "only pool")
        );

        config.initDefaultRateModel(loanAsset);
    }

    function test_InitDefaultRateModelSetsDefaults() public {
        _configurePool();

        vm.prank(pool);
        config.initDefaultRateModel(loanAsset);

        ProtocolConfig.RateModelParams memory params =
            config.getRateModelParams(loanAsset);

        assertEq(params.baseRateWad, 0.01e18);
        assertEq(params.slope1Wad, 0.04e18);
        assertEq(params.slope2Wad, 0.75e18);
        assertEq(params.kindWad, 0.80e18);
        assertTrue(params.initialized);
    }

    function test_InitDefaultRateModelEmitsEvent() public {
        _configurePool();

        vm.expectEmit(true, false, false, true, address(config));
        emit ProtocolConfig.RateModelUpdated(
            loanAsset,
            0.01e18,
            0.04e18,
            0.75e18,
            0.80e18
        );

        vm.prank(pool);
        config.initDefaultRateModel(loanAsset);
    }

    function test_InitDefaultRateModelIsIdempotent() public {
        _configurePool();

        vm.prank(pool);
        config.initDefaultRateModel(loanAsset);

        // Retune the model first.
        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0.02e18,
            0.06e18,
            0.90e18,
            0.75e18
        );

        // A second initialization must not overwrite governance settings.
        vm.prank(pool);
        config.initDefaultRateModel(loanAsset);

        ProtocolConfig.RateModelParams memory params =
            config.getRateModelParams(loanAsset);

        assertEq(params.baseRateWad, 0.02e18);
        assertEq(params.slope1Wad, 0.06e18);
        assertEq(params.slope2Wad, 0.90e18);
        assertEq(params.kindWad, 0.75e18);
        assertTrue(params.initialized);
    }

    function test_InitDefaultRateModelCanInitializeDifferentAssets()
        public
    {
        _configurePool();

        vm.startPrank(pool);
        config.initDefaultRateModel(loanAsset);
        config.initDefaultRateModel(loanAsset2);
        vm.stopPrank();

        assertTrue(
            config.getRateModelParams(loanAsset).initialized
        );

        assertTrue(
            config.getRateModelParams(loanAsset2).initialized
        );
    }

    // ============================================================
    // setAdapterCodehashAllowed
    // ============================================================

    function test_SetAdapterCodehashAllowed() public {
        bytes32 codehash = keccak256("trusted adapter");

        vm.prank(governance);
        config.setAdapterCodehashAllowed(codehash, true);

        assertTrue(config.allowedAdapterCodehash(codehash));
    }

    function test_SetAdapterCodehashAllowedEmitsEvent() public {
        bytes32 codehash = keccak256("trusted adapter");

        vm.expectEmit(true, false, false, true, address(config));
        emit ProtocolConfig.AdapterCodehashAllowed(
            codehash,
            true
        );

        vm.prank(governance);
        config.setAdapterCodehashAllowed(codehash, true);
    }

    function test_SetAdapterCodehashDisallowed() public {
        bytes32 codehash = keccak256("trusted adapter");

        vm.startPrank(governance);
        config.setAdapterCodehashAllowed(codehash, true);
        config.setAdapterCodehashAllowed(codehash, false);
        vm.stopPrank();

        assertFalse(config.allowedAdapterCodehash(codehash));
    }

    function test_SetAdapterCodehashDisallowedEmitsEvent()
        public
    {
        bytes32 codehash = keccak256("trusted adapter");

        vm.prank(governance);
        config.setAdapterCodehashAllowed(codehash, true);

        vm.expectEmit(true, false, false, true, address(config));
        emit ProtocolConfig.AdapterCodehashAllowed(
            codehash,
            false
        );

        vm.prank(governance);
        config.setAdapterCodehashAllowed(codehash, false);
    }

    function test_SetAdapterCodehashAllowedOnlyGovernance()
        public
    {
        bytes32 codehash = keccak256("trusted adapter");

        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                alice,
                GOVERNANCE_ROLE
            )
        );

        config.setAdapterCodehashAllowed(codehash, true);
    }

    function test_AdminCanSetAdapterCodehash() public {
        bytes32 codehash = keccak256("trusted adapter");

        vm.prank(admin);
        config.setAdapterCodehashAllowed(codehash, true);

        assertTrue(config.allowedAdapterCodehash(codehash));
    }

    function test_AllowlistingSameCodehashTwice() public {
        bytes32 codehash = keccak256("trusted adapter");

        vm.startPrank(governance);
        config.setAdapterCodehashAllowed(codehash, true);
        config.setAdapterCodehashAllowed(codehash, true);
        vm.stopPrank();

        assertTrue(config.allowedAdapterCodehash(codehash));
    }

    // ============================================================
    // isAdapterAllowed
    // ============================================================

    function test_IsAdapterAllowedForApprovedRuntimeCodehash()
        public
    {
        AdapterCodeMock adapter = new AdapterCodeMock();

        bytes32 codehash = address(adapter).codehash;

        vm.prank(governance);
        config.setAdapterCodehashAllowed(codehash, true);

        assertTrue(config.isAdapterAllowed(address(adapter)));
    }

    function test_IsAdapterNotAllowedForUnapprovedCodehash()
        public
    {
        AdapterCodeMock adapter = new AdapterCodeMock();

        assertFalse(config.isAdapterAllowed(address(adapter)));
    }

    function test_IsAdapterAllowedForMultipleInstancesOfSameCode()
        public
    {
        AdapterCodeMock adapter1 = new AdapterCodeMock();
        AdapterCodeMock adapter2 = new AdapterCodeMock();

        assertEq(
            address(adapter1).codehash,
            address(adapter2).codehash
        );

        vm.prank(governance);
        config.setAdapterCodehashAllowed(
            address(adapter1).codehash,
            true
        );

        assertTrue(config.isAdapterAllowed(address(adapter1)));
        assertTrue(config.isAdapterAllowed(address(adapter2)));
    }

    function test_IsAdapterDisallowedAfterRevocation() public {
        AdapterCodeMock adapter = new AdapterCodeMock();

        vm.startPrank(governance);
        config.setAdapterCodehashAllowed(
            address(adapter).codehash,
            true
        );

        assertTrue(config.isAdapterAllowed(address(adapter)));

        config.setAdapterCodehashAllowed(
            address(adapter).codehash,
            false
        );
        vm.stopPrank();

        assertFalse(config.isAdapterAllowed(address(adapter)));
    }

    function test_IsAdapterAllowedForEmptyCodehashIfAllowlisted()
        public
    {
        bytes32 emptyCodehash = address(0).codehash;

        vm.prank(governance);
        config.setAdapterCodehashAllowed(emptyCodehash, true);

        assertTrue(config.isAdapterAllowed(address(0)));
    }

    // ============================================================
    // setRateModel
    // ============================================================

    function test_SetRateModel() public {
        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0.75e18
        );

        ProtocolConfig.RateModelParams memory params =
            config.getRateModelParams(loanAsset);

        assertEq(params.baseRateWad, 0.02e18);
        assertEq(params.slope1Wad, 0.05e18);
        assertEq(params.slope2Wad, 0.80e18);
        assertEq(params.kindWad, 0.75e18);
        assertTrue(params.initialized);
    }

    function test_SetRateModelEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(config));
        emit ProtocolConfig.RateModelUpdated(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0.75e18
        );

        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0.75e18
        );
    }

    function test_SetRateModelOnlyGovernance() public {
        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                alice,
                GOVERNANCE_ROLE
            )
        );

        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0.75e18
        );
    }

    function test_AdminCanSetRateModel() public {
        vm.prank(admin);
        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0.75e18
        );

        assertTrue(
            config.getRateModelParams(loanAsset).initialized
        );
    }

    function test_SetRateModelWithZeroKinkReverts() public {
        vm.prank(governance);

        vm.expectRevert(bytes("bad kink"));

        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0
        );
    }

    function test_SetRateModelWithKinkEqualToWadReverts()
        public
    {
        vm.prank(governance);

        vm.expectRevert(bytes("bad kink"));

        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            WAD
        );
    }

    function test_SetRateModelWithKinkGreaterThanWadReverts()
        public
    {
        vm.prank(governance);

        vm.expectRevert(bytes("bad kink"));

        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            WAD + 1
        );
    }

    function test_SetRateModelWithMinimumValidKink() public {
        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0,
            0,
            0,
            1
        );

        assertEq(
            config.getRateModelParams(loanAsset).kindWad,
            1
        );
    }

    function test_SetRateModelWithMaximumValidKink() public {
        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0,
            0,
            0,
            WAD - 1
        );

        assertEq(
            config.getRateModelParams(loanAsset).kindWad,
            WAD - 1
        );
    }

    function test_SetRateModelCanSetZeroRates() public {
        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0,
            0,
            0,
            0.5e18
        );

        ProtocolConfig.RateModelParams memory params =
            config.getRateModelParams(loanAsset);

        assertEq(params.baseRateWad, 0);
        assertEq(params.slope1Wad, 0);
        assertEq(params.slope2Wad, 0);
        assertTrue(params.initialized);
    }

    function test_SetRateModelCanRetuneInitializedAsset()
        public
    {
        _configurePool();

        vm.prank(pool);
        config.initDefaultRateModel(loanAsset);

        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0.03e18,
            0.07e18,
            1e18,
            0.90e18
        );

        ProtocolConfig.RateModelParams memory params =
            config.getRateModelParams(loanAsset);

        assertEq(params.baseRateWad, 0.03e18);
        assertEq(params.slope1Wad, 0.07e18);
        assertEq(params.slope2Wad, 1e18);
        assertEq(params.kindWad, 0.90e18);
        assertTrue(params.initialized);
    }

    function test_SetRateModelDoesNotModifyOtherAsset()
        public
    {
        vm.prank(governance);
        config.setRateModel(
            loanAsset,
            0.02e18,
            0.05e18,
            0.80e18,
            0.75e18
        );

        vm.prank(governance);
        config.setRateModel(
            loanAsset2,
            0.03e18,
            0.06e18,
            0.90e18,
            0.85e18
        );

        assertEq(
            config.getRateModelParams(loanAsset).baseRateWad,
            0.02e18
        );

        assertEq(
            config.getRateModelParams(loanAsset2).baseRateWad,
            0.03e18
        );
    }

    // ============================================================
    // setLiquidationParams
    // ============================================================

    function test_SetLiquidationParams() public {
        vm.prank(governance);
        config.setLiquidationParams(
            0.01e18,
            0.15e18,
            1 hours
        );

        ProtocolConfig.LiquidationAuctionParams memory params =
            config.getLiquidationParams();

        assertEq(params.startBonusWad, 0.01e18);
        assertEq(params.maxBonusWad, 0.15e18);
        assertEq(params.rampDuration, 1 hours);
    }

    function test_SetLiquidationParamsEmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(config));
        emit ProtocolConfig.LiquidationParamsUpdated(
            0.01e18,
            0.15e18,
            1 hours
        );

        vm.prank(governance);
        config.setLiquidationParams(
            0.01e18,
            0.15e18,
            1 hours
        );
    }

    function test_SetLiquidationParamsOnlyGovernance()
        public
    {
        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                alice,
                GOVERNANCE_ROLE
            )
        );

        config.setLiquidationParams(
            0.01e18,
            0.15e18,
            1 hours
        );
    }

    function test_AdminCanSetLiquidationParams() public {
        vm.prank(admin);
        config.setLiquidationParams(
            0.01e18,
            0.15e18,
            1 hours
        );

        assertEq(
            config.getLiquidationParams().rampDuration,
            1 hours
        );
    }

    function test_SetLiquidationParamsWithEqualBonuses()
        public
    {
        vm.prank(governance);
        config.setLiquidationParams(
            0.10e18,
            0.10e18,
            1 hours
        );

        ProtocolConfig.LiquidationAuctionParams memory params =
            config.getLiquidationParams();

        assertEq(params.startBonusWad, params.maxBonusWad);
    }

    function test_SetLiquidationParamsWithZeroBonuses()
        public
    {
        vm.prank(governance);
        config.setLiquidationParams(
            0,
            0,
            1 hours
        );

        ProtocolConfig.LiquidationAuctionParams memory params =
            config.getLiquidationParams();

        assertEq(params.startBonusWad, 0);
        assertEq(params.maxBonusWad, 0);
    }

    function test_SetLiquidationParamsWithZeroDuration()
        public
    {
        vm.prank(governance);
        config.setLiquidationParams(
            0.01e18,
            0.15e18,
            0
        );

        assertEq(
            config.getLiquidationParams().rampDuration,
            0
        );
    }

    function test_SetLiquidationParamsWithMaxBelowStartReverts()
        public
    {
        vm.prank(governance);

        vm.expectRevert(bytes("bad bonus range"));

        config.setLiquidationParams(
            0.15e18,
            0.10e18,
            1 hours
        );
    }

    function test_SetLiquidationParamsRevertDoesNotChangeState()
        public
    {
        ProtocolConfig.LiquidationAuctionParams memory beforeParams =
            config.getLiquidationParams();

        vm.prank(governance);

        vm.expectRevert(bytes("bad bonus range"));

        config.setLiquidationParams(
            0.20e18,
            0.10e18,
            1 hours
        );

        ProtocolConfig.LiquidationAuctionParams memory afterParams =
            config.getLiquidationParams();

        assertEq(
            afterParams.startBonusWad,
            beforeParams.startBonusWad
        );

        assertEq(
            afterParams.maxBonusWad,
            beforeParams.maxBonusWad
        );

        assertEq(
            afterParams.rampDuration,
            beforeParams.rampDuration
        );
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _configurePool() internal {
        vm.prank(admin);
        config.setLendingPool(pool);
    }
}

/// @notice A simple deployed contract used to test runtime codehash
///         allowlisting. All instances share the same runtime bytecode.
contract AdapterCodeMock {
    function getPrice() external pure returns (uint256) {
        return 1e18;
    }
}