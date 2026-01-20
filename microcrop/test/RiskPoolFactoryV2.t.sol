// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {RiskPoolV2} from "../src/RiskPoolV2.sol";
import {RiskPoolFactoryV2} from "../src/RiskPoolFactoryV2.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title RiskPoolFactoryV2Test
 * @notice Tests for RiskPoolFactoryV2 pool creation and management
 */
contract RiskPoolFactoryV2Test is Test {
    MockUSDC public usdc;
    RiskPoolFactoryV2 public factory;

    address public admin = address(1);
    address public treasury = address(2);
    address public protocolTreasury = address(3);
    address public institution1 = address(4);
    address public institution2 = address(5);
    address public cooperative1 = address(6);
    address public distributor = address(7);

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();
        factory = new RiskPoolFactoryV2(
            address(usdc),
            treasury,
            protocolTreasury
        );

        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(factory.USDC(), address(usdc));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.protocolTreasury(), protocolTreasury);
        assertEq(factory.poolCounter(), 0);
    }

    function test_Constructor_ZeroAddress_Reverts() public {
        vm.expectRevert(RiskPoolFactoryV2.ZeroAddress.selector);
        new RiskPoolFactoryV2(address(0), treasury, protocolTreasury);

        vm.expectRevert(RiskPoolFactoryV2.ZeroAddress.selector);
        new RiskPoolFactoryV2(address(usdc), address(0), protocolTreasury);

        vm.expectRevert(RiskPoolFactoryV2.ZeroAddress.selector);
        new RiskPoolFactoryV2(address(usdc), treasury, address(0));
    }

    // ============ Public Pool Creation Tests ============

    function test_CreatePublicPool() public {
        vm.prank(admin);
        address poolAddr = factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Kenya Maize Drought Pool",
                symbol: "mcMAIZE-D",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        RiskPoolV2 pool = RiskPoolV2(poolAddr);

        assertEq(pool.name(), "Kenya Maize Drought Pool");
        assertEq(pool.symbol(), "mcMAIZE-D");
        assertEq(uint256(pool.poolType()), uint256(RiskPoolV2.PoolType.PUBLIC));
        assertEq(pool.poolOwner(), address(0));
        assertEq(pool.minDeposit(), 100e6);
        assertEq(pool.maxDeposit(), 100_000e6);
        assertEq(pool.protocolTreasury(), protocolTreasury);
        assertTrue(pool.depositsOpen());
        assertTrue(pool.withdrawalsOpen());

        // Check registry
        assertTrue(factory.isValidPool(poolAddr));
        assertEq(factory.getPoolCount(), 1);
        assertEq(factory.getPoolById(1), poolAddr);
    }

    function test_CreatePublicPool_MultipleTypes() public {
        vm.startPrank(admin);

        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Maize Drought",
                symbol: "mcMAIZE-D",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Beans Flood",
                symbol: "mcBEANS-F",
                coverageType: RiskPoolV2.CoverageType.FLOOD,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Multi Crop",
                symbol: "mcMULTI",
                coverageType: RiskPoolV2.CoverageType.BOTH,
                region: "Uganda",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        vm.stopPrank();

        assertEq(factory.getPoolCount(), 3);

        address[] memory publicPools = factory.getPublicPools();
        assertEq(publicPools.length, 3);
    }

    function test_CreatePublicPool_InvalidParams_Reverts() public {
        vm.startPrank(admin);

        // Empty name
        vm.expectRevert(RiskPoolFactoryV2.EmptyName.selector);
        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "",
                symbol: "mcTEST",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        // Empty symbol
        vm.expectRevert(RiskPoolFactoryV2.EmptySymbol.selector);
        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Test Pool",
                symbol: "",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        // Target capital too low
        vm.expectRevert(RiskPoolFactoryV2.InvalidTargetCapital.selector);
        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Test Pool",
                symbol: "mcTEST",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 10_000e6, // Below $100K minimum
                maxCapital: 2_000_000e6
            })
        );

        // Max capital too high
        vm.expectRevert(RiskPoolFactoryV2.InvalidMaxCapital.selector);
        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Test Pool",
                symbol: "mcTEST",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 100_000_000e6 // Above $50M maximum
            })
        );

        vm.stopPrank();
    }

    // ============ Private Pool Creation Tests ============

    function test_CreatePrivatePool() public {
        vm.prank(admin);
        address poolAddr = factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "UAP Risk Pool",
                symbol: "uapUAP",
                coverageType: RiskPoolV2.CoverageType.BOTH,
                region: "Kenya",
                poolOwner: institution1,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution1
            })
        );

        RiskPoolV2 pool = RiskPoolV2(poolAddr);

        assertEq(pool.name(), "UAP Risk Pool");
        assertEq(pool.symbol(), "uapUAP");
        assertEq(uint256(pool.poolType()), uint256(RiskPoolV2.PoolType.PRIVATE));
        assertEq(pool.poolOwner(), institution1);
        assertEq(pool.minDeposit(), 250_000e6);
        assertEq(pool.maxDeposit(), 5_000_000e6);
        assertEq(pool.productBuilder(), institution1);
        assertFalse(pool.depositsOpen()); // Closed by default

        // Owner has admin role
        assertTrue(pool.hasRole(pool.ADMIN_ROLE(), institution1));

        // Owner is whitelisted as depositor
        assertTrue(pool.hasRole(pool.DEPOSITOR_ROLE(), institution1));

        // Check registry
        address[] memory privatePools = factory.getPrivatePools();
        assertEq(privatePools.length, 1);

        address[] memory ownerPools = factory.getPoolsByOwner(institution1);
        assertEq(ownerPools.length, 1);
    }

    function test_CreatePrivatePool_SeparateBuilder() public {
        address externalBuilder = address(100);

        vm.prank(admin);
        address poolAddr = factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "Britam Pool",
                symbol: "britamBRITAM",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: institution1,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: externalBuilder
            })
        );

        RiskPoolV2 pool = RiskPoolV2(poolAddr);
        assertEq(pool.productBuilder(), externalBuilder);
    }

    function test_CreatePrivatePool_InvalidParams_Reverts() public {
        vm.startPrank(admin);

        // Zero owner
        vm.expectRevert(RiskPoolFactoryV2.ZeroAddress.selector);
        factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "Test Pool",
                symbol: "test",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: address(0),
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution1
            })
        );

        // Min deposit too low
        vm.expectRevert(RiskPoolFactoryV2.InvalidMinDeposit.selector);
        factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "Test Pool",
                symbol: "test",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: institution1,
                minDeposit: 100_000e6, // Below $250K
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution1
            })
        );

        vm.stopPrank();
    }

    // ============ Mutual Pool Creation Tests ============

    function test_CreateMutualPool() public {
        vm.prank(admin);
        address poolAddr = factory.createMutualPool(
            RiskPoolFactoryV2.MutualPoolParams({
                name: "KFA Mutual Pool",
                symbol: "kfaKFA",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: cooperative1,
                memberContribution: 50e6, // $50 fixed
                targetCapital: 100_000e6,
                maxCapital: 500_000e6
            })
        );

        RiskPoolV2 pool = RiskPoolV2(poolAddr);

        assertEq(pool.name(), "KFA Mutual Pool");
        assertEq(pool.symbol(), "kfaKFA");
        assertEq(uint256(pool.poolType()), uint256(RiskPoolV2.PoolType.MUTUAL));
        assertEq(pool.poolOwner(), cooperative1);
        assertEq(pool.minDeposit(), 50e6);
        assertEq(pool.maxDeposit(), 50e6); // Fixed contribution
        assertEq(pool.productBuilder(), cooperative1);
        assertEq(pool.defaultDistributor(), cooperative1);

        // Check registry
        address[] memory mutualPools = factory.getMutualPools();
        assertEq(mutualPools.length, 1);
    }

    // ============ Registry Tests ============

    function test_GetPoolsByType() public {
        vm.startPrank(admin);

        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Public 1",
                symbol: "mc1",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Public 2",
                symbol: "mc2",
                coverageType: RiskPoolV2.CoverageType.FLOOD,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "Private 1",
                symbol: "priv1",
                coverageType: RiskPoolV2.CoverageType.BOTH,
                region: "Kenya",
                poolOwner: institution1,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution1
            })
        );

        factory.createMutualPool(
            RiskPoolFactoryV2.MutualPoolParams({
                name: "Mutual 1",
                symbol: "mut1",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: cooperative1,
                memberContribution: 50e6,
                targetCapital: 100_000e6,
                maxCapital: 500_000e6
            })
        );

        vm.stopPrank();

        (uint256 publicCount, uint256 privateCount, uint256 mutualCount) = factory.getPoolCountsByType();
        assertEq(publicCount, 2);
        assertEq(privateCount, 1);
        assertEq(mutualCount, 1);

        assertEq(factory.getAllPools().length, 4);
    }

    function test_GetPoolsByOwner() public {
        vm.startPrank(admin);

        factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "UAP Pool 1",
                symbol: "uap1",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: institution1,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution1
            })
        );

        factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "UAP Pool 2",
                symbol: "uap2",
                coverageType: RiskPoolV2.CoverageType.FLOOD,
                region: "Uganda",
                poolOwner: institution1,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution1
            })
        );

        factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "Britam Pool",
                symbol: "brit1",
                coverageType: RiskPoolV2.CoverageType.BOTH,
                region: "Kenya",
                poolOwner: institution2,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: institution2
            })
        );

        vm.stopPrank();

        address[] memory inst1Pools = factory.getPoolsByOwner(institution1);
        assertEq(inst1Pools.length, 2);

        address[] memory inst2Pools = factory.getPoolsByOwner(institution2);
        assertEq(inst2Pools.length, 1);
    }

    function test_GetPoolMetadata() public {
        vm.prank(admin);
        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Kenya Maize Pool",
                symbol: "mcMAIZE",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        RiskPoolFactoryV2.PoolMetadata memory metadata = factory.getPoolMetadata(1);

        assertEq(metadata.poolId, 1);
        assertEq(metadata.name, "Kenya Maize Pool");
        assertEq(uint256(metadata.poolType), uint256(RiskPoolV2.PoolType.PUBLIC));
        assertEq(uint256(metadata.coverageType), uint256(RiskPoolV2.CoverageType.DROUGHT));
        assertEq(metadata.region, "Kenya");
        assertEq(metadata.poolOwner, address(0));
    }

    function test_GetPoolMetadata_NotFound_Reverts() public {
        vm.expectRevert(RiskPoolFactoryV2.PoolNotFound.selector);
        factory.getPoolMetadata(999);
    }

    // ============ Admin Functions Tests ============

    function test_SetDefaultDistributor() public {
        vm.prank(admin);
        factory.setDefaultDistributor(distributor);

        assertEq(factory.defaultDistributor(), distributor);

        // New public pools use this distributor
        vm.prank(admin);
        address poolAddr = factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Test Pool",
                symbol: "mcTEST",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        RiskPoolV2 pool = RiskPoolV2(poolAddr);
        assertEq(pool.defaultDistributor(), distributor);
    }

    function test_OnlyAdminCanCreatePools() public {
        address randomUser = address(999);

        vm.startPrank(randomUser);

        vm.expectRevert();
        factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Test Pool",
                symbol: "mcTEST",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        vm.stopPrank();
    }

    // ============ Treasury Role Tests ============

    function test_TreasuryRoleGranted() public {
        vm.prank(admin);
        address poolAddr = factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Test Pool",
                symbol: "mcTEST",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );

        RiskPoolV2 pool = RiskPoolV2(poolAddr);
        assertTrue(pool.hasRole(pool.TREASURY_ROLE(), treasury));
    }
}
