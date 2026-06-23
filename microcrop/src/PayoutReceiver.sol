// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PolicyManager} from "./PolicyManager.sol";
import {Treasury} from "./Treasury.sol";

/**
 * @title PayoutReceiver
 * @notice Verifies PKP-signed parametric determinations and triggers automatic payouts.
 * @dev UUPS upgradeable proxy. v2 replaced the Chainlink CRE / Keystone Forwarder entrypoint
 *      with `submitDetermination`, whose trust root is an ECDSA signature from the accredited
 *      calculating agent's PKP (`authorizedSigner`). See DETERMINATION_SCHEMA.md.
 *
 * Security Considerations:
 * - Authority root is the PKP signature: ecrecover(preimageHash) == authorizedSigner.
 * - RELAYER_ROLE is an anti-spam gate on WHO may relay; it does NOT authorize payouts.
 * - Both hashes are reconstructed on-chain from raw fields — never trusts a passed-in hash.
 * - chainId + address(this) are bound into the preimage (cross-chain/contract replay protection).
 * - ReentrancyGuard, Pausable, CEI; UUPS upgrade gated by UPGRADER_ROLE.
 *
 * submitDetermination validations (ALL must pass; CROP_DAMAGE):
 * 1. authorizedSigner configured
 * 2. bounds: damageBp <= 10000, weather/satellite sub-scores <= 100, weatherPresent in {0,1}
 * 3. evidence consistency: weatherPresent == 0 => weatherDamage == 0
 * 4. weighted-damage invariant (basis points, NO division):
 *      weather present  -> damageBp == 60*weatherDamage + 40*satelliteDamage
 *      satellite-only   -> damageBp == 100*satelliteDamage   (renormalized to 100% weight)
 * 5. threshold: damageBp >= 3000 (30%)
 * 6. policy: exists, ACTIVE, not expired, not already paid; evidence sumInsured == policy.sumInsured
 * 7. payout: payoutAmount == sumInsured * damageBp / 10000
 * 8. freshness: assessedAt within MAX_REPORT_AGE, not in the future
 * 9. farmer within yearly claim limit
 * 10. preimage reconstructed on-chain; not previously consumed; ecrecover == authorizedSigner
 */
