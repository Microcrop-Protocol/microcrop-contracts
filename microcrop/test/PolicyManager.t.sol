// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/**
 * @title PolicyManagerTest
 * @notice Test suite for PolicyManager upgradeable contract
 */
contract PolicyManagerTest is BaseTest {
    // ============ Test Constants ============
    uint256 public constant VALID_SUM_INSURED = 50_000e6;
    uint256 public constant VALID_PREMIUM = 4_000e6;
    uint256 public constant VALID_DURATION = 180;
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

    function setUp() public {
        _deployContracts();
    }

    // ============ Helper Functions ============

    function _createValidPolicy(address _farmer) internal returns (uint256) {
        vm.prank(backend);
        return policyManager.createPolicy(
            _farmer,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function _createAndActivatePolicy(address _farmer) internal returns (uint256) {
        uint256 policyId = _createValidPolicy(_farmer);
        vm.prank(backend);
        policyManager.activatePolicy(policyId, distributor, DISTRIBUTOR_NAME, REGION);
        return policyId;
    }

    // ============ Initialization Tests ============

    function test_Initialize_GrantsAdminRole() public view {
        assertTrue(policyManager.hasRole(policyManager.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Initialize_GrantsUpgraderRole() public view {
        assertTrue(policyManager.hasRole(policyManager.UPGRADER_ROLE(), admin));
    }

    // ============ createPolicy Tests ============

    function test_CreatePolicy_Success() public {
        vm.prank(backend);
        uint256 policyId = policyManager.createPolicy(
            farmer,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );

        assertEq(policyId, 1);
        
        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(policy.farmer, farmer);
        assertEq(policy.sumInsured, VALID_SUM_INSURED);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.PENDING));
    }

    function test_CreatePolicy_RevertsWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        policyManager.createPolicy(
            farmer,
            VALID_PLOT_ID,
            VALID_SUM_INSURED,
            VALID_PREMIUM,
            VALID_DURATION,
            PolicyManager.CoverageType.BOTH
        );
    }

    function test_CreatePolicy_RevertsWithZeroFarmer() public {
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

    // ============ activatePolicy Tests ============

    function test_ActivatePolicy_Success() public {
        uint256 policyId = _createValidPolicy(farmer);

        vm.prank(backend);
        policyManager.activatePolicy(policyId, distributor, DISTRIBUTOR_NAME, REGION);

        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.ACTIVE));
    }

    function test_ActivatePolicy_MintsNFTToFarmer() public {
        uint256 policyId = _createValidPolicy(farmer);

        assertEq(policyNFT.balanceOf(farmer), 0);

        vm.prank(backend);
        policyManager.activatePolicy(policyId, distributor, DISTRIBUTOR_NAME, REGION);

        assertEq(policyNFT.balanceOf(farmer), 1);
        assertEq(policyNFT.ownerOf(policyId), farmer);
    }

    function test_ActivatePolicy_RevertsWithZeroDistributor() public {
        uint256 policyId = _createValidPolicy(farmer);

        vm.prank(backend);
        vm.expectRevert(PolicyManager.ZeroAddressDistributor.selector);
        policyManager.activatePolicy(policyId, address(0), DISTRIBUTOR_NAME, REGION);
    }

    function test_ActivatePolicy_RevertsWhenPolicyNotFound() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(PolicyManager.PolicyDoesNotExist.selector, 999));
        policyManager.activatePolicy(999, distributor, DISTRIBUTOR_NAME, REGION);
    }

    // ============ markAsClaimed Tests ============

    function test_MarkAsClaimed_Success() public {
        uint256 policyId = _createAndActivatePolicy(farmer);

        vm.prank(address(payoutReceiver));
        policyManager.markAsClaimed(policyId);

        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CLAIMED));
    }

    function test_MarkAsClaimed_UpdatesNFTStatus() public {
        uint256 policyId = _createAndActivatePolicy(farmer);

        (, , , , , , , , , , , bool isActiveBefore) = policyNFT.certificates(policyId);
        assertTrue(isActiveBefore);

        vm.prank(address(payoutReceiver));
        policyManager.markAsClaimed(policyId);

        (, , , , , , , , , , , bool isActiveAfter) = policyNFT.certificates(policyId);
        assertFalse(isActiveAfter);
    }

    // ============ cancelPolicy Tests ============

    function test_CancelPolicy_Success() public {
        uint256 policyId = _createAndActivatePolicy(farmer);

        vm.prank(backend);
        policyManager.cancelPolicy(policyId);

        PolicyManager.Policy memory policy = policyManager.getPolicy(policyId);
        assertEq(uint8(policy.status), uint8(PolicyManager.PolicyStatus.CANCELLED));
    }

    function test_CancelPolicy_UpdatesNFTStatus() public {
        uint256 policyId = _createAndActivatePolicy(farmer);

        vm.prank(backend);
        policyManager.cancelPolicy(policyId);

        (, , , , , , , , , , , bool isActive) = policyNFT.certificates(policyId);
        assertFalse(isActive);
    }

    // ============ View Functions ============

    function test_GetFarmerPolicies_ReturnsArray() public {
        _createValidPolicy(farmer);
        _createValidPolicy(farmer);

        uint256[] memory policies = policyManager.getFarmerPolicies(farmer);
        assertEq(policies.length, 2);
    }

    function test_IsPolicyActive_ReturnsTrue() public {
        uint256 policyId = _createAndActivatePolicy(farmer);
        assertTrue(policyManager.isPolicyActive(policyId));
    }

    function test_IsPolicyActive_ReturnsFalseForPending() public {
        uint256 policyId = _createValidPolicy(farmer);
        assertFalse(policyManager.isPolicyActive(policyId));
    }
}
