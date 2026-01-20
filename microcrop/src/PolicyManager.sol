// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PolicyManager
 * @notice Manages the complete lifecycle of parametric crop insurance policies
 * @dev Handles policy creation, activation, and claims tracking with comprehensive
 *      access control and validation. This contract is the core registry for all
 *      insurance policies in the MicroCrop ecosystem.
 *
 * Security Considerations:
 * - All state-changing functions are protected by access control
 * - ReentrancyGuard prevents reentrancy attacks
 * - Comprehensive input validation on all parameters
 * - Events emitted for all state changes for auditability
 *
 * Role Hierarchy:
 * - DEFAULT_ADMIN_ROLE: Can grant/revoke all roles (should be multi-sig)
 * - ADMIN_ROLE: Can manage contract settings
 * - BACKEND_ROLE: Can create and activate policies
 * - ORACLE_ROLE: Can mark policies as claimed (PayoutReceiver only)
 */
contract PolicyManager is AccessControl, ReentrancyGuard {
    // ============ Type Declarations ============

    /**
     * @notice Types of coverage available for policies
     * @dev DROUGHT covers drought damage, FLOOD covers flood damage,
     *      BOTH covers both types of events
     */
    enum CoverageType {
        DROUGHT,
        FLOOD,
        BOTH
    }

    /**
     * @notice Status states for a policy throughout its lifecycle
     * @dev PENDING: Created but not yet active (awaiting premium)
     *      ACTIVE: Premium paid, policy in force
     *      EXPIRED: Policy end date has passed without claim
     *      CANCELLED: Policy cancelled before end date
     *      CLAIMED: Payout has been processed for this policy
     */
    enum PolicyStatus {
        PENDING,
        ACTIVE,
        EXPIRED,
        CANCELLED,
        CLAIMED
    }

    /**
     * @notice Complete policy data structure
     * @param id Unique policy identifier (auto-incremented)
     * @param farmer Address of the insured farmer
     * @param plotId Off-chain reference to the insured plot
     * @param sumInsured Maximum coverage amount in USDC (6 decimals)
     * @param premium Premium amount paid in USDC (6 decimals)
     * @param startDate Unix timestamp when coverage begins
     * @param endDate Unix timestamp when coverage ends
     * @param coverageType Type of coverage (DROUGHT, FLOOD, or BOTH)
     * @param status Current status of the policy
     * @param createdAt Unix timestamp when policy was created
     */
    struct Policy {
        uint256 id;
        address farmer;
        uint256 plotId;
        uint256 sumInsured;
        uint256 premium;
        uint256 startDate;
        uint256 endDate;
        CoverageType coverageType;
        PolicyStatus status;
        uint256 createdAt;
    }

    // ============ Constants ============

    /// @notice Minimum sum insured: 10,000 USDC (6 decimals)
    uint256 public constant MIN_SUM_INSURED = 10_000e6;

    /// @notice Maximum sum insured: 1,000,000 USDC (6 decimals)
    uint256 public constant MAX_SUM_INSURED = 1_000_000e6;

    /// @notice Minimum policy duration in days
    uint256 public constant MIN_DURATION_DAYS = 30;

    /// @notice Maximum policy duration in days
    uint256 public constant MAX_DURATION_DAYS = 365;

    /// @notice Maximum active policies per farmer
    uint256 public constant MAX_ACTIVE_POLICIES_PER_FARMER = 5;

    /// @notice Maximum claims per farmer per year
    uint256 public constant MAX_CLAIMS_PER_FARMER_PER_YEAR = 3;

    /// @notice Seconds in a day for duration calculations
    uint256 private constant SECONDS_PER_DAY = 86400;

    // ============ Role Definitions ============

    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Backend role for policy creation and activation
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Oracle role for claim processing (PayoutReceiver contract)
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ============ State Variables ============

    /// @notice Counter for generating unique policy IDs
    uint256 private _policyCounter;

    /// @notice Mapping from policy ID to Policy struct
    mapping(uint256 => Policy) private _policies;

    /// @notice Mapping from farmer address to array of their policy IDs
    mapping(address => uint256[]) private _farmerPolicies;

    /// @notice Mapping from farmer address to count of active policies
    mapping(address => uint256) private _farmerActiveCounts;

    /// @notice Mapping from farmer address to year to claim count
    /// @dev Year is calculated as timestamp / 365 days from epoch
    mapping(address => mapping(uint256 => uint256)) private _farmerClaimCounts;

    // ============ Events ============

    /**
     * @notice Emitted when a new policy is created
     * @param policyId Unique identifier of the created policy
     * @param farmer Address of the insured farmer
     * @param plotId Off-chain plot reference
     * @param sumInsured Coverage amount in USDC
     * @param premium Premium amount in USDC
     * @param startDate Policy start timestamp
     * @param endDate Policy end timestamp
     * @param coverageType Type of coverage selected
     */
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed farmer,
        uint256 indexed plotId,
        uint256 sumInsured,
        uint256 premium,
        uint256 startDate,
        uint256 endDate,
        CoverageType coverageType
    );

    /**
     * @notice Emitted when a policy is activated
     * @param policyId Unique identifier of the activated policy
     * @param activatedAt Timestamp of activation
     */
    event PolicyActivated(uint256 indexed policyId, uint256 activatedAt);

    /**
     * @notice Emitted when a policy is marked as claimed
     * @param policyId Unique identifier of the claimed policy
     * @param claimedAt Timestamp of claim
     */
    event PolicyClaimed(uint256 indexed policyId, uint256 claimedAt);

    /**
     * @notice Emitted when a policy is cancelled
     * @param policyId Unique identifier of the cancelled policy
     * @param cancelledAt Timestamp of cancellation
     */
    event PolicyCancelled(uint256 indexed policyId, uint256 cancelledAt);

    /**
     * @notice Emitted when a farmer's claim count is incremented
     * @param farmer Address of the farmer
     * @param year The year for which the claim count was incremented
     * @param newCount The new total claim count for that year
     */
    event ClaimCountIncremented(
        address indexed farmer,
        uint256 indexed year,
        uint256 newCount
    );

    // ============ Custom Errors ============

    /// @notice Thrown when farmer address is zero
    error ZeroAddressFarmer();

    /// @notice Thrown when sum insured is below minimum
    error SumInsuredTooLow(uint256 provided, uint256 minimum);

    /// @notice Thrown when sum insured exceeds maximum
    error SumInsuredTooHigh(uint256 provided, uint256 maximum);

    /// @notice Thrown when premium is zero
    error ZeroPremium();

    /// @notice Thrown when duration is outside allowed range
    error InvalidDuration(uint256 durationDays, uint256 minDays, uint256 maxDays);

    /// @notice Thrown when farmer has too many active policies
    error TooManyActivePolicies(address farmer, uint256 current, uint256 max);

    /// @notice Thrown when farmer has exceeded yearly claim limit
    error TooManyClaimsThisYear(address farmer, uint256 year, uint256 current, uint256 max);

    /// @notice Thrown when policy does not exist
    error PolicyDoesNotExist(uint256 policyId);

    /// @notice Thrown when policy status is not as expected
    error InvalidPolicyStatus(uint256 policyId, PolicyStatus current, PolicyStatus expected);

    /// @notice Thrown when policy has expired
    error PolicyExpired(uint256 policyId, uint256 endDate, uint256 currentTime);

    // ============ Constructor ============

    /**
     * @notice Initializes the PolicyManager contract
     * @dev Grants DEFAULT_ADMIN_ROLE and ADMIN_ROLE to the deployer
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Creates a new insurance policy for a farmer
     * @dev Only callable by addresses with BACKEND_ROLE. Performs comprehensive
     *      validation of all inputs and business rules before creating the policy.
     *
     * Business Rules Enforced:
     * - Farmer address must not be zero
     * - Sum insured must be between 10,000 and 1,000,000 USDC
     * - Premium must be greater than zero
     * - Duration must be between 30 and 365 days
     * - Farmer cannot have more than 5 active policies
     *
     * @param farmer Address of the farmer receiving coverage
     * @param plotId Off-chain reference to the plot being insured
     * @param sumInsured Maximum payout amount in USDC (6 decimals)
     * @param premium Premium amount to be paid in USDC (6 decimals)
     * @param durationDays Number of days the policy will be active
     * @param coverageType Type of coverage (DROUGHT, FLOOD, or BOTH)
     * @return policyId The unique identifier for the created policy
     */
    function createPolicy(
        address farmer,
        uint256 plotId,
        uint256 sumInsured,
        uint256 premium,
        uint256 durationDays,
        CoverageType coverageType
    ) external onlyRole(BACKEND_ROLE) nonReentrant returns (uint256 policyId) {
        // Validate farmer address
        if (farmer == address(0)) {
            revert ZeroAddressFarmer();
        }

        // Validate sum insured bounds
        if (sumInsured < MIN_SUM_INSURED) {
            revert SumInsuredTooLow(sumInsured, MIN_SUM_INSURED);
        }
        if (sumInsured > MAX_SUM_INSURED) {
            revert SumInsuredTooHigh(sumInsured, MAX_SUM_INSURED);
        }

        // Validate premium
        if (premium == 0) {
            revert ZeroPremium();
        }

        // Validate duration
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) {
            revert InvalidDuration(durationDays, MIN_DURATION_DAYS, MAX_DURATION_DAYS);
        }

        // Check farmer's active policy count
        uint256 currentActivePolicies = _farmerActiveCounts[farmer];
        if (currentActivePolicies >= MAX_ACTIVE_POLICIES_PER_FARMER) {
            revert TooManyActivePolicies(
                farmer,
                currentActivePolicies,
                MAX_ACTIVE_POLICIES_PER_FARMER
            );
        }

        // Generate unique policy ID
        unchecked {
            policyId = ++_policyCounter;
        }

        // Calculate timestamps
        uint256 startDate = block.timestamp;
        uint256 endDate = startDate + (durationDays * SECONDS_PER_DAY);

        // Create and store the policy
        _policies[policyId] = Policy({
            id: policyId,
            farmer: farmer,
            plotId: plotId,
            sumInsured: sumInsured,
            premium: premium,
            startDate: startDate,
            endDate: endDate,
            coverageType: coverageType,
            status: PolicyStatus.PENDING,
            createdAt: block.timestamp
        });

        // Update farmer's policy tracking
        _farmerPolicies[farmer].push(policyId);

        // Emit event
        emit PolicyCreated(
            policyId,
            farmer,
            plotId,
            sumInsured,
            premium,
            startDate,
            endDate,
            coverageType
        );

        return policyId;
    }

    /**
     * @notice Activates a pending policy after premium payment
     * @dev Only callable by addresses with BACKEND_ROLE. The policy must be in
     *      PENDING status. This should be called after confirming premium payment.
     *
     * @param policyId The unique identifier of the policy to activate
     */
    function activatePolicy(uint256 policyId)
        external
        onlyRole(BACKEND_ROLE)
        nonReentrant
    {
        Policy storage policy = _policies[policyId];

        // Check policy exists
        if (policy.id == 0) {
            revert PolicyDoesNotExist(policyId);
        }

        // Check policy is pending
        if (policy.status != PolicyStatus.PENDING) {
            revert InvalidPolicyStatus(
                policyId,
                policy.status,
                PolicyStatus.PENDING
            );
        }

        // Activate the policy
        policy.status = PolicyStatus.ACTIVE;

        // Increment farmer's active policy count
        unchecked {
            ++_farmerActiveCounts[policy.farmer];
        }

        emit PolicyActivated(policyId, block.timestamp);
    }

    /**
     * @notice Marks a policy as claimed after payout processing
     * @dev Only callable by addresses with ORACLE_ROLE (PayoutReceiver contract).
     *      The policy must be ACTIVE and not expired.
     *
     * @param policyId The unique identifier of the policy to mark as claimed
     */
    function markAsClaimed(uint256 policyId) external onlyRole(ORACLE_ROLE) nonReentrant {
        Policy storage policy = _policies[policyId];

        // Check policy exists
        if (policy.id == 0) {
            revert PolicyDoesNotExist(policyId);
        }

        // Check policy is active
        if (policy.status != PolicyStatus.ACTIVE) {
            revert InvalidPolicyStatus(
                policyId,
                policy.status,
                PolicyStatus.ACTIVE
            );
        }

        // Check policy has not expired
        if (block.timestamp > policy.endDate) {
            revert PolicyExpired(policyId, policy.endDate, block.timestamp);
        }

        // Update status
        policy.status = PolicyStatus.CLAIMED;

        // Decrement farmer's active policy count
        if (_farmerActiveCounts[policy.farmer] > 0) {
            unchecked {
                --_farmerActiveCounts[policy.farmer];
            }
        }

        emit PolicyClaimed(policyId, block.timestamp);
    }

    /**
     * @notice Increments the claim count for a farmer for the current year
     * @dev Only callable by addresses with ORACLE_ROLE (PayoutReceiver contract).
     *      Enforces the maximum of 3 claims per farmer per year.
     *
     * @param farmer The address of the farmer whose claim count to increment
     */
    function incrementClaimCount(address farmer) external onlyRole(ORACLE_ROLE) nonReentrant {
        // Calculate current year (approximate, based on 365-day years)
        uint256 currentYear = block.timestamp / (365 days);

        // Get current count and increment
        uint256 currentCount = _farmerClaimCounts[farmer][currentYear];
        uint256 newCount = currentCount + 1;

        // Check claim limit
        if (newCount > MAX_CLAIMS_PER_FARMER_PER_YEAR) {
            revert TooManyClaimsThisYear(
                farmer,
                currentYear,
                currentCount,
                MAX_CLAIMS_PER_FARMER_PER_YEAR
            );
        }

        // Update count
        _farmerClaimCounts[farmer][currentYear] = newCount;

        emit ClaimCountIncremented(farmer, currentYear, newCount);
    }

    /**
     * @notice Cancels a pending or active policy
     * @dev Only callable by addresses with BACKEND_ROLE. Cannot cancel
     *      already claimed or expired policies.
     *
     * @param policyId The unique identifier of the policy to cancel
     */
    function cancelPolicy(uint256 policyId)
        external
        onlyRole(BACKEND_ROLE)
        nonReentrant
    {
        Policy storage policy = _policies[policyId];

        // Check policy exists
        if (policy.id == 0) {
            revert PolicyDoesNotExist(policyId);
        }

        // Can only cancel PENDING or ACTIVE policies
        if (
            policy.status != PolicyStatus.PENDING &&
            policy.status != PolicyStatus.ACTIVE
        ) {
            revert InvalidPolicyStatus(
                policyId,
                policy.status,
                PolicyStatus.ACTIVE // Using ACTIVE as expected, will show current status
            );
        }

        // If policy was active, decrement active count
        if (policy.status == PolicyStatus.ACTIVE) {
            if (_farmerActiveCounts[policy.farmer] > 0) {
                unchecked {
                    --_farmerActiveCounts[policy.farmer];
                }
            }
        }

        policy.status = PolicyStatus.CANCELLED;

        emit PolicyCancelled(policyId, block.timestamp);
    }

    // ============ View Functions ============

    /**
     * @notice Retrieves the complete policy data for a given policy ID
     * @param policyId The unique identifier of the policy
     * @return policy The complete Policy struct
     */
    function getPolicy(uint256 policyId) external view returns (Policy memory policy) {
        policy = _policies[policyId];
        if (policy.id == 0) {
            revert PolicyDoesNotExist(policyId);
        }
        return policy;
    }

    /**
     * @notice Retrieves all policy IDs associated with a farmer
     * @param farmer The address of the farmer
     * @return policyIds Array of policy IDs belonging to the farmer
     */
    function getFarmerPolicies(address farmer)
        external
        view
        returns (uint256[] memory policyIds)
    {
        return _farmerPolicies[farmer];
    }

    /**
     * @notice Retrieves the count of active policies for a farmer
     * @param farmer The address of the farmer
     * @return count The number of currently active policies
     */
    function getFarmerActiveCount(address farmer) external view returns (uint256 count) {
        return _farmerActiveCounts[farmer];
    }

    /**
     * @notice Retrieves the claim count for a farmer in a specific year
     * @param farmer The address of the farmer
     * @param year The year to check (timestamp / 365 days)
     * @return count The number of claims made in that year
     */
    function getFarmerClaimCount(address farmer, uint256 year)
        external
        view
        returns (uint256 count)
    {
        return _farmerClaimCounts[farmer][year];
    }

    /**
     * @notice Checks if a farmer has reached their yearly claim limit
     * @param farmer The address of the farmer
     * @return hasCapacity True if farmer can still make claims this year
     */
    function canFarmerClaim(address farmer) external view returns (bool hasCapacity) {
        uint256 currentYear = block.timestamp / (365 days);
        return _farmerClaimCounts[farmer][currentYear] < MAX_CLAIMS_PER_FARMER_PER_YEAR;
    }

    /**
     * @notice Checks if a policy is currently active and not expired
     * @param policyId The unique identifier of the policy
     * @return isActive True if policy is active and coverage period is valid
     */
    function isPolicyActive(uint256 policyId) external view returns (bool isActive) {
        Policy storage policy = _policies[policyId];
        return (
            policy.id != 0 &&
            policy.status == PolicyStatus.ACTIVE &&
            block.timestamp <= policy.endDate
        );
    }

    /**
     * @notice Returns the total number of policies created
     * @return total The total policy count
     */
    function getTotalPolicies() external view returns (uint256 total) {
        return _policyCounter;
    }

    /**
     * @notice Gets the current year used for claim counting
     * @return year The current year (timestamp / 365 days)
     */
    function getCurrentYear() external view returns (uint256 year) {
        return block.timestamp / (365 days);
    }

    /**
     * @notice Checks if a policy exists
     * @param policyId The unique identifier of the policy
     * @return exists True if the policy exists
     */
    function policyExists(uint256 policyId) external view returns (bool exists) {
        return _policies[policyId].id != 0;
    }
}
