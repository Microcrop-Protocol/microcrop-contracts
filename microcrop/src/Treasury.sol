// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal PolicyManager view interface for per-org reserve accounting (v3).
interface IPolicyManagerOrg {
    function policyOrg(uint256 policyId) external view returns (address);
    function orgOutstandingSumInsured(address org) external view returns (uint256);
}

/**
 * @title Treasury
 * @notice Holds USDC reserves, collects premiums, and disburses payouts for the MicroCrop insurance platform
 * @dev UUPS upgradeable proxy implementation. Implements comprehensive reserve management to ensure
 *      sufficient funds for payouts. Uses SafeERC20 for all token transfers.
 *
 * Security Considerations:
 * - All token transfers use SafeERC20
 * - ReentrancyGuard on all fund-moving functions
 * - Pausable for emergency situations
 * - Reserve requirements enforced before payouts
 * - Double-operation prevention (premiumReceived, payoutProcessed)
 * - UUPS upgrade pattern with UPGRADER_ROLE protection
 *
 * Role Hierarchy:
 * - DEFAULT_ADMIN_ROLE: Can grant/revoke all roles (should be multi-sig)
 * - ADMIN_ROLE: Can update platform fee, pause/unpause, emergency withdraw
 * - BACKEND_ROLE: Can receive premiums
 * - PAYOUT_ROLE: Can request payouts (PayoutReceiver contract only)
 * - UPGRADER_ROLE: Can authorize contract upgrades
 */
