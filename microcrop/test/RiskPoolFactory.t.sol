// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RiskPoolFactory} from "../src/RiskPoolFactory.sol";
import {RiskPool} from "../src/RiskPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockUSDC
 * @dev Simple mock USDC for testing
 */
contract MockUSDC is IERC20 {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/**
 * @title RiskPoolFactoryTest
 * @dev Tests for the upgradeable factory contract
 */
contract RiskPoolFactoryTest is Test {
    RiskPoolFactory public factoryImplementation;
    RiskPoolFactory public factory;
    RiskPool public poolImplementation;
    MockUSDC public usdc;

    address public admin = address(this);
    address public treasury = address(0x2);
    address public protocolTreasury = address(0x3);
    address public defaultDistributor = address(0x4);
    address public investor1 = address(0x5);
    address public institutionalInvestor = address(0x6);
    address public productBuilder = address(0x7);

    uint256 public constant INITIAL_BALANCE = 10_000_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy implementations
        factoryImplementation = new RiskPoolFactory();
        poolImplementation = new RiskPool();

        // Deploy factory proxy
        bytes memory initData = abi.encodeWithSelector(
            RiskPoolFactory.initialize.selector,
            address(usdc),
            treasury,
            protocolTreasury,
            address(poolImplementation)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImplementation), initData);
        factory = RiskPoolFactory(address(proxy));

        // Set default distributor
        factory.setDefaultDistributor(defaultDistributor);

        // Mint USDC
        usdc.mint(investor1, INITIAL_BALANCE);
        usdc.mint(institutionalInvestor, INITIAL_BALANCE);
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(factory.usdc(), address(usdc));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.protocolTreasury(), protocolTreasury);
        assertEq(factory.poolImplementation(), address(poolImplementation));
        assertEq(factory.defaultDistributor(), defaultDistributor);
    }

    function test_Initialize_GrantsRoles() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(factory.hasRole(factory.ADMIN_ROLE(), address(this)));
        assertTrue(factory.hasRole(factory.UPGRADER_ROLE(), address(this)));
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        factory.initialize(
            address(usdc),
            treasury,
            protocolTreasury,
            address(poolImplementation)
        );
    }

    // ============ Create Public Pool Tests ============

    function test_CreatePublicPool() public {
        RiskPoolFactory.PublicPoolParams memory params = RiskPoolFactory.PublicPoolParams({
            name: "Kenya Maize Pool",
            symbol: "mcMAIZE",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        });

        address poolAddress = factory.createPublicPool(params);

        assertTrue(poolAddress != address(0));
        assertTrue(factory.isPool(poolAddress));
        assertEq(factory.poolCounter(), 1);

        // Verify pool configuration
        RiskPool pool = RiskPool(poolAddress);
        assertEq(pool.name(), "Kenya Maize Pool");
        assertEq(pool.symbol(), "mcMAIZE");
        assertEq(uint256(pool.poolType()), uint256(RiskPool.PoolType.PUBLIC));
        assertEq(pool.minDeposit(), factory.PUBLIC_MIN_DEPOSIT());
    }

    function test_CreatePublicPool_EmitsEvent() public {
        RiskPoolFactory.PublicPoolParams memory params = RiskPoolFactory.PublicPoolParams({
            name: "Kenya Maize Pool",
            symbol: "mcMAIZE",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        });

        vm.expectEmit(true, false, false, true);
        emit RiskPoolFactory.PoolCreated(
            1,
            address(0), // We don't know the address yet
            RiskPool.PoolType.PUBLIC,
            "Kenya Maize Pool",
            "mcMAIZE",
            address(0)
        );
        factory.createPublicPool(params);
    }

    function test_CreatePublicPool_InvalidTargetCapital_Reverts() public {
        RiskPoolFactory.PublicPoolParams memory params = RiskPoolFactory.PublicPoolParams({
            name: "Kenya Maize Pool",
            symbol: "mcMAIZE",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 10_000e6, // Below minimum
            maxCapital: 2_000_000e6
        });

        vm.expectRevert(RiskPoolFactory.InvalidTargetCapital.selector);
        factory.createPublicPool(params);
    }

    // ============ Create Private Pool Tests ============

    function test_CreatePrivatePool() public {
        RiskPoolFactory.PrivatePoolParams memory params = RiskPoolFactory.PrivatePoolParams({
            name: "UAP Institutional Pool",
            symbol: "uapKENYA",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "East Africa",
            poolOwner: institutionalInvestor,
            minDeposit: 500_000e6,
            maxDeposit: 5_000_000e6,
            targetCapital: 5_000_000e6,
            maxCapital: 20_000_000e6,
            productBuilder: productBuilder
        });

        address poolAddress = factory.createPrivatePool(params);

        assertTrue(poolAddress != address(0));
        assertTrue(factory.isPool(poolAddress));

        // Verify pool configuration
        RiskPool pool = RiskPool(poolAddress);
        assertEq(uint256(pool.poolType()), uint256(RiskPool.PoolType.PRIVATE));
        assertEq(pool.minDeposit(), 500_000e6);
        assertEq(pool.poolOwner(), institutionalInvestor);
    }

    function test_CreatePrivatePool_InvalidMinDeposit_Reverts() public {
        RiskPoolFactory.PrivatePoolParams memory params = RiskPoolFactory.PrivatePoolParams({
            name: "UAP Institutional Pool",
            symbol: "uapKENYA",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "East Africa",
            poolOwner: institutionalInvestor,
            minDeposit: 10_000e6, // Below private minimum
            maxDeposit: 5_000_000e6,
            targetCapital: 5_000_000e6,
            maxCapital: 20_000_000e6,
            productBuilder: productBuilder
        });

        vm.expectRevert(RiskPoolFactory.InvalidMinDeposit.selector);
        factory.createPrivatePool(params);
    }

    // ============ Create Mutual Pool Tests ============

    function test_CreateMutualPool() public {
        RiskPoolFactory.MutualPoolParams memory params = RiskPoolFactory.MutualPoolParams({
            name: "KFA Cooperative Pool",
            symbol: "kfaCOOP",
            coverageType: RiskPool.CoverageType.FLOOD,
            region: "Western Kenya",
            poolOwner: treasury,
            memberContribution: 1_000e6,
            targetCapital: 200_000e6,
            maxCapital: 1_000_000e6
        });

        address poolAddress = factory.createMutualPool(params);

        assertTrue(poolAddress != address(0));
        assertTrue(factory.isPool(poolAddress));

        // Verify pool configuration
        RiskPool pool = RiskPool(poolAddress);
        assertEq(uint256(pool.poolType()), uint256(RiskPool.PoolType.MUTUAL));
    }

    // ============ Pool Tracking Tests ============

    function test_GetPoolsByType() public {
        // Create one of each type
        factory.createPublicPool(RiskPoolFactory.PublicPoolParams({
            name: "Public Pool",
            symbol: "PUB",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        }));

        factory.createPrivatePool(RiskPoolFactory.PrivatePoolParams({
            name: "Private Pool",
            symbol: "PRIV",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "East Africa",
            poolOwner: institutionalInvestor,
            minDeposit: 500_000e6,
            maxDeposit: 5_000_000e6,
            targetCapital: 5_000_000e6,
            maxCapital: 20_000_000e6,
            productBuilder: productBuilder
        }));

        factory.createMutualPool(RiskPoolFactory.MutualPoolParams({
            name: "Mutual Pool",
            symbol: "MUT",
            coverageType: RiskPool.CoverageType.FLOOD,
            region: "West Kenya",
            poolOwner: treasury,
            memberContribution: 1_000e6,
            targetCapital: 200_000e6,
            maxCapital: 1_000_000e6
        }));

        address[] memory publicPools = factory.getPoolsByType(RiskPool.PoolType.PUBLIC);
        address[] memory privatePools = factory.getPoolsByType(RiskPool.PoolType.PRIVATE);
        address[] memory mutualPools = factory.getPoolsByType(RiskPool.PoolType.MUTUAL);

        assertEq(publicPools.length, 1);
        assertEq(privatePools.length, 1);
        assertEq(mutualPools.length, 1);
    }

    function test_GetPoolsByOwner() public {
        // Create multiple pools for same owner
        factory.createPrivatePool(RiskPoolFactory.PrivatePoolParams({
            name: "Pool 1",
            symbol: "P1",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "East Africa",
            poolOwner: institutionalInvestor,
            minDeposit: 500_000e6,
            maxDeposit: 5_000_000e6,
            targetCapital: 5_000_000e6,
            maxCapital: 20_000_000e6,
            productBuilder: productBuilder
        }));

        factory.createPrivatePool(RiskPoolFactory.PrivatePoolParams({
            name: "Pool 2",
            symbol: "P2",
            coverageType: RiskPool.CoverageType.FLOOD,
            region: "West Africa",
            poolOwner: institutionalInvestor,
            minDeposit: 500_000e6,
            maxDeposit: 5_000_000e6,
            targetCapital: 5_000_000e6,
            maxCapital: 20_000_000e6,
            productBuilder: productBuilder
        }));

        address[] memory ownerPools = factory.getPoolsByOwner(institutionalInvestor);
        assertEq(ownerPools.length, 2);
    }

    function test_GetAllPools() public {
        // Create multiple pools
        factory.createPublicPool(RiskPoolFactory.PublicPoolParams({
            name: "Pool 1",
            symbol: "P1",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        }));

        factory.createPublicPool(RiskPoolFactory.PublicPoolParams({
            name: "Pool 2",
            symbol: "P2",
            coverageType: RiskPool.CoverageType.FLOOD,
            region: "Tanzania",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        }));

        address[] memory allPoolsList = factory.getAllPools();
        assertEq(allPoolsList.length, 2);
    }

    function test_GetPoolMetadata() public {
        factory.createPublicPool(RiskPoolFactory.PublicPoolParams({
            name: "Kenya Maize Pool",
            symbol: "mcMAIZE",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        }));

        RiskPoolFactory.PoolMetadata memory metadata = factory.getPoolMetadata(1);

        assertEq(metadata.poolId, 1);
        assertEq(metadata.name, "Kenya Maize Pool");
        assertEq(metadata.region, "Kenya");
        assertEq(uint256(metadata.poolType), uint256(RiskPool.PoolType.PUBLIC));
    }

    function test_GetPoolMetadata_NotFound_Reverts() public {
        vm.expectRevert(RiskPoolFactory.PoolNotFound.selector);
        factory.getPoolMetadata(999);
    }

    // ============ Access Control Tests ============

    function test_OnlyAdmin_CanCreatePool() public {
        RiskPoolFactory.PublicPoolParams memory params = RiskPoolFactory.PublicPoolParams({
            name: "Test Pool",
            symbol: "TEST",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        });

        vm.prank(investor1);
        vm.expectRevert();
        factory.createPublicPool(params);
    }

    function test_SetDefaultDistributor() public {
        address newDistributor = address(0x123);
        factory.setDefaultDistributor(newDistributor);
        assertEq(factory.defaultDistributor(), newDistributor);
    }

    function test_SetPoolImplementation() public {
        RiskPool newImpl = new RiskPool();
        factory.setPoolImplementation(address(newImpl));
        assertEq(factory.poolImplementation(), address(newImpl));
    }

    // ============ Upgrade Tests ============

    function test_Upgrade_OnlyUpgrader() public {
        RiskPoolFactory newImpl = new RiskPoolFactory();

        vm.prank(investor1);
        vm.expectRevert();
        factory.upgradeToAndCall(address(newImpl), "");

        // Admin can upgrade
        factory.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_PreservesState() public {
        // Create a pool
        factory.createPublicPool(RiskPoolFactory.PublicPoolParams({
            name: "Test Pool",
            symbol: "TEST",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        }));

        uint256 poolCountBefore = factory.poolCounter();

        // Upgrade
        RiskPoolFactory newImpl = new RiskPoolFactory();
        factory.upgradeToAndCall(address(newImpl), "");

        // State preserved
        assertEq(factory.poolCounter(), poolCountBefore);
        assertEq(factory.usdc(), address(usdc));
    }

    // ============ Pool Deposits Work ============

    function test_CreatedPool_AcceptsDeposits() public {
        address poolAddress = factory.createPublicPool(RiskPoolFactory.PublicPoolParams({
            name: "Kenya Maize Pool",
            symbol: "mcMAIZE",
            coverageType: RiskPool.CoverageType.DROUGHT,
            region: "Kenya",
            targetCapital: 500_000e6,
            maxCapital: 2_000_000e6
        }));

        RiskPool pool = RiskPool(poolAddress);
        uint256 depositAmount = 1_000e6;

        vm.startPrank(investor1);
        usdc.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, 0);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), depositAmount);
    }
}
