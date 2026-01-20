// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RiskPoolV1} from "./RiskPoolV1.sol";

/**
 * @title RiskPoolFactoryV1
 * @author MicroCrop Protocol
 * @notice UUPS upgradeable factory for creating and managing RiskPoolV1 instances
 * @dev Creates new RiskPoolV1 ERC20 tokens (as UUPS proxies) for different insurance pools.
 *      Each pool represents a specific coverage period, region, and coverage type.
 *      The factory maintains a registry of all pools and provides query functions.
 *
 * Security Features:
 * - Only ADMIN_ROLE can create pools
 * - Validates all pool parameters
 * - Grants TREASURY_ROLE to treasury on each pool
 * - UUPS upgrade pattern with UPGRADER_ROLE protection
 */
contract RiskPoolFactoryV1 is 
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    // ============ Structs ============

    /// @notice Metadata for a pool
    struct PoolMetadata {
        address poolAddress;
        uint256 poolId;
        string name;
        RiskPoolV1.CoverageType coverageType;
        string region;
        uint256 createdAt;
        RiskPoolV1.PoolStatus status;
    }

    // ============ Roles ============

    /// @notice Admin role for pool creation
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Upgrader role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Constants ============

    /// @notice Minimum fundraise duration (7 days)
    uint256 public constant MIN_FUNDRAISE_DURATION = 7 days;

    /// @notice Maximum fundraise duration (30 days)
    uint256 public constant MAX_FUNDRAISE_DURATION = 30 days;

    /// @notice Minimum coverage duration (30 days)
    uint256 public constant MIN_COVERAGE_DURATION = 30 days;

    /// @notice Maximum coverage duration (365 days)
    uint256 public constant MAX_COVERAGE_DURATION = 365 days;

    /// @notice Minimum target capital (500,000 USDC)
    uint256 public constant MIN_TARGET_CAPITAL = 500_000e6;

    /// @notice Maximum pool capital (2,000,000 USDC)
    uint256 public constant MAX_POOL_CAPITAL = 2_000_000e6;

    // ============ State Variables ============
    // NOTE: Storage layout must be preserved across upgrades

    /// @notice USDC token address
    address public USDC;

    /// @notice Treasury contract address
    address public treasury;

    /// @notice RiskPoolV1 implementation address for creating proxies
    address public riskPoolImplementation;

    /// @notice Counter for unique pool IDs
    uint256 public poolCounter;

    /// @notice Mapping from pool ID to pool address
    mapping(uint256 => address) public pools;

    /// @notice Mapping to verify if an address is a valid pool
    mapping(address => bool) public isPool;

    /// @notice Array of all pool addresses
    address[] public allPools;

    /// @notice Default platform fee for new pools (10%)
    uint256 public defaultPlatformFee;

    /// @dev Reserved storage gap for future upgrades (50 slots)
    uint256[50] private __gap;

    // ============ Events ============

    /// @notice Emitted when a new pool is created
    event PoolCreated(
        uint256 indexed poolId,
        address indexed poolAddress,
        string name,
        RiskPoolV1.CoverageType coverageType,
        string region
    );

    /// @notice Emitted when default platform fee is updated
    event PlatformFeeUpdated(uint256 newFee);

    /// @notice Emitted when RiskPool implementation is updated
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    // ============ Errors ============

    error ZeroAddress();
    error EmptyName();
    error EmptyRegion();
    error InvalidTargetCapital();
    error InvalidMaxCapital();
    error InvalidFundraiseDuration();
    error InvalidCoverageDuration();
    error InvalidPlatformFee();
    error PoolNotFound();

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the RiskPoolFactory
     * @param _usdc USDC token address
     * @param _treasury Treasury contract address
     * @param _riskPoolImplementation RiskPoolV1 implementation address
     * @param _admin Address to receive admin roles
     */
    function initialize(
        address _usdc,
        address _treasury,
        address _riskPoolImplementation,
        address _admin
    ) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_riskPoolImplementation == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControl_init();

        USDC = _usdc;
        treasury = _treasury;
        riskPoolImplementation = _riskPoolImplementation;
        defaultPlatformFee = 10; // 10%

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

    // ============ Admin Functions ============

    /**
     * @notice Create a new RiskPool (as UUPS proxy)
     * @param name Pool name (e.g., "Kenya Maize Drought Q1 2026")
     * @param symbol Token symbol (e.g., "mKM-Q1-26")
     * @param coverageType Type of coverage (DROUGHT, FLOOD, BOTH)
     * @param region Geographic region covered
     * @param targetCapital Minimum USDC to raise
     * @param maxCapital Maximum USDC to accept
     * @param fundraiseDuration Duration of fundraising period
     * @param coverageDuration Duration of coverage period (after fundraising)
     * @return poolAddress Address of the new pool proxy
     */
    function createPool(
        string memory name,
        string memory symbol,
        RiskPoolV1.CoverageType coverageType,
        string memory region,
        uint256 targetCapital,
        uint256 maxCapital,
        uint256 fundraiseDuration,
        uint256 coverageDuration
    ) external onlyRole(ADMIN_ROLE) returns (address poolAddress) {
        // Validate inputs
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(region).length == 0) revert EmptyRegion();
        if (targetCapital < MIN_TARGET_CAPITAL) revert InvalidTargetCapital();
        if (maxCapital > MAX_POOL_CAPITAL) revert InvalidMaxCapital();
        if (targetCapital > maxCapital) revert InvalidTargetCapital();
        if (fundraiseDuration < MIN_FUNDRAISE_DURATION || fundraiseDuration > MAX_FUNDRAISE_DURATION) {
            revert InvalidFundraiseDuration();
        }
        if (coverageDuration < MIN_COVERAGE_DURATION || coverageDuration > MAX_COVERAGE_DURATION) {
            revert InvalidCoverageDuration();
        }

        // Increment pool counter
        poolCounter++;
        uint256 newPoolId = poolCounter;

        // Calculate timing
        uint256 fundraiseStart = block.timestamp;
        uint256 fundraiseEnd = fundraiseStart + fundraiseDuration;
        uint256 coverageEnd = fundraiseEnd + coverageDuration;

        // Build config struct
        RiskPoolV1.PoolConfig memory config = RiskPoolV1.PoolConfig({
            usdc: USDC,
            poolId: newPoolId,
            name: name,
            symbol: symbol,
            coverageType: coverageType,
            region: region,
            targetCapital: targetCapital,
            maxCapital: maxCapital,
            fundraiseStart: fundraiseStart,
            fundraiseEnd: fundraiseEnd,
            coverageEnd: coverageEnd,
            platformFeePercent: defaultPlatformFee
        });

        // Build initialization data
        bytes memory initData = abi.encodeWithSelector(
            RiskPoolV1.initialize.selector,
            config,
            address(this) // Factory is initial admin
        );

        // Deploy ERC1967 proxy pointing to RiskPoolV1 implementation
        ERC1967Proxy proxy = new ERC1967Proxy(riskPoolImplementation, initData);
        poolAddress = address(proxy);

        RiskPoolV1 pool = RiskPoolV1(poolAddress);

        // Grant TREASURY_ROLE to treasury contract
        pool.grantRole(pool.TREASURY_ROLE(), treasury);

        // Store pool in registry
        pools[newPoolId] = poolAddress;
        isPool[poolAddress] = true;
        allPools.push(poolAddress);

        emit PoolCreated(newPoolId, poolAddress, name, coverageType, region);
    }

    /**
     * @notice Update the RiskPoolV1 implementation for new pools
     * @param newImplementation New implementation address
     */
    function setRiskPoolImplementation(address newImplementation) external onlyRole(ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();

        address oldImpl = riskPoolImplementation;
        riskPoolImplementation = newImplementation;

        emit ImplementationUpdated(oldImpl, newImplementation);
    }

    /**
     * @notice Update default platform fee for new pools
     * @param newFee New fee percentage (5-20%)
     */
    function setDefaultPlatformFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        if (newFee < 5 || newFee > 20) revert InvalidPlatformFee();

        defaultPlatformFee = newFee;

        emit PlatformFeeUpdated(newFee);
    }

    // ============ View Functions ============

    /**
     * @notice Get all pool addresses
     * @return Array of pool addresses
     */
    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    /**
     * @notice Get all active pools (status == ACTIVE)
     * @return activePools Array of active pool addresses
     */
    function getActivePools() external view returns (address[] memory activePools) {
        uint256 activeCount = 0;

        // First pass: count active pools
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPoolV1 pool = RiskPoolV1(allPools[i]);
            if (pool.status() == RiskPoolV1.PoolStatus.ACTIVE) {
                activeCount++;
            }
        }

        // Second pass: populate array
        activePools = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPoolV1 pool = RiskPoolV1(allPools[i]);
            if (pool.status() == RiskPoolV1.PoolStatus.ACTIVE) {
                activePools[index] = allPools[i];
                index++;
            }
        }
    }

    /**
     * @notice Get pools by status
     * @param status Pool status to filter by
     * @return filteredPools Array of pool addresses with given status
     */
    function getPoolsByStatus(RiskPoolV1.PoolStatus status) 
        external 
        view 
        returns (address[] memory filteredPools) 
    {
        uint256 count = 0;

        // First pass: count matching pools
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPoolV1 pool = RiskPoolV1(allPools[i]);
            if (pool.status() == status) {
                count++;
            }
        }

        // Second pass: populate array
        filteredPools = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPoolV1 pool = RiskPoolV1(allPools[i]);
            if (pool.status() == status) {
                filteredPools[index] = allPools[i];
                index++;
            }
        }
    }

    /**
     * @notice Get metadata for a specific pool
     * @param poolId Pool ID to query
     * @return metadata Pool metadata struct
     */
    function getPoolMetadata(uint256 poolId) 
        external 
        view 
        returns (PoolMetadata memory metadata) 
    {
        address poolAddress = pools[poolId];
        if (poolAddress == address(0)) revert PoolNotFound();

        RiskPoolV1 pool = RiskPoolV1(poolAddress);

        metadata = PoolMetadata({
            poolAddress: poolAddress,
            poolId: poolId,
            name: pool.poolName(),
            coverageType: pool.coverageType(),
            region: pool.region(),
            createdAt: pool.fundraiseStart(),
            status: pool.status()
        });
    }

    /**
     * @notice Get pool address by ID
     * @param poolId Pool ID
     * @return Pool address
     */
    function getPoolById(uint256 poolId) external view returns (address) {
        return pools[poolId];
    }

    /**
     * @notice Get total number of pools created
     * @return Number of pools
     */
    function getPoolCount() external view returns (uint256) {
        return allPools.length;
    }

    /**
     * @notice Check if an address is a valid pool
     * @param poolAddress Address to check
     * @return Whether address is a pool
     */
    function isValidPool(address poolAddress) external view returns (bool) {
        return isPool[poolAddress];
    }

    /**
     * @notice Returns the contract version for upgrade tracking
     * @return The contract version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