contract Treasury is Initializable, AccessControlUpgradeable, ReentrancyGuard, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Minimum reserve percentage (20% of premiums)
    uint256 public constant MIN_RESERVE_PERCENT = 20;

    /// @notice Target reserve percentage for healthy operations (30%)
    uint256 public constant TARGET_RESERVE_PERCENT = 30;

    /// @notice Maximum platform fee percentage (20%)
    uint256 public constant MAX_PLATFORM_FEE_PERCENT = 20;

    /// @notice Basis points denominator (100%)
    uint256 private constant BASIS_POINTS = 100;

    // ── Per-org treasury (v3) — true basis points (denominator 10000) ──
    /// @notice True basis-points denominator for per-org reserve/fee math.
    uint256 private constant BPS_DENOMINATOR = 10_000;
    /// @notice Default per-org reserve ratio when unset: 2000 bps (20%).
    uint256 public constant DEFAULT_RESERVE_RATIO_BPS = 2_000;
    /// @notice Ceiling for a per-org reserve ratio: 10000 bps (100%).
    uint256 public constant MAX_RESERVE_RATIO_BPS = 10_000;
    /// @notice Ceiling for a per-org platform fee: 3000 bps (30%).
    uint256 public constant MAX_FEE_BPS = 3_000;

    // ============ Role Definitions ============

    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Backend role for receiving premiums
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Payout role for requesting payouts (PayoutReceiver contract)
    bytes32 public constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");

    /// @notice Upgrader role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ State Variables ============
    // NOTE: Storage layout must be preserved across upgrades

    /// @notice USDC token contract
    IERC20 public usdc;

    /// @notice Backend wallet that receives payouts for M-Pesa conversion
    address public backendWallet;

    /// @notice Emitted when backend wallet is updated
    event BackendWalletUpdated(address indexed oldWallet, address indexed newWallet);

    /// @notice Lifetime total premiums collected (net of platform fees)
    uint256 public totalPremiums;

    /// @notice High-water mark of net premiums for reserve calculation (never decremented)
    /// @dev DEPRECATED: retained for storage-layout compatibility; no longer updated
    ///      (was an unused v1 high-water mark).
    uint256 public peakPremiums;

    /// @notice Lifetime total payouts disbursed
    uint256 public totalPayouts;

    /// @notice Platform fee percentage (default 10%)
    uint256 public platformFeePercent;

    /// @notice Accumulated platform fees available for withdrawal
    uint256 public accumulatedFees;

    /// @notice Mapping to track if premium has been received for a policy
    mapping(uint256 => bool) public premiumReceived;

    /// @notice Mapping to track if payout has been processed for a policy
    mapping(uint256 => bool) public payoutProcessed;

    /// @dev DEPRECATED (Batch C — RiskPool removal). Slot retained for storage-layout
    ///      compatibility; no longer read or written. Was `address public factory`.
    address private __deprecated_factory;

    // ── Per-org treasury (v3) — appended; storage-safe ──

    /// @notice PolicyManager, read to resolve a policy's backing org and that org's exposure.
    IPolicyManagerOrg public policyManager;

    /// @notice Each org's reserve balance (USDC, 6dp), keyed by the org's wallet address.
    ///         Premiums credit it; payouts debit it; the org withdraws surplus above reserveRequired.
    mapping(address => uint256) public orgReserve;

    /// @notice Per-org reserve ratio in true bps. Only meaningful when orgRatioSet[org] is true;
    ///         otherwise DEFAULT_RESERVE_RATIO_BPS applies (a stored 0 is a valid explicit ratio).
    ///         Platform-admin set.
    mapping(address => uint256) public orgReserveRatioBps;

    /// @notice Per-org platform fee in true bps. Only meaningful when orgFeeSet[org] is true;
    ///         otherwise the global platformFeePercent applies (a stored 0 is a valid explicit fee).
    ///         Platform-admin set.
    mapping(address => uint256) public orgFeeBps;

    /// @notice Running sum of all orgReserve balances. Lets emergencyWithdraw recover only
    ///         UNBACKED surplus (balance - totalOrgReserves - accumulatedFees), so it can never
    ///         drain funds that back org reserves or platform fees.
    uint256 public totalOrgReserves;

    /// @notice Presence flag for orgFeeBps: true once setOrgFeeBps has been called for the org,
    ///         so an explicit 0-bps fee is honored instead of falling back to the global rate.
    mapping(address => bool) private orgFeeSet;

    /// @notice Presence flag for orgReserveRatioBps: true once setOrgReserveRatioBps has been called
    ///         for the org, so an explicit 0-bps reserve ratio is honored instead of the default.
    mapping(address => bool) private orgRatioSet;

    /// @notice PayoutReceiver contract authorized to call requestPayout. When set (non-zero),
    ///         requestPayout additionally requires msg.sender == payoutReceiver (defense-in-depth
    ///         on top of PAYOUT_ROLE). Zero keeps deploy ordering flexible before wiring.
    address public payoutReceiver;

    /// @dev Reserved storage gap (was 48; reduced by 8 for policyManager + 3 org mappings +
    ///      totalOrgReserves + orgFeeSet + orgRatioSet + payoutReceiver).
    uint256[40] private __gap;

    // ============ Events ============

    /**
     * @notice Emitted when a premium is received
     * @param policyId The policy for which premium was paid
     * @param grossAmount The total premium amount received
     * @param platformFee The platform fee deducted
     * @param netAmount The net amount added to the pool
     * @param from The address that paid the premium
     */
    event PremiumReceived(
        uint256 indexed policyId, uint256 grossAmount, uint256 platformFee, uint256 netAmount, address indexed from
    );

    /**
     * @notice Emitted when a payout is sent
     * @param policyId The policy for which payout was sent
     * @param amount The payout amount
     * @param recipient The recipient of the payout
     */
    event PayoutSent(uint256 indexed policyId, uint256 amount, address indexed recipient);

    /**
     * @notice Emitted when the platform fee is updated
     * @param oldFee The previous platform fee percentage
     * @param newFee The new platform fee percentage
     */
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Emitted when platform fees are withdrawn
     * @param recipient The recipient of the fees
     * @param amount The amount withdrawn
     */
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when emergency withdrawal is executed
     * @param recipient The recipient of the emergency withdrawal
     * @param amount The amount withdrawn
     */
    event EmergencyWithdrawal(address indexed recipient, uint256 amount);

    // ── Per-org treasury (v3) ──
    /// @notice Emitted when an org's reserve is credited from a premium.
    event OrgReserveCredited(address indexed org, uint256 indexed policyId, uint256 netAmount);
    /// @notice Emitted when reserve capital is deposited into an org's reserve.
    event OrgReserveDeposited(address indexed org, address indexed from, uint256 amount);
    /// @notice Emitted when an org's reserve is debited for a payout.
    event OrgReserveDebited(address indexed org, uint256 indexed policyId, uint256 amount);
    /// @notice Emitted (non-reverting) when, after a payout, an org's remaining reserve falls below
    ///         its required reserve — a solvency alert for the backend/platform admin.
    event ReserveBelowRequirement(address indexed org, uint256 remaining, uint256 required);
    /// @notice Emitted when an org withdraws surplus reserve.
    event OrgSurplusWithdrawn(address indexed org, address indexed to, uint256 amount);
    /// @notice Emitted when the platform admin sets an org's reserve ratio.
    event OrgReserveRatioSet(address indexed org, uint256 ratioBps);
    /// @notice Emitted when the platform admin sets an org's fee rate.
    event OrgFeeBpsSet(address indexed org, uint256 feeBps);
    /// @notice Emitted when the PolicyManager reference is set.
    event PolicyManagerSet(address indexed policyManager);
    /// @notice Emitted when the authorized PayoutReceiver reference is set.
    event PayoutReceiverSet(address indexed payoutReceiver);

    // ============ Custom Errors ============

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when premium has already been received for a policy
    error PremiumAlreadyReceived(uint256 policyId);

    /// @notice Thrown when payout has already been processed for a policy
    error PayoutAlreadyProcessed(uint256 policyId);

    /// @notice Thrown when there are insufficient reserves for a payout
    error InsufficientReserves(uint256 available, uint256 required, uint256 reserveRequired);

    /// @notice Thrown when platform fee exceeds maximum
    error FeeTooHigh(uint256 provided, uint256 maximum);

    /// @notice Thrown when emergency withdraw amount exceeds balance
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Thrown when an org's reserve cannot cover a payout (LOUD — never a silent skip).
    error InsufficientOrgReserve(address org, uint256 required, uint256 available);

    /// @notice Thrown when a payout is requested for a policy whose premium was never received.
    error PremiumNotReceived(uint256 policyId);

    /// @notice Thrown when emergencyWithdraw is asked for more than the unbacked recoverable surplus.
    error ExceedsRecoverableSurplus(uint256 requested, uint256 recoverable);

    /// @notice Thrown when a policy has no resolvable backing org.
    error OrgNotResolved(uint256 policyId);

    /// @notice Thrown when the PolicyManager reference has not been configured (post-upgrade setup).
    error PolicyManagerNotSet();

    /// @notice Thrown when requestPayout is called by an address other than the wired PayoutReceiver.
    error NotPayoutReceiver(address caller);

    /// @notice Thrown when a per-org bps parameter exceeds its ceiling.
    error BpsTooHigh(uint256 provided, uint256 maximum);

    /// @notice Thrown when a withdrawal would breach the org's required reserve.
    error WouldBreachReserve(address org, uint256 reserveRequired, uint256 remaining);

    /// @notice Thrown when there are no fees to withdraw
    error NoFeesToWithdraw();

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initializes the Treasury contract
     * @dev Replaces constructor for upgradeable contracts. Can only be called once.
     * @param _usdc Address of the USDC token contract
     * @param _backendWallet Address of the backend wallet for payouts
     * @param _admin Address to receive admin roles
     */
    function initialize(address _usdc, address _backendWallet, address _admin) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_backendWallet == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        usdc = IERC20(_usdc);
        backendWallet = _backendWallet;
        platformFeePercent = 10; // Default 10%

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
     * @notice Receives premium payment for a policy
     * @dev Transfers USDC from the caller (msg.sender), deducts platform fee, and adds to pool.
     *      Only callable by addresses with BACKEND_ROLE. The caller must hold and approve the USDC.
     *
     * Process:
     * 1. Validate inputs and prevent double payment
     * 2. Calculate platform fee and net premium
     * 3. Transfer USDC from caller
     * 4. Update state (fees, premiums, tracking)
     *
     * @param policyId The unique identifier of the policy
     * @param amount The gross premium amount in USDC (6 decimals)
     */
    function receivePremium(uint256 policyId, uint256 amount)
        external
        onlyRole(BACKEND_ROLE)
        nonReentrant
        whenNotPaused
    {
        // Validate inputs
        if (amount == 0) revert ZeroAmount();
        if (premiumReceived[policyId]) revert PremiumAlreadyReceived(policyId);

        // Resolve the backing org and split the per-org platform fee.
        address org = _resolveOrg(policyId);
        uint256 platformFee = (amount * _feeBps(org)) / BPS_DENOMINATOR;
        uint256 netPremium = amount - platformFee;

        // Mark as received BEFORE external call (CEI pattern)
        premiumReceived[policyId] = true;
        accumulatedFees += platformFee;
        totalPremiums += netPremium;
        // Credit the org's own reserve — this is the pool that backs its payouts.
        orgReserve[org] += netPremium;
        totalOrgReserves += netPremium;

        // Transfer USDC from caller
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit PremiumReceived(policyId, amount, platformFee, netPremium, msg.sender);
        emit OrgReserveCredited(org, policyId, netPremium);
    }

    /**
     * @notice Requests a payout for an approved claim
     * @dev Only callable by addresses with PAYOUT_ROLE (PayoutReceiver contract).
     *      Validates reserve requirements before processing payout.
     *
     * Process:
     * 1. Validate inputs and prevent double payout
     * 2. Check reserve requirements
     * 3. Update state BEFORE external call (CEI pattern)
     * 4. Transfer USDC to backend wallet
     *
     * @param policyId The unique identifier of the policy
     * @param amount The payout amount in USDC (6 decimals)
     */
    function requestPayout(uint256 policyId, uint256 amount)
        external
        onlyRole(PAYOUT_ROLE)
        nonReentrant
        whenNotPaused
    {
        // Validate inputs
        if (amount == 0) revert ZeroAmount();
        // Defense-in-depth: when the PayoutReceiver is wired, restrict callers to it (in addition
        // to PAYOUT_ROLE), so a mis-granted role alone cannot drain reserves. Zero keeps deploy
        // ordering flexible: the role still applies before the address is set.
        if (payoutReceiver != address(0) && msg.sender != payoutReceiver) revert NotPayoutReceiver(msg.sender);
        if (payoutProcessed[policyId]) revert PayoutAlreadyProcessed(policyId);
        // Defense-in-depth: never pay out a policy whose premium was never collected.
        if (!premiumReceived[policyId]) revert PremiumNotReceived(policyId);

        // Per-org solvency: the payout is funded ONLY by the policy's org's own reserve.
        // If the org under-reserved, this REVERTS loudly (the farmer is owed money and the
        // backend must alert the org + platform admin) — never a silent skip.
        address org = _resolveOrg(policyId);
        uint256 available = orgReserve[org];
        if (available < amount) {
            revert InsufficientOrgReserve(org, amount, available);
        }

        // Update state BEFORE external call (CEI pattern)
        payoutProcessed[policyId] = true;
        totalPayouts += amount;
        orgReserve[org] = available - amount;
        totalOrgReserves -= amount;

        // Transfer USDC to backend wallet (for M-Pesa offramp to the farmer)
        usdc.safeTransfer(backendWallet, amount);

        emit PayoutSent(policyId, amount, backendWallet);
        emit OrgReserveDebited(org, policyId, amount);

        // Solvency signal (non-reverting): a cascade of otherwise-valid payouts can drain an org
        // below its required reserve. We never block a valid payout — the farmer is owed money —
        // but we surface it so the backend/platform admin can alert the org to top up.
        uint256 required = reserveRequired(org);
        if (orgReserve[org] < required) {
            emit ReserveBelowRequirement(org, orgReserve[org], required);
        }
    }

    // ============ Per-org treasury (v3) ============

    /// @notice Deposit reserve capital into an org's reserve. This is how an insurer funds the
    ///         reserve that backs its coverage (premiums alone don't cover potential payouts).
    ///         Anyone may fund an org (the org itself, or the backend on its behalf); the caller
    ///         supplies the USDC.
    /// @param org The org (wallet) whose reserve to credit.
    /// @param amount USDC (6dp) to deposit.
    function depositReserve(address org, uint256 amount) external nonReentrant whenNotPaused {
        if (org == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        orgReserve[org] += amount;
        totalOrgReserves += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit OrgReserveDeposited(org, msg.sender, amount);
    }

    /// @notice Withdraw surplus reserve. Callable ONLY by the org's own wallet (msg.sender == org),
    ///         and only down to the org's required reserve — the contract enforces solvency, so an
    ///         insurer cannot pull capital out from under outstanding policies. MicroCrop (platform
    ///         admin) cannot move org money; it only sets the ratio (setOrgReserveRatioBps) + can pause.
    /// @param amount USDC (6dp) to withdraw.
    /// @param to Recipient of the surplus.
    function withdrawOrgSurplus(uint256 amount, address to) external nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        address org = msg.sender; // the org's Privy wallet is the per-org key and the authority
        uint256 available = orgReserve[org];
        if (available < amount) revert InsufficientOrgReserve(org, amount, available);

        uint256 remaining = available - amount;
        uint256 required = reserveRequired(org);
        if (remaining < required) revert WouldBreachReserve(org, required, remaining);

        orgReserve[org] = remaining;
        totalOrgReserves -= amount;
        usdc.safeTransfer(to, amount);
        emit OrgSurplusWithdrawn(org, to, amount);
    }

    /// @notice The reserve an org must keep: outstanding (ACTIVE, unpaid) sum insured × its ratio.
    function reserveRequired(address org) public view returns (uint256) {
        if (address(policyManager) == address(0)) revert PolicyManagerNotSet();
        uint256 outstanding = policyManager.orgOutstandingSumInsured(org);
        return (outstanding * _reserveRatioBps(org)) / BPS_DENOMINATOR;
    }

    /// @notice Sets the PolicyManager reference (post-upgrade wiring). Admin only.
    function setPolicyManager(address _policyManager) external onlyRole(ADMIN_ROLE) {
        if (_policyManager == address(0)) revert ZeroAddress();
        policyManager = IPolicyManagerOrg(_policyManager);
        emit PolicyManagerSet(_policyManager);
    }

    /// @notice Sets the authorized PayoutReceiver (post-upgrade wiring). Admin only. Once set,
    ///         requestPayout requires msg.sender == payoutReceiver on top of PAYOUT_ROLE.
    function setPayoutReceiver(address _payoutReceiver) external onlyRole(ADMIN_ROLE) {
        if (_payoutReceiver == address(0)) revert ZeroAddress();
        payoutReceiver = _payoutReceiver;
        emit PayoutReceiverSet(_payoutReceiver);
    }

    /// @notice Sets an org's reserve ratio (true bps). Platform admin only — this is MicroCrop's
    ///         only lever over org capital (set the solvency rule; never move the money).
    function setOrgReserveRatioBps(address org, uint256 ratioBps) external onlyRole(ADMIN_ROLE) {
        if (org == address(0)) revert ZeroAddress();
        if (ratioBps > MAX_RESERVE_RATIO_BPS) revert BpsTooHigh(ratioBps, MAX_RESERVE_RATIO_BPS);
        orgReserveRatioBps[org] = ratioBps;
        orgRatioSet[org] = true;
        emit OrgReserveRatioSet(org, ratioBps);
    }

    /// @notice Sets an org's platform fee (true bps; negotiable per partner). Platform admin only.
    function setOrgFeeBps(address org, uint256 feeBps) external onlyRole(ADMIN_ROLE) {
        if (org == address(0)) revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS) revert BpsTooHigh(feeBps, MAX_FEE_BPS);
        orgFeeBps[org] = feeBps;
        orgFeeSet[org] = true;
        emit OrgFeeBpsSet(org, feeBps);
    }

    /// @dev Resolve a policy's backing org via PolicyManager; revert if unset/unknown.
    function _resolveOrg(uint256 policyId) private view returns (address org) {
        if (address(policyManager) == address(0)) revert PolicyManagerNotSet();
        org = policyManager.policyOrg(policyId);
        if (org == address(0)) revert OrgNotResolved(policyId);
    }

    /// @dev Effective reserve ratio for an org (explicit per-org value if set — including 0 —
    ///      else the default).
    function _reserveRatioBps(address org) private view returns (uint256) {
        uint256 r = orgReserveRatioBps[org];
        return orgRatioSet[org] ? r : DEFAULT_RESERVE_RATIO_BPS;
    }

    /// @dev Effective fee bps for an org (explicit per-org value if set — including 0 — else the
    ///      global platformFeePercent).
    function _feeBps(address org) private view returns (uint256) {
        uint256 f = orgFeeBps[org];
        return orgFeeSet[org] ? f : platformFeePercent * 100; // platformFeePercent is a percent (10 -> 1000 bps)
    }

    /**
     * @notice Updates the platform fee percentage
     * @dev Only callable by addresses with ADMIN_ROLE. Fee cannot exceed 20%.
     * @param newFeePercent The new platform fee percentage (0-20)
     */
    function setPlatformFee(uint256 newFeePercent) external onlyRole(ADMIN_ROLE) {
        if (newFeePercent > MAX_PLATFORM_FEE_PERCENT) {
            revert FeeTooHigh(newFeePercent, MAX_PLATFORM_FEE_PERCENT);
        }

        uint256 oldFee = platformFeePercent;
        platformFeePercent = newFeePercent;

        emit PlatformFeeUpdated(oldFee, newFeePercent);
    }

    /**
     * @notice Withdraws accumulated platform fees
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param recipient The address to receive the fees
     */
    function withdrawFees(address recipient) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (accumulatedFees == 0) revert NoFeesToWithdraw();

        // Fees are platform revenue, accounted separately from per-org reserves (v3): the
        // invariant balance == sum(orgReserve) + accumulatedFees means withdrawing exactly
        // accumulatedFees never touches an org's reserve.
        uint256 fees = accumulatedFees;
        accumulatedFees = 0;

        usdc.safeTransfer(recipient, fees);

        emit FeesWithdrawn(recipient, fees);
    }

    /**
     * @notice Updates the backend wallet address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param newBackendWallet The new backend wallet address
     */
    function setBackendWallet(address newBackendWallet) external onlyRole(ADMIN_ROLE) {
        if (newBackendWallet == address(0)) revert ZeroAddress();
        address oldWallet = backendWallet;
        backendWallet = newBackendWallet;
        emit BackendWalletUpdated(oldWallet, newBackendWallet);
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

    /**
     * @notice Emergency withdrawal of funds when paused
     * @dev Only callable by addresses with ADMIN_ROLE and only when paused.
     *      This is a last resort for recovering funds in emergencies.
     * @param recipient The address to receive the funds
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(address recipient, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenPaused
    {
        if (recipient == address(0)) revert ZeroAddress();

        // Only UNBACKED surplus may be recovered (e.g. tokens sent here by mistake) — never
        // funds that back org reserves or accumulated fees. This preserves the solvency
        // invariant: usdc.balanceOf(this) >= totalOrgReserves + accumulatedFees at all times.
        uint256 balance = usdc.balanceOf(address(this));
        uint256 backed = totalOrgReserves + accumulatedFees;
        uint256 recoverable = balance > backed ? balance - backed : 0;
        if (amount > recoverable) revert ExceedsRecoverableSurplus(amount, recoverable);

        usdc.safeTransfer(recipient, amount);

        emit EmergencyWithdrawal(recipient, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Calculates the platform fee for a given premium amount
     * @param premium The gross premium amount
     * @return fee The platform fee amount
     * @dev DEPRECATED: returns the global rate only; use calculatePlatformFee(premium, org) for the
     *      actual per-org fee. This diverges from receivePremium, which charges the per-org rate.
     */
    function calculatePlatformFee(uint256 premium) public view returns (uint256 fee) {
        return (premium * platformFeePercent) / BASIS_POINTS;
    }

    /**
     * @notice Calculates the actual platform fee charged for a premium on a given org's policy.
     * @dev Mirrors receivePremium exactly: (premium * _feeBps(org)) / BPS_DENOMINATOR. Honors an
     *      explicit per-org fee (including 0 bps) and otherwise falls back to the global rate.
     * @param premium The gross premium amount
     * @param org The backing org whose fee rate applies
     * @return fee The platform fee amount
     */
    function calculatePlatformFee(uint256 premium, address org) public view returns (uint256 fee) {
        return (premium * _feeBps(org)) / BPS_DENOMINATOR;
    }

    /**
     * @notice Returns the current USDC balance of the treasury
     * @return balance The current balance in USDC
     */
    function getBalance() external view returns (uint256 balance) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Calculates the amount available for payouts after reserve
     * @return available The amount available for payouts
     * @dev DEPRECATED (v3): global pooled model; does not reflect per-org solvency. Use the
     *      per-org views below.
     */
    function getAvailableForPayouts() public view returns (uint256 available) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 outstandingPremiums = totalPremiums > totalPayouts ? totalPremiums - totalPayouts : 0;
        uint256 requiredReserve = (outstandingPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;

        if (balance <= requiredReserve) {
            return 0;
        }
        return balance - requiredReserve;
    }

    /**
     * @notice The amount available to fund payouts for a specific org (v3 per-org model).
     * @dev A payout is funded solely from the org's own reserve; this returns that balance.
     * @param org The org whose reserve to read
     * @return available The org's current reserve balance
     */
    function getAvailableForPayouts(address org) external view returns (uint256 available) {
        return orgReserve[org];
    }

    /**
     * @notice Checks if the treasury meets minimum reserve requirements
     * @return meetsReserve True if reserve requirements are met
     * @dev DEPRECATED (v3): global pooled model; does not reflect per-org solvency. Use the
     *      per-org views below.
     */
    function meetsReserveRequirements() public view returns (bool meetsReserve) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 outstandingPremiums = totalPremiums > totalPayouts ? totalPremiums - totalPayouts : 0;
        uint256 requiredReserve = (outstandingPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;
        return balance >= requiredReserve;
    }

    /**
     * @notice Checks if an org meets its required reserve (v3 per-org model).
     * @param org The org to check
     * @return meetsReserve True if the org's reserve covers its required reserve
     */
    function meetsReserveRequirements(address org) external view returns (bool meetsReserve) {
        return orgReserve[org] >= reserveRequired(org);
    }

    /**
     * @notice Returns the required minimum reserve amount
     * @return required The minimum reserve amount required
     * @dev DEPRECATED (v3): global pooled model; does not reflect per-org solvency. Use the
     *      per-org views below.
     */
    function getRequiredReserve() external view returns (uint256 required) {
        uint256 outstandingPremiums = totalPremiums > totalPayouts ? totalPremiums - totalPayouts : 0;
        return (outstandingPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;
    }

    /**
     * @notice Returns the current reserve ratio as a percentage
     * @return ratio The current reserve ratio (0-100+)
     * @dev DEPRECATED (v3): global pooled model; does not reflect per-org solvency. Use the
     *      per-org views below.
     */
    function getReserveRatio() external view returns (uint256 ratio) {
        uint256 outstandingPremiums = totalPremiums > totalPayouts ? totalPremiums - totalPayouts : 0;
        if (outstandingPremiums == 0) return 100;

        uint256 balance = usdc.balanceOf(address(this));
        return (balance * BASIS_POINTS) / outstandingPremiums;
    }

    /**
     * @notice Returns lifetime total premiums collected
     * @return total The total net premiums collected
     */
    function getTotalPremiums() external view returns (uint256 total) {
        return totalPremiums;
    }

    /**
     * @notice Returns lifetime total payouts disbursed
     * @return total The total payouts disbursed
     */
    function getTotalPayouts() external view returns (uint256 total) {
        return totalPayouts;
    }

    /**
     * @notice Checks if premium has been received for a specific policy
     * @param policyId The policy to check
     * @return received True if premium has been received
     */
    function isPremiumReceived(uint256 policyId) external view returns (bool received) {
        return premiumReceived[policyId];
    }

    /**
     * @notice Checks if payout has been processed for a specific policy
     * @param policyId The policy to check
     * @return processed True if payout has been processed
     */
    function isPayoutProcessed(uint256 policyId) external view returns (bool processed) {
        return payoutProcessed[policyId];
    }

    /**
     * @notice Returns the contract version for upgrade tracking
     * @return version The contract version string
     */
    function version() external pure returns (string memory) {
        return "3.0.0"; // per-org treasury (v3)
    }
}
