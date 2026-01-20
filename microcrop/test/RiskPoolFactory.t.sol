// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskPoolFactory} from "../src/RiskPoolFactory.sol";
import {RiskPool} from "../src/RiskPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title RiskPoolFactoryTest
 * @notice Comprehensive test suite for RiskPoolFactory contract
 */
contract RiskPoolFactoryTest is Test {
    RiskPoolFactory public factory;
    MockUSDC public usdc;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public investor1 = makeAddr("investor1");
    address public nonAdmin = makeAddr("nonAdmin");

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(admin);
        factory = new RiskPoolFactory(address(usdc), treasury);

        // Fund investor for testing created pools
        usdc.mint(investor1, 1_000_000e6);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsCorrectValues() public view {
        assertEq(factory.USDC(), address(usdc));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.defaultPlatformFee(), 10);
        assertEq(factory.poolCounter(), 0);
    }

    function test_Constructor_GrantsRoles() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(factory.hasRole(factory.ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsWithZeroUSDC() public {
        vm.expectRevert(RiskPoolFactory.ZeroAddress.selector);
        new RiskPoolFactory(address(0), treasury);
    }

    function test_Constructor_RevertsWithZeroTreasury() public {
        vm.expectRevert(RiskPoolFactory.ZeroAddress.selector);
        new RiskPoolFactory(address(usdc), address(0));
    }

    // ============ Create Pool Tests ============

    function test_CreatePool_Success() public {
        vm.prank(admin);
        address poolAddress = factory.createPool(
            "Kenya Maize Drought Q1 2026",
            "mKM-Q1-26",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        assertTrue(poolAddress != address(0));
        assertTrue(factory.isPool(poolAddress));
        assertEq(factory.poolCounter(), 1);
        assertEq(factory.pools(1), poolAddress);
    }

    function test_CreatePool_SetsPoolConfigCorrectly() public {
        vm.prank(admin);
        address poolAddress = factory.createPool(
            "Kenya Maize Drought Q1 2026",
            "mKM-Q1-26",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        RiskPool pool = RiskPool(poolAddress);
        assertEq(pool.poolId(), 1);
        assertEq(pool.poolName(), "Kenya Maize Drought Q1 2026");
        assertEq(pool.symbol(), "mKM-Q1-26");
        assertEq(uint256(pool.coverageType()), uint256(RiskPool.CoverageType.DROUGHT));
        assertEq(pool.region(), "Kenya");
        assertEq(pool.targetCapital(), 500_000e6);
        assertEq(pool.maxCapital(), 2_000_000e6);
        assertEq(pool.platformFeePercent(), 10);
    }

    function test_CreatePool_SetsFundraisingTimesCorrectly() public {
        uint256 startTime = block.timestamp;

        vm.prank(admin);
        address poolAddress = factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        RiskPool pool = RiskPool(poolAddress);
        assertEq(pool.fundraiseStart(), startTime);
        assertEq(pool.fundraiseEnd(), startTime + 14 days);
        assertEq(pool.coverageEnd(), startTime + 14 days + 180 days);
    }

    function test_CreatePool_GrantsTreasuryRole() public {
        vm.prank(admin);
        address poolAddress = factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        RiskPool pool = RiskPool(poolAddress);
        assertTrue(pool.hasRole(pool.TREASURY_ROLE(), treasury));
    }

    function test_CreatePool_IncrementsPoolCounter() public {
        vm.startPrank(admin);

        factory.createPool(
            "Pool 1",
            "P1",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );
        assertEq(factory.poolCounter(), 1);

        factory.createPool(
            "Pool 2",
            "P2",
            RiskPool.CoverageType.FLOOD,
            "Uganda",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );
        assertEq(factory.poolCounter(), 2);

        vm.stopPrank();
    }

    function test_CreatePool_AddsToAllPools() public {
        vm.startPrank(admin);

        address pool1 = factory.createPool(
            "Pool 1",
            "P1",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        address pool2 = factory.createPool(
            "Pool 2",
            "P2",
            RiskPool.CoverageType.FLOOD,
            "Uganda",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        vm.stopPrank();

        address[] memory allPools = factory.getAllPools();
        assertEq(allPools.length, 2);
        assertEq(allPools[0], pool1);
        assertEq(allPools[1], pool2);
    }

    function test_CreatePool_EmitsEvent() public {
        vm.prank(admin);

        vm.expectEmit(true, false, false, true);
        emit RiskPoolFactory.PoolCreated(
            1,
            address(0), // We don't know the address beforehand
            "Test Pool",
            RiskPool.CoverageType.DROUGHT,
            "Kenya"
        );

        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );
    }

    function test_CreatePool_RevertsWithEmptyName() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.EmptyName.selector);
        factory.createPool(
            "",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );
    }

    function test_CreatePool_RevertsWithEmptyRegion() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.EmptyRegion.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );
    }

    function test_CreatePool_RevertsWithTargetCapitalBelowMinimum() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidTargetCapital.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            499_000e6, // Below 500k minimum
            2_000_000e6,
            14 days,
            180 days
        );
    }

    function test_CreatePool_RevertsWithMaxCapitalAboveLimit() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidMaxCapital.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_001e6, // Above 2M limit
            14 days,
            180 days
        );
    }

    function test_CreatePool_RevertsWithTargetAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidTargetCapital.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            1_500_000e6,
            1_000_000e6, // Max below target
            14 days,
            180 days
        );
    }

    function test_CreatePool_RevertsWithFundraiseDurationTooShort() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidFundraiseDuration.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            6 days, // Below 7 day minimum
            180 days
        );
    }

    function test_CreatePool_RevertsWithFundraiseDurationTooLong() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidFundraiseDuration.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            31 days, // Above 30 day maximum
            180 days
        );
    }

    function test_CreatePool_RevertsWithCoverageDurationTooShort() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidCoverageDuration.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            29 days // Below 30 day minimum
        );
    }

    function test_CreatePool_RevertsWithCoverageDurationTooLong() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidCoverageDuration.selector);
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            366 days // Above 365 day maximum
        );
    }

    function test_CreatePool_RevertsWhenUnauthorized() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );
    }

    function test_CreatePool_AllCoverageTypes() public {
        vm.startPrank(admin);

        address pool1 = factory.createPool(
            "Drought Pool",
            "DP",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        address pool2 = factory.createPool(
            "Flood Pool",
            "FP",
            RiskPool.CoverageType.FLOOD,
            "Uganda",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        address pool3 = factory.createPool(
            "Both Pool",
            "BP",
            RiskPool.CoverageType.BOTH,
            "Tanzania",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        vm.stopPrank();

        assertEq(uint256(RiskPool(pool1).coverageType()), uint256(RiskPool.CoverageType.DROUGHT));
        assertEq(uint256(RiskPool(pool2).coverageType()), uint256(RiskPool.CoverageType.FLOOD));
        assertEq(uint256(RiskPool(pool3).coverageType()), uint256(RiskPool.CoverageType.BOTH));
    }

    // ============ Created Pool Functionality Tests ============

    function test_CreatedPool_AcceptsDeposits() public {
        vm.prank(admin);
        address poolAddress = factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        RiskPool pool = RiskPool(poolAddress);

        vm.startPrank(investor1);
        usdc.approve(poolAddress, 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), 100_000e6);
    }

    function test_CreatedPool_IndependentFromOthers() public {
        vm.startPrank(admin);

        address pool1Addr = factory.createPool(
            "Pool 1",
            "P1",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        address pool2Addr = factory.createPool(
            "Pool 2",
            "P2",
            RiskPool.CoverageType.FLOOD,
            "Uganda",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        vm.stopPrank();

        RiskPool pool1 = RiskPool(pool1Addr);
        RiskPool pool2 = RiskPool(pool2Addr);

        // Deposit to pool1 only
        vm.startPrank(investor1);
        usdc.approve(pool1Addr, 100_000e6);
        pool1.deposit(100_000e6);
        vm.stopPrank();

        assertEq(pool1.balanceOf(investor1), 100_000e6);
        assertEq(pool2.balanceOf(investor1), 0);
        assertEq(usdc.balanceOf(pool1Addr), 100_000e6);
        assertEq(usdc.balanceOf(pool2Addr), 0);
    }

    // ============ Set Platform Fee Tests ============

    function test_SetDefaultPlatformFee_Success() public {
        vm.prank(admin);
        factory.setDefaultPlatformFee(15);

        assertEq(factory.defaultPlatformFee(), 15);
    }

    function test_SetDefaultPlatformFee_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RiskPoolFactory.PlatformFeeUpdated(15);
        factory.setDefaultPlatformFee(15);
    }

    function test_SetDefaultPlatformFee_AppliestoNewPools() public {
        vm.prank(admin);
        factory.setDefaultPlatformFee(15);

        vm.prank(admin);
        address poolAddress = factory.createPool(
            "Test Pool",
            "TEST",
            RiskPool.CoverageType.DROUGHT,
            "Kenya",
            500_000e6,
            2_000_000e6,
            14 days,
            180 days
        );

        RiskPool pool = RiskPool(poolAddress);
        assertEq(pool.platformFeePercent(), 15);
    }

    function test_SetDefaultPlatformFee_RevertsBelowMinimum() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidPlatformFee.selector);
        factory.setDefaultPlatformFee(4);
    }

    function test_SetDefaultPlatformFee_RevertsAboveMaximum() public {
        vm.prank(admin);
        vm.expectRevert(RiskPoolFactory.InvalidPlatformFee.selector);
        factory.setDefaultPlatformFee(21);
    }

    function test_SetDefaultPlatformFee_RevertsWhenUnauthorized() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        factory.setDefaultPlatformFee(15);
    }

    function test_SetDefaultPlatformFee_AtBoundaries() public {
        vm.startPrank(admin);

        factory.setDefaultPlatformFee(5);
        assertEq(factory.defaultPlatformFee(), 5);

        factory.setDefaultPlatformFee(20);
        assertEq(factory.defaultPlatformFee(), 20);

        vm.stopPrank();
    }

    // ============ View Function Tests ============

    function test_GetAllPools_ReturnsEmptyInitially() public view {
        address[] memory pools = factory.getAllPools();
        assertEq(pools.length, 0);
    }

    function test_GetAllPools_ReturnsAllCreatedPools() public {
        vm.startPrank(admin);

        address pool1 = factory.createPool(
            "Pool 1", "P1", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        address pool2 = factory.createPool(
            "Pool 2", "P2", RiskPool.CoverageType.FLOOD, "Uganda",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        address pool3 = factory.createPool(
            "Pool 3", "P3", RiskPool.CoverageType.BOTH, "Tanzania",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        vm.stopPrank();

        address[] memory pools = factory.getAllPools();
        assertEq(pools.length, 3);
        assertEq(pools[0], pool1);
        assertEq(pools[1], pool2);
        assertEq(pools[2], pool3);
    }

    function test_GetActivePools_ReturnsOnlyActive() public {
        vm.prank(admin);
        address poolAddr = factory.createPool(
            "Test Pool", "TEST", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        // Before activation
        address[] memory activeBefore = factory.getActivePools();
        assertEq(activeBefore.length, 0);

        // Activate pool
        _fundAndActivatePool(poolAddr);

        // After activation
        address[] memory activeAfter = factory.getActivePools();
        assertEq(activeAfter.length, 1);
        assertEq(activeAfter[0], poolAddr);
    }

    function test_GetPoolsByStatus_FiltersCorrectly() public {
        vm.startPrank(admin);

        address pool1 = factory.createPool(
            "Pool 1", "P1", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        address pool2 = factory.createPool(
            "Pool 2", "P2", RiskPool.CoverageType.FLOOD, "Uganda",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        vm.stopPrank();

        // Both should be FUNDRAISING
        address[] memory fundraising = factory.getPoolsByStatus(RiskPool.PoolStatus.FUNDRAISING);
        assertEq(fundraising.length, 2);

        // Activate pool1
        _fundAndActivatePool(pool1);

        // Check again
        fundraising = factory.getPoolsByStatus(RiskPool.PoolStatus.FUNDRAISING);
        assertEq(fundraising.length, 1);
        assertEq(fundraising[0], pool2);

        address[] memory active = factory.getPoolsByStatus(RiskPool.PoolStatus.ACTIVE);
        assertEq(active.length, 1);
        assertEq(active[0], pool1);
    }

    function test_GetPoolMetadata_ReturnsCorrectData() public {
        vm.prank(admin);
        address poolAddr = factory.createPool(
            "Kenya Maize Q1 2026", "mKM-Q1", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        RiskPoolFactory.PoolMetadata memory metadata = factory.getPoolMetadata(1);

        assertEq(metadata.poolAddress, poolAddr);
        assertEq(metadata.poolId, 1);
        assertEq(metadata.name, "Kenya Maize Q1 2026");
        assertEq(uint256(metadata.coverageType), uint256(RiskPool.CoverageType.DROUGHT));
        assertEq(metadata.region, "Kenya");
        assertEq(metadata.createdAt, block.timestamp);
        assertEq(uint256(metadata.status), uint256(RiskPool.PoolStatus.FUNDRAISING));
    }

    function test_GetPoolMetadata_RevertsForNonExistent() public {
        vm.expectRevert(RiskPoolFactory.PoolNotFound.selector);
        factory.getPoolMetadata(999);
    }

    function test_GetPoolById_ReturnsCorrectAddress() public {
        vm.prank(admin);
        address poolAddr = factory.createPool(
            "Test Pool", "TEST", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        assertEq(factory.getPoolById(1), poolAddr);
    }

    function test_GetPoolById_ReturnsZeroForNonExistent() public view {
        assertEq(factory.getPoolById(999), address(0));
    }

    function test_GetPoolCount_ReturnsCorrectCount() public {
        assertEq(factory.getPoolCount(), 0);

        vm.startPrank(admin);

        factory.createPool(
            "Pool 1", "P1", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );
        assertEq(factory.getPoolCount(), 1);

        factory.createPool(
            "Pool 2", "P2", RiskPool.CoverageType.FLOOD, "Uganda",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );
        assertEq(factory.getPoolCount(), 2);

        vm.stopPrank();
    }

    function test_IsValidPool_ReturnsCorrectly() public {
        vm.prank(admin);
        address poolAddr = factory.createPool(
            "Test Pool", "TEST", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, 14 days, 180 days
        );

        assertTrue(factory.isValidPool(poolAddr));
        assertFalse(factory.isValidPool(address(0x1234)));
    }

    // ============ Fuzz Tests ============

    function testFuzz_CreatePool_ValidDurations(
        uint256 fundraiseDuration,
        uint256 coverageDuration
    ) public {
        fundraiseDuration = bound(fundraiseDuration, 7 days, 30 days);
        coverageDuration = bound(coverageDuration, 30 days, 365 days);

        vm.prank(admin);
        address poolAddr = factory.createPool(
            "Test Pool", "TEST", RiskPool.CoverageType.DROUGHT, "Kenya",
            500_000e6, 2_000_000e6, fundraiseDuration, coverageDuration
        );

        RiskPool pool = RiskPool(poolAddr);
        assertEq(pool.fundraiseEnd() - pool.fundraiseStart(), fundraiseDuration);
    }

    function testFuzz_CreatePool_ValidCapitals(
        uint256 targetCapital,
        uint256 maxCapital
    ) public {
        targetCapital = bound(targetCapital, 500_000e6, 2_000_000e6);
        maxCapital = bound(maxCapital, targetCapital, 2_000_000e6);

        vm.prank(admin);
        address poolAddr = factory.createPool(
            "Test Pool", "TEST", RiskPool.CoverageType.DROUGHT, "Kenya",
            targetCapital, maxCapital, 14 days, 180 days
        );

        RiskPool pool = RiskPool(poolAddr);
        assertEq(pool.targetCapital(), targetCapital);
        assertEq(pool.maxCapital(), maxCapital);
    }

    // ============ Helper Functions ============

    function _fundAndActivatePool(address poolAddr) internal {
        RiskPool pool = RiskPool(poolAddr);

        // Create investors and fund to target
        for (uint256 i = 0; i < 5; i++) {
            address investor = makeAddr(string(abi.encodePacked("funder", i)));
            usdc.mint(investor, 100_000e6);
            vm.startPrank(investor);
            usdc.approve(poolAddr, 100_000e6);
            pool.deposit(100_000e6);
            vm.stopPrank();
        }

        // Fast forward past fundraising
        vm.warp(block.timestamp + 15 days);
        
        // The RiskPool constructor grants DEFAULT_ADMIN_ROLE to msg.sender (factory)
        // and ADMIN_ROLE to msg.sender (factory)
        // So the factory address has ADMIN_ROLE and can activate the pool
        // We can call activatePool from the factory, but factory has no such function
        // So we need to grant ADMIN_ROLE to our admin address first
        
        // Cache the role before prank (view calls can consume prank in some scenarios)
        bytes32 adminRole = pool.ADMIN_ROLE();
        
        // Factory has DEFAULT_ADMIN_ROLE on the pool, so it can grant ADMIN_ROLE
        vm.prank(address(factory));
        pool.grantRole(adminRole, admin);
        
        vm.prank(admin);
        pool.activatePool();
    }
}
