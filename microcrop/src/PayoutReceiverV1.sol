// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PolicyManagerV1} from "./PolicyManagerV1.sol";
import {TreasuryV1} from "./TreasuryV1.sol";

/**
 * @title PayoutReceiverV1
 * @notice Receives and validates damage reports from Chainlink CRE and triggers automatic payouts
 * @dev UUPS upgradeable proxy implementation. Acts as the bridge between Chainlink's oracle 
 *      infrastructure and the MicroCrop insurance system.
 *
 * Security Considerations:
 * - Only accepts calls from the configured Keystone Forwarder address
 * - Validates workflow address and ID to prevent unauthorized reports
 * - Performs 11 comprehensive validations on each damage report
 * - ReentrancyGuard and Pausable for additional safety
 * - All state changes before external calls (CEI pattern)
 * - UUPS upgrade pattern with UPGRADER_ROLE protection
 *
 * Validation Requirements (ALL must pass):
 * 1. msg.sender == keystoneForwarderAddress
 * 2. Workflow address matches config
 * 3. Workflow ID matches config
 * 4. Policy exists in PolicyManager
 * 5. Policy status == ACTIVE
 * 6. Policy not expired (block.timestamp <= endDate)
 * 7. !policyPaid[policyId] (prevent double payout)
 * 8. damagePercentage >= 3000 (30% minimum threshold)
 * 9. damagePercentage <= 10000 (100% maximum)
 * 10. Payout calculation correct: (sumInsured * damagePercentage) / 10000
 * 11. Weighted damage calculation: (60 * weather + 40 * satellite) / 100 == damage
 * 12. assessedAt is recent (within 1 hour)
 */
