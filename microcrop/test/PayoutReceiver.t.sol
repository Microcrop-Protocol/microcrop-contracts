// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/**
 * @title PayoutReceiverTest
 * @notice Test suite for PayoutReceiver upgradeable contract
 */
contract PayoutReceiverTest is BaseTest {
    // ============ Test Constants ============
    uint256 public constant VALID_SUM_INSURED = 50_000e6;
    uint256 public constant VALID_PREMIUM = 8_000e6;
    uint256 public constant VALID_DURATION = 180;
    uint256 public constant VALID_WORKFLOW_ID = 12345;
    uint256 public constant VALID_DAMAGE_PERCENTAGE = 5000; // 50%
    
    address public workflowAddr = address(100);

    // ============ Events ============
    event DamageReportReceived(
        uint256 indexed policyId,
        uint256 damagePercentage,
        uint256 payoutAmount,
        address indexed farmer
    );

    function setUp() public {
        _deployContracts();
        
        // Configure PayoutReceiver
        vm.startPrank(admin);
        payoutReceiver.setKeystoneForwarder(keystoneForwarder);
        payoutReceiver.setWorkflowConfig(workflowAddr, VALID_WORKFLOW_ID);
        vm.stopPrank();
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
        policyManager.activatePolicy(policyId, distributor, DISTRIBUTOR_NAME, REGION);
        
        // Fund treasury
        treasury.receivePremium(policyId, 100_000e6, backend);
        vm.stopPrank();

        return policyId;
    }

    function _createValidReport(uint256 policyId) internal view returns (PayoutReceiver.DamageReport memory) {
        uint256 expectedPayout = (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000;
        return PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: VALID_DAMAGE_PERCENTAGE,
            weatherDamage: 5000,
            satelliteDamage: 5000,
            payoutAmount: expectedPayout,
            assessedAt: block.timestamp
        });
    }

    // ============ Initialization Tests ============

    function test_Initialize_SetsTreasury() public view {
        assertEq(address(payoutReceiver.treasury()), address(treasury));
    }

    function test_Initialize_SetsPolicyManager() public view {
        assertEq(address(payoutReceiver.policyManager()), address(policyManager));
    }

    // ============ setKeystoneForwarder Tests ============

    function test_SetKeystoneForwarder_Success() public {
        address newForwarder = address(999);
        
        vm.prank(admin);
        payoutReceiver.setKeystoneForwarder(newForwarder);
        
        assertEq(payoutReceiver.keystoneForwarderAddress(), newForwarder);
    }

    function test_SetKeystoneForwarder_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        payoutReceiver.setKeystoneForwarder(address(999));
    }

    // ============ setWorkflowConfig Tests ============

    function test_SetWorkflowConfig_Success() public {
        address newWorkflow = address(888);
        uint256 newId = 99999;
        
        vm.prank(admin);
        payoutReceiver.setWorkflowConfig(newWorkflow, newId);
        
        assertEq(payoutReceiver.workflowAddress(), newWorkflow);
        assertEq(payoutReceiver.workflowId(), newId);
    }

    // ============ receiveDamageReport Tests ============

    function test_ReceiveDamageReport_Success() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        // Treasury pays to backendWallet (for M-Pesa conversion)
        uint256 backendBalBefore = usdc.balanceOf(backendWallet);

        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        // Verify payout was sent to backendWallet
        uint256 expectedPayout = (VALID_SUM_INSURED * VALID_DAMAGE_PERCENTAGE) / 10000;
        assertEq(usdc.balanceOf(backendWallet), backendBalBefore + expectedPayout);
        assertTrue(payoutReceiver.policyPaid(policyId));
    }

    function test_ReceiveDamageReport_RevertsFromWrongSender() public {
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

    function test_ReceiveDamageReport_RevertsForWrongWorkflow() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.InvalidWorkflowAddress.selector,
                address(999),
                workflowAddr
            )
        );
        payoutReceiver.receiveDamageReport(report, address(999), VALID_WORKFLOW_ID);
    }

    function test_ReceiveDamageReport_RevertsForDoublePayout() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.startPrank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
        
        // After first payout, policy is CLAIMED (status 4), so PolicyNotActive is triggered first
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.PolicyNotActive.selector,
                policyId,
                PolicyManager.PolicyStatus.CLAIMED
            )
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
        vm.stopPrank();
    }

    function test_ReceiveDamageReport_RevertsBelowThreshold() public {
        uint256 policyId = _createAndActivatePolicy();
        
        PayoutReceiver.DamageReport memory report = PayoutReceiver.DamageReport({
            policyId: policyId,
            damagePercentage: 2000, // 20% - below 30% threshold
            weatherDamage: 2000,
            satelliteDamage: 2000,
            payoutAmount: (VALID_SUM_INSURED * 2000) / 10000,
            assessedAt: block.timestamp
        });

        vm.prank(keystoneForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.DamageBelowThreshold.selector, 2000, 3000)
        );
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    // ============ Pause Tests ============

    function test_Pause_BlocksReports() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(admin);
        payoutReceiver.pause();

        vm.prank(keystoneForwarder);
        vm.expectRevert();
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);
    }

    // ============ View Functions ============

    function test_PolicyPaid_ReturnsTrue() public {
        uint256 policyId = _createAndActivatePolicy();
        PayoutReceiver.DamageReport memory report = _createValidReport(policyId);

        vm.prank(keystoneForwarder);
        payoutReceiver.receiveDamageReport(report, workflowAddr, VALID_WORKFLOW_ID);

        assertTrue(payoutReceiver.policyPaid(policyId));
    }
}
