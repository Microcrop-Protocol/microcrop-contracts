// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RiskPool} from "./RiskPool.sol";

/**
 * @title RiskPoolFactory
 * @author MicroCrop Protocol
 * @notice Factory contract for creating and managing RiskPool instances
 * @dev Creates new RiskPool ERC20 tokens for different insurance pools.
 *      Each pool represents a specific coverage period, region, and coverage type.
 *      The factory maintains a registry of all pools and provides query functions.
 *
 * Security Features:
 * - Only ADMIN_ROLE can create pools
 * - Validates all pool parameters
 * - Grants TREASURY_ROLE to treasury on each pool
 */
contract RiskPoolFactory is AccessControl {
    // ============ Structs ============

    /// @notice Metadata for a pool
    struct PoolMetadata {
        address poolAddress;
        uint256 poolId;
        string name;
        RiskPool.CoverageType coverageType;
        string region;
        uint256 createdAt;
        RiskPool.PoolStatus status;
    }

    // ============ Roles ============

    /// @notice Admin role for pool creation
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

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

    // ============ Immutable State ============

    /// @notice USDC token address
    address public immutable USDC;

    /// @notice Treasury contract address
    address public immutable treasury;

    // ============ State Variables ============

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

    // ============ Events ============

    /// @notice Emitted when a new pool is created
    event PoolCreated(
        uint256 indexed poolId,
        address indexed poolAddress,
        string name,
        RiskPool.CoverageType coverageType,
        string region
    );

    /// @notice Emitted when default platform fee is updated
    event PlatformFeeUpdated(uint256 newFee);

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

    /**
     * @notice Create a new RiskPoolFactory
     * @param _usdc USDC token address
     * @param _treasury Treasury contract address
     */
    constructor(address _usdc, address _treasury) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        USDC = _usdc;
        treasury = _treasury;
        defaultPlatformFee = 10; // 10%

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ============ Admin Functions ============

    /**
     * @notice Create a new RiskPool
     * @param name Pool name (e.g., "Kenya Maize Drought Q1 2026")
     * @param symbol Token symbol (e.g., "mKM-Q1-26")
     * @param coverageType Type of coverage (DROUGHT, FLOOD, BOTH)
     * @param region Geographic region covered
     * @param targetCapital Minimum USDC to raise
     * @param maxCapital Maximum USDC to accept
     * @param fundraiseDuration Duration of fundraising period
     * @param coverageDuration Duration of coverage period (after fundraising)
     * @return poolAddress Address of the new pool
     */
    function createPool(
        string memory name,
        string memory symbol,
        RiskPool.CoverageType coverageType,
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
        RiskPool.PoolConfig memory config = RiskPool.PoolConfig({
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

        // Deploy new RiskPool
        RiskPool pool = new RiskPool(config);

        poolAddress = address(pool);

        // Grant TREASURY_ROLE to treasury contract
        pool.grantRole(pool.TREASURY_ROLE(), treasury);

        // Store pool in registry
        pools[newPoolId] = poolAddress;
        isPool[poolAddress] = true;
        allPools.push(poolAddress);

        emit PoolCreated(newPoolId, poolAddress, name, coverageType, region);
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
            RiskPool pool = RiskPool(allPools[i]);
            if (pool.status() == RiskPool.PoolStatus.ACTIVE) {
                activeCount++;
            }
        }

        // Second pass: populate array
        activePools = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPool pool = RiskPool(allPools[i]);
            if (pool.status() == RiskPool.PoolStatus.ACTIVE) {
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
    function getPoolsByStatus(RiskPool.PoolStatus status) 
        external 
        view 
        returns (address[] memory filteredPools) 
    {
        uint256 count = 0;

        // First pass: count matching pools
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPool pool = RiskPool(allPools[i]);
            if (pool.status() == status) {
                count++;
            }
        }

        // Second pass: populate array
        filteredPools = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allPools.length; i++) {
            RiskPool pool = RiskPool(allPools[i]);
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

        RiskPool pool = RiskPool(poolAddress);

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
}
