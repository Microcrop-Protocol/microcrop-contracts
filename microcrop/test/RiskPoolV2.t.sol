// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {RiskPoolV2} from "../src/RiskPoolV2.sol";
import {RiskPoolFactoryV2} from "../src/RiskPoolFactoryV2.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title RiskPoolV2Test
 * @notice Comprehensive tests for RiskPoolV2 institutional LP token model
 */
contract RiskPoolV2Test is Test {
    MockUSDC public usdc;
    RiskPoolV2 public publicPool;
    RiskPoolV2 public privatePool;
    RiskPoolV2 public mutualPool;
    RiskPoolFactoryV2 public factory;

    address public admin = address(1);
    address public treasury = address(2);
    address public protocolTreasury = address(3);
    address public institutionOwner = address(4);
    address public cooperativeOwner = address(5);
    address public productBuilder = address(6);
    address public distributor = address(7);

    address public investor1 = address(10);
    address public investor2 = address(11);
    address public investor3 = address(12);
    address public institutionLP = address(13);
    address public member1 = address(14);
    address public member2 = address(15);

    uint256 public constant PRECISION = 1e18;

    function setUp() public {
        // Deploy USDC (no prank needed, test contract deploys)
        usdc = new MockUSDC();

        // Deploy factory (test contract is admin)
        factory = new RiskPoolFactoryV2(
            address(usdc),
            treasury,
            protocolTreasury
        );

        // Set default distributor
        factory.setDefaultDistributor(distributor);

        // Create PUBLIC pool
        address publicPoolAddr = factory.createPublicPool(
            RiskPoolFactoryV2.PublicPoolParams({
                name: "Kenya Maize Drought Pool",
                symbol: "mcMAIZE-D",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                targetCapital: 500_000e6,
                maxCapital: 2_000_000e6
            })
        );
        publicPool = RiskPoolV2(publicPoolAddr);

        // Create PRIVATE pool (UAP example)
        address privatePoolAddr = factory.createPrivatePool(
            RiskPoolFactoryV2.PrivatePoolParams({
                name: "UAP Risk Pool",
                symbol: "uapUAP",
                coverageType: RiskPoolV2.CoverageType.BOTH,
                region: "Kenya",
                poolOwner: institutionOwner,
                minDeposit: 250_000e6,
                maxDeposit: 5_000_000e6,
                targetCapital: 1_000_000e6,
                maxCapital: 10_000_000e6,
                productBuilder: productBuilder
            })
        );
        privatePool = RiskPoolV2(privatePoolAddr);

        // Create MUTUAL pool (KFA example)
        address mutualPoolAddr = factory.createMutualPool(
            RiskPoolFactoryV2.MutualPoolParams({
                name: "KFA Mutual Pool",
                symbol: "kfaKFA",
                coverageType: RiskPoolV2.CoverageType.DROUGHT,
                region: "Kenya",
                poolOwner: cooperativeOwner,
                memberContribution: 50e6, // $50 fixed contribution
                targetCapital: 100_000e6,
                maxCapital: 500_000e6
            })
        );
        mutualPool = RiskPoolV2(mutualPoolAddr);

        // Fund test accounts
        usdc.mint(investor1, 1_000_000e6);
        usdc.mint(investor2, 1_000_000e6);
        usdc.mint(investor3, 1_000_000e6);
        usdc.mint(institutionOwner, 10_000_000e6);
        usdc.mint(institutionLP, 5_000_000e6);
        usdc.mint(member1, 10_000e6);
        usdc.mint(member2, 10_000e6);
        usdc.mint(treasury, 10_000_000e6);
    }

    // ============ Pool Type Tests ============

    function test_PublicPool_Configuration() public view {
        assertEq(uint256(publicPool.poolType()), uint256(RiskPoolV2.PoolType.PUBLIC));
        assertEq(publicPool.poolOwner(), address(0));
        assertEq(publicPool.minDeposit(), 100e6); // $100
        assertEq(publicPool.maxDeposit(), 100_000e6); // $100K
        assertTrue(publicPool.depositsOpen());
        assertTrue(publicPool.withdrawalsOpen());
    }

    function test_PrivatePool_Configuration() public view {
        assertEq(uint256(privatePool.poolType()), uint256(RiskPoolV2.PoolType.PRIVATE));
        assertEq(privatePool.poolOwner(), institutionOwner);
        assertEq(privatePool.minDeposit(), 250_000e6); // $250K
        assertEq(privatePool.maxDeposit(), 5_000_000e6); // $5M
        assertEq(privatePool.productBuilder(), productBuilder);
        assertFalse(privatePool.depositsOpen()); // Closed by default for private
    }

    function test_MutualPool_Configuration() public view {
        assertEq(uint256(mutualPool.poolType()), uint256(RiskPoolV2.PoolType.MUTUAL));
        assertEq(mutualPool.poolOwner(), cooperativeOwner);
        assertEq(mutualPool.minDeposit(), 50e6); // $50
        assertEq(mutualPool.maxDeposit(), 50e6); // Fixed contribution
        assertEq(mutualPool.productBuilder(), cooperativeOwner);
        assertEq(mutualPool.defaultDistributor(), cooperativeOwner);
    }

    // ============ Public Pool Deposit/Withdraw Tests ============

    function test_PublicPool_Deposit() public {
        uint256 depositAmount = 10_000e6; // $10K

        vm.startPrank(investor1);
        usdc.approve(address(publicPool), depositAmount);
        publicPool.deposit(depositAmount);
        vm.stopPrank();

        // Check tokens minted (should be ~10K at 1:1 initial price)
        uint256 tokenBalance = publicPool.balanceOf(investor1);
        assertGt(tokenBalance, 0);

        // Token price should be 1e18 (1.00)
        assertEq(publicPool.getTokenPrice(), PRECISION);

        // Pool value should match deposit
        assertEq(publicPool.getPoolValue(), depositAmount);
    }

    function test_PublicPool_Deposit_BelowMinimum_Reverts() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 50e6);
        vm.expectRevert(RiskPoolV2.BelowMinimumDeposit.selector);
        publicPool.deposit(50e6); // $50 < $100 min
        vm.stopPrank();
    }

    function test_PublicPool_MultipleDeposits_NAVBased() public {
        // Investor 1 deposits first
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6); // $100K
        vm.stopPrank();

        uint256 investor1Tokens = publicPool.balanceOf(investor1);
        uint256 priceAfterFirst = publicPool.getTokenPrice();

        // Simulate premium collection (increases pool value)
        // Test contract has admin role from factory
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        vm.startPrank(treasury);
        usdc.approve(address(publicPool), 10_000e6);
        publicPool.collectPremium(1, 10_000e6, distributor);
        vm.stopPrank();

        // Token price should have increased (70% of premium stays in pool)
        uint256 newPrice = publicPool.getTokenPrice();
        assertGt(newPrice, priceAfterFirst);

        // Investor 2 deposits at new NAV
        vm.startPrank(investor2);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        uint256 investor2Tokens = publicPool.balanceOf(investor2);

        // Investor 2 should receive fewer tokens (higher price)
        assertLt(investor2Tokens, investor1Tokens);

        // But token price should remain stable after deposit
        uint256 priceAfterSecond = publicPool.getTokenPrice();
        assertApproxEqRel(priceAfterSecond, newPrice, 0.01e18); // Within 1%
    }

    function test_PublicPool_Withdraw() public {
        // First deposit
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);

        uint256 tokenBalance = publicPool.balanceOf(investor1);
        uint256 initialPoolValue = publicPool.getPoolValue();

        // Withdraw half
        uint256 withdrawTokens = tokenBalance / 2;
        publicPool.withdraw(withdrawTokens);
        vm.stopPrank();

        // Check USDC received (should be ~$50K at 1:1)
        uint256 usdcBalance = usdc.balanceOf(investor1);
        assertGt(usdcBalance, 900_000e6); // Had 1M, deposited 100K, got back ~50K

        // Pool value should decrease
        assertLt(publicPool.getPoolValue(), initialPoolValue);

        // Token price should remain stable
        assertEq(publicPool.getTokenPrice(), PRECISION);
    }

    function test_PublicPool_Withdraw_InsufficientLiquidity_Reverts() public {
        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        // Add exposure (simulates active policies)
        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        vm.prank(treasury);
        publicPool.updateExposure(1, int256(90_000e6)); // 90K exposure

        // Try to withdraw more than available liquidity
        uint256 tokenBalance = publicPool.balanceOf(investor1);

        vm.startPrank(investor1);
        vm.expectRevert(RiskPoolV2.InsufficientLiquidity.selector);
        publicPool.withdraw(tokenBalance); // Can't withdraw all with high exposure
        vm.stopPrank();
    }

    // ============ Private Pool Tests ============

    function test_PrivatePool_Deposit_RequiresDepositorRole() public {
        // Enable deposits
        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(true);

        // Non-whitelisted investor cannot deposit
        vm.startPrank(investor1);
        usdc.approve(address(privatePool), 500_000e6);
        vm.expectRevert(RiskPoolV2.NotAuthorized.selector);
        privatePool.deposit(500_000e6);
        vm.stopPrank();

        // Whitelist the institution LP
        vm.prank(institutionOwner);
        privatePool.addDepositor(institutionLP);

        // Now can deposit
        vm.startPrank(institutionLP);
        usdc.approve(address(privatePool), 500_000e6);
        privatePool.deposit(500_000e6);
        vm.stopPrank();

        assertGt(privatePool.balanceOf(institutionLP), 0);
    }

    function test_PrivatePool_OwnerDeposit() public {
        // Enable deposits
        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(true);

        // Owner already has depositor role
        vm.startPrank(institutionOwner);
        usdc.approve(address(privatePool), 4_000_000e6);
        privatePool.deposit(4_000_000e6); // 80% ownership like UAP example
        vm.stopPrank();

        assertEq(privatePool.balanceOf(institutionOwner), 4_000_000e6 * PRECISION / PRECISION);
    }

    function test_PrivatePool_HighMinimum() public {
        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(true);

        vm.prank(institutionOwner);
        privatePool.addDepositor(institutionLP);

        vm.startPrank(institutionLP);
        usdc.approve(address(privatePool), 100_000e6);
        vm.expectRevert(RiskPoolV2.BelowMinimumDeposit.selector);
        privatePool.deposit(100_000e6); // $100K < $250K min
        vm.stopPrank();
    }

    // ============ Mutual Pool Tests ============

    function test_MutualPool_FixedContribution() public {
        // Enable deposits
        vm.prank(cooperativeOwner);
        mutualPool.setDepositsOpen(true);

        // Whitelist members
        vm.startPrank(cooperativeOwner);
        mutualPool.addDepositor(member1);
        mutualPool.addDepositor(member2);
        vm.stopPrank();

        // Members deposit fixed amount
        vm.startPrank(member1);
        usdc.approve(address(mutualPool), 50e6);
        mutualPool.deposit(50e6);
        vm.stopPrank();

        assertGt(mutualPool.balanceOf(member1), 0);

        // Cannot deposit more than fixed amount
        vm.startPrank(member2);
        usdc.approve(address(mutualPool), 100e6);
        vm.expectRevert(RiskPoolV2.ExceedsMaximumDeposit.selector);
        mutualPool.deposit(100e6); // $100 > $50 max
        vm.stopPrank();
    }

    // ============ Premium Collection Tests ============

    function test_PremiumCollection_RevenueDistribution() public {
        // Setup: deposit to pool
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        // Grant treasury role (test contract has admin)
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        uint256 grossPremium = 10_000e6; // $10K premium
        uint256 protocolBalanceBefore = usdc.balanceOf(protocolTreasury);
        uint256 distributorBalanceBefore = usdc.balanceOf(distributor);
        uint256 poolValueBefore = publicPool.getPoolValue();

        // Collect premium
        vm.startPrank(treasury);
        usdc.approve(address(publicPool), grossPremium);
        publicPool.collectPremium(1, grossPremium, distributor);
        vm.stopPrank();

        // Check distribution (70% LP, 12% builder, 10% protocol, 8% distributor)
        // No builder for public pool, so that 12% stays in pool
        uint256 lpShare = (grossPremium * 7000) / 10000; // 70%
        uint256 builderShare = (grossPremium * 1200) / 10000; // 12% (stays in pool)
        uint256 protocolShare = (grossPremium * 1000) / 10000; // 10%
        uint256 distributorShare = (grossPremium * 800) / 10000; // 8%

        // Pool should have LP share + builder share (no builder set)
        assertEq(
            publicPool.getPoolValue(),
            poolValueBefore + lpShare + builderShare
        );

        // Protocol treasury should receive 10%
        assertEq(
            usdc.balanceOf(protocolTreasury),
            protocolBalanceBefore + protocolShare
        );

        // Distributor should receive 8%
        assertEq(
            usdc.balanceOf(distributor),
            distributorBalanceBefore + distributorShare
        );
    }

    function test_PrivatePool_PremiumDistribution_WithBuilder() public {
        // Setup private pool with deposits
        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(true);

        vm.startPrank(institutionOwner);
        usdc.approve(address(privatePool), 4_000_000e6);
        privatePool.deposit(4_000_000e6);
        vm.stopPrank();

        // Grant treasury role (test contract has admin via factory)
        privatePool.grantRole(privatePool.TREASURY_ROLE(), treasury);

        uint256 grossPremium = 100_000e6; // $100K premium
        uint256 builderBalanceBefore = usdc.balanceOf(productBuilder);
        uint256 protocolBalanceBefore = usdc.balanceOf(protocolTreasury);

        // Collect premium
        vm.startPrank(treasury);
        usdc.approve(address(privatePool), grossPremium);
        privatePool.collectPremium(1, grossPremium, address(0)); // No distributor for private
        vm.stopPrank();

        // Builder should receive 12%
        uint256 builderShare = (grossPremium * 1200) / 10000;
        assertEq(
            usdc.balanceOf(productBuilder),
            builderBalanceBefore + builderShare
        );

        // Protocol should receive 10%
        uint256 protocolShare = (grossPremium * 1000) / 10000;
        assertEq(
            usdc.balanceOf(protocolTreasury),
            protocolBalanceBefore + protocolShare
        );
    }

    // ============ Payout Tests ============

    function test_PayoutProcessing() public {
        // Setup
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        uint256 poolValueBefore = publicPool.getPoolValue();
        uint256 tokenPriceBefore = publicPool.getTokenPrice();

        // Process payout
        uint256 payoutAmount = 20_000e6;
        vm.prank(treasury);
        publicPool.processPayout(1, payoutAmount);

        // Pool value should decrease
        assertEq(publicPool.getPoolValue(), poolValueBefore - payoutAmount);

        // Token price should decrease (loss)
        assertLt(publicPool.getTokenPrice(), tokenPriceBefore);

        // Total payouts tracked
        assertEq(publicPool.totalPayouts(), payoutAmount);
    }

    // ============ Token Price Tests ============

    function test_TokenPrice_IncreasesWithPremiums() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        uint256 initialPrice = publicPool.getTokenPrice();

        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        // Collect premium
        vm.startPrank(treasury);
        usdc.approve(address(publicPool), 10_000e6);
        publicPool.collectPremium(1, 10_000e6, distributor);
        vm.stopPrank();

        // Price should increase
        assertGt(publicPool.getTokenPrice(), initialPrice);
    }

    function test_TokenPrice_DecreasesWithPayouts() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        uint256 initialPrice = publicPool.getTokenPrice();

        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        // Process payout
        vm.prank(treasury);
        publicPool.processPayout(1, 10_000e6);

        // Price should decrease
        assertLt(publicPool.getTokenPrice(), initialPrice);
    }

    function test_TokenPrice_NoSupply_Returns1() public view {
        // Empty pool should return 1.00
        assertEq(publicPool.getTokenPrice(), PRECISION);
    }

    // ============ Investor Info Tests ============

    function test_GetInvestorInfo() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        (
            uint256 deposited,
            uint256 tokensHeld,
            uint256 currentValue,
            int256 roi
        ) = publicPool.getInvestorInfo(investor1);

        assertEq(deposited, 100_000e6);
        assertGt(tokensHeld, 0);
        assertApproxEqRel(currentValue, 100_000e6, 0.01e18);
        assertEq(roi, 0); // No gains/losses yet
    }

    function test_GetInvestorInfo_WithProfit() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        // Add profit via premium
        vm.startPrank(treasury);
        usdc.approve(address(publicPool), 20_000e6);
        publicPool.collectPremium(1, 20_000e6, distributor);
        vm.stopPrank();

        (, , uint256 currentValue, int256 roi) = publicPool.getInvestorInfo(investor1);

        assertGt(currentValue, 100_000e6);
        assertGt(roi, 0); // Positive ROI
    }

    // ============ Exposure Tests ============

    function test_ExposureTracking() public {
        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        // Add exposure for new policies
        vm.prank(treasury);
        publicPool.updateExposure(1, int256(50_000e6));
        assertEq(publicPool.activeExposure(), 50_000e6);

        vm.prank(treasury);
        publicPool.updateExposure(2, int256(30_000e6));
        assertEq(publicPool.activeExposure(), 80_000e6);

        // Remove exposure when policy expires
        vm.prank(treasury);
        publicPool.updateExposure(1, -int256(50_000e6));
        assertEq(publicPool.activeExposure(), 30_000e6);
    }

    function test_AvailableLiquidity() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        // Test contract has admin role
        publicPool.grantRole(publicPool.TREASURY_ROLE(), treasury);

        // No exposure = full liquidity
        assertEq(publicPool.getAvailableLiquidity(), 100_000e6);

        // Add exposure
        vm.prank(treasury);
        publicPool.updateExposure(1, int256(50_000e6));

        // Liquidity = pool - (exposure * 1.2)
        // 100K - 60K = 40K available
        assertEq(publicPool.getAvailableLiquidity(), 40_000e6);
    }

    // ============ Admin Functions Tests ============

    function test_SetDepositsOpen() public {
        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(true);
        assertTrue(privatePool.depositsOpen());

        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(false);
        assertFalse(privatePool.depositsOpen());
    }

    function test_SetWithdrawalsOpen() public {
        vm.prank(institutionOwner);
        privatePool.setWithdrawalsOpen(true);
        assertTrue(privatePool.withdrawalsOpen());

        vm.prank(institutionOwner);
        privatePool.setWithdrawalsOpen(false);
        assertFalse(privatePool.withdrawalsOpen());
    }

    function test_AddRemoveDepositor() public {
        vm.prank(institutionOwner);
        privatePool.addDepositor(investor1);
        assertTrue(privatePool.hasRole(privatePool.DEPOSITOR_ROLE(), investor1));

        vm.prank(institutionOwner);
        privatePool.removeDepositor(investor1);
        assertFalse(privatePool.hasRole(privatePool.DEPOSITOR_ROLE(), investor1));
    }

    function test_Pause_BlocksDeposits() public {
        // Grant ADMIN_ROLE to test contract (we have DEFAULT_ADMIN_ROLE)
        publicPool.grantRole(publicPool.ADMIN_ROLE(), address(this));
        publicPool.pause();

        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 10_000e6);
        vm.expectRevert();
        publicPool.deposit(10_000e6);
        vm.stopPrank();
    }

    // ============ Pool Summary Tests ============

    function test_GetPoolSummary() public {
        vm.startPrank(investor1);
        usdc.approve(address(publicPool), 100_000e6);
        publicPool.deposit(100_000e6);
        vm.stopPrank();

        (
            uint256 poolValue,
            uint256 supply,
            uint256 tokenPrice,
            uint256 premiums,
            uint256 payouts,
            uint256 exposure
        ) = publicPool.getPoolSummary();

        assertEq(poolValue, 100_000e6);
        assertGt(supply, 0);
        assertEq(tokenPrice, PRECISION);
        assertEq(premiums, 0);
        assertEq(payouts, 0);
        assertEq(exposure, 0);
    }

    // ============ Can Deposit Tests ============

    function test_CanDeposit_PublicPool() public view {
        assertTrue(publicPool.canDeposit(investor1));
        assertTrue(publicPool.canDeposit(investor2));
    }

    function test_CanDeposit_PrivatePool() public {
        assertFalse(privatePool.canDeposit(investor1)); // Deposits closed

        vm.prank(institutionOwner);
        privatePool.setDepositsOpen(true);

        assertFalse(privatePool.canDeposit(investor1)); // Not whitelisted

        vm.prank(institutionOwner);
        privatePool.addDepositor(investor1);

        assertTrue(privatePool.canDeposit(investor1)); // Now can deposit
    }
}
