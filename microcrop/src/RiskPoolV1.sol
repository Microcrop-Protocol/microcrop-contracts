// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RiskPoolV1
 * @author MicroCrop Protocol
 * @notice ERC20 token representing fractional ownership of an insurance risk pool
 * @dev UUPS upgradeable proxy implementation. Each pool represents a specific coverage 
 *      period, region, and coverage type. Investors deposit USDC during fundraising, 
 *      receive tokens 1:1, and can redeem after the pool expires.
 *
 * State Machine:
 *   FUNDRAISING → ACTIVE → CLOSED → EXPIRED
 *
 * Security Features:
 * - ReentrancyGuard on all fund-moving functions
 * - Pausable for emergencies
 * - Role-based access control
 * - SafeERC20 for all token transfers
 * - UUPS upgrade pattern with UPGRADER_ROLE protection
 */
contract RiskPoolV1 is 
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Enums ============

    /// @notice Pool lifecycle status
    enum PoolStatus {
        FUNDRAISING,    // Accepting investor deposits
        ACTIVE,         // Underwriting policies, collecting premiums
        CLOSED,         // No new policies, existing policies still active
        EXPIRED         // All policies expired, redemption available
    }

    /// @notice Coverage type for the pool
    enum CoverageType {
        DROUGHT,
        FLOOD,
        BOTH
    }

    // ============ Roles ============

    /// @notice Admin role for pool management operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Treasury role for premium/payout operations
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    /// @notice Upgrader role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Constants ============

    /// @notice Minimum investment per investor (1,000 USDC)
    uint256 public constant MIN_INVESTMENT = 1_000e6;

    /// @notice Maximum investment per investor (100,000 USDC)
    uint256 public constant MAX_INVESTMENT = 100_000e6;

    /// @notice Precision for token value calculations (18 decimals)
    uint256 public constant PRECISION = 1e18;

    // ============ State Variables ============
    // NOTE: Storage layout must be preserved across upgrades

    /// @notice USDC token contract
    IERC20 public USDC;

    /// @notice Unique pool identifier
    uint256 public poolId;

    /// @notice Human-readable pool name (e.g., "Kenya Maize Drought Q1 2026")
    string public poolName;

    /// @notice Current pool status
    PoolStatus public status;

    /// @notice Coverage type for this pool
    CoverageType public coverageType;

    /// @notice Geographic region covered (e.g., "Kenya")
    string public region;

    // ============ Timing ============

    /// @notice Timestamp when fundraising begins
    uint256 public fundraiseStart;

    /// @notice Timestamp when fundraising ends
    uint256 public fundraiseEnd;

    /// @notice Timestamp when coverage period starts (set on activation)
    uint256 public coverageStart;

    /// @notice Timestamp when coverage period ends
    uint256 public coverageEnd;

    // ============ Capacity Limits ============

    /// @notice Target USDC to raise (minimum to activate)
    uint256 public targetCapital;

    /// @notice Maximum USDC accepted
    uint256 public maxCapital;

    // ============ Financial Tracking ============

    /// @notice Total net premiums collected (after platform fee)
    uint256 public totalPremiumsCollected;

    /// @notice Total payouts made for claims
    uint256 public totalPayoutsMade;

    /// @notice Platform fee percentage (default 10%)
    uint256 public platformFeePercent;

    // ============ Investor Tracking ============

    /// @notice USDC deposited by each investor
    mapping(address => uint256) public investorDeposits;

    /// @notice Whether investor has redeemed their tokens
    mapping(address => bool) public hasRedeemed;

    /// @notice Number of unique investors
    uint256 public investorCount;

    // ============ Policy Tracking ============

    /// @notice Array of policy IDs in this pool
    uint256[] public policyIds;

    /// @notice Whether a policy belongs to this pool
    mapping(uint256 => bool) public isPolicyInPool;

    /// @dev Reserved storage gap for future upgrades (50 slots)
    uint256[50] private __gap;

    // ============ Events ============

    /// @notice Emitted when an investor deposits USDC
    event Deposited(
        address indexed investor,
        uint256 amount,
        uint256 tokensIssued
    );

    /// @notice Emitted when an investor redeems tokens for USDC
    event Redeemed(
        address indexed investor,
        uint256 tokensBurned,
        uint256 usdcReceived
    );

    /// @notice Emitted when premium is received for a policy
    event PremiumReceived(
        uint256 indexed policyId,
        uint256 grossAmount,
        uint256 netAmount
    );

    /// @notice Emitted when a payout is processed for a claim
    event PayoutProcessed(
        uint256 indexed policyId,
        uint256 amount
    );

    /// @notice Emitted when pool transitions to ACTIVE
    event PoolActivated(
        uint256 timestamp,
        uint256 totalRaised
    );

    /// @notice Emitted when pool transitions to CLOSED
    event PoolClosed(uint256 timestamp);

    /// @notice Emitted when pool transitions to EXPIRED
    event PoolExpired(uint256 timestamp);

    /// @notice Emitted when platform fee is updated
    event PlatformFeeUpdated(uint256 newFee);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTargetCapital();
    error InvalidMaxCapital();
    error InvalidFundraiseDuration();
    error InvalidCoverageDuration();
    error InvalidPoolStatus();
    error FundraisingNotStarted();
    error FundraisingEnded();
    error BelowMinimumInvestment();
    error ExceedsMaximumInvestment();
    error ExceedsPoolCapacity();
    error InsufficientBalance();
    error InsufficientTokens();
    error FundraisingNotEnded();
    error TargetCapitalNotMet();
    error CoverageNotEnded();
    error PolicyAlreadyInPool();
    error PolicyNotInPool();
    error InvalidPlatformFee();
    error AlreadyRedeemed();

    // ============ Structs ============

    /// @notice Configuration struct for pool initialization
    struct PoolConfig {
        address usdc;
        uint256 poolId;
        string name;
        string symbol;
        CoverageType coverageType;
        string region;
        uint256 targetCapital;
        uint256 maxCapital;
        uint256 fundraiseStart;
        uint256 fundraiseEnd;
        uint256 coverageEnd;
        uint256 platformFeePercent;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize a new RiskPool
     * @param config Pool configuration struct
     * @param admin Address to receive admin roles
     */
    function initialize(
        PoolConfig memory config,
        address admin
    ) external initializer {
        if (config.usdc == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        if (config.targetCapital == 0) revert InvalidTargetCapital();
        if (config.maxCapital < config.targetCapital) revert InvalidMaxCapital();
        if (config.fundraiseEnd <= config.fundraiseStart) revert InvalidFundraiseDuration();
        if (config.coverageEnd <= config.fundraiseEnd) revert InvalidCoverageDuration();
        if (config.platformFeePercent > 20) revert InvalidPlatformFee();

        __ERC20_init(config.name, config.symbol);
        __AccessControl_init();
        __Pausable_init();

        USDC = IERC20(config.usdc);
        poolId = config.poolId;
        poolName = config.name;
        coverageType = config.coverageType;
        region = config.region;
        targetCapital = config.targetCapital;
        maxCapital = config.maxCapital;
        fundraiseStart = config.fundraiseStart;
        fundraiseEnd = config.fundraiseEnd;
        coverageEnd = config.coverageEnd;
        platformFeePercent = config.platformFeePercent;

        status = PoolStatus.FUNDRAISING;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    // ============ UUPS Authorization ============

    /**
     * @notice Authorizes contract upgrades
     * @dev Only addresses with UPGRADER_ROLE can authorize upgrades
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Investor Functions ============

    /**
     * @notice Deposit USDC and receive pool tokens 1:1
     * @param amount USDC amount to deposit (6 decimals)
     * @dev Tokens are minted 1:1 with USDC during fundraising.
     *      USDC has 6 decimals, tokens have 18 decimals, but we maintain
     *      1:1 value relationship (1 USDC = 1 token at launch)
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (status != PoolStatus.FUNDRAISING) revert InvalidPoolStatus();
        if (block.timestamp < fundraiseStart) revert FundraisingNotStarted();
        if (block.timestamp > fundraiseEnd) revert FundraisingEnded();
        if (amount < MIN_INVESTMENT) revert BelowMinimumInvestment();
        if (investorDeposits[msg.sender] + amount > MAX_INVESTMENT) {
            revert ExceedsMaximumInvestment();
        }
        if (totalSupply() + amount > maxCapital) revert ExceedsPoolCapacity();

        // Track first-time investors
        if (investorDeposits[msg.sender] == 0) {
            investorCount++;
        }

        // Transfer USDC from investor
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        // Update investor tracking
        investorDeposits[msg.sender] += amount;

        // Mint tokens 1:1 (same amount as USDC deposited)
        _mint(msg.sender, amount);

        emit Deposited(msg.sender, amount, amount);
    }

    /**
     * @notice Redeem tokens for USDC after pool expires
     * @param tokenAmount Amount of tokens to redeem
     * @dev Redemption value = (tokenAmount * poolBalance) / totalSupply
     */
    function redeem(uint256 tokenAmount) external nonReentrant {
        if (status != PoolStatus.EXPIRED) revert InvalidPoolStatus();
        if (tokenAmount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < tokenAmount) revert InsufficientTokens();

        uint256 totalBalance = USDC.balanceOf(address(this));
        uint256 supply = totalSupply();

        // Calculate USDC to return: (tokenAmount * totalBalance) / supply
        uint256 redemptionAmount = (tokenAmount * totalBalance) / supply;

        // Burn tokens first (CEI pattern)
        _burn(msg.sender, tokenAmount);

        // Transfer USDC to investor
        USDC.safeTransfer(msg.sender, redemptionAmount);

        emit Redeemed(msg.sender, tokenAmount, redemptionAmount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Activate pool after fundraising completes
     * @dev Can only be called after fundraiseEnd and if targetCapital is met
     */
    function activatePool() external onlyRole(ADMIN_ROLE) {
        if (status != PoolStatus.FUNDRAISING) revert InvalidPoolStatus();
        if (block.timestamp <= fundraiseEnd) revert FundraisingNotEnded();
        if (totalSupply() < targetCapital) revert TargetCapitalNotMet();

        status = PoolStatus.ACTIVE;
        coverageStart = block.timestamp;

        emit PoolActivated(block.timestamp, totalSupply());
    }

    /**
     * @notice Close pool to new policies
     */
    function closePool() external onlyRole(ADMIN_ROLE) {
        if (status != PoolStatus.ACTIVE) revert InvalidPoolStatus();

        status = PoolStatus.CLOSED;

        emit PoolClosed(block.timestamp);
    }

    /**
     * @notice Mark pool as expired after all policies end
     */
    function expirePool() external onlyRole(ADMIN_ROLE) {
        if (status != PoolStatus.CLOSED) revert InvalidPoolStatus();
        if (block.timestamp <= coverageEnd) revert CoverageNotEnded();

        status = PoolStatus.EXPIRED;

        emit PoolExpired(block.timestamp);
    }

    /**
     * @notice Update platform fee percentage
     * @param newFee New fee percentage (max 20%)
     */
    function setPlatformFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        if (newFee > 20) revert InvalidPlatformFee();

        platformFeePercent = newFee;

        emit PlatformFeeUpdated(newFee);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ Treasury Functions ============

    /**
     * @notice Receive premium payment for a policy
     * @param policyId Policy identifier
     * @param grossPremium Total premium amount (before platform fee)
     */
    function receivePremium(
        uint256 policyId,
        uint256 grossPremium
    ) external onlyRole(TREASURY_ROLE) nonReentrant whenNotPaused {
        if (status != PoolStatus.ACTIVE && status != PoolStatus.CLOSED) {
            revert InvalidPoolStatus();
        }
        if (isPolicyInPool[policyId]) revert PolicyAlreadyInPool();
        if (grossPremium == 0) revert ZeroAmount();

        // Transfer USDC from Treasury
        USDC.safeTransferFrom(msg.sender, address(this), grossPremium);

        // Calculate platform fee and net premium
        uint256 platformFee = (grossPremium * platformFeePercent) / 100;
        uint256 netPremium = grossPremium - platformFee;

        // Track premium collection
        totalPremiumsCollected += netPremium;

        // Add policy to pool
        policyIds.push(policyId);
        isPolicyInPool[policyId] = true;

        emit PremiumReceived(policyId, grossPremium, netPremium);
    }

    /**
     * @notice Process payout for a claim
     * @param policyId Policy identifier
     * @param payoutAmount Amount to pay out
     */
    function processPayout(
        uint256 policyId,
        uint256 payoutAmount
    ) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (!isPolicyInPool[policyId]) revert PolicyNotInPool();
        if (payoutAmount == 0) revert ZeroAmount();
        if (USDC.balanceOf(address(this)) < payoutAmount) {
            revert InsufficientBalance();
        }

        // Update tracking
        totalPayoutsMade += payoutAmount;

        // Transfer USDC to Treasury
        USDC.safeTransfer(msg.sender, payoutAmount);

        emit PayoutProcessed(policyId, payoutAmount);
    }

    // ============ View Functions ============

    /**
     * @notice Get current token value in USDC (with 18 decimal precision)
     * @return Token value with 18 decimals
     */
    function getTokenValue() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return PRECISION;

        uint256 balance = USDC.balanceOf(address(this));
        return (balance * PRECISION) / supply;
    }

    /**
     * @notice Get pool USDC balance
     * @return Current USDC balance
     */
    function getPoolBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /**
     * @notice Get net asset value per token
     * @return NAV with 18 decimals
     */
    function getNetAssetValue() external view returns (uint256) {
        return getTokenValue();
    }

    /**
     * @notice Get number of policies in this pool
     * @return Policy count
     */
    function getPolicyCount() external view returns (uint256) {
        return policyIds.length;
    }

    /**
     * @notice Calculate current ROI percentage
     * @return ROI as percentage with 2 decimal precision
     */
    function getROI() external view returns (int256) {
        uint256 currentValue = getTokenValue();

        if (currentValue >= PRECISION) {
            return int256(((currentValue - PRECISION) * 10000) / PRECISION);
        } else {
            return -int256(((PRECISION - currentValue) * 10000) / PRECISION);
        }
    }

    /**
     * @notice Get comprehensive investor information
     * @param investor Address to query
     * @return deposited USDC originally deposited
     * @return tokensHeld Current token balance
     * @return currentValue Current USDC value of holdings
     * @return roi Current ROI percentage
     */
    function getInvestorInfo(address investor)
        external
        view
        returns (
            uint256 deposited,
            uint256 tokensHeld,
            uint256 currentValue,
            int256 roi
        )
    {
        deposited = investorDeposits[investor];
        tokensHeld = balanceOf(investor);
        currentValue = (tokensHeld * getTokenValue()) / PRECISION;
        
        if (deposited > 0) {
            if (currentValue >= deposited) {
                roi = int256(((currentValue - deposited) * 10000) / deposited);
            } else {
                roi = -int256(((deposited - currentValue) * 10000) / deposited);
            }
        }
    }

    /**
     * @notice Get all policy IDs in this pool
     * @return Array of policy IDs
     */
    function getAllPolicyIds() external view returns (uint256[] memory) {
        return policyIds;
    }

    /**
     * @notice Check if pool can accept a new policy
     * @param sumInsured The sum insured for the proposed policy
     * @return Whether the pool has sufficient capital
     */
    function canAcceptPolicy(uint256 sumInsured) external view returns (bool) {
        if (status != PoolStatus.ACTIVE && status != PoolStatus.CLOSED) {
            return false;
        }
        return USDC.balanceOf(address(this)) >= sumInsured;
    }

    /**
     * @notice Calculate redemption amount for a given token amount
     * @param tokenAmount Tokens to redeem
     * @return USDC amount that would be received
     */
    function calculateRedemption(uint256 tokenAmount) external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 totalBalance = USDC.balanceOf(address(this));
        return (tokenAmount * totalBalance) / supply;
    }

    /**
     * @notice Returns the contract version for upgrade tracking
     * @return The contract version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
