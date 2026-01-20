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
 * @title RiskPoolV2Upgradeable
 * @author MicroCrop Protocol
 * @notice Upgradeable ERC20 LP token representing fractional ownership of an insurance risk pool
 * @dev Implements the institutional LP token model with three pool types:
 *      - PUBLIC: Open to anyone, liquid, tradeable
 *      - PRIVATE: Restricted to institutions, high minimums
 *      - MUTUAL: Cooperative-owned, members only
 *
 *      Token price is NAV-based: Token Price = Pool Value / Total Supply
 *      LPs deposit/withdraw at current NAV without diluting other holders.
 *
 * Revenue Distribution (per premium):
 *   - LP Pool:        70% (increases token value)
 *   - Product Builder: 12% (institution fee)
 *   - Protocol:       10% (MicroCrop platform)
 *   - Distributor:     8% (cooperative/agent)
 *
 * Upgradeability:
 *   - Uses UUPS proxy pattern
 *   - Only UPGRADER_ROLE can authorize upgrades
 *   - Storage gaps for future upgrades
 */
contract RiskPoolV2Upgradeable is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Enums ============

    /// @notice Pool type determines access and liquidity rules
    enum PoolType {
        PUBLIC,     // Open to anyone with USDC
        PRIVATE,    // Restricted to approved institutions
        MUTUAL      // Cooperative members only
    }

    /// @notice Coverage type for the pool
    enum CoverageType {
        DROUGHT,
        FLOOD,
        BOTH
    }

    // ============ Roles ============

    /// @notice Admin role for pool management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Treasury role for premium/payout operations
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    /// @notice Depositor role for private/mutual pools (whitelisted)
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Upgrader role for UUPS upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Constants ============

    /// @notice Precision for token value calculations (18 decimals)
    uint256 public constant PRECISION = 1e18;

    /// @notice Revenue share for LP pool (70%)
    uint256 public constant LP_SHARE_BPS = 7000;

    /// @notice Revenue share for product builder (12%)
    uint256 public constant BUILDER_SHARE_BPS = 1200;

    /// @notice Revenue share for protocol (10%)
    uint256 public constant PROTOCOL_SHARE_BPS = 1000;

    /// @notice Revenue share for distributor (8%)
    uint256 public constant DISTRIBUTOR_SHARE_BPS = 800;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Storage ============

    /// @notice USDC token contract
    IERC20 public usdc;

    /// @notice Unique pool identifier
    uint256 public poolId;

    /// @notice Pool type (PUBLIC, PRIVATE, MUTUAL)
    PoolType public poolType;

    /// @notice Human-readable pool name
    string public poolName;

    /// @notice Pool owner (institution address for private pools, zero for public)
    address public poolOwner;

    /// @notice Coverage type for this pool
    CoverageType public coverageType;

    /// @notice Geographic region covered
    string public region;

    /// @notice Minimum deposit amount
    uint256 public minDeposit;

    /// @notice Maximum deposit per investor
    uint256 public maxDeposit;

    /// @notice Target pool capital
    uint256 public targetCapital;

    /// @notice Maximum pool capital
    uint256 public maxCapital;

    /// @notice Whether deposits are currently accepted
    bool public depositsOpen;

    /// @notice Whether withdrawals are currently allowed
    bool public withdrawalsOpen;

    /// @notice Total premiums collected (gross)
    uint256 public totalPremiums;

    /// @notice Total payouts made
    uint256 public totalPayouts;

    /// @notice Active exposure (sum insured of active policies)
    uint256 public activeExposure;

    /// @notice Product builder address (receives 12% of premiums)
    address public productBuilder;

    /// @notice Protocol treasury address (receives 10% of premiums)
    address public protocolTreasury;

    /// @notice Default distributor address (receives 8% of premiums)
    address public defaultDistributor;

    /// @notice Total USDC deposited by each investor
    mapping(address => uint256) public totalDeposited;

    /// @notice Number of unique investors
    uint256 public investorCount;

    /// @notice Storage gap for future upgrades
    uint256[40] private __gap;

    // ============ Events ============

    /// @notice Emitted when LP deposits USDC
    event Deposited(
        address indexed investor,
        uint256 usdcAmount,
        uint256 tokensMinted,
        uint256 tokenPrice
    );

    /// @notice Emitted when LP withdraws USDC
    event Withdrawn(
        address indexed investor,
        uint256 tokensBurned,
        uint256 usdcReceived,
        uint256 tokenPrice
    );

    /// @notice Emitted when premium is collected
    event PremiumCollected(
        uint256 indexed policyId,
        uint256 grossAmount,
        uint256 lpShare,
        uint256 builderShare,
        uint256 protocolShare,
        uint256 distributorShare
    );

    /// @notice Emitted when payout is processed
    event PayoutProcessed(
        uint256 indexed policyId,
        uint256 amount
    );

    /// @notice Emitted when exposure changes
    event ExposureUpdated(
        uint256 indexed policyId,
        int256 delta,
        uint256 newTotalExposure
    );

    /// @notice Emitted when deposit status changes
    event DepositsStatusChanged(bool open);

    /// @notice Emitted when withdrawal status changes
    event WithdrawalsStatusChanged(bool open);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidPoolType();
    error InvalidAmount();
    error DepositsNotOpen();
    error WithdrawalsNotOpen();
    error BelowMinimumDeposit();
    error ExceedsMaximumDeposit();
    error ExceedsPoolCapacity();
    error InsufficientBalance();
    error InsufficientLiquidity();
    error InsufficientTokens();
    error NotAuthorized();
    error InvalidRecipient();

    // ============ Structs ============

    /// @notice Configuration struct for pool initialization
    struct PoolConfig {
        address usdc;
        uint256 poolId;
        string name;
        string symbol;
        PoolType poolType;
        CoverageType coverageType;
        string region;
        address poolOwner;
        uint256 minDeposit;
        uint256 maxDeposit;
        uint256 targetCapital;
        uint256 maxCapital;
        address productBuilder;
        address protocolTreasury;
        address defaultDistributor;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the pool (replaces constructor)
     * @param config Pool configuration struct
     */
    function initialize(PoolConfig memory config) external initializer {
        if (config.usdc == address(0)) revert ZeroAddress();
        if (config.protocolTreasury == address(0)) revert ZeroAddress();
        if (config.targetCapital == 0) revert InvalidAmount();
        if (config.maxCapital < config.targetCapital) revert InvalidAmount();
        if (config.minDeposit == 0) revert InvalidAmount();
        if (config.maxDeposit < config.minDeposit) revert InvalidAmount();

        __ERC20_init(config.name, config.symbol);
        __AccessControl_init();
        __Pausable_init();

        usdc = IERC20(config.usdc);
        poolId = config.poolId;
        poolType = config.poolType;
        poolName = config.name;
        coverageType = config.coverageType;
        region = config.region;
        poolOwner = config.poolOwner;
        minDeposit = config.minDeposit;
        maxDeposit = config.maxDeposit;
        targetCapital = config.targetCapital;
        maxCapital = config.maxCapital;
        productBuilder = config.productBuilder;
        protocolTreasury = config.protocolTreasury;
        defaultDistributor = config.defaultDistributor;

        // Public pools start with deposits open
        depositsOpen = (config.poolType == PoolType.PUBLIC);
        withdrawalsOpen = (config.poolType == PoolType.PUBLIC);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        // For private/mutual pools, grant depositor role to owner
        if (config.poolOwner != address(0)) {
            _grantRole(DEPOSITOR_ROLE, config.poolOwner);
        }
    }

    // ============ UUPS ============

    /**
     * @notice Authorize upgrade (UUPS pattern)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ============ LP Functions ============

    /**
     * @notice Deposit USDC and receive LP tokens at current NAV
     * @param usdcAmount Amount of USDC to deposit
     */
    function deposit(uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (!depositsOpen) revert DepositsNotOpen();
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount < minDeposit) revert BelowMinimumDeposit();
        if (totalDeposited[msg.sender] + usdcAmount > maxDeposit) {
            revert ExceedsMaximumDeposit();
        }

        // Check pool capacity
        uint256 currentValue = getPoolValue();
        if (currentValue + usdcAmount > maxCapital) revert ExceedsPoolCapacity();

        // For PRIVATE and MUTUAL pools, require DEPOSITOR_ROLE
        if (poolType != PoolType.PUBLIC) {
            if (!hasRole(DEPOSITOR_ROLE, msg.sender)) revert NotAuthorized();
        }

        // Calculate tokens to mint at current NAV
        uint256 tokenPrice = getTokenPrice();
        uint256 tokensToMint = (usdcAmount * PRECISION) / tokenPrice;

        // Track first-time investors
        if (totalDeposited[msg.sender] == 0) {
            investorCount++;
        }

        // Transfer USDC from LP
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Update tracking
        totalDeposited[msg.sender] += usdcAmount;

        // Mint LP tokens
        _mint(msg.sender, tokensToMint);

        emit Deposited(msg.sender, usdcAmount, tokensToMint, tokenPrice);
    }

    /**
     * @notice Withdraw USDC by burning LP tokens at current NAV
     * @param tokenAmount Amount of LP tokens to burn
     */
    function withdraw(uint256 tokenAmount) external nonReentrant {
        if (!withdrawalsOpen) revert WithdrawalsNotOpen();
        if (tokenAmount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < tokenAmount) revert InsufficientTokens();

        // Calculate USDC to return at current NAV
        uint256 tokenPrice = getTokenPrice();
        uint256 usdcAmount = (tokenAmount * tokenPrice) / PRECISION;

        // Check pool has liquidity
        uint256 availableLiquidity = getAvailableLiquidity();
        if (availableLiquidity < usdcAmount) revert InsufficientLiquidity();

        // Burn LP tokens first (CEI pattern)
        _burn(msg.sender, tokenAmount);

        // Transfer USDC to LP
        usdc.safeTransfer(msg.sender, usdcAmount);

        emit Withdrawn(msg.sender, tokenAmount, usdcAmount, tokenPrice);
    }

    // ============ Treasury Functions ============

    /**
     * @notice Collect premium and distribute to stakeholders
     * @param policyId Policy identifier
     * @param grossPremium Total premium amount
     * @param distributor Address of the distributor
     */
    function collectPremium(
        uint256 policyId,
        uint256 grossPremium,
        address distributor
    ) external onlyRole(TREASURY_ROLE) nonReentrant whenNotPaused {
        if (grossPremium == 0) revert ZeroAmount();

        // Transfer gross premium from Treasury
        usdc.safeTransferFrom(msg.sender, address(this), grossPremium);

        // Calculate shares
        uint256 lpShare = (grossPremium * LP_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 builderShare = (grossPremium * BUILDER_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 protocolShare = (grossPremium * PROTOCOL_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 distributorShare = (grossPremium * DISTRIBUTOR_SHARE_BPS) / BPS_DENOMINATOR;

        // Distribute builder share
        if (productBuilder != address(0) && builderShare > 0) {
            usdc.safeTransfer(productBuilder, builderShare);
        } else {
            lpShare += builderShare;
        }

        // Distribute protocol share
        if (protocolShare > 0) {
            usdc.safeTransfer(protocolTreasury, protocolShare);
        }

        // Distribute distributor share
        address actualDistributor = distributor != address(0) ? distributor : defaultDistributor;
        if (actualDistributor != address(0) && distributorShare > 0) {
            usdc.safeTransfer(actualDistributor, distributorShare);
        } else {
            lpShare += distributorShare;
        }

        totalPremiums += grossPremium;

        emit PremiumCollected(
            policyId,
            grossPremium,
            lpShare,
            productBuilder != address(0) ? builderShare : 0,
            protocolShare,
            actualDistributor != address(0) ? distributorShare : 0
        );
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
        if (payoutAmount == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) < payoutAmount) {
            revert InsufficientBalance();
        }

        totalPayouts += payoutAmount;
        usdc.safeTransfer(msg.sender, payoutAmount);

        emit PayoutProcessed(policyId, payoutAmount);
    }

    /**
     * @notice Update active exposure
     * @param policyId Policy identifier
     * @param delta Change in exposure
     */
    function updateExposure(
        uint256 policyId,
        int256 delta
    ) external onlyRole(TREASURY_ROLE) {
        if (delta > 0) {
            activeExposure += uint256(delta);
        } else if (delta < 0) {
            uint256 decrease = uint256(-delta);
            if (decrease > activeExposure) {
                activeExposure = 0;
            } else {
                activeExposure -= decrease;
            }
        }

        emit ExposureUpdated(policyId, delta, activeExposure);
    }

    // ============ Admin Functions ============

    /**
     * @notice Open or close deposits
     * @param open Whether deposits should be open
     */
    function setDepositsOpen(bool open) external onlyRole(ADMIN_ROLE) {
        depositsOpen = open;
        emit DepositsStatusChanged(open);
    }

    /**
     * @notice Open or close withdrawals
     * @param open Whether withdrawals should be open
     */
    function setWithdrawalsOpen(bool open) external onlyRole(ADMIN_ROLE) {
        withdrawalsOpen = open;
        emit WithdrawalsStatusChanged(open);
    }

    /**
     * @notice Update minimum deposit amount
     * @param newMin New minimum deposit
     */
    function setMinDeposit(uint256 newMin) external onlyRole(ADMIN_ROLE) {
        if (newMin == 0) revert InvalidAmount();
        if (newMin > maxDeposit) revert InvalidAmount();
        minDeposit = newMin;
    }

    /**
     * @notice Update maximum deposit amount
     * @param newMax New maximum deposit
     */
    function setMaxDeposit(uint256 newMax) external onlyRole(ADMIN_ROLE) {
        if (newMax < minDeposit) revert InvalidAmount();
        maxDeposit = newMax;
    }

    /**
     * @notice Update product builder address
     * @param newBuilder New builder address
     */
    function setProductBuilder(address newBuilder) external onlyRole(ADMIN_ROLE) {
        productBuilder = newBuilder;
    }

    /**
     * @notice Update default distributor address
     * @param newDistributor New distributor address
     */
    function setDefaultDistributor(address newDistributor) external onlyRole(ADMIN_ROLE) {
        defaultDistributor = newDistributor;
    }

    /**
     * @notice Whitelist depositor for private/mutual pools
     * @param depositor Address to whitelist
     */
    function addDepositor(address depositor) external onlyRole(ADMIN_ROLE) {
        if (depositor == address(0)) revert ZeroAddress();
        _grantRole(DEPOSITOR_ROLE, depositor);
    }

    /**
     * @notice Remove depositor whitelist
     * @param depositor Address to remove
     */
    function removeDepositor(address depositor) external onlyRole(ADMIN_ROLE) {
        _revokeRole(DEPOSITOR_ROLE, depositor);
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

    // ============ View Functions ============

    /**
     * @notice Get current token price (NAV per token)
     * @return Token price with 18 decimal precision
     */
    function getTokenPrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return PRECISION;

        uint256 poolValue = usdc.balanceOf(address(this));
        return (poolValue * PRECISION) / supply;
    }

    /**
     * @notice Get total pool value in USDC
     * @return Pool USDC balance
     */
    function getPoolValue() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Get available liquidity for withdrawals
     * @return Available USDC after reserving for active exposure
     */
    function getAvailableLiquidity() public view returns (uint256) {
        uint256 poolBalance = usdc.balanceOf(address(this));
        uint256 reserved = (activeExposure * 120) / 100;

        if (poolBalance <= reserved) return 0;
        return poolBalance - reserved;
    }

    /**
     * @notice Calculate how many tokens would be minted for a deposit
     * @param usdcAmount USDC amount to deposit
     * @return Tokens that would be minted
     */
    function calculateMintAmount(uint256 usdcAmount) external view returns (uint256) {
        uint256 tokenPrice = getTokenPrice();
        return (usdcAmount * PRECISION) / tokenPrice;
    }

    /**
     * @notice Calculate USDC received for token redemption
     * @param tokenAmount Tokens to redeem
     * @return USDC that would be received
     */
    function calculateWithdrawAmount(uint256 tokenAmount) external view returns (uint256) {
        uint256 tokenPrice = getTokenPrice();
        return (tokenAmount * tokenPrice) / PRECISION;
    }

    /**
     * @notice Get investor information
     * @param investor Address to query
     * @return deposited Total USDC deposited
     * @return tokensHeld Current token balance
     * @return currentValue Current USDC value
     * @return roi Return on investment (basis points)
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
        deposited = totalDeposited[investor];
        tokensHeld = balanceOf(investor);
        currentValue = (tokensHeld * getTokenPrice()) / PRECISION;

        if (deposited > 0) {
            if (currentValue >= deposited) {
                roi = int256(((currentValue - deposited) * 10000) / deposited);
            } else {
                roi = -int256(((deposited - currentValue) * 10000) / deposited);
            }
        }
    }

    /**
     * @notice Get pool financial summary
     * @return poolValue Total pool value
     * @return supply Total token supply
     * @return tokenPrice Current token price
     * @return premiums Total premiums collected
     * @return payouts Total payouts made
     * @return exposure Active exposure
     */
    function getPoolSummary()
        external
        view
        returns (
            uint256 poolValue,
            uint256 supply,
            uint256 tokenPrice,
            uint256 premiums,
            uint256 payouts,
            uint256 exposure
        )
    {
        poolValue = getPoolValue();
        supply = totalSupply();
        tokenPrice = getTokenPrice();
        premiums = totalPremiums;
        payouts = totalPayouts;
        exposure = activeExposure;
    }

    /**
     * @notice Check if pool can accept a policy
     * @param sumInsured Sum insured of proposed policy
     * @return Whether pool can underwrite the policy
     */
    function canAcceptPolicy(uint256 sumInsured) external view returns (bool) {
        return getPoolValue() >= sumInsured;
    }

    /**
     * @notice Check if an address can deposit
     * @param investor Address to check
     * @return Whether the address can deposit
     */
    function canDeposit(address investor) external view returns (bool) {
        if (!depositsOpen) return false;
        if (poolType != PoolType.PUBLIC) {
            return hasRole(DEPOSITOR_ROLE, investor);
        }
        return true;
    }
}
