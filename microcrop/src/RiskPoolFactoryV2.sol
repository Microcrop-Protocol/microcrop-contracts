// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RiskPoolV2} from "./RiskPoolV2.sol";

/**
 * @title RiskPoolFactoryV2
 * @author MicroCrop Protocol
 * @notice Factory for creating RiskPoolV2 instances with different pool types
 * @dev Supports three pool types:
 *      - PUBLIC: Open to anyone, lower minimums ($100+)
 *      - PRIVATE: Institutions only, high minimums ($250K+)
 *      - MUTUAL: Cooperative members only, member-set minimums
 *
 * Token Naming Convention:
 *      - PUBLIC: mcMAIZE-D, mcBEANS-F (mc = MicroCrop)
 *      - PRIVATE: uapUAP, equityEQUITY (institution prefix)
 *      - MUTUAL: kfaKFA (cooperative prefix)
 *
 * Security Features:
 * - Only ADMIN_ROLE can create pools
 * - Validates all pool parameters
 * - Grants TREASURY_ROLE to treasury on each pool
 */
contract RiskPoolFactoryV2 is AccessControl {
    // ============ Structs ============

    /// @notice Metadata for a pool
    struct PoolMetadata {
        address poolAddress;
        uint256 poolId;
        string name;
        RiskPoolV2.PoolType poolType;
        RiskPoolV2.CoverageType coverageType;
        string region;
        address poolOwner;
        uint256 createdAt;
    }

    /// @notice Parameters for creating a public pool
    struct PublicPoolParams {
        string name;
        string symbol;
        RiskPoolV2.CoverageType coverageType;
        string region;
        uint256 targetCapital;
        uint256 maxCapital;
    }

    /// @notice Parameters for creating a private pool
    struct PrivatePoolParams {
        string name;
        string symbol;
        RiskPoolV2.CoverageType coverageType;
        string region;
        address poolOwner;
        uint256 minDeposit;
        uint256 maxDeposit;
        uint256 targetCapital;
        uint256 maxCapital;
        address productBuilder;
    }

    /// @notice Parameters for creating a mutual pool
    struct MutualPoolParams {
        string name;
        string symbol;
        RiskPoolV2.CoverageType coverageType;
        string region;
        address poolOwner;
        uint256 memberContribution;
        uint256 targetCapital;
        uint256 maxCapital;
    }

    // ============ Roles ============

    /// @notice Admin role for pool creation
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ============ Constants ============

    /// @notice Minimum deposit for public pools ($100)
    uint256 public constant PUBLIC_MIN_DEPOSIT = 100e6;

    /// @notice Maximum deposit for public pools ($100K)
    uint256 public constant PUBLIC_MAX_DEPOSIT = 100_000e6;

    /// @notice Minimum deposit for private pools ($250K)
    uint256 public constant PRIVATE_MIN_DEPOSIT = 250_000e6;

    /// @notice Maximum deposit for private pools ($10M)
    uint256 public constant PRIVATE_MAX_DEPOSIT = 10_000_000e6;

    /// @notice Minimum target capital for any pool ($100K)
    uint256 public constant MIN_TARGET_CAPITAL = 100_000e6;

    /// @notice Maximum pool capital ($50M)
    uint256 public constant MAX_POOL_CAPITAL = 50_000_000e6;

    // ============ Immutable State ============

    /// @notice USDC token address
    address public immutable USDC;

    /// @notice Treasury contract address
    address public immutable treasury;

    /// @notice Protocol treasury address (receives 10% of premiums)
    address public immutable protocolTreasury;

    // ============ State Variables ============

    /// @notice Counter for unique pool IDs
    uint256 public poolCounter;

    /// @notice Mapping from pool ID to pool address
    mapping(uint256 => address) public pools;

    /// @notice Mapping to verify if an address is a valid pool
    mapping(address => bool) public isPool;

    /// @notice Array of all pool addresses
    address[] public allPools;

    /// @notice Pools by type
    mapping(RiskPoolV2.PoolType => address[]) public poolsByType;

    /// @notice Pools by owner (for private pools)
    mapping(address => address[]) public poolsByOwner;

    /// @notice Default distributor for public pools
    address public defaultDistributor;

    // ============ Events ============

    /// @notice Emitted when a new pool is created
    event PoolCreated(
        uint256 indexed poolId,
        address indexed poolAddress,
        RiskPoolV2.PoolType poolType,
        string name,
        string symbol,
        address poolOwner
    );

    /// @notice Emitted when default distributor is updated
    event DefaultDistributorUpdated(address newDistributor);

    // ============ Errors ============

    error ZeroAddress();
    error EmptyName();
    error EmptySymbol();
    error EmptyRegion();
    error InvalidTargetCapital();
    error InvalidMaxCapital();
    error InvalidMinDeposit();
    error InvalidMaxDeposit();
    error PoolNotFound();

    // ============ Constructor ============

    /**
     * @notice Create a new RiskPoolFactoryV2
     * @param _usdc USDC token address
     * @param _treasury Treasury contract address
     * @param _protocolTreasury Protocol treasury address (receives protocol fees)
     */
    constructor(
        address _usdc,
        address _treasury,
        address _protocolTreasury
    ) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        USDC = _usdc;
        treasury = _treasury;
        protocolTreasury = _protocolTreasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ============ Public Pool Creation ============

    /**
     * @notice Create a public pool (open to anyone)
     * @param params Pool parameters
     * @return poolAddress Address of the new pool
     * @dev Public pools have:
     *      - $100 minimum deposit
     *      - $100K maximum deposit per investor
     *      - Deposits/withdrawals open by default
     *      - No pool owner (owned by protocol)
     */
    function createPublicPool(PublicPoolParams calldata params)
        external
        onlyRole(ADMIN_ROLE)
        returns (address poolAddress)
    {
        _validateBasicParams(params.name, params.symbol, params.region);
        _validateCapital(params.targetCapital, params.maxCapital);

        poolCounter++;
        uint256 newPoolId = poolCounter;

        RiskPoolV2.PoolConfig memory config = RiskPoolV2.PoolConfig({
            usdc: USDC,
            poolId: newPoolId,
            name: params.name,
            symbol: params.symbol,
            poolType: RiskPoolV2.PoolType.PUBLIC,
            coverageType: params.coverageType,
            region: params.region,
            poolOwner: address(0), // No owner for public pools
            minDeposit: PUBLIC_MIN_DEPOSIT,
            maxDeposit: PUBLIC_MAX_DEPOSIT,
            targetCapital: params.targetCapital,
            maxCapital: params.maxCapital,
            productBuilder: address(0), // No builder fee for public pools
            protocolTreasury: protocolTreasury,
            defaultDistributor: defaultDistributor
        });

        poolAddress = _deployPool(newPoolId, config);

        emit PoolCreated(
            newPoolId,
            poolAddress,
            RiskPoolV2.PoolType.PUBLIC,
            params.name,
            params.symbol,
            address(0)
        );
    }

    // ============ Private Pool Creation ============

    /**
     * @notice Create a private pool (institutions only)
     * @param params Pool parameters
     * @return poolAddress Address of the new pool
     * @dev Private pools have:
     *      - $250K+ minimum deposit (configurable)
     *      - Pool owner controls access
     *      - Product builder receives 12% of premiums
     *      - Deposits require DEPOSITOR_ROLE
     */
    function createPrivatePool(PrivatePoolParams calldata params)
        external
        onlyRole(ADMIN_ROLE)
        returns (address poolAddress)
    {
        _validateBasicParams(params.name, params.symbol, params.region);
        _validateCapital(params.targetCapital, params.maxCapital);
        if (params.poolOwner == address(0)) revert ZeroAddress();
        if (params.minDeposit < PRIVATE_MIN_DEPOSIT) revert InvalidMinDeposit();
        if (params.maxDeposit < params.minDeposit) revert InvalidMaxDeposit();
        if (params.maxDeposit > PRIVATE_MAX_DEPOSIT) revert InvalidMaxDeposit();

        poolCounter++;
        uint256 newPoolId = poolCounter;

        RiskPoolV2.PoolConfig memory config = RiskPoolV2.PoolConfig({
            usdc: USDC,
            poolId: newPoolId,
            name: params.name,
            symbol: params.symbol,
            poolType: RiskPoolV2.PoolType.PRIVATE,
            coverageType: params.coverageType,
            region: params.region,
            poolOwner: params.poolOwner,
            minDeposit: params.minDeposit,
            maxDeposit: params.maxDeposit,
            targetCapital: params.targetCapital,
            maxCapital: params.maxCapital,
            productBuilder: params.productBuilder != address(0) ? params.productBuilder : params.poolOwner,
            protocolTreasury: protocolTreasury,
            defaultDistributor: address(0) // Private pools don't use distributors
        });

        poolAddress = _deployPool(newPoolId, config);

        // Grant admin role to pool owner
        RiskPoolV2(poolAddress).grantRole(
            RiskPoolV2(poolAddress).ADMIN_ROLE(),
            params.poolOwner
        );

        // Add to owner's pools
        poolsByOwner[params.poolOwner].push(poolAddress);

        emit PoolCreated(
            newPoolId,
            poolAddress,
            RiskPoolV2.PoolType.PRIVATE,
            params.name,
            params.symbol,
            params.poolOwner
        );
    }

    // ============ Mutual Pool Creation ============

    /**
     * @notice Create a mutual pool (cooperative members only)
     * @param params Pool parameters
     * @return poolAddress Address of the new pool
     * @dev Mutual pools have:
     *      - Fixed member contribution (min/max same)
     *      - Pool owner controls member whitelist
     *      - Members are both insured AND LPs
     *      - No external product builder (cooperative is builder)
     */
    function createMutualPool(MutualPoolParams calldata params)
        external
        onlyRole(ADMIN_ROLE)
        returns (address poolAddress)
    {
        _validateBasicParams(params.name, params.symbol, params.region);
        _validateCapital(params.targetCapital, params.maxCapital);
        if (params.poolOwner == address(0)) revert ZeroAddress();
        if (params.memberContribution == 0) revert InvalidMinDeposit();

        poolCounter++;
        uint256 newPoolId = poolCounter;

        RiskPoolV2.PoolConfig memory config = RiskPoolV2.PoolConfig({
            usdc: USDC,
            poolId: newPoolId,
            name: params.name,
            symbol: params.symbol,
            poolType: RiskPoolV2.PoolType.MUTUAL,
            coverageType: params.coverageType,
            region: params.region,
            poolOwner: params.poolOwner,
            minDeposit: params.memberContribution,
            maxDeposit: params.memberContribution, // Fixed contribution
            targetCapital: params.targetCapital,
            maxCapital: params.maxCapital,
            productBuilder: params.poolOwner, // Cooperative receives builder fee
            protocolTreasury: protocolTreasury,
            defaultDistributor: params.poolOwner // Cooperative receives distributor fee
        });

        poolAddress = _deployPool(newPoolId, config);

        // Grant admin role to cooperative
        RiskPoolV2(poolAddress).grantRole(
            RiskPoolV2(poolAddress).ADMIN_ROLE(),
            params.poolOwner
        );

        // Add to owner's pools
        poolsByOwner[params.poolOwner].push(poolAddress);

        emit PoolCreated(
            newPoolId,
            poolAddress,
            RiskPoolV2.PoolType.MUTUAL,
            params.name,
            params.symbol,
            params.poolOwner
        );
    }

    // ============ Internal Functions ============

    function _validateBasicParams(
        string memory name,
        string memory symbol,
        string memory region
    ) internal pure {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (bytes(region).length == 0) revert EmptyRegion();
    }

    function _validateCapital(uint256 target, uint256 max) internal pure {
        if (target < MIN_TARGET_CAPITAL) revert InvalidTargetCapital();
        if (max > MAX_POOL_CAPITAL) revert InvalidMaxCapital();
        if (target > max) revert InvalidTargetCapital();
    }

    function _deployPool(
        uint256 poolId,
        RiskPoolV2.PoolConfig memory config
    ) internal returns (address poolAddress) {
        // Deploy new RiskPoolV2
        RiskPoolV2 pool = new RiskPoolV2(config);
        poolAddress = address(pool);

        // Grant TREASURY_ROLE to treasury contract
        pool.grantRole(pool.TREASURY_ROLE(), treasury);

        // Grant DEFAULT_ADMIN_ROLE to factory admin (allows pool management)
        pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), msg.sender);

        // Store in registry
        pools[poolId] = poolAddress;
        isPool[poolAddress] = true;
        allPools.push(poolAddress);
        poolsByType[config.poolType].push(poolAddress);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set default distributor for public pools
     * @param newDistributor New distributor address
     */
    function setDefaultDistributor(address newDistributor) external onlyRole(ADMIN_ROLE) {
        defaultDistributor = newDistributor;
        emit DefaultDistributorUpdated(newDistributor);
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
     * @notice Get pools by type
     * @param poolType Type of pools to query
     * @return Array of pool addresses
     */
    function getPoolsByType(RiskPoolV2.PoolType poolType)
        external
        view
        returns (address[] memory)
    {
        return poolsByType[poolType];
    }

    /**
     * @notice Get pools by owner
     * @param owner Owner address
     * @return Array of pool addresses
     */
    function getPoolsByOwner(address owner)
        external
        view
        returns (address[] memory)
    {
        return poolsByOwner[owner];
    }

    /**
     * @notice Get public pools only
     * @return Array of public pool addresses
     */
    function getPublicPools() external view returns (address[] memory) {
        return poolsByType[RiskPoolV2.PoolType.PUBLIC];
    }

    /**
     * @notice Get private pools only
     * @return Array of private pool addresses
     */
    function getPrivatePools() external view returns (address[] memory) {
        return poolsByType[RiskPoolV2.PoolType.PRIVATE];
    }

    /**
     * @notice Get mutual pools only
     * @return Array of mutual pool addresses
     */
    function getMutualPools() external view returns (address[] memory) {
        return poolsByType[RiskPoolV2.PoolType.MUTUAL];
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

        RiskPoolV2 pool = RiskPoolV2(poolAddress);

        metadata = PoolMetadata({
            poolAddress: poolAddress,
            poolId: poolId,
            name: pool.poolName(),
            poolType: pool.poolType(),
            coverageType: pool.coverageType(),
            region: pool.region(),
            poolOwner: pool.poolOwner(),
            createdAt: block.timestamp
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
     * @notice Get count of pools by type
     * @return publicCount Number of public pools
     * @return privateCount Number of private pools
     * @return mutualCount Number of mutual pools
     */
    function getPoolCountsByType()
        external
        view
        returns (
            uint256 publicCount,
            uint256 privateCount,
            uint256 mutualCount
        )
    {
        publicCount = poolsByType[RiskPoolV2.PoolType.PUBLIC].length;
        privateCount = poolsByType[RiskPoolV2.PoolType.PRIVATE].length;
        mutualCount = poolsByType[RiskPoolV2.PoolType.MUTUAL].length;
    }
}