contract PayoutReceiver is
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

    /**
     * @notice CROP_DAMAGE signed-determination input (Determination Schema v1.0, §5.2).
     * @dev The contract reconstructs BOTH the inputsHash (abi.encode of the 10 evidence
     *      fields) and the settlement preimageHash (abi.encodePacked of the 12 fields)
     *      from these raw values — it never trusts a passed-in hash. Units (FROZEN):
     *      - damagePercentBp: BASIS POINTS 0..10000 (the only unit on the money path)
     *      - weatherDamage / satelliteDamage: WHOLE PERCENT 0..100 (dual-index sub-scores)
     *      - latitude_e6/longitude_e6 (deg ×1e6), ndviScaled (×1e4), weatherTempC_e2 (°C ×1e2)
     *        are SIGNED (int256, two's-complement); precip/humidity/wind are unsigned.
     *      - weatherPresent: 0 = satellite-only, 1 = weather present (null-handling, §5.1).
     */
    struct CropDetermination {
        // --- settlement preimage (result/subject) ---
        uint256 onChainPolicyId;
        uint256 damagePercentBp;     // basis points 0..10000
        uint256 weatherDamage;       // whole percent 0..100
        uint256 satelliteDamage;     // whole percent 0..100
        uint256 payoutAmount;        // USDC base units (6 dp)
        uint256 assessedAt;          // unix seconds
        // --- evidence (inputsHash) ---
        int256  latitude_e6;
        int256  longitude_e6;
        uint256 sumInsured;          // must equal policy.sumInsured
        int256  ndviScaled;
        uint256 weatherPresent;      // 0 | 1
        int256  weatherTempC_e2;
        uint256 weatherPrecip_e2;
        uint256 weatherHumidity;
        uint256 weatherWind_e2;
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

    /// @notice Weight denominator (100%) — retained for storage/ABI continuity; the
    ///         v1.0 weighted invariant deliberately does NOT divide by it (§8.2).
    uint256 private constant WEIGHT_DENOMINATOR = 100;

    // ---- Determination Schema v1.0 domain constants (FROZEN, §5.1) ----
    /// @notice keccak256(bytes(schemaVersion)) for "1.0"
    bytes32 private constant SCHEMA_VERSION_HASH = keccak256("1.0");
    /// @notice keccak256(bytes(kind)) for "CROP_DAMAGE"
    bytes32 private constant KIND_CROP_HASH = keccak256("CROP_DAMAGE");
    /// @notice keccak256(bytes(methodologyVersion)) for "crop-dualindex-1.0" (pins weights 60/40, §8.6)
    bytes32 private constant METHODOLOGY_CROP_HASH = keccak256("crop-dualindex-1.0");

    // ============ Role Definitions ============

    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Upgrader role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Relayer role — gates WHO may submit a determination (anti-spam only).
    /// @dev This is NOT the authority root. A relayer cannot authorize a payout; only a
    ///      signature from `authorizedSigner` (the PKP) can. Separation is deliberate (§6.2).
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // ============ State Variables ============
    // NOTE: Storage layout must be preserved across upgrades

    /// @notice Reference to the Treasury contract
    Treasury public treasury;

    /// @notice Reference to the PolicyManager contract
    PolicyManager public policyManager;

    /// @notice [DEPRECATED — CRE/Keystone path removed in v2] Retained for storage-layout
    ///         continuity. No longer read by any entrypoint. Do not remove (would shift slots).
    address public keystoneForwarderAddress;

    /// @notice [DEPRECATED — see above] Retained for storage-layout continuity.
    address public workflowAddress;

    /// @notice [DEPRECATED — see above] Retained for storage-layout continuity.
    uint256 public workflowId;

    /// @notice Mapping from policy ID to damage report
    mapping(uint256 => DamageReport) private _damageReports;

    /// @notice Mapping to track if a policy has been paid
    mapping(uint256 => bool) public policyPaid;

    // ---- v2 appended storage (consumed from the former 50-slot gap) ----

    /// @notice EVM address of the accredited calculating-agent PKP for THIS environment.
    /// @dev Authority root for payouts: a determination is valid iff ecrecover == this (§6.2).
    ///      Environment-specific (dev and prod use different PKPs, §6.3).
    address public authorizedSigner;

    /// @notice Determination replay guard, keyed by the reconstructed preimageHash.
    mapping(bytes32 => bool) public consumedDetermination;

    /// @dev Reserved storage gap, reduced 50 -> 48 for the two vars appended above.
    uint256[48] private __gap;

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

    /**
     * @notice Emitted when a signed determination is verified and consumed
     * @param policyId The policy the determination authorized
     * @param preimageHash The reconstructed settlement digest (replay key)
     * @param signer The recovered signer (== authorizedSigner)
     */
    event DeterminationVerified(uint256 indexed policyId, bytes32 indexed preimageHash, address indexed signer);

    /**
     * @notice Emitted when the authorized signer (PKP) is updated
     * @param oldSigner Previous authorized signer
     * @param newSigner New authorized signer
     */
    event AuthorizedSignerUpdated(address indexed oldSigner, address indexed newSigner);

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
    error PolicyNotActive(uint256 policyId, PolicyManager.PolicyStatus status);

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

    /// @notice Thrown when Keystone Forwarder is not configured
    error KeystoneForwarderNotConfigured();

    /// @notice Thrown when workflow is not configured
    error WorkflowNotConfigured();

    /// @notice Thrown when the authorized signer (PKP) has not been configured
    error SignerNotConfigured();

    /// @notice Thrown when ecrecover does not match the authorized signer
    error InvalidSignature(address recovered, address expected);

    /// @notice Thrown when a determination (by preimageHash) has already been consumed
    error DeterminationAlreadyConsumed(bytes32 preimageHash);

    /// @notice Thrown when a dual-index sub-score is outside 0..100 (whole percent)
    error SubScoreOutOfRange(uint256 weatherDamage, uint256 satelliteDamage);

    /// @notice Thrown when weatherPresent is not 0 or 1
    error InvalidWeatherFlag(uint256 weatherPresent);

    /// @notice Thrown when weatherPresent == 0 but weatherDamage != 0 (inconsistent evidence)
    error WeatherFlagDamageMismatch(uint256 weatherPresent, uint256 weatherDamage);

    /// @notice Thrown when the determination's sumInsured does not match the on-chain policy
    error SumInsuredMismatch(uint256 provided, uint256 expected);

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

        treasury = Treasury(_treasury);
        policyManager = PolicyManager(_policyManager);

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
     * @notice Verifies a PKP-signed CROP_DAMAGE determination and triggers payout.
     * @dev Replaces the CRE/Keystone `receiveDamageReport` path. The trust root is the
     *      signature: the call is authorized iff `ECDSA.recover(preimageHash, signature)
     *      == authorizedSigner`. `RELAYER_ROLE` only rate-limits WHO may relay; it cannot
     *      authorize a payout. Determination Schema v1.0 §5/§6.
     *
     * Order (cheap checks first, signature + external calls last; CEI on effects):
     *  1. signer configured
     *  2. bounds: damageBp<=10000, sub-scores<=100, weatherPresent in {0,1}
     *  3. pinned-weight invariant: 60*weather + 40*satellite == damageBp  (NO /WEIGHT_DENOMINATOR)
     *  4. threshold: damageBp >= 3000
     *  5. policy: exists, ACTIVE, not expired, not already paid
     *  6. evidence binds the real policy: d.sumInsured == policy.sumInsured
     *  7. payout (bp): payoutAmount == sumInsured * damageBp / 10000
     *  8. freshness: assessedAt within MAX_REPORT_AGE, not future
     *  9. farmer claim limit
     * 10. reconstruct inputsHash (abi.encode) + preimageHash (abi.encodePacked) ON-CHAIN
     * 11. replay: preimageHash not consumed
     * 12. signature: ecrecover(preimageHash) == authorizedSigner
     *
     * @param d CROP_DAMAGE determination (result + evidence; see struct)
     * @param signature 65-byte secp256k1 signature over the RAW preimageHash (no EIP-191 prefix)
     */
    function submitDetermination(CropDetermination calldata d, bytes calldata signature)
        external
        onlyRole(RELAYER_ROLE)
        nonReentrant
        whenNotPaused
    {
        // 1. authority root must be configured
        if (authorizedSigner == address(0)) revert SignerNotConfigured();

        // 2. bounds
        if (d.damagePercentBp > MAX_DAMAGE_PERCENTAGE) {
            revert DamageExceedsMaximum(d.damagePercentBp, MAX_DAMAGE_PERCENTAGE);
        }
        if (d.weatherDamage > 100 || d.satelliteDamage > 100) {
            revert SubScoreOutOfRange(d.weatherDamage, d.satelliteDamage);
        }
        if (d.weatherPresent > 1) revert InvalidWeatherFlag(d.weatherPresent);

        // 3. weatherPresent must be consistent with weatherDamage: a satellite-only
        //    determination (weatherPresent == 0) MUST carry weatherDamage == 0, so the flag
        //    cannot be gamed against the renormalized invariant below.
        if (d.weatherPresent == 0 && d.weatherDamage != 0) {
            revert WeatherFlagDamageMismatch(d.weatherPresent, d.weatherDamage);
        }

        // 4. weighted-damage invariant (basis points; NO /WEIGHT_DENOMINATOR — §8.2).
        //    Dual-index when weather is present; renormalized to 100% satellite weight when it
        //    is absent — otherwise a total satellite loss during a weather-data outage would be
        //    capped at 40% (60*0 + 40*100). See methodology crop-dualindex-1.0 (two formulas).
        uint256 expectedBp = d.weatherPresent == 0
            ? d.satelliteDamage * WEIGHT_DENOMINATOR // satellite-only: pct -> bp at 100% weight
            : (WEATHER_WEIGHT * d.weatherDamage) + (SATELLITE_WEIGHT * d.satelliteDamage);
        if (expectedBp != d.damagePercentBp) {
            revert InvalidWeightedDamage(expectedBp, d.damagePercentBp);
        }

        // 4. threshold
        if (d.damagePercentBp < MIN_DAMAGE_THRESHOLD) {
            revert DamageBelowThreshold(d.damagePercentBp, MIN_DAMAGE_THRESHOLD);
        }

        // 5. policy state
        if (!policyManager.policyExists(d.onChainPolicyId)) {
            revert PolicyDoesNotExist(d.onChainPolicyId);
        }
        PolicyManager.Policy memory policy = policyManager.getPolicy(d.onChainPolicyId);
        if (policy.status != PolicyManager.PolicyStatus.ACTIVE) {
            revert PolicyNotActive(d.onChainPolicyId, policy.status);
        }
        if (block.timestamp > policy.endDate) {
            revert PolicyExpired(d.onChainPolicyId, policy.endDate, block.timestamp);
        }
        if (policyPaid[d.onChainPolicyId]) {
            revert PolicyAlreadyPaid(d.onChainPolicyId);
        }

        // 6. evidence must bind the real policy's sum insured
        if (d.sumInsured != policy.sumInsured) {
            revert SumInsuredMismatch(d.sumInsured, policy.sumInsured);
        }

        // 7. payout (basis points — single unit on the money path)
        uint256 expectedPayout = (policy.sumInsured * d.damagePercentBp) / BASIS_POINTS;
        if (d.payoutAmount != expectedPayout) {
            revert InvalidPayoutCalculation(d.payoutAmount, expectedPayout);
        }

        // 8. freshness
        if (d.assessedAt > block.timestamp) {
            revert ReportTooOld(d.assessedAt, block.timestamp, MAX_REPORT_AGE);
        }
        if (block.timestamp > d.assessedAt + MAX_REPORT_AGE) {
            revert ReportTooOld(d.assessedAt, block.timestamp, MAX_REPORT_AGE);
        }

        // 9. farmer claim limit
        if (!policyManager.canFarmerClaim(policy.farmer)) {
            revert FarmerClaimLimitExceeded(policy.farmer);
        }

        // 10. reconstruct BOTH hashes on-chain — never trust a passed-in hash.
        //     inputsHash: abi.encode (32B-padded, two's-complement int256). Field order is FROZEN.
        bytes32 inputsHash = keccak256(
            abi.encode(
                d.onChainPolicyId,
                d.latitude_e6,
                d.longitude_e6,
                d.sumInsured,
                d.ndviScaled,
                d.weatherPresent,
                d.weatherTempC_e2,
                d.weatherPrecip_e2,
                d.weatherHumidity,
                d.weatherWind_e2
            )
        );
        //     settlement preimage: abi.encodePacked. chainId/contract come from the chain,
        //     not the caller — so a dev-signed determination can't verify on prod (§6.3).
        bytes32 preimageHash = keccak256(
            abi.encodePacked(
                SCHEMA_VERSION_HASH,
                KIND_CROP_HASH,
                METHODOLOGY_CROP_HASH,
                block.chainid,
                address(this),
                inputsHash,
                d.onChainPolicyId,
                d.damagePercentBp,
                d.weatherDamage,
                d.satelliteDamage,
                d.payoutAmount,
                d.assessedAt
            )
        );

        // 11. replay guard
        if (consumedDetermination[preimageHash]) {
            revert DeterminationAlreadyConsumed(preimageHash);
        }

        // 12. signature is the authority (raw digest, no EIP-191 prefix; OZ rejects malleable s)
        address recovered = ECDSA.recoverCalldata(preimageHash, signature);
        if (recovered != authorizedSigner) {
            revert InvalidSignature(recovered, authorizedSigner);
        }

        // ============ All checks passed — effects before interactions (CEI) ============
        consumedDetermination[preimageHash] = true;
        policyPaid[d.onChainPolicyId] = true;
        _damageReports[d.onChainPolicyId] = DamageReport({
            policyId: d.onChainPolicyId,
            damagePercentage: d.damagePercentBp,
            weatherDamage: d.weatherDamage,
            satelliteDamage: d.satelliteDamage,
            payoutAmount: d.payoutAmount,
            assessedAt: d.assessedAt
        });

        // Interactions
        treasury.requestPayout(d.onChainPolicyId, d.payoutAmount);
        policyManager.markAsClaimed(d.onChainPolicyId);
        policyManager.incrementClaimCount(policy.farmer);

        emit DeterminationVerified(d.onChainPolicyId, preimageHash, recovered);
        emit DamageReportReceived(d.onChainPolicyId, d.damagePercentBp, d.payoutAmount, policy.farmer);
        emit PayoutInitiated(d.onChainPolicyId, d.payoutAmount);
    }

    /**
     * @notice Sets the accredited calculating-agent signer (PKP EVM address) for this environment.
     * @dev Authority root for `submitDetermination`. Role-gated; environment-specific (§6.3).
     * @param _authorizedSigner The PKP-derived EVM address
     */
    function setAuthorizedSigner(address _authorizedSigner) external onlyRole(ADMIN_ROLE) {
        if (_authorizedSigner == address(0)) revert ZeroAddress();
        address old = authorizedSigner;
        authorizedSigner = _authorizedSigner;
        emit AuthorizedSignerUpdated(old, _authorizedSigner);
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
        return "2.0.0";
    }
}
