// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RiskPool} from "./RiskPool.sol";

/**
 * @title RiskPoolFactory
 * @author MicroCrop Protocol
 * @notice Upgradeable factory for creating RiskPoolV2 instances with different pool types
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
 * Upgradeability:
 *   - Uses UUPS proxy pattern
 *   - Only UPGRADER_ROLE can authorize upgrades
 *   - Deploys pool instances as ERC1967 proxies
 */
contract RiskPoolFactory is
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
        RiskPool.PoolType poolType;
        RiskPool.CoverageType coverageType;
        string region;
        address poolOwner;
        uint256 createdAt;
    }

    /// @notice Parameters for creating a public pool
    struct PublicPoolParams {
        string name;
        string symbol;
        RiskPool.CoverageType coverageType;
        string region;
        uint256 targetCapital;
        uint256 maxCapital;
    }

    /// @notice Parameters for creating a private pool
    struct PrivatePoolParams {
        string name;
        string symbol;
        RiskPool.CoverageType coverageType;
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
        RiskPool.CoverageType coverageType;
        string region;
        address poolOwner;
        uint256 memberContribution;
        uint256 targetCapital;
        uint256 maxCapital;
    }

    // ============ Roles ============

    /// @notice Admin role for pool creation
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Upgrader role for UUPS upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

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

    // ============ Storage ============

    /// @notice USDC token address
    address public usdc;

    /// @notice Treasury contract address
    address public treasury;

    /// @notice Protocol treasury address (receives 10% of premiums)
    address public protocolTreasury;

    /// @notice RiskPool implementation address
    address public poolImplementation;

    /// @notice Counter for unique pool IDs
    uint256 public poolCounter;

    /// @notice Mapping from pool ID to pool address
    mapping(uint256 => address) public pools;

    /// @notice Mapping to verify if an address is a valid pool
    mapping(address => bool) public isPool;

    /// @notice Array of all pool addresses
    address[] public allPools;

    /// @notice Pools by type
    mapping(RiskPool.PoolType => address[]) public poolsByType;

    /// @notice Pools by owner (for private pools)
    mapping(address => address[]) public poolsByOwner;

    /// @notice Default distributor for public pools
    address public defaultDistributor;

    /// @notice Storage gap for future upgrades
    uint256[40] private __gap;

    // ============ Events ============

    /// @notice Emitted when a new pool is created
    event PoolCreated(
        uint256 indexed poolId,
        address indexed poolAddress,
        RiskPool.PoolType poolType,
        string name,
        string symbol,
        address poolOwner
    );

    /// @notice Emitted when default distributor is updated
    event DefaultDistributorUpdated(address newDistributor);

    /// @notice Emitted when pool implementation is updated
    event PoolImplementationUpdated(address newImplementation);

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the factory
     * @param _usdc USDC token address
     * @param _treasury Treasury contract address
     * @param _protocolTreasury Protocol treasury address
     * @param _poolImplementation RiskPool implementation address
     */
    function initialize(
        address _usdc,
        address _treasury,
        address _protocolTreasury,
        address _poolImplementation
    ) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();
        if (_poolImplementation == address(0)) revert ZeroAddress();

        __AccessControl_init();

        usdc = _usdc;
        treasury = _treasury;
        protocolTreasury = _protocolTreasury;
        poolImplementation = _poolImplementation;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
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

    // ============ Public Pool Creation ============

    /**
     * @notice Create a public pool (open to anyone)
     * @param params Pool parameters
     * @return poolAddress Address of the new pool proxy
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

        RiskPool.PoolConfig memory config = RiskPool.PoolConfig({
            usdc: usdc,
            poolId: newPoolId,
            name: params.name,
            symbol: params.symbol,
            poolType: RiskPool.PoolType.PUBLIC,
            coverageType: params.coverageType,
            region: params.region,
            poolOwner: address(0),
            minDeposit: PUBLIC_MIN_DEPOSIT,
            maxDeposit: PUBLIC_MAX_DEPOSIT,
            targetCapital: params.targetCapital,
            maxCapital: params.maxCapital,
            productBuilder: address(0),
            protocolTreasury: protocolTreasury,
            defaultDistributor: defaultDistributor
        });

        poolAddress = _deployPool(newPoolId, config);

        emit PoolCreated(
            newPoolId,
            poolAddress,
            RiskPool.PoolType.PUBLIC,
            params.name,
            params.symbol,
            address(0)
        );
    }

    // ============ Private Pool Creation ============

    /**
     * @notice Create a private pool (institutions only)
     * @param params Pool parameters
     * @return poolAddress Address of the new pool proxy
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

        RiskPool.PoolConfig memory config = RiskPool.PoolConfig({
            usdc: usdc,
            poolId: newPoolId,
            name: params.name,
            symbol: params.symbol,
            poolType: RiskPool.PoolType.PRIVATE,
            coverageType: params.coverageType,
            region: params.region,
            poolOwner: params.poolOwner,
            minDeposit: params.minDeposit,
            maxDeposit: params.maxDeposit,
            targetCapital: params.targetCapital,
            maxCapital: params.maxCapital,
            productBuilder: params.productBuilder != address(0) ? params.productBuilder : params.poolOwner,
            protocolTreasury: protocolTreasury,
            defaultDistributor: address(0)
        });

        poolAddress = _deployPool(newPoolId, config);

        // Grant admin role to pool owner
        RiskPool(poolAddress).grantRole(
            RiskPool(poolAddress).ADMIN_ROLE(),
            params.poolOwner
        );

        // Add to owner's pools
        poolsByOwner[params.poolOwner].push(poolAddress);

        emit PoolCreated(
            newPoolId,
            poolAddress,
            RiskPool.PoolType.PRIVATE,
            params.name,
            params.symbol,
            params.poolOwner
        );
    }

    // ============ Mutual Pool Creation ============

    /**
     * @notice Create a mutual pool (cooperative members only)
     * @param params Pool parameters
     * @return poolAddress Address of the new pool proxy
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

        RiskPool.PoolConfig memory config = RiskPool.PoolConfig({
            usdc: usdc,
            poolId: newPoolId,
            name: params.name,
            symbol: params.symbol,
            poolType: RiskPool.PoolType.MUTUAL,
            coverageType: params.coverageType,
            region: params.region,
            poolOwner: params.poolOwner,
            minDeposit: params.memberContribution,
            maxDeposit: params.memberContribution,
            targetCapital: params.targetCapital,
            maxCapital: params.maxCapital,
            productBuilder: params.poolOwner,
            protocolTreasury: protocolTreasury,
            defaultDistributor: params.poolOwner
        });

        poolAddress = _deployPool(newPoolId, config);

        // Grant admin role to cooperative
        RiskPool(poolAddress).grantRole(
            RiskPool(poolAddress).ADMIN_ROLE(),
            params.poolOwner
        );

        // Add to owner's pools
        poolsByOwner[params.poolOwner].push(poolAddress);

        emit PoolCreated(
            newPoolId,
            poolAddress,
            RiskPool.PoolType.MUTUAL,
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
        RiskPool.PoolConfig memory config
    ) internal returns (address poolAddress) {
        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            RiskPool.initialize.selector,
            config
        );

        // Deploy ERC1967 proxy pointing to pool implementation
        ERC1967Proxy proxy = new ERC1967Proxy(
            poolImplementation,
            initData
        );

        poolAddress = address(proxy);

        // Grant TREASURY_ROLE to treasury contract
        RiskPool(poolAddress).grantRole(
            RiskPool(poolAddress).TREASURY_ROLE(),
            treasury
        );

        // Grant DEFAULT_ADMIN_ROLE to factory admin
        RiskPool(poolAddress).grantRole(
            RiskPool(poolAddress).DEFAULT_ADMIN_ROLE(),
            msg.sender
        );

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

    /**
     * @notice Update pool implementation for new pools
     * @param newImplementation New implementation address
     */
    function setPoolImplementation(address newImplementation) external onlyRole(ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        poolImplementation = newImplementation;
        emit PoolImplementationUpdated(newImplementation);
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
     * @param _poolType Type of pools to query
     * @return Array of pool addresses
     */
    function getPoolsByType(RiskPool.PoolType _poolType)
        external
        view
        returns (address[] memory)
    {
        return poolsByType[_poolType];
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
        return poolsByType[RiskPool.PoolType.PUBLIC];
    }

    /**
     * @notice Get private pools only
     * @return Array of private pool addresses
     */
    function getPrivatePools() external view returns (address[] memory) {
        return poolsByType[RiskPool.PoolType.PRIVATE];
    }

    /**
     * @notice Get mutual pools only
     * @return Array of mutual pool addresses
     */
    function getMutualPools() external view returns (address[] memory) {
        return poolsByType[RiskPool.PoolType.MUTUAL];
    }

    /**
     * @notice Get metadata for a specific pool
     * @param _poolId Pool ID to query
     * @return metadata Pool metadata struct
     */
    function getPoolMetadata(uint256 _poolId)
        external
        view
        returns (PoolMetadata memory metadata)
    {
        address poolAddress = pools[_poolId];
        if (poolAddress == address(0)) revert PoolNotFound();

        RiskPool pool = RiskPool(poolAddress);

        metadata = PoolMetadata({
            poolAddress: poolAddress,
            poolId: _poolId,
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
     * @param _poolId Pool ID
     * @return Pool address
     */
    function getPoolById(uint256 _poolId) external view returns (address) {
        return pools[_poolId];
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
        publicCount = poolsByType[RiskPool.PoolType.PUBLIC].length;
        privateCount = poolsByType[RiskPool.PoolType.PRIVATE].length;
        mutualCount = poolsByType[RiskPool.PoolType.MUTUAL].length;
    }
}
