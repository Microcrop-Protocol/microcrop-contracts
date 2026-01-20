// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Treasury
 * @notice Holds USDC reserves, collects premiums, and disburses payouts for the MicroCrop insurance platform
 * @dev Implements comprehensive reserve management to ensure sufficient funds for payouts.
 *      Uses SafeERC20 for all token transfers to prevent common ERC20 pitfalls.
 *
 * Security Considerations:
 * - All token transfers use SafeERC20
 * - ReentrancyGuard on all fund-moving functions
 * - Pausable for emergency situations
 * - Reserve requirements enforced before payouts
 * - Double-operation prevention (premiumReceived, payoutProcessed)
 *
 * Role Hierarchy:
 * - DEFAULT_ADMIN_ROLE: Can grant/revoke all roles (should be multi-sig)
 * - ADMIN_ROLE: Can update platform fee, pause/unpause, emergency withdraw
 * - BACKEND_ROLE: Can receive premiums
 * - PAYOUT_ROLE: Can request payouts (PayoutReceiver contract only)
 */
contract Treasury is AccessControl, ReentrancyGuard, Pausable {
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

    // ============ Role Definitions ============

    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Backend role for receiving premiums
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Payout role for requesting payouts (PayoutReceiver contract)
    bytes32 public constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");

    // ============ Immutable State Variables ============

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Backend wallet that receives payouts for M-Pesa conversion
    address public immutable backendWallet;

    // ============ State Variables ============

    /// @notice Lifetime total premiums collected (net of platform fees)
    uint256 public totalPremiums;

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
        uint256 indexed policyId,
        uint256 grossAmount,
        uint256 platformFee,
        uint256 netAmount,
        address indexed from
    );

    /**
     * @notice Emitted when a payout is sent
     * @param policyId The policy for which payout was sent
     * @param amount The payout amount
     * @param recipient The recipient of the payout
     */
    event PayoutSent(
        uint256 indexed policyId,
        uint256 amount,
        address indexed recipient
    );

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

    /// @notice Thrown when there are no fees to withdraw
    error NoFeesToWithdraw();

    // ============ Constructor ============

    /**
     * @notice Initializes the Treasury contract
     * @dev Sets up USDC token, backend wallet, and default platform fee
     * @param _usdc Address of the USDC token contract
     * @param _backendWallet Address of the backend wallet for payouts
     */
    constructor(address _usdc, address _backendWallet) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_backendWallet == address(0)) revert ZeroAddress();

        usdc = IERC20(_usdc);
        backendWallet = _backendWallet;
        platformFeePercent = 10; // Default 10%

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Receives premium payment for a policy
     * @dev Transfers USDC from the sender, deducts platform fee, and adds to pool.
     *      Only callable by addresses with BACKEND_ROLE.
     *
     * Process:
     * 1. Validate inputs and prevent double payment
     * 2. Calculate platform fee and net premium
     * 3. Transfer USDC from sender
     * 4. Update state (fees, premiums, tracking)
     *
     * @param policyId The unique identifier of the policy
     * @param amount The gross premium amount in USDC (6 decimals)
     * @param from The address paying the premium
     */
    function receivePremium(
        uint256 policyId,
        uint256 amount,
        address from
    ) external onlyRole(BACKEND_ROLE) nonReentrant whenNotPaused {
        // Validate inputs
        if (amount == 0) revert ZeroAmount();
        if (from == address(0)) revert ZeroAddress();
        if (premiumReceived[policyId]) revert PremiumAlreadyReceived(policyId);

        // Calculate fees
        uint256 platformFee = calculatePlatformFee(amount);
        uint256 netPremium = amount - platformFee;

        // Mark as received BEFORE external call (CEI pattern)
        premiumReceived[policyId] = true;
        accumulatedFees += platformFee;
        totalPremiums += netPremium;

        // Transfer USDC from sender
        usdc.safeTransferFrom(from, address(this), amount);

        emit PremiumReceived(policyId, amount, platformFee, netPremium, from);
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
    function requestPayout(
        uint256 policyId,
        uint256 amount
    ) external onlyRole(PAYOUT_ROLE) nonReentrant whenNotPaused {
        // Validate inputs
        if (amount == 0) revert ZeroAmount();
        if (payoutProcessed[policyId]) revert PayoutAlreadyProcessed(policyId);

        // Calculate reserve requirement
        uint256 currentBalance = usdc.balanceOf(address(this));
        uint256 requiredReserve = (totalPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;

        // Check if payout would violate reserve requirement
        if (currentBalance < amount + requiredReserve) {
            revert InsufficientReserves(
                currentBalance > requiredReserve ? currentBalance - requiredReserve : 0,
                amount,
                requiredReserve
            );
        }

        // Update state BEFORE external call (CEI pattern)
        payoutProcessed[policyId] = true;
        totalPayouts += amount;

        // Transfer USDC to backend wallet
        usdc.safeTransfer(backendWallet, amount);

        emit PayoutSent(policyId, amount, backendWallet);
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

        uint256 fees = accumulatedFees;
        accumulatedFees = 0;

        usdc.safeTransfer(recipient, fees);

        emit FeesWithdrawn(recipient, fees);
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
    function emergencyWithdraw(
        address recipient,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) nonReentrant whenPaused {
        if (recipient == address(0)) revert ZeroAddress();
        
        uint256 balance = usdc.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance(amount, balance);

        usdc.safeTransfer(recipient, amount);

        emit EmergencyWithdrawal(recipient, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Calculates the platform fee for a given premium amount
     * @param premium The gross premium amount
     * @return fee The platform fee amount
     */
    function calculatePlatformFee(uint256 premium) public view returns (uint256 fee) {
        return (premium * platformFeePercent) / BASIS_POINTS;
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
     */
    function getAvailableForPayouts() public view returns (uint256 available) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 requiredReserve = (totalPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;
        
        if (balance <= requiredReserve) {
            return 0;
        }
        return balance - requiredReserve;
    }

    /**
     * @notice Checks if the treasury meets minimum reserve requirements
     * @return meetsReserve True if reserve requirements are met
     */
    function meetsReserveRequirements() public view returns (bool meetsReserve) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 requiredReserve = (totalPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;
        return balance >= requiredReserve;
    }

    /**
     * @notice Returns the required minimum reserve amount
     * @return required The minimum reserve amount required
     */
    function getRequiredReserve() external view returns (uint256 required) {
        return (totalPremiums * MIN_RESERVE_PERCENT) / BASIS_POINTS;
    }

    /**
     * @notice Returns the current reserve ratio as a percentage
     * @return ratio The current reserve ratio (0-100+)
     */
    function getReserveRatio() external view returns (uint256 ratio) {
        if (totalPremiums == 0) return 100;
        
        uint256 balance = usdc.balanceOf(address(this));
        return (balance * BASIS_POINTS) / totalPremiums;
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
}
