// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/**
 * @title PolicyManagerTest
 * @notice Comprehensive test suite for PolicyManager contract
 * @dev Tests cover happy paths, access control, input validation,
 *      edge cases, and state transitions as required by specs
 */
contract PolicyManagerTest is Test {
    // ============ Contracts ============
    PolicyManager public policyManager;

    // ============ Test Addresses ============
    address public admin = address(1);
    address public backend = address(2);
    address public oracle = address(3);
    address public farmer1 = address(4);
    address public farmer2 = address(5);
    address public unauthorized = address(6);

    // ============ Test Constants ============
    uint256 public constant VALID_SUM_INSURED = 50_000e6; // 50,000 USDC
    uint256 public constant VALID_PREMIUM = 4_000e6; // 4,000 USDC
    uint256 public constant VALID_DURATION = 180; // 180 days
    uint256 public constant VALID_PLOT_ID = 12345;

    // ============ Events ============
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed farmer,
        uint256 indexed plotId,
        uint256 sumInsured,
        uint256 premium,
        uint256 startDate,
        uint256 endDate,
        PolicyManager.CoverageType coverageType
    );
    event PolicyActivated(uint256 indexed policyId, uint256 activatedAt);
    event PolicyClaimed(uint256 indexed policyId, uint256 claimedAt);
    event PolicyCancelled(uint256 indexed policyId, uint256 cancelledAt);
    event ClaimCountIncremented(
        address indexed farmer,
        uint256 indexed year,
        uint256 newCount
    );

    // ============ Setup ============

    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy PolicyManager
        policyManager = new PolicyManager();
        
        // Grant roles
        policyManager.grantRole(policyManager.BACKEND_ROLE(), backend);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), oracle);
        
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _createValidPolicy(address farmer) internal returns (uint256) {
        vm.prank(backend);
        return policyManager.createPolicy(
            farmer,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function _createAndActivatePolicy(address farmer) internal returns (uint256) {
        uint256 policyId = _createValidPolicy(farmer);
        vm.prank(backend);
        policyManager.activatePolicy(policyId);
        return policyId;
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsDefaultAdminRole() public view {
        assertTrue(policyManager.hasRole(policyManager.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_SetsAdminRole() public view {
        assertTrue(policyManager.hasRole(policyManager.ADMIN_ROLE(), admin));
    }

    // ============ Role Configuration Tests ============

    function test_BackendRole_CorrectlyConfigured() public view {
        assertTrue(policyManager.hasRole(policyManager.BACKEND_ROLE(), backend));
        assertFalse(policyManager.hasRole(policyManager.BACKEND_ROLE(), unauthorized));
    }

    function test_OracleRole_CorrectlyConfigured() public view {
        assertTrue(policyManager.hasRole(policyManager.ORACLE_ROLE(), oracle));
        assertFalse(policyManager.hasRole(policyManager.ORACLE_ROLE(), unauthorized));
    }

    // ============ createPolicy Tests ============

    function test_CreatePolicy_Success() public {
        vm.prank(backend);
        
        vm.expectEmit(true, true, true, true);
        emit PolicyCreated(
            1,
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            block.timestamp,
            block.timestamp + (VALID_DURATION * 1 days),
            PolicyManager.CoverageType.BOTH
        );
        
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
        
        assertEq(policyId, 1);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.id, 1);
        assertEq(policy.farmer, farmer1);
        assertEq(policy.plotId, VALID_PLOT_ID);
        assertEq(policy.sumInsured, VALID_SUM_INSURED);
        assertEq(policy.premium, VALID_PREMIUM);
        assertEq(policy.startDate, block.timestamp);
        assertEq(policy.endDate, block.timestamp + (VALID_DURATION * 1 days));
        assertEq(uint8(policy.coverageType), uint8(PolicyManager.CoverageType.BOTH));
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.PENDING));
    }

    function test_CreatePolicy_WithDroughtCoverage() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.DROUGHT
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.coverageType), uint8(PolicyManager.CoverageType.DROUGHT));
    }

    function test_CreatePolicy_WithFloodCoverage() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.FLOOD
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.coverageType), uint8(PolicyManager.CoverageType.FLOOD));
    }

    function test_CreatePolicy_MultiplePoliciesIncrementCounter() public {
        vm.startPrank(backend);
        
        uint256 id1 = policyManager.createPolicy(
            farmer1, 1, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        uint256 id2 = policyManager.createPolicy(
            farmer2, 2, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        uint256 id3 = policyManager.createPolicy(
            farmer1, 3, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        
        vm.stopPrank();
        
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(policyManager.getTotalPolicies(), 3);
    }

    function test_CreatePolicy_UpdatesFarmerPoliciesArray() public {
        uint256 id1 = _createValidPolicy(farmer1);
        
        vm.prank(backend);
        uint256 id2 = policyManager.createPolicy(
            farmer1, 2, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        
        uint256[] memory policies = policyManager.getFarmerPolicies(farmer1);
        assertEq(policies.length, 2);
        assertEq(policies[0], id1);
        assertEq(policies[1], id2);
    }

    // ============ createPolicy Access Control Tests ============

    function test_CreatePolicy_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        
        vm.expectRevert();
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWhenCalledByAdmin() public {
        vm.prank(admin);
        
        vm.expectRevert();
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWhenCalledByOracle() public {
        vm.prank(oracle);
        
        vm.expectRevert();
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    // ============ createPolicy Validation Tests ============

    function test_CreatePolicy_RevertsWithZeroAddressFarmer() public {
        vm.prank(backend);
        
        vm.expectRevert(PolicyManager.ZeroAddressFarmer.selector);
        policyManager.createPolicy(
            address(0),
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWithSumInsuredTooLow() public {
        uint256 tooLow = 10_000e6 - 1; // Just below minimum
        
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.SumInsuredTooLow.selector,
                tooLow,
                10_000e6
            )
        );
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            tooLow,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWithSumInsuredTooHigh() public {
        uint256 tooHigh = 1_000_000e6 + 1; // Just above maximum
        
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.SumInsuredTooHigh.selector,
                tooHigh,
                1_000_000e6
            )
        );
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            tooHigh,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_AcceptsMinimumSumInsured() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            10_000e6, // Exact minimum
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.sumInsured, 10_000e6);
    }

    function test_CreatePolicy_AcceptsMaximumSumInsured() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            1_000_000e6, // Exact maximum
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.sumInsured, 1_000_000e6);
    }

    function test_CreatePolicy_RevertsWithZeroPremium() public {
        vm.prank(backend);
        
        vm.expectRevert(PolicyManager.ZeroPremium.selector);
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            0, // Zero premium
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWithDurationTooShort() public {
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.InvalidDuration.selector,
                29, // Too short
                30,
                365
            )
        );
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            29, // Below minimum
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWithDurationTooLong() public {
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.InvalidDuration.selector,
                366, // Too long
                30,
                365
            )
        );
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            366, // Above maximum
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_AcceptsMinimumDuration() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            30, // Exact minimum
            PolicyManager.CoverageType.BOTH
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.endDate, policy.startDate + (30 * 1 days));
    }

    function test_CreatePolicy_AcceptsMaximumDuration() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            365, // Exact maximum
            PolicyManager.CoverageType.BOTH
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.endDate, policy.startDate + (365 * 1 days));
    }

    function test_CreatePolicy_RevertsWhenFarmerHasMaxActivePolicies() public {
        vm.startPrank(backend);
        
        // Create and activate 5 policies (maximum allowed)
        for (uint256 i = 0; i < 5; i++) {
            uint256 id = policyManager.createPolicy(
                farmer1, i, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
            );
            policyManager.activatePolicy(id);
        }
        
        vm.stopPrank();
        
        // Try to create 6th policy
        vm.prank(backend);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.TooManyActivePolicies.selector,
                farmer1,
                5,
                5
            )
        );
        policyManager.createPolicy(
            farmer1,
            6,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_AllowsNewPolicyAfterOneIsClaimed() public {
        // Create and activate 5 policies
        vm.startPrank(backend);
        uint256[] memory policyIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            policyIds[i] = policyManager.createPolicy(
                farmer1, i, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
            );
            policyManager.activatePolicy(policyIds[i]);
        }
        vm.stopPrank();
        
        // Mark first policy as claimed (via oracle)
        vm.prank(oracle);
        policyManager.markAsClaimed(policyIds[0]);
        
        // Should now be able to create another policy
        vm.prank(backend);
        uint256 newPolicyId = policyManager.createPolicy(
            farmer1, 10, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        
        assertEq(newPolicyId, 6);
    }

    // ============ activatePolicy Tests ============

    function test_ActivatePolicy_Success() public {
        uint256 policyId = _createValidPolicy(farmer1);
        
        vm.prank(backend);
        
        vm.expectEmit(true, true, true, true);
        emit PolicyActivated(policyId, block.timestamp);
        
        policyManager.activatePolicy(policyId);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.ACTIVE));
    }

    function test_ActivatePolicy_IncrementsFarmerActiveCount() public {
        assertEq(policyManager.getFarmerActiveCount(farmer1), 0);
        
        uint256 policyId = _createValidPolicy(farmer1);
        
        vm.prank(backend);
        policyManager.activatePolicy(policyId);
        
        assertEq(policyManager.getFarmerActiveCount(farmer1), 1);
    }

    function test_ActivatePolicy_RevertsWhenPolicyDoesNotExist() public {
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(PolicyManager.PolicyDoesNotExist.selector, 999)
        );
        policyManager.activatePolicy(999);
    }

    function test_ActivatePolicy_RevertsWhenAlreadyActive() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.InvalidPolicyStatus.selector,
                policyId,
                PolicyManager.PolicyStatus.ACTIVE,
                PolicyManager.PolicyStatus.PENDING
            )
        );
        policyManager.activatePolicy(policyId);
    }

    function test_ActivatePolicy_RevertsWhenUnauthorized() public {
        uint256 policyId = _createValidPolicy(farmer1);
        
        vm.prank(unauthorized);
        
        vm.expectRevert();
        policyManager.activatePolicy(policyId);
    }

    // ============ markAsClaimed Tests ============

    function test_MarkAsClaimed_Success() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        vm.prank(oracle);
        
        vm.expectEmit(true, true, true, true);
        emit PolicyClaimed(policyId, block.timestamp);
        
        policyManager.markAsClaimed(policyId);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CLAIMED));
    }

    function test_MarkAsClaimed_DecrementsFarmerActiveCount() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        assertEq(policyManager.getFarmerActiveCount(farmer1), 1);
        
        vm.prank(oracle);
        policyManager.markAsClaimed(policyId);
        
        assertEq(policyManager.getFarmerActiveCount(farmer1), 0);
    }

    function test_MarkAsClaimed_RevertsWhenNotActive() public {
        uint256 policyId = _createValidPolicy(farmer1); // Still PENDING
        
        vm.prank(oracle);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.InvalidPolicyStatus.selector,
                policyId,
                PolicyManager.PolicyStatus.PENDING,
                PolicyManager.PolicyStatus.ACTIVE
            )
        );
        policyManager.markAsClaimed(policyId);
    }

    function test_MarkAsClaimed_RevertsWhenExpired() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        
        // Fast forward past end date
        vm.warp(block.timestamp + (VALID_DURATION * 1 days) + 1);
        
        vm.prank(oracle);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.PolicyExpired.selector,
                policyId,
                policy.endDate,
                block.timestamp
            )
        );
        policyManager.markAsClaimed(policyId);
    }

    function test_MarkAsClaimed_RevertsWhenPolicyDoesNotExist() public {
        vm.prank(oracle);
        
        vm.expectRevert(
            abi.encodeWithSelector(PolicyManager.PolicyDoesNotExist.selector, 999)
        );
        policyManager.markAsClaimed(999);
    }

    function test_MarkAsClaimed_RevertsWhenUnauthorized() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        vm.prank(unauthorized);
        
        vm.expectRevert();
        policyManager.markAsClaimed(policyId);
    }

    function test_MarkAsClaimed_RevertsWhenCalledByBackend() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        vm.prank(backend);
        
        vm.expectRevert();
        policyManager.markAsClaimed(policyId);
    }

    // ============ incrementClaimCount Tests ============

    function test_IncrementClaimCount_Success() public {
        uint256 currentYear = policyManager.getCurrentYear();
        
        vm.prank(oracle);
        
        vm.expectEmit(true, true, true, true);
        emit ClaimCountIncremented(farmer1, currentYear, 1);
        
        policyManager.incrementClaimCount(farmer1);
        
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 1);
    }

    function test_IncrementClaimCount_AllowsUpToThree() public {
        uint256 currentYear = policyManager.getCurrentYear();
        
        vm.startPrank(oracle);
        
        policyManager.incrementClaimCount(farmer1);
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 1);
        
        policyManager.incrementClaimCount(farmer1);
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 2);
        
        policyManager.incrementClaimCount(farmer1);
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 3);
        
        vm.stopPrank();
    }

    function test_IncrementClaimCount_RevertsOnFourthClaim() public {
        uint256 currentYear = policyManager.getCurrentYear();
        
        vm.startPrank(oracle);
        
        policyManager.incrementClaimCount(farmer1);
        policyManager.incrementClaimCount(farmer1);
        policyManager.incrementClaimCount(farmer1);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.TooManyClaimsThisYear.selector,
                farmer1,
                currentYear,
                3,
                3
            )
        );
        policyManager.incrementClaimCount(farmer1);
        
        vm.stopPrank();
    }

    function test_IncrementClaimCount_ResetsEachYear() public {
        vm.startPrank(oracle);
        
        // Use 3 claims this year
        policyManager.incrementClaimCount(farmer1);
        policyManager.incrementClaimCount(farmer1);
        policyManager.incrementClaimCount(farmer1);
        
        uint256 currentYear = policyManager.getCurrentYear();
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 3);
        
        // Move to next year
        vm.warp(block.timestamp + 365 days);
        
        uint256 nextYear = policyManager.getCurrentYear();
        assertEq(policyManager.getFarmerClaimCount(farmer1, nextYear), 0);
        
        // Should be able to claim again
        policyManager.incrementClaimCount(farmer1);
        assertEq(policyManager.getFarmerClaimCount(farmer1, nextYear), 1);
        
        vm.stopPrank();
    }

    function test_IncrementClaimCount_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        
        vm.expectRevert();
        policyManager.incrementClaimCount(farmer1);
    }

    // ============ cancelPolicy Tests ============

    function test_CancelPolicy_FromPending() public {
        uint256 policyId = _createValidPolicy(farmer1);
        
        vm.prank(backend);
        
        vm.expectEmit(true, true, true, true);
        emit PolicyCancelled(policyId, block.timestamp);
        
        policyManager.cancelPolicy(policyId);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CANCELLED));
    }

    function test_CancelPolicy_FromActive() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        assertEq(policyManager.getFarmerActiveCount(farmer1), 1);
        
        vm.prank(backend);
        policyManager.cancelPolicy(policyId);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CANCELLED));
        assertEq(policyManager.getFarmerActiveCount(farmer1), 0);
    }

    function test_CancelPolicy_RevertsWhenAlreadyClaimed() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        vm.prank(oracle);
        policyManager.markAsClaimed(policyId);
        
        vm.prank(backend);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.InvalidPolicyStatus.selector,
                policyId,
                PolicyManager.PolicyStatus.CLAIMED,
                PolicyManager.PolicyStatus.ACTIVE
            )
        );
        policyManager.cancelPolicy(policyId);
    }

    function test_CancelPolicy_RevertsWhenUnauthorized() public {
        uint256 policyId = _createValidPolicy(farmer1);
        
        vm.prank(unauthorized);
        
        vm.expectRevert();
        policyManager.cancelPolicy(policyId);
    }

    // ============ View Function Tests ============

    function test_GetPolicy_ReturnsCorrectData() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.DROUGHT
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        
        assertEq(policy.id, policyId);
        assertEq(policy.farmer, farmer1);
        assertEq(policy.plotId, VALID_PLOT_ID);
        assertEq(policy.sumInsured, VALID_SUM_INSURED);
        assertEq(policy.premium, VALID_PREMIUM);
        assertEq(uint8(policy.coverageType), uint8(PolicyManager.CoverageType.DROUGHT));
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.PENDING));
    }

    function test_GetPolicy_RevertsForNonExistentPolicy() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolicyManager.PolicyDoesNotExist.selector, 999)
        );
        policyManager.getPolicy(999);
    }

    function test_GetFarmerPolicies_ReturnsCorrectArray() public {
        vm.startPrank(backend);
        
        uint256 id1 = policyManager.createPolicy(
            farmer1, 1, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        uint256 id2 = policyManager.createPolicy(
            farmer1, 2, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        
        // Create policy for different farmer
        policyManager.createPolicy(
            farmer2, 3, VALID_SUM_INSURED, VALID_PREMIUM, VALID_DURATION, PolicyManager.CoverageType.BOTH
        );
        
        vm.stopPrank();
        
        uint256[] memory farmer1Policies = policyManager.getFarmerPolicies(farmer1);
        uint256[] memory farmer2Policies = policyManager.getFarmerPolicies(farmer2);
        
        assertEq(farmer1Policies.length, 2);
        assertEq(farmer1Policies[0], id1);
        assertEq(farmer1Policies[1], id2);
        
        assertEq(farmer2Policies.length, 1);
    }

    function test_GetFarmerPolicies_ReturnsEmptyForNewFarmer() public view {
        uint256[] memory policies = policyManager.getFarmerPolicies(farmer1);
        assertEq(policies.length, 0);
    }

    function test_IsPolicyActive_ReturnsTrueForActivePolicy() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        assertTrue(policyManager.isPolicyActive(policyId));
    }

    function test_IsPolicyActive_ReturnsFalseForPendingPolicy() public {
        uint256 policyId = _createValidPolicy(farmer1);
        
        assertFalse(policyManager.isPolicyActive(policyId));
    }

    function test_IsPolicyActive_ReturnsFalseForExpiredPolicy() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        // Fast forward past end date
        vm.warp(block.timestamp + (VALID_DURATION * 1 days) + 1);
        
        assertFalse(policyManager.isPolicyActive(policyId));
    }

    function test_IsPolicyActive_ReturnsFalseForClaimedPolicy() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        vm.prank(oracle);
        policyManager.markAsClaimed(policyId);
        
        assertFalse(policyManager.isPolicyActive(policyId));
    }

    function test_IsPolicyActive_ReturnsFalseForNonExistentPolicy() public view {
        assertFalse(policyManager.isPolicyActive(999));
    }

    function test_CanFarmerClaim_ReturnsTrueWhenUnderLimit() public view {
        assertTrue(policyManager.canFarmerClaim(farmer1));
    }

    function test_CanFarmerClaim_ReturnsFalseWhenAtLimit() public {
        vm.startPrank(oracle);
        policyManager.incrementClaimCount(farmer1);
        policyManager.incrementClaimCount(farmer1);
        policyManager.incrementClaimCount(farmer1);
        vm.stopPrank();
        
        assertFalse(policyManager.canFarmerClaim(farmer1));
    }

    function test_PolicyExists_ReturnsCorrectly() public {
        uint256 policyId = _createValidPolicy(farmer1);
        
        assertTrue(policyManager.policyExists(policyId));
        assertFalse(policyManager.policyExists(999));
    }

    function test_GetTotalPolicies_ReturnsCorrectCount() public {
        assertEq(policyManager.getTotalPolicies(), 0);
        
        _createValidPolicy(farmer1);
        assertEq(policyManager.getTotalPolicies(), 1);
        
        _createValidPolicy(farmer2);
        assertEq(policyManager.getTotalPolicies(), 2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_CreatePolicy_ValidDurations(uint256 duration) public {
        duration = bound(duration, 30, 365);
        
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            duration,
            PolicyManager.CoverageType.BOTH
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.endDate, policy.startDate + (duration * 1 days));
    }

    function testFuzz_CreatePolicy_ValidSumInsured(uint256 sumInsured) public {
        sumInsured = bound(sumInsured, 10_000e6, 1_000_000e6);
        
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            sumInsured,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.sumInsured, sumInsured);
    }

    function testFuzz_CreatePolicy_InvalidDurationReverts(uint256 duration) public {
        vm.assume(duration < 30 || duration > 365);
        
        vm.prank(backend);
        
        vm.expectRevert();
        policyManager.createPolicy(
            farmer1,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            duration,
            PolicyManager.CoverageType.BOTH
        );
    }

    // ============ Integration Tests ============

    function test_FullPolicyLifecycle_PendingToActive() public {
        // Create policy
        uint256 policyId = _createValidPolicy(farmer1);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.PENDING));
        
        // Activate
        vm.prank(backend);
        policyManager.activatePolicy(policyId);
        
        policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.ACTIVE));
        assertTrue(policyManager.isPolicyActive(policyId));
    }

    function test_FullPolicyLifecycle_ActiveToClaimed() public {
        uint256 policyId = _createAndActivatePolicy(farmer1);
        
        // Claim
        vm.prank(oracle);
        policyManager.markAsClaimed(policyId);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CLAIMED));
        assertFalse(policyManager.isPolicyActive(policyId));
        
        // Increment claim count
        vm.prank(oracle);
        policyManager.incrementClaimCount(farmer1);
        
        uint256 currentYear = policyManager.getCurrentYear();
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 1);
    }

    function test_MultipleFarmers_IndependentTracking() public {
        // Create policies for both farmers
        _createAndActivatePolicy(farmer1);
        _createAndActivatePolicy(farmer2);
        
        assertEq(policyManager.getFarmerActiveCount(farmer1), 1);
        assertEq(policyManager.getFarmerActiveCount(farmer2), 1);
        
        // Claim for farmer1
        vm.startPrank(oracle);
        policyManager.markAsClaimed(1);
        policyManager.incrementClaimCount(farmer1);
        vm.stopPrank();
        
        // Verify independent tracking
        assertEq(policyManager.getFarmerActiveCount(farmer1), 0);
        assertEq(policyManager.getFarmerActiveCount(farmer2), 1);
        
        uint256 currentYear = policyManager.getCurrentYear();
        assertEq(policyManager.getFarmerClaimCount(farmer1, currentYear), 1);
        assertEq(policyManager.getFarmerClaimCount(farmer2, currentYear), 0);
    }
}
