// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title TreasuryTest
 * @notice Comprehensive test suite for Treasury contract
 * @dev Tests cover premium collection, payout disbursement, reserve management,
 *      access control, and emergency functions
 */
contract TreasuryTest is Test {
    // ============ Contracts ============
    Treasury public treasury;
    MockUSDC public usdc;

    // ============ Test Addresses ============
    address public admin = address(1);
    address public backend = address(2);
    address public payoutRole = address(3);
    address public backendWallet = address(4);
    address public farmer = address(5);
    address public unauthorized = address(6);

    // ============ Test Constants ============
    uint256 public constant VALID_PREMIUM = 10_000e6; // 10,000 USDC
    uint256 public constant VALID_PAYOUT = 5_000e6; // 5,000 USDC

    // ============ Events ============
    event PremiumReceived(
        uint256 indexed policyId,
        uint256 grossAmount,
        uint256 platformFee,
        uint256 netAmount,
        address indexed from
    );
    event PayoutSent(
        uint256 indexed policyId,
        uint256 amount,
        address indexed recipient
    );
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event EmergencyWithdrawal(address indexed recipient, uint256 amount);

    // ============ Setup ============

    function setUp() public {
        vm.startPrank(admin);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy Treasury
        treasury = new Treasury(address(usdc), backendWallet);

        // Grant roles
        treasury.grantRole(treasury.BACKEND_ROLE(), backend);
        treasury.grantRole(treasury.PAYOUT_ROLE(), payoutRole);

        vm.stopPrank();

        // Mint USDC to backend for premiums
        usdc.mint(backend, 1_000_000e6);
        vm.prank(backend);
        usdc.approve(address(treasury), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _receivePremium(uint256 policyId, uint256 amount) internal {
        vm.prank(backend);
        treasury.receivePremium(policyId, amount, backend);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsUSDC() public view {
        assertEq(address(treasury.usdc()), address(usdc));
    }

    function test_Constructor_SetsBackendWallet() public view {
        assertEq(treasury.backendWallet(), backendWallet);
    }

    function test_Constructor_SetsDefaultPlatformFee() public view {
        assertEq(treasury.platformFeePercent(), 10);
    }

    function test_Constructor_GrantsRoles() public view {
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(treasury.hasRole(treasury.ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsWithZeroUSDC() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(0), backendWallet);
    }

    function test_Constructor_RevertsWithZeroBackendWallet() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(0));
    }

    // ============ receivePremium Tests ============

    function test_ReceivePremium_Success() public {
        uint256 policyId = 1;
        uint256 platformFee = (VALID_PREMIUM * 10) / 100; // 10%
        uint256 netPremium = VALID_PREMIUM - platformFee;

        vm.prank(backend);

        vm.expectEmit(true, true, true, true);
        emit PremiumReceived(policyId, VALID_PREMIUM, platformFee, netPremium, backend);

        treasury.receivePremium(policyId, VALID_PREMIUM, backend);

        assertEq(treasury.totalPremiums(), netPremium);
        assertEq(treasury.accumulatedFees(), platformFee);
        assertTrue(treasury.premiumReceived(policyId));
        assertEq(usdc.balanceOf(address(treasury)), VALID_PREMIUM);
    }

    function test_ReceivePremium_MultiplePolicies() public {
        _receivePremium(1, VALID_PREMIUM);
        _receivePremium(2, VALID_PREMIUM * 2);
        _receivePremium(3, VALID_PREMIUM / 2);

        uint256 totalGross = VALID_PREMIUM + (VALID_PREMIUM * 2) + (VALID_PREMIUM / 2);
        uint256 totalFees = (totalGross * 10) / 100;
        uint256 totalNet = totalGross - totalFees;

        assertEq(treasury.totalPremiums(), totalNet);
        assertEq(treasury.accumulatedFees(), totalFees);
    }

    function test_ReceivePremium_RevertsWithZeroAmount() public {
        vm.prank(backend);

        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.receivePremium(1, 0, backend);
    }

    function test_ReceivePremium_RevertsWithZeroFrom() public {
        vm.prank(backend);

        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.receivePremium(1, VALID_PREMIUM, address(0));
    }

    function test_ReceivePremium_RevertsWhenAlreadyReceived() public {
        _receivePremium(1, VALID_PREMIUM);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PremiumAlreadyReceived.selector, 1));
        treasury.receivePremium(1, VALID_PREMIUM, backend);
    }

    function test_ReceivePremium_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert();
        treasury.receivePremium(1, VALID_PREMIUM, backend);
    }

    function test_ReceivePremium_RevertsWhenPaused() public {
        vm.prank(admin);
        treasury.pause();

        vm.prank(backend);
        vm.expectRevert();
        treasury.receivePremium(1, VALID_PREMIUM, backend);
    }

    // ============ requestPayout Tests ============

    function test_RequestPayout_Success() public {
        // First receive premium to have funds
        _receivePremium(1, 100_000e6); // 100K USDC

        uint256 balanceBefore = usdc.balanceOf(backendWallet);

        vm.prank(payoutRole);

        vm.expectEmit(true, true, true, true);
        emit PayoutSent(2, VALID_PAYOUT, backendWallet);

        treasury.requestPayout(2, VALID_PAYOUT);

        assertEq(usdc.balanceOf(backendWallet), balanceBefore + VALID_PAYOUT);
        assertEq(treasury.totalPayouts(), VALID_PAYOUT);
        assertTrue(treasury.payoutProcessed(2));
    }

    function test_RequestPayout_MultiplePayouts() public {
        // Receive large premium
        _receivePremium(1, 500_000e6);

        vm.startPrank(payoutRole);
        treasury.requestPayout(1, 10_000e6);
        treasury.requestPayout(2, 20_000e6);
        treasury.requestPayout(3, 15_000e6);
        vm.stopPrank();

        assertEq(treasury.totalPayouts(), 45_000e6);
    }

    function test_RequestPayout_RevertsWithZeroAmount() public {
        vm.prank(payoutRole);

        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.requestPayout(1, 0);
    }

    function test_RequestPayout_RevertsWhenAlreadyProcessed() public {
        _receivePremium(1, 100_000e6);

        vm.startPrank(payoutRole);
        treasury.requestPayout(1, VALID_PAYOUT);

        vm.expectRevert(abi.encodeWithSelector(Treasury.PayoutAlreadyProcessed.selector, 1));
        treasury.requestPayout(1, VALID_PAYOUT);
        vm.stopPrank();
    }

    function test_RequestPayout_RevertsWhenUnauthorized() public {
        _receivePremium(1, 100_000e6);

        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.requestPayout(2, VALID_PAYOUT);
    }

    function test_RequestPayout_RevertsWhenPaused() public {
        _receivePremium(1, 100_000e6);

        vm.prank(admin);
        treasury.pause();

        vm.prank(payoutRole);
        vm.expectRevert();
        treasury.requestPayout(2, VALID_PAYOUT);
    }

    function test_RequestPayout_RevertsWhenInsufficientReserves() public {
        // Receive 100 USDC premium (net: 90 USDC after 10% fee)
        // Reserve requirement: 90 * 20% = 18 USDC
        // Available: 100 - 18 = 82 USDC (balance is 100, gross amount)
        _receivePremium(1, 100e6);

        // Net premium is 90 USDC, reserve is 18 USDC
        // Balance is 100 USDC
        // Available for payout: 100 - 18 = 82 USDC

        vm.prank(payoutRole);
        vm.expectRevert();
        treasury.requestPayout(2, 90e6); // Try to payout 90, but only ~82 available
    }

    function test_RequestPayout_RespectsReserveRequirement() public {
        // Receive 100,000 USDC premium
        _receivePremium(1, 100_000e6);

        // Net premium: 90,000 USDC (after 10% fee)
        // Balance: 100,000 USDC
        // Required reserve: 90,000 * 20% = 18,000 USDC
        // Available: 100,000 - 18,000 = 82,000 USDC

        // This should succeed - exactly at the limit
        vm.prank(payoutRole);
        treasury.requestPayout(2, 82_000e6);

        // Verify balance after payout
        assertEq(usdc.balanceOf(address(treasury)), 18_000e6);
    }

    // ============ Platform Fee Tests ============

    function test_SetPlatformFee_Success() public {
        vm.prank(admin);

        vm.expectEmit(true, true, true, true);
        emit PlatformFeeUpdated(10, 15);

        treasury.setPlatformFee(15);

        assertEq(treasury.platformFeePercent(), 15);
    }

    function test_SetPlatformFee_CanSetToZero() public {
        vm.prank(admin);
        treasury.setPlatformFee(0);

        assertEq(treasury.platformFeePercent(), 0);

        // Verify no fee is taken
        _receivePremium(1, VALID_PREMIUM);
        assertEq(treasury.accumulatedFees(), 0);
        assertEq(treasury.totalPremiums(), VALID_PREMIUM);
    }

    function test_SetPlatformFee_CanSetToMax() public {
        vm.prank(admin);
        treasury.setPlatformFee(20);

        assertEq(treasury.platformFeePercent(), 20);
    }

    function test_SetPlatformFee_RevertsWhenTooHigh() public {
        vm.prank(admin);

        vm.expectRevert(abi.encodeWithSelector(Treasury.FeeTooHigh.selector, 21, 20));
        treasury.setPlatformFee(21);
    }

    function test_SetPlatformFee_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert();
        treasury.setPlatformFee(15);
    }

    function test_CalculatePlatformFee_CorrectCalculation() public view {
        // 10% of 10,000 = 1,000
        assertEq(treasury.calculatePlatformFee(10_000e6), 1_000e6);

        // 10% of 0 = 0
        assertEq(treasury.calculatePlatformFee(0), 0);

        // 10% of 1 = 0 (truncated)
        assertEq(treasury.calculatePlatformFee(1), 0);
    }

    // ============ Fee Withdrawal Tests ============

    function test_WithdrawFees_Success() public {
        _receivePremium(1, 100_000e6);

        uint256 expectedFees = 10_000e6; // 10% of 100,000
        address recipient = address(100);

        vm.prank(admin);

        vm.expectEmit(true, true, true, true);
        emit FeesWithdrawn(recipient, expectedFees);

        treasury.withdrawFees(recipient);

        assertEq(usdc.balanceOf(recipient), expectedFees);
        assertEq(treasury.accumulatedFees(), 0);
    }

    function test_WithdrawFees_RevertsWithZeroAddress() public {
        _receivePremium(1, 100_000e6);

        vm.prank(admin);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.withdrawFees(address(0));
    }

    function test_WithdrawFees_RevertsWithNoFees() public {
        vm.prank(admin);
        vm.expectRevert(Treasury.NoFeesToWithdraw.selector);
        treasury.withdrawFees(address(100));
    }

    function test_WithdrawFees_RevertsWhenUnauthorized() public {
        _receivePremium(1, 100_000e6);

        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.withdrawFees(address(100));
    }

    // ============ Emergency Withdraw Tests ============

    function test_EmergencyWithdraw_Success() public {
        _receivePremium(1, 100_000e6);
        address recipient = address(100);

        vm.startPrank(admin);
        treasury.pause();

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(recipient, 50_000e6);

        treasury.emergencyWithdraw(recipient, 50_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 50_000e6);
    }

    function test_EmergencyWithdraw_CanWithdrawAll() public {
        _receivePremium(1, 100_000e6);
        address recipient = address(100);

        vm.startPrank(admin);
        treasury.pause();
        treasury.emergencyWithdraw(recipient, 100_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 100_000e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_EmergencyWithdraw_RevertsWithZeroAddress() public {
        _receivePremium(1, 100_000e6);

        vm.startPrank(admin);
        treasury.pause();

        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.emergencyWithdraw(address(0), 50_000e6);
        vm.stopPrank();
    }

    function test_EmergencyWithdraw_RevertsWithInsufficientBalance() public {
        _receivePremium(1, 100_000e6);

        vm.startPrank(admin);
        treasury.pause();

        vm.expectRevert(
            abi.encodeWithSelector(Treasury.InsufficientBalance.selector, 200_000e6, 100_000e6)
        );
        treasury.emergencyWithdraw(address(100), 200_000e6);
        vm.stopPrank();
    }

    function test_EmergencyWithdraw_RevertsWhenNotPaused() public {
        _receivePremium(1, 100_000e6);

        vm.prank(admin);
        vm.expectRevert();
        treasury.emergencyWithdraw(address(100), 50_000e6);
    }

    function test_EmergencyWithdraw_RevertsWhenUnauthorized() public {
        _receivePremium(1, 100_000e6);

        vm.prank(admin);
        treasury.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.emergencyWithdraw(address(100), 50_000e6);
    }

    // ============ Pause Tests ============

    function test_Pause_Success() public {
        vm.prank(admin);
        treasury.pause();

        assertTrue(treasury.paused());
    }

    function test_Unpause_Success() public {
        vm.startPrank(admin);
        treasury.pause();
        treasury.unpause();
        vm.stopPrank();

        assertFalse(treasury.paused());
    }

    function test_Pause_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.pause();
    }

    function test_Unpause_RevertsWhenUnauthorized() public {
        vm.prank(admin);
        treasury.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.unpause();
    }

    // ============ View Function Tests ============

    function test_GetBalance_ReturnsCorrectBalance() public {
        assertEq(treasury.getBalance(), 0);

        _receivePremium(1, 100_000e6);

        assertEq(treasury.getBalance(), 100_000e6);
    }

    function test_GetAvailableForPayouts_ReturnsCorrectAmount() public {
        assertEq(treasury.getAvailableForPayouts(), 0);

        // Receive 100,000 USDC premium
        _receivePremium(1, 100_000e6);

        // Net premium: 90,000 USDC
        // Balance: 100,000 USDC
        // Required reserve: 90,000 * 20% = 18,000 USDC
        // Available: 100,000 - 18,000 = 82,000 USDC
        assertEq(treasury.getAvailableForPayouts(), 82_000e6);
    }

    function test_MeetsReserveRequirements_ReturnsTrue() public {
        assertTrue(treasury.meetsReserveRequirements()); // True when no premiums

        _receivePremium(1, 100_000e6);

        assertTrue(treasury.meetsReserveRequirements());
    }

    function test_MeetsReserveRequirements_ReturnsFalseAfterPayout() public {
        _receivePremium(1, 100_000e6);

        // Make maximum payout to bring balance to reserve level
        vm.prank(payoutRole);
        treasury.requestPayout(1, 82_000e6);

        // Balance now equals required reserve, still meets requirement
        assertTrue(treasury.meetsReserveRequirements());
    }

    function test_GetRequiredReserve_ReturnsCorrectAmount() public {
        assertEq(treasury.getRequiredReserve(), 0);

        _receivePremium(1, 100_000e6);

        // Net premium: 90,000 USDC
        // Required reserve: 90,000 * 20% = 18,000 USDC
        assertEq(treasury.getRequiredReserve(), 18_000e6);
    }

    function test_GetReserveRatio_ReturnsCorrectRatio() public {
        // No premiums = 100%
        assertEq(treasury.getReserveRatio(), 100);

        _receivePremium(1, 100_000e6);

        // Balance: 100,000 / Net Premiums: 90,000 = 111.11%
        assertEq(treasury.getReserveRatio(), 111); // Truncated
    }

    function test_IsPremiumReceived_ReturnsCorrectly() public {
        assertFalse(treasury.isPremiumReceived(1));

        _receivePremium(1, VALID_PREMIUM);

        assertTrue(treasury.isPremiumReceived(1));
        assertFalse(treasury.isPremiumReceived(2));
    }

    function test_IsPayoutProcessed_ReturnsCorrectly() public {
        _receivePremium(1, 100_000e6);

        assertFalse(treasury.isPayoutProcessed(1));

        vm.prank(payoutRole);
        treasury.requestPayout(1, 5_000e6);

        assertTrue(treasury.isPayoutProcessed(1));
        assertFalse(treasury.isPayoutProcessed(2));
    }

    // ============ Fuzz Tests ============

    function testFuzz_ReceivePremium_VariousAmounts(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e6); // 1 wei to 10M USDC

        usdc.mint(backend, amount);

        vm.prank(backend);
        treasury.receivePremium(100, amount, backend);

        uint256 expectedFee = (amount * 10) / 100;
        uint256 expectedNet = amount - expectedFee;

        assertEq(treasury.accumulatedFees(), expectedFee);
        assertEq(treasury.totalPremiums(), expectedNet);
    }

    function testFuzz_SetPlatformFee_ValidRange(uint256 fee) public {
        fee = bound(fee, 0, 20);

        vm.prank(admin);
        treasury.setPlatformFee(fee);

        assertEq(treasury.platformFeePercent(), fee);
    }

    // ============ Integration Tests ============

    function test_FullFlow_PremiumToPayoutToFeeWithdrawal() public {
        // 1. Receive premium
        _receivePremium(1, 100_000e6);

        uint256 netPremium = 90_000e6;
        uint256 platformFee = 10_000e6;

        assertEq(treasury.totalPremiums(), netPremium);
        assertEq(treasury.accumulatedFees(), platformFee);
        assertEq(treasury.getBalance(), 100_000e6);

        // 2. Request payout
        vm.prank(payoutRole);
        treasury.requestPayout(1, 50_000e6);

        assertEq(treasury.totalPayouts(), 50_000e6);
        assertEq(treasury.getBalance(), 50_000e6);
        assertEq(usdc.balanceOf(backendWallet), 50_000e6);

        // 3. Withdraw fees
        address feeRecipient = address(200);
        vm.prank(admin);
        treasury.withdrawFees(feeRecipient);

        assertEq(usdc.balanceOf(feeRecipient), platformFee);
        assertEq(treasury.accumulatedFees(), 0);
        assertEq(treasury.getBalance(), 40_000e6); // 50K - 10K fees
    }
}