contract PayoutReceiverV1 is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ============ Type Declarations ============

    /**
     * @notice Structure containing damage assessment data from Chainlink CRE
     * @param policyId The policy being assessed
     * @param damagePercentage Total damage in basis points (0-10000 = 0-100%)
     * @param weatherDamage Weather-based damage in basis points
     * @param satelliteDamage Satellite-based vegetation damage in basis points
     * @param payoutAmount Calculated payout in USDC (6 decimals)
     * @param assessedAt Unix timestamp when assessment was made
     */
    struct DamageReport {
        uint256 policyId;
        uint256 damagePercentage;
        uint256 weatherDamage;
        uint256 satelliteDamage;
        uint256 payoutAmount;
        uint256 assessedAt;
    }

    // ============ Constants ============

    /// @notice Minimum damage threshold for payout (30% = 3000 basis points)
    uint256 public constant MIN_DAMAGE_THRESHOLD = 3000;

    /// @notice Maximum damage percentage (100% = 10000 basis points)
    uint256 public constant MAX_DAMAGE_PERCENTAGE = 10000;

    /// @notice Weather damage weight (60%)
    uint256 public constant WEATHER_WEIGHT = 60;

    /// @notice Satellite damage weight (40%)
    uint256 public constant SATELLITE_WEIGHT = 40;

    /// @notice Maximum age for damage report (1 hour)
    uint256 public constant MAX_REPORT_AGE = 1 hours;

    /// @notice Basis points denominator
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Weight denominator (100%)
    uint256 private constant WEIGHT_DENOMINATOR = 100;

    // ============ Role Definitions ============

    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Upgrader role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ State Variables ============
    // NOTE: Storage layout must be preserved across upgrades

    /// @notice Reference to the Treasury contract
    TreasuryV1 public treasury;

    /// @notice Reference to the PolicyManager contract
    PolicyManagerV1 public policyManager;

    /// @notice Address of the Chainlink Keystone Forwarder
    address public keystoneForwarderAddress;

    /// @notice Configured workflow address for validation
    address public workflowAddress;

    /// @notice Configured workflow ID for validation
    uint256 public workflowId;

    /// @notice Mapping from policy ID to damage report
    mapping(uint256 => DamageReport) private _damageReports;

    /// @notice Mapping to track if a policy has been paid
    mapping(uint256 => bool) public policyPaid;

    /// @dev Reserved storage gap for future upgrades (50 slots)
    uint256[50] private __gap;

    // ============ Events ============

    /**
     * @notice Emitted when a valid damage report is received and processed
     * @param policyId The policy that was assessed
     * @param damagePercentage The damage percentage in basis points
     * @param payoutAmount The payout amount in USDC
     * @param farmer The farmer receiving the payout
     */
    event DamageReportReceived(
        uint256 indexed policyId,
        uint256 damagePercentage,
        uint256 payoutAmount,
        address indexed farmer
    );

    /**
     * @notice Emitted when a payout is initiated
     * @param policyId The policy for which payout was initiated
     * @param amount The payout amount
     */
    event PayoutInitiated(uint256 indexed policyId, uint256 amount);

    /**
     * @notice Emitted when workflow configuration is updated
     * @param workflowAddress The new workflow address
     * @param workflowId The new workflow ID
     */
    event WorkflowConfigUpdated(address indexed workflowAddress, uint256 workflowId);

    /**
     * @notice Emitted when Keystone Forwarder address is updated
     * @param oldAddress The previous forwarder address
     * @param newAddress The new forwarder address
     */
    event KeystoneForwarderUpdated(address indexed oldAddress, address indexed newAddress);

    // ============ Custom Errors ============

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when caller is not the Keystone Forwarder
    error UnauthorizedForwarder(address caller, address expected);

    /// @notice Thrown when workflow address doesn't match
    error InvalidWorkflowAddress(address provided, address expected);

    /// @notice Thrown when workflow ID doesn't match
    error InvalidWorkflowId(uint256 provided, uint256 expected);

    /// @notice Thrown when policy does not exist
    error PolicyDoesNotExist(uint256 policyId);

    /// @notice Thrown when policy is not active
    error PolicyNotActive(uint256 policyId, PolicyManagerV1.PolicyStatus status);

    /// @notice Thrown when policy has expired
    error PolicyExpired(uint256 policyId, uint256 endDate, uint256 currentTime);

    /// @notice Thrown when policy has already been paid
    error PolicyAlreadyPaid(uint256 policyId);

    /// @notice Thrown when damage is below minimum threshold
    error DamageBelowThreshold(uint256 damage, uint256 minimum);

    /// @notice Thrown when damage exceeds maximum
    error DamageExceedsMaximum(uint256 damage, uint256 maximum);

    /// @notice Thrown when payout calculation is incorrect
    error InvalidPayoutCalculation(uint256 provided, uint256 expected);

    /// @notice Thrown when weighted damage calculation is incorrect
    error InvalidWeightedDamage(uint256 calculated, uint256 provided);

    /// @notice Thrown when damage report is too old
    error ReportTooOld(uint256 assessedAt, uint256 currentTime, uint256 maxAge);

    /// @notice Thrown when farmer has exceeded yearly claim limit
    error FarmerClaimLimitExceeded(address farmer);

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initializes the PayoutReceiver contract
     * @dev Replaces constructor for upgradeable contracts. Can only be called once.
     * @param _treasury Address of the Treasury contract
     * @param _policyManager Address of the PolicyManager contract
     * @param _admin Address to receive admin roles
     */
    function initialize(
        address _treasury,
        address _policyManager,
        address _admin
    ) external initializer {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_policyManager == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        treasury = TreasuryV1(_treasury);
        policyManager = PolicyManagerV1(_policyManager);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    // ============ UUPS Authorization ============

    /**
     * @notice Authorizes contract upgrades
     * @dev Only addresses with UPGRADER_ROLE can authorize upgrades
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ External Functions ============

    /**
     * @notice Receives and processes a damage report from Chainlink CRE
     * @dev Only callable via the Keystone Forwarder. Performs comprehensive validation
     *      of all report parameters before triggering payout.
     *
     * Validation Order:
     * 1. Caller validation (Keystone Forwarder)
     * 2. Workflow validation (address + ID)
     * 3. Policy validation (exists, active, not expired)
     * 4. Payout validation (not already paid)
     * 5. Damage validation (threshold, maximum)
     * 6. Calculation validation (payout amount, weighted damage)
     * 7. Timestamp validation (report freshness)
     * 8. Farmer claim limit validation
     *
     * @param report The damage report from Chainlink CRE
     * @param reportedWorkflowAddress The workflow address from the report
     * @param reportedWorkflowId The workflow ID from the report
     */
    function receiveDamageReport(
        DamageReport calldata report,
        address reportedWorkflowAddress,
        uint256 reportedWorkflowId
    ) external nonReentrant whenNotPaused {
        // 1. Validate caller is Keystone Forwarder
        if (msg.sender != keystoneForwarderAddress) {
            revert UnauthorizedForwarder(msg.sender, keystoneForwarderAddress);
        }

        // 2. Validate workflow address
        if (reportedWorkflowAddress != workflowAddress) {
            revert InvalidWorkflowAddress(reportedWorkflowAddress, workflowAddress);
        }

        // 3. Validate workflow ID
        if (reportedWorkflowId != workflowId) {
            revert InvalidWorkflowId(reportedWorkflowId, workflowId);
        }

        // 4. Validate policy exists
        if (!policyManager.policyExists(report.policyId)) {
            revert PolicyDoesNotExist(report.policyId);
        }

        // Get policy data
        PolicyManagerV1.Policy memory policy = policyManager.getPolicy(report.policyId);

        // 5. Validate policy is active
        if (policy.status != PolicyManagerV1.PolicyStatus.ACTIVE) {
            revert PolicyNotActive(report.policyId, policy.status);
        }

        // 6. Validate policy not expired
        if (block.timestamp > policy.endDate) {
            revert PolicyExpired(report.policyId, policy.endDate, block.timestamp);
        }

        // 7. Validate not already paid
        if (policyPaid[report.policyId]) {
            revert PolicyAlreadyPaid(report.policyId);
        }

        // 8. Validate damage above threshold
        if (report.damagePercentage < MIN_DAMAGE_THRESHOLD) {
            revert DamageBelowThreshold(report.damagePercentage, MIN_DAMAGE_THRESHOLD);
        }

        // 9. Validate damage doesn't exceed maximum
        if (report.damagePercentage > MAX_DAMAGE_PERCENTAGE) {
            revert DamageExceedsMaximum(report.damagePercentage, MAX_DAMAGE_PERCENTAGE);
        }

        // 10. Validate payout calculation
        uint256 expectedPayout = (policy.sumInsured * report.damagePercentage) / BASIS_POINTS;
        if (report.payoutAmount != expectedPayout) {
            revert InvalidPayoutCalculation(report.payoutAmount, expectedPayout);
        }

        // 11. Validate weighted damage calculation
        uint256 calculatedDamage = (
            (WEATHER_WEIGHT * report.weatherDamage) + 
            (SATELLITE_WEIGHT * report.satelliteDamage)
        ) / WEIGHT_DENOMINATOR;
        if (calculatedDamage != report.damagePercentage) {
            revert InvalidWeightedDamage(calculatedDamage, report.damagePercentage);
        }

        // 12. Validate report is recent (within 1 hour)
        if (block.timestamp > report.assessedAt + MAX_REPORT_AGE) {
            revert ReportTooOld(report.assessedAt, block.timestamp, MAX_REPORT_AGE);
        }

        // 13. Check farmer claim limit
        if (!policyManager.canFarmerClaim(policy.farmer)) {
            revert FarmerClaimLimitExceeded(policy.farmer);
        }

        // ============ All validations passed - Process payout ============

        // Store report (state update BEFORE external calls - CEI)
        _damageReports[report.policyId] = report;
        policyPaid[report.policyId] = true;

        // Request payout from Treasury
        treasury.requestPayout(report.policyId, report.payoutAmount);

        // Update PolicyManager state
        policyManager.markAsClaimed(report.policyId);
        policyManager.incrementClaimCount(policy.farmer);

        // Emit events
        emit DamageReportReceived(
            report.policyId,
            report.damagePercentage,
            report.payoutAmount,
            policy.farmer
        );
        emit PayoutInitiated(report.policyId, report.payoutAmount);
    }

    /**
     * @notice Sets the Keystone Forwarder address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param _keystoneForwarder Address of the Chainlink Keystone Forwarder
     */
    function setKeystoneForwarder(address _keystoneForwarder) external onlyRole(ADMIN_ROLE) {
        if (_keystoneForwarder == address(0)) revert ZeroAddress();

        address oldAddress = keystoneForwarderAddress;
        keystoneForwarderAddress = _keystoneForwarder;

        emit KeystoneForwarderUpdated(oldAddress, _keystoneForwarder);
    }

    /**
     * @notice Sets the workflow configuration for validation
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param _workflowAddress Address of the authorized workflow
     * @param _workflowId ID of the authorized workflow
     */
    function setWorkflowConfig(
        address _workflowAddress,
        uint256 _workflowId
    ) external onlyRole(ADMIN_ROLE) {
        if (_workflowAddress == address(0)) revert ZeroAddress();

        workflowAddress = _workflowAddress;
        workflowId = _workflowId;

        emit WorkflowConfigUpdated(_workflowAddress, _workflowId);
    }

    /**
     * @notice Pauses the contract in case of emergency
     * @dev Only callable by addresses with ADMIN_ROLE
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract after emergency is resolved
     * @dev Only callable by addresses with ADMIN_ROLE
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Retrieves the damage report for a policy
     * @param policyId The policy to get the report for
     * @return report The damage report
     */
    function getReport(uint256 policyId) external view returns (DamageReport memory report) {
        return _damageReports[policyId];
    }

    /**
     * @notice Checks if a policy has been paid
     * @param policyId The policy to check
     * @return paid True if the policy has been paid
     */
    function isPolicyPaid(uint256 policyId) external view returns (bool paid) {
        return policyPaid[policyId];
    }

    /**
     * @notice Gets the current workflow configuration
     * @return _workflowAddress The configured workflow address
     * @return _workflowId The configured workflow ID
     */
    function getWorkflowConfig() external view returns (address _workflowAddress, uint256 _workflowId) {
        return (workflowAddress, workflowId);
    }

    /**
     * @notice Gets the Keystone Forwarder address
     * @return forwarder The Keystone Forwarder address
     */
    function getKeystoneForwarder() external view returns (address forwarder) {
        return keystoneForwarderAddress;
    }

    /**
     * @notice Returns the contract version for upgrade tracking
     * @return The contract version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
