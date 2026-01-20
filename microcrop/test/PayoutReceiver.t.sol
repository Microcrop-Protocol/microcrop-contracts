// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title PayoutReceiverTest
 * @notice Comprehensive test suite for PayoutReceiver contract
 * @dev Tests cover damage report validation, payout processing,
 *      access control, and all validation requirements
 */
contract PayoutReceiverTest is Test {
    // ============ Contracts ============
    PayoutReceiver public payoutReceiver;
    PolicyManager public policyManager;
    Treasury public treasury;
    MockUSDC public usdc;

    // ============ Test Addresses ============
    address public admin = address(1);
    address public backend = address(2);
    address public keystoneForwarder = address(3);
    address public backendWallet = address(4);
    address public farmer = address(5);
    address public unauthorized = address(6);
    address public workflowAddr = address(7);

    // ============ Test Constants ============
    uint256 public constant VALID_SUM_INSURED = 50_000e6; // Reduced for easier testing
    uint256 public constant VALID_PREMIUM = 8_000e6;
    uint256 public constant VALID_DURATION = 180;
    uint256 public constant VALID_WORKFLOW_ID = 12345;
    
    // Damage percentages (basis points)
    uint256 public constant VALID_DAMAGE_PERCENTAGE = 5000; // 50%
    uint256 public constant VALID_WEATHER_DAMAGE = 5000;     // 50% (contributes 60% weight = 3000)
    uint256 public constant VALID_SATELLITE_DAMAGE = 5000;   // 50% (contributes 40% weight = 2000)
    // Total: 3000 + 2000 = 5000 (50%)

    // ============ Events ============
    event DamageReportReceived(
        uint256 indexed policyId,
        uint256 damagePercentage,
        uint256 payoutAmount,
        address indexed farmer
    );
    event PayoutInitiated(uint256 indexed policyId, uint256 amount);
    event WorkflowConfigUpdated(address indexed workflowAddress, uint256 workflowId);
    event KeystoneForwarderUpdated(address indexed oldAddress, address indexed newAddress);

    // ============ Setup ============

    function setUp() public {
        vm.startPrank(admin);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy PolicyManager
        policyManager = new PolicyManager();

        // Deploy Treasury
        treasury = new Treasury(address(usdc), backendWallet);

        // Deploy PayoutReceiver
        payoutReceiver = new PayoutReceiver(address(treasury), address(policyManager));

        // Grant roles on PolicyManager
        policyManager.grantRole(policyManager.BACKEND_ROLE(), backend);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), address(payoutReceiver));

        // Grant roles on Treasury
        treasury.grantRole(treasury.BACKEND_ROLE(), backend);
        treasury.grantRole(treasury.PAYOUT_ROLE(), address(payoutReceiver));

        // Configure PayoutReceiver
        payoutReceiver.setKeystoneForwarder(keystoneForwarder);
        payoutReceiver.setWorkflowConfig(workflowAddr, VALID_WORKFLOW_ID);

        vm.stopPrank();

        // Fund backend for premiums
        usdc.mint(backend, 1_000_000e6);
        vm.prank(backend);
        usdc.approve(address(treasury), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createAndActivatePolicy() internal returns (uint256) {
        vm.startPrank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer,
            1,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
        policyManager.activatePolicy(policyId);
        
        // Receive premium to fund treasury - need enough to cover payout + reserve
        // Premium: 8000 USDC, Net after 10% fee: 7200 USDC
        // Reserve requirement: 7200 * 20% = 1440 USDC
        // Need to add more funds to cover 50% of 50K = 25K payout
        treasury.receivePremium(policyId, 100_000e6, backend); // Fund with more
        vm.stopPrank();

        return policyId;
    }

    function _createValidReport(uint256 policyId) internal view returns (PayoutReceiver.DamageReport memory) {
        uint256 expectedPayout = (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000;
        return PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: VALID_DAMAGE_PERCENTAGE,
            weatherDamage: VALID_WEATHER_DAMAGE,
            satelliteDamage: VALID_SATELLITE_DAMAGE,
            payoutAmount: expectedPayout,
            assessedAt: block.timestamp
        });
    }

    function _submitValidReport(uint256 policyId) internal {
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);
        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsTreasury() public view {
        assertEq(address(payoutReceiver.treasury()), address(treasury));
    }

    function test_Constructor_SetsPolicyManager() public view {
        assertEq(address(payoutReceiver.policyManager()), address(policyManager));
    }

    function test_Constructor_GrantsRoles() public view {
        assertTrue(payoutReceiver.hasRole(payoutReceiver.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(payoutReceiver.hasRole(payoutReceiver.ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsWithZeroTreasury() public {
        vm.expectRevert(PayoutReceiver.ZeroAddress.selector);
        new PayoutReceiver(address(0), address(policyManager));
    }

    function test_Constructor_RevertsWithZeroPolicyManager() public {
        vm.expectRevert(PayoutReceiver.ZeroAddress.selector);
        new PayoutReceiver(address(treasury), address(0));
    }

    // ============ Configuration Tests ============

    function test_SetKeystoneForwarder_Success() public {
        address newForwarder = address(100);

        vm.prank(admin);

        vm.expectEmit(true, true, true, true);
        emit KeystoneForwarderUpdated(keystoneForwarder, newForwarder);

        payoutReceiver.setKeystoneForwarder(newForwarder);

        assertEq(payoutReceiver.keystoneForwarderAddress(), newForwarder);
    }

    function test_SetKeystoneForwarder_RevertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PayoutReceiver.ZeroAddress.selector);
        payoutReceiver.setKeystoneForwarder(address(0));
    }

    function test_SetKeystoneForwarder_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        payoutReceiver.setKeystoneForwarder(address(100));
    }

    function test_SetWorkflowConfig_Success() public {
        address newWorkflow = address(200);
        uint256 newId = 999;

        vm.prank(admin);

        vm.expectEmit(true, true, true, true);
        emit WorkflowConfigUpdated(newWorkflow, newId);

        payoutReceiver.setWorkflowConfig(newWorkflow, newId);

        (address addr, uint256 id) = payoutReceiver.getWorkflowConfig();
        assertEq(addr, newWorkflow);
        assertEq(id, newId);
    }

    function test_SetWorkflowConfig_RevertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PayoutReceiver.ZeroAddress.selector);
        payoutReceiver.setWorkflowConfig(address(0), VALID_WORKFLOW_ID);
    }

    function test_SetWorkflowConfig_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        payoutReceiver.setWorkflowConfig(address(200), 999);
    }

    // ============ receiveDamageReport - Happy Path Tests ============

    function test_ReceiveDamageReport_Success() public {
        uint256 policyId = _createAndActivatePolicy();
        uint256 expectedPayout = (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000;

        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(keystoneForwarder);

        vm.expectEmit(true, true, true, true);
        emit DamageReportReceived(policyId, VALID_DAMAGE_PERCENTAGE, expectedPayout, farmer);

        vm.expectEmit(true, true, true, true);
        emit PayoutInitiated(policyId, expectedPayout);

        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        // Verify state updates
        assertTrue(payoutReceiver.policyPaid(policyId));
        
        PayoutReceiver.DamageReport memory storedReport = payoutReceiver.getReport(policyId);
        assertEq(storedReport.policyId, policyId);
        assertEq(storedReport.damagePercentage, VALID_DAMAGE_PERCENTAGE);
        assertEq(storedReport.payoutAmount, expectedPayout);

        // Verify policy status updated
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CLAIMED));

        // Verify payout was sent
        assertEq(usdc.balanceOf(backendWallet), expectedPayout);
    }

    function test_ReceiveDamageReport_At30PercentThreshold() public {
        uint256 policyId = _createAndActivatePolicy();

        // Create report at exactly 30% threshold
        // 60% * 30 + 40% * 30 = 18 + 12 = 30
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: 3000, // Exactly 30%
            weatherDamage: 3000,
            satelliteDamage: 3000,
            payoutAmount: (VALID_SUM_INSURED * 3000) / 10000,
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        assertTrue(payoutReceiver.policyPaid(policyId));
    }

    function test_ReceiveDamageReport_At100Percent() public {
        uint256 policyId = _createAndActivatePolicy();

        // Fund treasury more for 100% payout
        usdc.mint(backend, 500_000e6);
        vm.startPrank(backend);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.receivePremium(999, 500_000e6, backend);
        vm.stopPrank();

        // Create report at 100%
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: 10000, // 100%
            weatherDamage: 10000,
            satelliteDamage: 10000,
            payoutAmount: VALID_SUM_INSURED, // Full payout
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        assertTrue(payoutReceiver.policyPaid(policyId));
        assertEq(usdc.balanceOf(backendWallet), VALID_SUM_INSURED);
    }

    // ============ receiveDamageReport - Caller Validation Tests ============

    function test_ReceiveDamageReport_RevertsWithUnauthorizedCaller() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.UnauthorizedForwarder.selector,
                unauthorized,
                keystoneForwarder
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithWrongWorkflowAddress() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        address wrongWorkflow = address(999);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.InvalidWorkflowAddress.selector,
                wrongWorkflow,
                workflowAddr
            )
        );
        payoutReceiver.receiveDamageReport(report, wrongWorkflow, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithWrongWorkflowId() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        uint256 wrongId = 99999;

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.InvalidWorkflowId.selector,
                wrongId,
                VALID_WORKFLOW_ID
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, wrongId);
    }

    // ============ receiveDamageReport - Policy Validation Tests ============

    function test_ReceiveDamageReport_RevertsWithNonExistentPolicy() public {
        uint256 nonExistentPolicyId = 999;
        PayoutReceiver.DamageReport memory report = _createValidReport(nonExistentPolicyId);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.PolicyDoesNotExist.selector, nonExistentPolicyId)
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithPendingPolicy() public {
        // Create but don't activate
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer, 1, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );

        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.PolicyNotActive.selector,
                policyId,
                PolicyManager.PolicyStatus.PENDING
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithExpiredPolicy() public {
        uint256 policyId = _createAndActivatePolicy();

        // Fast forward past end date
        vm.warp(block.timestamp + (VALID_DURATION * 1 days) + 1);

        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);
        report.assessedAt = block.timestamp; // Update to current time

        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.PolicyExpired.selector,
                policyId,
                policy.endDate,
                block.timestamp
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithAlreadyPaidPolicy() public {
        uint256 policyId = _createAndActivatePolicy();

        // First payout
        _submitValidReport(policyId);

        // Try to submit again - policy is now CLAIMED, so it fails on PolicyNotActive check first
        // (status is CLAIMED = 4, not ACTIVE = 1)
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.PolicyNotActive.selector, 
                policyId, 
                PolicyManager.PolicyStatus.CLAIMED
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    // ============ receiveDamageReport - Damage Validation Tests ============

    function test_ReceiveDamageReport_RevertsWithDamageBelowThreshold() public {
        uint256 policyId = _createAndActivatePolicy();

        // 29% damage (below 30% threshold)
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: 2900, // 29%
            weatherDamage: 2900,
            satelliteDamage: 2900,
            payoutAmount: (VALID_SUM_INSURED * 2900) / 10000,
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.DamageBelowThreshold.selector, 2900, 3000)
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithDamageAboveMaximum() public {
        uint256 policyId = _createAndActivatePolicy();

        // 101% damage (invalid)
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: 10100, // 101%
            weatherDamage: 10100,
            satelliteDamage: 10100,
            payoutAmount: (VALID_SUM_INSURED * 10100) / 10000,
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.DamageExceedsMaximum.selector, 10100, 10000)
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    // ============ receiveDamageReport - Calculation Validation Tests ============

    function test_ReceiveDamageReport_RevertsWithIncorrectPayoutAmount() public {
        uint256 policyId = _createAndActivatePolicy();

        uint256 expectedPayout = (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000;
        uint256 wrongPayout = expectedPayout + 1;

        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: VALID_DAMAGE_PERCENTAGE,
            weatherDamage: VALID_WEATHER_DAMAGE,
            satelliteDamage: VALID_SATELLITE_DAMAGE,
            payoutAmount: wrongPayout, // Wrong amount
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.InvalidPayoutCalculation.selector,
                wrongPayout,
                expectedPayout
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithIncorrectWeightedDamage() public {
        uint256 policyId = _createAndActivatePolicy();

        // Weighted damage should be (60*weather + 40*satellite) / 100
        // With weather=60% and satellite=40%: (60*6000 + 40*4000)/100 = 5200
        // But we claim 50% damage
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: 5000, // 50% claimed
            weatherDamage: 6000,    // 60% weather
            satelliteDamage: 4000,  // 40% satellite
            // Actual: (60*6000 + 40*4000)/100 = 5200, not 5000
            payoutAmount: (VALID_SUM_INSURED * 5000) / 10000,
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.InvalidWeightedDamage.selector,
                5200, // Calculated
                5000  // Provided
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsWithStaleReport() public {
        uint256 policyId = _createAndActivatePolicy();

        // Warp to a time where we can go back 2 hours
        vm.warp(block.timestamp + 3 hours);

        // Report from 2 hours ago
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: VALID_DAMAGE_PERCENTAGE,
            weatherDamage: VALID_WEATHER_DAMAGE,
            satelliteDamage: VALID_SATELLITE_DAMAGE,
            payoutAmount: (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000,
            assessedAt: block.timestamp - 2 hours // Too old
        });

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.ReportTooOld.selector,
                block.timestamp - 2 hours,
                block.timestamp,
                1 hours
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_AcceptsReportJustUnderMaxAge() public {
        uint256 policyId = _createAndActivatePolicy();

        // Warp to ensure we have time to go back
        vm.warp(block.timestamp + 2 hours);

        // Report from just under 1 hour ago
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: VALID_DAMAGE_PERCENTAGE,
            weatherDamage: VALID_WEATHER_DAMAGE,
            satelliteDamage: VALID_SATELLITE_DAMAGE,
            payoutAmount: (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000,
            assessedAt: block.timestamp - 59 minutes // Just under limit
        });

        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        assertTrue(payoutReceiver.policyPaid(policyId));
    }

    // ============ receiveDamageReport - Claim Limit Tests ============

    function test_ReceiveDamageReport_RevertsWhenFarmerAtClaimLimit() public {
        // Create and process 3 policies (max claims)
        for (uint256 i = 0; i < 3; i++) {
            uint256 policyId = _createAndActivatePolicy();
            _submitValidReport(policyId);
        }

        // Create 4th policy
        uint256 fourthPolicyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(fourthPolicyId);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.FarmerClaimLimitExceeded.selector, farmer)
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    // ============ Pause Tests ============

    function test_Pause_Success() public {
        vm.prank(admin);
        payoutReceiver.pause();

        assertTrue(payoutReceiver.paused());
    }

    function test_Unpause_Success() public {
        vm.startPrank(admin);
        payoutReceiver.pause();
        payoutReceiver.unpause();
        vm.stopPrank();

        assertFalse(payoutReceiver.paused());
    }

    function test_ReceiveDamageReport_RevertsWhenPaused() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(admin);
        payoutReceiver.pause();

        vm.prank(keystoneForwarder);
        vm.expectRevert();
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    function test_Pause_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        payoutReceiver.pause();
    }

    // ============ View Function Tests ============

    function test_GetReport_ReturnsCorrectData() public {
        uint256 policyId = _createAndActivatePolicy();
        _submitValidReport(policyId);

        PayoutReceiver.DamageReport memory report = payoutReceiver.getReport(policyId);

        assertEq(report.policyId, policyId);
        assertEq(report.damagePercentage, VALID_DAMAGE_PERCENTAGE);
        assertEq(report.weatherDamage, VALID_WEATHER_DAMAGE);
        assertEq(report.satelliteDamage, VALID_SATELLITE_DAMAGE);
    }

    function test_IsPolicyPaid_ReturnsCorrectly() public {
        uint256 policyId = _createAndActivatePolicy();

        assertFalse(payoutReceiver.isPolicyPaid(policyId));

        _submitValidReport(policyId);

        assertTrue(payoutReceiver.isPolicyPaid(policyId));
    }

    function test_GetWorkflowConfig_ReturnsCorrectly() public view {
        (address addr, uint256 id) = payoutReceiver.getWorkflowConfig();
        assertEq(addr, workflowAddr);
        assertEq(id, VALID_WORKFLOW_ID);
    }

    function test_GetKeystoneForwarder_ReturnsCorrectly() public view {
        assertEq(payoutReceiver.getKeystoneForwarder(), keystoneForwarder);
    }

    // ============ Fuzz Tests ============

    function testFuzz_ReceiveDamageReport_ValidDamageRange(uint256 damagePercentage) public {
        damagePercentage = bound(damagePercentage, 3000, 10000);

        uint256 policyId = _createAndActivatePolicy();

        // Fund treasury more for potential 100% payouts
        usdc.mint(backend, 500_000e6);
        vm.startPrank(backend);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.receivePremium(888, 500_000e6, backend);
        vm.stopPrank();

        uint256 expectedPayout = (VALID_SUM_INSURED * damagePercentage) / 10000;

        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: damagePercentage,
            weatherDamage: damagePercentage, // Same for simplicity (60% * X + 40% * X = X)
            satelliteDamage: damagePercentage,
            payoutAmount: expectedPayout,
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        assertTrue(payoutReceiver.policyPaid(policyId));
    }

    // ============ Integration Tests ============

    function test_FullFlow_DamageReportToFarmerPayout() public {
        // 1. Create and activate policy
        uint256 policyId = _createAndActivatePolicy();

        // Verify initial state
        assertTrue(policyManager.isPolicyActive(policyId));
        assertFalse(payoutReceiver.policyPaid(policyId));
        uint256 backendWalletBefore = usdc.balanceOf(backendWallet);

        // 2. Submit damage report
        uint256 expectedPayout = (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000;
        _submitValidReport(policyId);

        // 3. Verify all state changes
        // - PayoutReceiver: report stored, policy marked paid
        assertTrue(payoutReceiver.policyPaid(policyId));
        PayoutReceiver.DamageReport memory report = payoutReceiver.getReport(policyId);
        assertEq(report.payoutAmount, expectedPayout);

        // - PolicyManager: policy claimed, claim count incremented
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CLAIMED));
        assertFalse(policyManager.isPolicyActive(policyId));
        assertEq(policyManager.getFarmerClaimCount(farmer, policyManager.getCurrentYear()), 1);

        // - Treasury: payout sent
        assertEq(usdc.balanceOf(backendWallet), backendWalletBefore + expectedPayout);
        assertTrue(treasury.payoutProcessed(policyId));
    }

    function test_MultiplePayouts_DifferentFarmers() public {
        address farmer2 = address(100);
        address farmer3 = address(101);

        // Fund treasury with enough for all payouts
        usdc.mint(backend, 500_000e6);
        vm.prank(backend);
        usdc.approve(address(treasury), type(uint256).max);

        // Create policies for different farmers
        vm.startPrank(backend);
        
        // Add base funding to treasury
        treasury.receivePremium(999, 300_000e6, backend);
        
        uint256 policy1 = policyManager.createPolicy(
            farmer, 1, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        policyManager.activatePolicy(policy1);

        uint256 policy2 = policyManager.createPolicy(
            farmer2, 2, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.DROUGHT
        );
        policyManager.activatePolicy(policy2);

        uint256 policy3 = policyManager.createPolicy(
            farmer3, 3, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.FLOOD
        );
        policyManager.activatePolicy(policy3);

        vm.stopPrank();

        // Submit reports for all
        _submitValidReport(policy1);
        _submitValidReport(policy2);
        _submitValidReport(policy3);

        // Verify all processed
        assertTrue(payoutReceiver.policyPaid(policy1));
        assertTrue(payoutReceiver.policyPaid(policy2));
        assertTrue(payoutReceiver.policyPaid(policy3));

        // Verify claim counts are independent
        uint256 year = policyManager.getCurrentYear();
        assertEq(policyManager.getFarmerClaimCount(farmer, year), 1);
        assertEq(policyManager.getFarmerClaimCount(farmer2, year), 1);
        assertEq(policyManager.getFarmerClaimCount(farmer3, year), 1);
    }
}
