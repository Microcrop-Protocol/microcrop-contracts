// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskPool} from "../src/RiskPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title RiskPoolTest
 * @notice Comprehensive test suite for RiskPool ERC20 token contract
 */
contract RiskPoolTest is Test {
    RiskPool public pool;
    MockUSDC public usdc;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public investor1 = makeAddr("investor1");
    address public investor2 = makeAddr("investor2");
    address public investor3 = makeAddr("investor3");

    uint256 public constant TARGET_CAPITAL = 500_000e6;
    uint256 public constant MAX_CAPITAL = 2_000_000e6;
    uint256 public constant MIN_INVESTMENT = 1_000e6;
    uint256 public constant MAX_INVESTMENT = 100_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        // Create pool configuration
        RiskPool.PoolConfig memory config = RiskPool.PoolConfig({
            usdc: address(usdc),
            poolId: 1,
            name: "Kenya Maize Drought Q1 2026",
            symbol: "mKM-Q1-26",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: TARGET_CAPITAL,
            maxCapital: MAX_CAPITAL,
            fundraiseStart: block.timestamp,
            fundraiseEnd: block.timestamp + 14 days,
            coverageEnd: block.timestamp + 14 days + 180 days,
            platformFeePercent: 10
        });

        vm.startPrank(admin);
        pool = new RiskPool(config);

        // Grant treasury role
        pool.grantRole(pool.TREASURY_ROLE(), treasury);
        vm.stopPrank();

        // Fund investors
        usdc.mint(investor1, 100_000e6);
        usdc.mint(investor2, 100_000e6);
        usdc.mint(investor3, 100_000e6);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsCorrectValues() public view {
        assertEq(address(pool.USDC()), address(usdc));
        assertEq(pool.poolId(), 1);
        assertEq(pool.poolName(), "Kenya Maize Drought Q1 2026");
        assertEq(pool.symbol(), "mKM-Q1-26");
        assertEq(uint256(pool.coverageType()), uint256(RiskPool.CoverageType.DROUGHT));
        assertEq(pool.region(), "Kenya");
        assertEq(pool.targetCapital(), TARGET_CAPITAL);
        assertEq(pool.maxCapital(), MAX_CAPITAL);
        assertEq(pool.platformFeePercent(), 10);
        assertEq(uint256(pool.status()), uint256(RiskPool.PoolStatus.FUNDRAISING));
    }

    function test_Constructor_GrantsAdminRoles() public view {
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(pool.hasRole(pool.ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsWithZeroUSDC() public {
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.usdc = address(0);

        vm.expectRevert(RiskPool.ZeroAddress.selector);
        new RiskPool(config);
    }

    function test_Constructor_RevertsWithZeroTargetCapital() public {
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.targetCapital = 0;

        vm.expectRevert(RiskPool.InvalidTargetCapital.selector);
        new RiskPool(config);
    }

    function test_Constructor_RevertsWithMaxCapitalBelowTarget() public {
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.targetCapital = 1_000_000e6;
        config.maxCapital = 500_000e6;

        vm.expectRevert(RiskPool.InvalidMaxCapital.selector);
        new RiskPool(config);
    }

    function test_Constructor_RevertsWithInvalidFundraiseDuration() public {
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.fundraiseEnd = config.fundraiseStart;

        vm.expectRevert(RiskPool.InvalidFundraiseDuration.selector);
        new RiskPool(config);
    }

    function test_Constructor_RevertsWithInvalidCoverageDuration() public {
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.coverageEnd = config.fundraiseEnd;

        vm.expectRevert(RiskPool.InvalidCoverageDuration.selector);
        new RiskPool(config);
    }

    function test_Constructor_RevertsWithPlatformFeeAbove20() public {
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.platformFeePercent = 21;

        vm.expectRevert(RiskPool.InvalidPlatformFee.selector);
        new RiskPool(config);
    }

    // ============ Deposit Tests ============

    function test_Deposit_Success() public {
        uint256 amount = 10_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), amount);
        assertEq(pool.investorDeposits(investor1), amount);
        assertEq(pool.investorCount(), 1);
        assertEq(usdc.balanceOf(address(pool)), amount);
    }

    function test_Deposit_MintsTokensOneToOne() public {
        uint256 amount = 50_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        // 1 USDC = 1 token (both 6 decimals for display purposes)
        assertEq(pool.balanceOf(investor1), amount);
    }

    function test_Deposit_TracksInvestorDeposits() public {
        uint256 firstDeposit = 10_000e6;
        uint256 secondDeposit = 20_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), firstDeposit + secondDeposit);
        pool.deposit(firstDeposit);
        pool.deposit(secondDeposit);
        vm.stopPrank();

        assertEq(pool.investorDeposits(investor1), firstDeposit + secondDeposit);
        assertEq(pool.balanceOf(investor1), firstDeposit + secondDeposit);
    }

    function test_Deposit_IncrementsInvestorCountOnFirstDeposit() public {
        vm.startPrank(investor1);
        usdc.approve(address(pool), 20_000e6);
        pool.deposit(10_000e6);
        assertEq(pool.investorCount(), 1);

        pool.deposit(10_000e6);
        assertEq(pool.investorCount(), 1); // Still 1 after second deposit
        vm.stopPrank();

        vm.startPrank(investor2);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        assertEq(pool.investorCount(), 2); // Now 2
    }

    function test_Deposit_EmitsEvent() public {
        uint256 amount = 10_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), amount);

        vm.expectEmit(true, true, true, true);
        emit RiskPool.Deposited(investor1, amount, amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function test_Deposit_RevertsWhenNotFundraising() public {
        // Fast forward past fundraise end
        vm.warp(block.timestamp + 15 days);

        vm.startPrank(investor3);
        usdc.approve(address(pool), 10_000e6);
        vm.expectRevert(RiskPool.FundraisingEnded.selector);
        pool.deposit(10_000e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertsBeforeFundraisingStarts() public {
        // Create pool with future fundraise start
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.fundraiseStart = block.timestamp + 1 days;
        config.fundraiseEnd = block.timestamp + 15 days;
        config.coverageEnd = block.timestamp + 15 days + 180 days;

        RiskPool futurePool = new RiskPool(config);

        vm.startPrank(investor1);
        usdc.approve(address(futurePool), 10_000e6);
        vm.expectRevert(RiskPool.FundraisingNotStarted.selector);
        futurePool.deposit(10_000e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertsAfterFundraisingEnds() public {
        vm.warp(block.timestamp + 15 days);

        vm.startPrank(investor1);
        usdc.approve(address(pool), 10_000e6);
        vm.expectRevert(RiskPool.FundraisingEnded.selector);
        pool.deposit(10_000e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertsBelowMinimumInvestment() public {
        vm.startPrank(investor1);
        usdc.approve(address(pool), 999e6);
        vm.expectRevert(RiskPool.BelowMinimumInvestment.selector);
        pool.deposit(999e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertsExceedingMaximumInvestment() public {
        usdc.mint(investor1, 200_000e6); // Extra funds

        vm.startPrank(investor1);
        usdc.approve(address(pool), 200_000e6);
        pool.deposit(100_000e6); // Max first deposit

        vm.expectRevert(RiskPool.ExceedsMaximumInvestment.selector);
        pool.deposit(1_000e6); // Would exceed max
        vm.stopPrank();
    }

    function test_Deposit_RevertsExceedingPoolCapacity() public {
        // Create smaller pool
        RiskPool.PoolConfig memory config = _createDefaultConfig();
        config.maxCapital = 150_000e6;
        config.targetCapital = 100_000e6;

        vm.prank(admin);
        RiskPool smallPool = new RiskPool(config);

        // Fund two investors to fill pool
        usdc.mint(investor1, 200_000e6);
        usdc.mint(investor2, 200_000e6);

        vm.startPrank(investor1);
        usdc.approve(address(smallPool), 100_000e6);
        smallPool.deposit(100_000e6);
        vm.stopPrank();

        vm.startPrank(investor2);
        usdc.approve(address(smallPool), 100_000e6);
        vm.expectRevert(RiskPool.ExceedsPoolCapacity.selector);
        smallPool.deposit(100_000e6); // Would exceed pool max
        vm.stopPrank();
    }

    function test_Deposit_RevertsWhenPaused() public {
        vm.prank(admin);
        pool.pause();

        vm.startPrank(investor1);
        usdc.approve(address(pool), 10_000e6);
        vm.expectRevert();
        pool.deposit(10_000e6);
        vm.stopPrank();
    }

    // ============ Pool Activation Tests ============

    function test_ActivatePool_Success() public {
        _fundPoolToTarget();
        vm.warp(block.timestamp + 15 days);

        vm.prank(admin);
        pool.activatePool();

        assertEq(uint256(pool.status()), uint256(RiskPool.PoolStatus.ACTIVE));
        assertEq(pool.coverageStart(), block.timestamp);
    }

    function test_ActivatePool_EmitsEvent() public {
        _fundPoolToTarget();
        vm.warp(block.timestamp + 15 days);

        vm.prank(admin);
        // Just check that the event is emitted, don't check exact values
        vm.expectEmit(false, false, false, false);
        emit RiskPool.PoolActivated(0, 0);
        pool.activatePool();
    }

    function test_ActivatePool_RevertsWhenNotFundraising() public {
        _fundPoolToTarget();
        vm.warp(block.timestamp + 15 days);

        vm.prank(admin);
        pool.activatePool();

        vm.prank(admin);
        vm.expectRevert(RiskPool.InvalidPoolStatus.selector);
        pool.activatePool();
    }

    function test_ActivatePool_RevertsBeforeFundraisingEnds() public {
        _fundPoolToTarget();

        vm.prank(admin);
        vm.expectRevert(RiskPool.FundraisingNotEnded.selector);
        pool.activatePool();
    }

    function test_ActivatePool_RevertsIfTargetNotMet() public {
        // Only fund partially
        vm.startPrank(investor1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);

        vm.prank(admin);
        vm.expectRevert(RiskPool.TargetCapitalNotMet.selector);
        pool.activatePool();
    }

    function test_ActivatePool_RevertsWhenUnauthorized() public {
        _fundPoolToTarget();
        vm.warp(block.timestamp + 15 days);

        vm.expectRevert();
        pool.activatePool();
    }

    // ============ Close Pool Tests ============

    function test_ClosePool_Success() public {
        _activatePool();

        vm.prank(admin);
        pool.closePool();

        assertEq(uint256(pool.status()), uint256(RiskPool.PoolStatus.CLOSED));
    }

    function test_ClosePool_EmitsEvent() public {
        _activatePool();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RiskPool.PoolClosed(block.timestamp);
        pool.closePool();
    }

    function test_ClosePool_RevertsWhenNotActive() public {
        vm.prank(admin);
        vm.expectRevert(RiskPool.InvalidPoolStatus.selector);
        pool.closePool();
    }

    function test_ClosePool_RevertsWhenUnauthorized() public {
        _activatePool();

        vm.expectRevert();
        pool.closePool();
    }

    // ============ Expire Pool Tests ============

    function test_ExpirePool_Success() public {
        _activatePool();

        vm.prank(admin);
        pool.closePool();

        // Fast forward past coverage end
        vm.warp(block.timestamp + 200 days);

        vm.prank(admin);
        pool.expirePool();

        assertEq(uint256(pool.status()), uint256(RiskPool.PoolStatus.EXPIRED));
    }

    function test_ExpirePool_EmitsEvent() public {
        _activatePool();
        vm.prank(admin);
        pool.closePool();
        vm.warp(block.timestamp + 200 days);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RiskPool.PoolExpired(block.timestamp);
        pool.expirePool();
    }

    function test_ExpirePool_RevertsWhenNotClosed() public {
        _activatePool();
        vm.warp(block.timestamp + 200 days);

        vm.prank(admin);
        vm.expectRevert(RiskPool.InvalidPoolStatus.selector);
        pool.expirePool();
    }

    function test_ExpirePool_RevertsBeforeCoverageEnds() public {
        _activatePool();
        vm.prank(admin);
        pool.closePool();

        vm.prank(admin);
        vm.expectRevert(RiskPool.CoverageNotEnded.selector);
        pool.expirePool();
    }

    // ============ Premium Tests ============

    function test_ReceivePremium_Success() public {
        _activatePool();

        uint256 grossPremium = 10_000e6;
        usdc.mint(treasury, grossPremium);

        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium);
        pool.receivePremium(1, grossPremium);
        vm.stopPrank();

        // Platform fee is 10%, net = 9000
        assertEq(pool.totalPremiumsCollected(), 9_000e6);
        assertTrue(pool.isPolicyInPool(1));
        assertEq(pool.getPolicyCount(), 1);
    }

    function test_ReceivePremium_CalculatesPlatformFeeCorrectly() public {
        _activatePool();

        uint256 grossPremium = 10_000e6;
        uint256 expectedFee = 1_000e6; // 10%
        uint256 expectedNet = 9_000e6;

        usdc.mint(treasury, grossPremium);

        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium);
        pool.receivePremium(1, grossPremium);
        vm.stopPrank();

        assertEq(pool.totalPremiumsCollected(), expectedNet);
        // Full premium stays in pool (including fee portion)
        assertEq(usdc.balanceOf(address(pool)), TARGET_CAPITAL + grossPremium);
    }

    function test_ReceivePremium_EmitsEvent() public {
        _activatePool();

        uint256 grossPremium = 10_000e6;
        usdc.mint(treasury, grossPremium);

        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium);

        vm.expectEmit(true, true, true, true);
        emit RiskPool.PremiumReceived(1, grossPremium, 9_000e6);
        pool.receivePremium(1, grossPremium);
        vm.stopPrank();
    }

    function test_ReceivePremium_RevertsWhenNotActiveOrClosed() public {
        uint256 grossPremium = 10_000e6;
        usdc.mint(treasury, grossPremium);

        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium);
        vm.expectRevert(RiskPool.InvalidPoolStatus.selector);
        pool.receivePremium(1, grossPremium);
        vm.stopPrank();
    }

    function test_ReceivePremium_WorksWhenClosed() public {
        _activatePool();
        vm.prank(admin);
        pool.closePool();

        uint256 grossPremium = 10_000e6;
        usdc.mint(treasury, grossPremium);

        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium);
        pool.receivePremium(1, grossPremium);
        vm.stopPrank();

        assertEq(pool.totalPremiumsCollected(), 9_000e6);
    }

    function test_ReceivePremium_RevertsForDuplicatePolicy() public {
        _activatePool();

        uint256 grossPremium = 10_000e6;
        usdc.mint(treasury, grossPremium * 2);

        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium * 2);
        pool.receivePremium(1, grossPremium);

        vm.expectRevert(RiskPool.PolicyAlreadyInPool.selector);
        pool.receivePremium(1, grossPremium);
        vm.stopPrank();
    }

    function test_ReceivePremium_RevertsWithZeroAmount() public {
        _activatePool();

        vm.startPrank(treasury);
        vm.expectRevert(RiskPool.ZeroAmount.selector);
        pool.receivePremium(1, 0);
        vm.stopPrank();
    }

    function test_ReceivePremium_RevertsWhenUnauthorized() public {
        _activatePool();

        vm.expectRevert();
        pool.receivePremium(1, 10_000e6);
    }

    // ============ Payout Tests ============

    function test_ProcessPayout_Success() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        uint256 payoutAmount = 50_000e6;
        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        vm.prank(treasury);
        pool.processPayout(1, payoutAmount);

        assertEq(pool.totalPayoutsMade(), payoutAmount);
        assertEq(usdc.balanceOf(address(pool)), poolBalanceBefore - payoutAmount);
        assertEq(usdc.balanceOf(treasury), payoutAmount);
    }

    function test_ProcessPayout_EmitsEvent() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        uint256 payoutAmount = 50_000e6;

        vm.prank(treasury);
        vm.expectEmit(true, true, true, true);
        emit RiskPool.PayoutProcessed(1, payoutAmount);
        pool.processPayout(1, payoutAmount);
    }

    function test_ProcessPayout_RevertsForNonPoolPolicy() public {
        _activatePool();

        vm.prank(treasury);
        vm.expectRevert(RiskPool.PolicyNotInPool.selector);
        pool.processPayout(999, 10_000e6);
    }

    function test_ProcessPayout_RevertsWithZeroAmount() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        vm.prank(treasury);
        vm.expectRevert(RiskPool.ZeroAmount.selector);
        pool.processPayout(1, 0);
    }

    function test_ProcessPayout_RevertsWithInsufficientBalance() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        uint256 poolBalance = usdc.balanceOf(address(pool));

        vm.prank(treasury);
        vm.expectRevert(RiskPool.InsufficientBalance.selector);
        pool.processPayout(1, poolBalance + 1);
    }

    function test_ProcessPayout_RevertsWhenUnauthorized() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        vm.expectRevert();
        pool.processPayout(1, 10_000e6);
    }

    // ============ Redemption Tests ============

    function test_Redeem_Success() public {
        // First deposit investor1 funds
        vm.startPrank(investor1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        // Add 4 more funders to meet target (500k total)
        for (uint256 i = 0; i < 4; i++) {
            address funder = makeAddr(string(abi.encodePacked("extraFunder", i)));
            usdc.mint(funder, 100_000e6);
            vm.startPrank(funder);
            usdc.approve(address(pool), 100_000e6);
            pool.deposit(100_000e6);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 15 days);
        vm.prank(admin);
        pool.activatePool();
        vm.prank(admin);
        pool.closePool();
        vm.warp(block.timestamp + 200 days);
        vm.prank(admin);
        pool.expirePool();

        // Investor1 deposited 100k out of 500k total (20%)
        // With no premium/payout, they should get back their 100k
        uint256 tokenBalance = pool.balanceOf(investor1);
        assertEq(tokenBalance, 100_000e6);

        uint256 expectedUSDC = pool.calculateRedemption(tokenBalance);
        assertEq(expectedUSDC, 100_000e6);

        vm.prank(investor1);
        pool.redeem(tokenBalance);

        assertEq(pool.balanceOf(investor1), 0);
        assertEq(usdc.balanceOf(investor1), expectedUSDC);
    }

    function test_Redeem_CalculatesCorrectAmountAfterProfits() public {
        // First deposit investor1 funds
        vm.startPrank(investor1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        // Add 4 more funders to meet target (500k total)
        for (uint256 i = 0; i < 4; i++) {
            address funder = makeAddr(string(abi.encodePacked("profitFunder", i)));
            usdc.mint(funder, 100_000e6);
            vm.startPrank(funder);
            usdc.approve(address(pool), 100_000e6);
            pool.deposit(100_000e6);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 15 days);
        vm.prank(admin);
        pool.activatePool();

        _addPolicyToPool(1, 50_000e6); // Add premium

        vm.prank(admin);
        pool.closePool();
        vm.warp(block.timestamp + 200 days);
        vm.prank(admin);
        pool.expirePool();

        // investor1 has 100k tokens out of 500k total (20%)
        // Pool balance is now 500k + 50k = 550k
        // investor1's share: (100k * 550k) / 500k = 110k
        uint256 tokenBalance = pool.balanceOf(investor1);
        uint256 totalBalance = usdc.balanceOf(address(pool)); // 550k
        uint256 supply = pool.totalSupply(); // 500k

        uint256 expectedRedemption = (tokenBalance * totalBalance) / supply;
        assertEq(expectedRedemption, 110_000e6);

        vm.prank(investor1);
        pool.redeem(tokenBalance);

        // Should get proportional share including premiums
        assertEq(usdc.balanceOf(investor1), 110_000e6);
    }

    function test_Redeem_CalculatesCorrectAmountAfterLosses() public {
        // First deposit investor1 funds
        vm.startPrank(investor1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        // Add 4 more funders to meet target (500k total)
        for (uint256 i = 0; i < 4; i++) {
            address funder = makeAddr(string(abi.encodePacked("lossFunder", i)));
            usdc.mint(funder, 100_000e6);
            vm.startPrank(funder);
            usdc.approve(address(pool), 100_000e6);
            pool.deposit(100_000e6);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 15 days);
        vm.prank(admin);
        pool.activatePool();

        _addPolicyToPool(1, 10_000e6);

        // Process a payout (loss)
        vm.prank(treasury);
        pool.processPayout(1, 100_000e6);

        vm.prank(admin);
        pool.closePool();
        vm.warp(block.timestamp + 200 days);
        vm.prank(admin);
        pool.expirePool();

        // investor1 has 100k tokens out of 500k total (20%)
        // Pool balance: 500k + 10k - 100k = 410k
        // investor1's share: (100k * 410k) / 500k = 82k
        uint256 tokenBalance = pool.balanceOf(investor1);
        uint256 totalBalance = usdc.balanceOf(address(pool)); // 410k
        uint256 supply = pool.totalSupply();

        uint256 expectedRedemption = (tokenBalance * totalBalance) / supply;
        assertEq(expectedRedemption, 82_000e6);

        vm.prank(investor1);
        pool.redeem(tokenBalance);

        // Should get less than initial due to payout
        assertLt(usdc.balanceOf(investor1), 100_000e6);
        assertEq(usdc.balanceOf(investor1), 82_000e6);
    }

    function test_Redeem_PartialRedemption() public {
        _fullLifecycleToExpired();

        address funder = makeAddr("funder1");
        uint256 tokenBalance = pool.balanceOf(funder);
        uint256 halfTokens = tokenBalance / 2;

        vm.prank(funder);
        pool.redeem(halfTokens);

        assertEq(pool.balanceOf(funder), tokenBalance - halfTokens);
        assertGt(usdc.balanceOf(funder), 0);
    }

    function test_Redeem_EmitsEvent() public {
        _fullLifecycleToExpired();

        address funder = makeAddr("funder1");
        uint256 tokenBalance = pool.balanceOf(funder);
        uint256 expectedUSDC = pool.calculateRedemption(tokenBalance);

        vm.prank(funder);
        vm.expectEmit(true, true, true, true);
        emit RiskPool.Redeemed(funder, tokenBalance, expectedUSDC);
        pool.redeem(tokenBalance);
    }

    function test_Redeem_RevertsWhenNotExpired() public {
        _activatePool();

        vm.prank(investor1);
        vm.expectRevert(RiskPool.InvalidPoolStatus.selector);
        pool.redeem(100_000e6);
    }

    function test_Redeem_RevertsWithZeroAmount() public {
        _fullLifecycleToExpired();

        vm.prank(investor1);
        vm.expectRevert(RiskPool.ZeroAmount.selector);
        pool.redeem(0);
    }

    function test_Redeem_RevertsWithInsufficientTokens() public {
        _fullLifecycleToExpired();

        uint256 tokenBalance = pool.balanceOf(investor1);

        vm.prank(investor1);
        vm.expectRevert(RiskPool.InsufficientTokens.selector);
        pool.redeem(tokenBalance + 1);
    }

    // ============ Token Value Tests ============

    function test_GetTokenValue_ReturnsOneInitially() public view {
        uint256 value = pool.getTokenValue();
        assertEq(value, 1e18); // 1.00 with 18 decimals
    }

    function test_GetTokenValue_IncreasesAfterPremiums() public {
        _activatePool();
        _addPolicyToPool(1, 50_000e6);

        uint256 value = pool.getTokenValue();
        assertGt(value, 1e18); // Value increased
    }

    function test_GetTokenValue_DecreasesAfterPayouts() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        vm.prank(treasury);
        pool.processPayout(1, 100_000e6);

        uint256 value = pool.getTokenValue();
        assertLt(value, 1e18); // Value decreased
    }

    function test_GetTokenValue_CalculatesCorrectly() public {
        _activatePool();
        _addPolicyToPool(1, 50_000e6);

        // Pool balance = 500k + 50k = 550k
        // Total supply = 500k
        // Value = 550k * 1e18 / 500k = 1.1e18

        uint256 value = pool.getTokenValue();
        uint256 expectedValue = (550_000e6 * 1e18) / 500_000e6;

        assertEq(value, expectedValue);
    }

    // ============ ROI Tests ============

    function test_GetROI_ReturnsZeroAtBreakEven() public {
        _fundPoolToTarget();
        int256 roi = pool.getROI();
        assertEq(roi, 0);
    }

    function test_GetROI_ReturnsPositiveAfterProfits() public {
        _activatePool();
        _addPolicyToPool(1, 50_000e6);

        int256 roi = pool.getROI();
        assertGt(roi, 0);
    }

    function test_GetROI_ReturnsNegativeAfterLosses() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);

        vm.prank(treasury);
        pool.processPayout(1, 100_000e6);

        int256 roi = pool.getROI();
        assertLt(roi, 0);
    }

    function test_GetROI_CalculatesCorrectPercentage() public {
        _activatePool();
        _addPolicyToPool(1, 50_000e6);

        // Pool balance = 550k, supply = 500k
        // Token value = 1.1 (10% gain)
        // ROI should be ~1000 (10% with 2 decimal precision)

        int256 roi = pool.getROI();
        assertEq(roi, 1000); // 10.00%
    }

    // ============ Investor Info Tests ============

    function test_GetInvestorInfo_ReturnsCorrectData() public {
        _activatePool();
        _addPolicyToPool(1, 50_000e6);

        address funder = makeAddr("funder1");
        (uint256 deposited, uint256 tokensHeld, uint256 currentValue, int256 roi) =
            pool.getInvestorInfo(funder);

        assertEq(deposited, 100_000e6);
        assertEq(tokensHeld, 100_000e6);
        assertGt(currentValue, deposited); // Made profit
        assertGt(roi, 0);
    }

    // ============ View Function Tests ============

    function test_GetPoolBalance_ReturnsCorrectAmount() public {
        _fundPoolToTarget();
        assertEq(pool.getPoolBalance(), TARGET_CAPITAL);
    }

    function test_GetNetAssetValue_EqualsTokenValue() public {
        _activatePool();
        assertEq(pool.getNetAssetValue(), pool.getTokenValue());
    }

    function test_GetPolicyCount_ReturnsCorrectCount() public {
        _activatePool();
        assertEq(pool.getPolicyCount(), 0);

        _addPolicyToPool(1, 10_000e6);
        assertEq(pool.getPolicyCount(), 1);

        _addPolicyToPool(2, 10_000e6);
        assertEq(pool.getPolicyCount(), 2);
    }

    function test_GetAllPolicyIds_ReturnsArray() public {
        _activatePool();
        _addPolicyToPool(1, 10_000e6);
        _addPolicyToPool(2, 10_000e6);
        _addPolicyToPool(3, 10_000e6);

        uint256[] memory policyIds = pool.getAllPolicyIds();
        assertEq(policyIds.length, 3);
        assertEq(policyIds[0], 1);
        assertEq(policyIds[1], 2);
        assertEq(policyIds[2], 3);
    }

    function test_CanAcceptPolicy_ReturnsTrueWithSufficientCapital() public {
        _activatePool();
        assertTrue(pool.canAcceptPolicy(100_000e6));
    }

    function test_CanAcceptPolicy_ReturnsFalseWithInsufficientCapital() public {
        _activatePool();
        assertFalse(pool.canAcceptPolicy(1_000_000e6));
    }

    function test_CanAcceptPolicy_ReturnsFalseWhenNotActive() public view {
        assertFalse(pool.canAcceptPolicy(100_000e6));
    }

    function test_CalculateRedemption_ReturnsCorrectAmount() public {
        _fullLifecycleToExpired();

        uint256 tokenAmount = 100_000e6;
        uint256 totalBalance = usdc.balanceOf(address(pool));
        uint256 supply = pool.totalSupply();

        uint256 expected = (tokenAmount * totalBalance) / supply;
        uint256 actual = pool.calculateRedemption(tokenAmount);

        assertEq(actual, expected);
    }

    // ============ ERC20 Tests ============

    function test_Transfer_Works() public {
        vm.startPrank(investor1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);

        pool.transfer(investor2, 5_000e6);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), 5_000e6);
        assertEq(pool.balanceOf(investor2), 5_000e6);
    }

    function test_Approve_Works() public {
        vm.startPrank(investor1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);

        pool.approve(investor2, 5_000e6);
        vm.stopPrank();

        assertEq(pool.allowance(investor1, investor2), 5_000e6);
    }

    function test_TransferFrom_Works() public {
        vm.startPrank(investor1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        pool.approve(investor2, 5_000e6);
        vm.stopPrank();

        vm.prank(investor2);
        pool.transferFrom(investor1, investor2, 5_000e6);

        assertEq(pool.balanceOf(investor1), 5_000e6);
        assertEq(pool.balanceOf(investor2), 5_000e6);
    }

    // ============ Admin Tests ============

    function test_SetPlatformFee_Success() public {
        vm.prank(admin);
        pool.setPlatformFee(15);

        assertEq(pool.platformFeePercent(), 15);
    }

    function test_SetPlatformFee_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RiskPool.PlatformFeeUpdated(15);
        pool.setPlatformFee(15);
    }

    function test_SetPlatformFee_RevertsAbove20() public {
        vm.prank(admin);
        vm.expectRevert(RiskPool.InvalidPlatformFee.selector);
        pool.setPlatformFee(21);
    }

    function test_SetPlatformFee_RevertsWhenUnauthorized() public {
        vm.expectRevert();
        pool.setPlatformFee(15);
    }

    function test_Pause_Success() public {
        vm.prank(admin);
        pool.pause();
        assertTrue(pool.paused());
    }

    function test_Unpause_Success() public {
        vm.prank(admin);
        pool.pause();

        vm.prank(admin);
        pool.unpause();
        assertFalse(pool.paused());
    }

    // ============ Fuzz Tests ============

    function testFuzz_Deposit_ValidAmounts(uint256 amount) public {
        amount = bound(amount, MIN_INVESTMENT, MAX_INVESTMENT);

        usdc.mint(investor1, amount);

        vm.startPrank(investor1);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), amount);
    }

    function testFuzz_TokenValue_AfterOperations(uint256 premium, uint256 payout) public {
        premium = bound(premium, 1_000e6, 100_000e6);

        _activatePool();
        _addPolicyToPool(1, premium);

        uint256 maxPayout = usdc.balanceOf(address(pool)) - 1;
        payout = bound(payout, 1, maxPayout);

        vm.prank(treasury);
        pool.processPayout(1, payout);

        uint256 value = pool.getTokenValue();
        uint256 expectedBalance = TARGET_CAPITAL + premium - payout;
        uint256 expectedValue = (expectedBalance * 1e18) / TARGET_CAPITAL;

        assertEq(value, expectedValue);
    }

    // ============ Helper Functions ============

    function _createDefaultConfig() internal view returns (RiskPool.PoolConfig memory) {
        return RiskPool.PoolConfig({
            usdc: address(usdc),
            poolId: 99,
            name: "Test Pool",
            symbol: "TEST",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Test",
            targetCapital: TARGET_CAPITAL,
            maxCapital: MAX_CAPITAL,
            fundraiseStart: block.timestamp,
            fundraiseEnd: block.timestamp + 14 days,
            coverageEnd: block.timestamp + 14 days + 180 days,
            platformFeePercent: 10
        });
    }

    function _fundPoolToTarget() internal {
        // Need 5 investors at 100k each = 500k total
        // Use investor1, investor2 (from setUp) plus 3 new ones
        address[5] memory investors = [
            makeAddr("funder1"),
            makeAddr("funder2"),
            makeAddr("funder3"),
            makeAddr("funder4"),
            makeAddr("funder5")
        ];

        for (uint256 i = 0; i < 5; i++) {
            usdc.mint(investors[i], 100_000e6);
            vm.startPrank(investors[i]);
            usdc.approve(address(pool), 100_000e6);
            pool.deposit(100_000e6);
            vm.stopPrank();
        }
    }

    function _activatePool() internal {
        _fundPoolToTarget();
        vm.warp(block.timestamp + 15 days);
        vm.prank(admin);
        pool.activatePool();
    }

    function _addPolicyToPool(uint256 policyId, uint256 grossPremium) internal {
        usdc.mint(treasury, grossPremium);
        vm.startPrank(treasury);
        usdc.approve(address(pool), grossPremium);
        pool.receivePremium(policyId, grossPremium);
        vm.stopPrank();
    }

    function _fullLifecycleToExpired() internal {
        _activatePool();
        vm.prank(admin);
        pool.closePool();
        vm.warp(block.timestamp + 200 days);
        vm.prank(admin);
        pool.expirePool();
    }
}
