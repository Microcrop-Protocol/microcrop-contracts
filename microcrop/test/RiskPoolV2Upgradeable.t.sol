// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RiskPoolV2Upgradeable} from "../src/RiskPoolV2Upgradeable.sol";
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
 * @title RiskPoolV2UpgradeableTest
 * @dev Tests for the upgradeable version of RiskPoolV2
 */
contract RiskPoolV2UpgradeableTest is Test {
    RiskPoolV2Upgradeable public implementation;
    RiskPoolV2Upgradeable public pool;
    MockUSDC public usdc;

    address public admin = address(this); // Deployer is admin
    address public poolOwner = address(0x2);
    address public protocolTreasury = address(0x3);
    address public productBuilder = address(0x4);
    address public defaultDistributor = address(0x5);
    address public investor1 = address(0x6);
    address public investor2 = address(0x7);

    uint256 public constant INITIAL_BALANCE = 10_000_000e6; // 10M USDC
    uint256 public constant PUBLIC_MIN_DEPOSIT = 100e6; // 100 USDC
    uint256 public constant PRIVATE_MIN_DEPOSIT = 250_000e6; // 250k USDC

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy implementation
        implementation = new RiskPoolV2Upgradeable();

        // Mint USDC to test accounts
        usdc.mint(investor1, INITIAL_BALANCE);
        usdc.mint(investor2, INITIAL_BALANCE);
    }

    function _createPublicConfig() internal view returns (RiskPoolV2Upgradeable.PoolConfig memory) {
        return RiskPoolV2Upgradeable.PoolConfig({
            usdc: address(usdc),
            poolId: 1,
            name: "Public Pool",
            symbol: "PP",
            poolType: RiskPoolV2Upgradeable.PoolType.PUBLIC,
            coverageType: RiskPoolV2Upgradeable.CoverageType.DROUGHT,
            region: "East Africa",
            poolOwner: poolOwner,
            minDeposit: PUBLIC_MIN_DEPOSIT,
            maxDeposit: 1_000_000e6,
            targetCapital: 1_000_000e6,
            maxCapital: 10_000_000e6,
            productBuilder: productBuilder,
            protocolTreasury: protocolTreasury,
            defaultDistributor: defaultDistributor
        });
    }

    function _createPrivateConfig() internal view returns (RiskPoolV2Upgradeable.PoolConfig memory) {
        return RiskPoolV2Upgradeable.PoolConfig({
            usdc: address(usdc),
            poolId: 2,
            name: "Private Pool",
            symbol: "PVP",
            poolType: RiskPoolV2Upgradeable.PoolType.PRIVATE,
            coverageType: RiskPoolV2Upgradeable.CoverageType.DROUGHT,
            region: "East Africa",
            poolOwner: poolOwner,
            minDeposit: PRIVATE_MIN_DEPOSIT,
            maxDeposit: 10_000_000e6,
            targetCapital: 5_000_000e6,
            maxCapital: 50_000_000e6,
            productBuilder: productBuilder,
            protocolTreasury: protocolTreasury,
            defaultDistributor: defaultDistributor
        });
    }

    function _createMutualConfig() internal view returns (RiskPoolV2Upgradeable.PoolConfig memory) {
        return RiskPoolV2Upgradeable.PoolConfig({
            usdc: address(usdc),
            poolId: 3,
            name: "Mutual Pool",
            symbol: "MP",
            poolType: RiskPoolV2Upgradeable.PoolType.MUTUAL,
            coverageType: RiskPoolV2Upgradeable.CoverageType.FLOOD,
            region: "West Africa",
            poolOwner: poolOwner,
            minDeposit: 500e6,
            maxDeposit: 10_000e6,
            targetCapital: 100_000e6,
            maxCapital: 500_000e6,
            productBuilder: productBuilder,
            protocolTreasury: protocolTreasury,
            defaultDistributor: defaultDistributor
        });
    }

    function _deployPublicPool() internal returns (RiskPoolV2Upgradeable) {
        RiskPoolV2Upgradeable.PoolConfig memory config = _createPublicConfig();
        bytes memory initData = abi.encodeWithSelector(
            RiskPoolV2Upgradeable.initialize.selector,
            config
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return RiskPoolV2Upgradeable(address(proxy));
    }

    function _deployPrivatePool() internal returns (RiskPoolV2Upgradeable) {
        RiskPoolV2Upgradeable.PoolConfig memory config = _createPrivateConfig();
        bytes memory initData = abi.encodeWithSelector(
            RiskPoolV2Upgradeable.initialize.selector,
            config
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return RiskPoolV2Upgradeable(address(proxy));
    }

    function _deployMutualPool() internal returns (RiskPoolV2Upgradeable) {
        RiskPoolV2Upgradeable.PoolConfig memory config = _createMutualConfig();
        bytes memory initData = abi.encodeWithSelector(
            RiskPoolV2Upgradeable.initialize.selector,
            config
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return RiskPoolV2Upgradeable(address(proxy));
    }

    // ============ Initialization Tests ============

    function test_Initialize_PublicPool() public {
        pool = _deployPublicPool();

        assertEq(pool.name(), "Public Pool");
        assertEq(pool.symbol(), "PP");
        assertEq(address(pool.usdc()), address(usdc));
        assertEq(uint256(pool.poolType()), uint256(RiskPoolV2Upgradeable.PoolType.PUBLIC));
        assertEq(pool.minDeposit(), PUBLIC_MIN_DEPOSIT);
        assertTrue(pool.depositsOpen());
        assertTrue(pool.withdrawalsOpen());
    }

    function test_Initialize_PrivatePool() public {
        pool = _deployPrivatePool();

        assertEq(pool.name(), "Private Pool");
        assertEq(pool.symbol(), "PVP");
        assertEq(uint256(pool.poolType()), uint256(RiskPoolV2Upgradeable.PoolType.PRIVATE));
        assertEq(pool.minDeposit(), PRIVATE_MIN_DEPOSIT);
        // Private pools start with deposits closed
        assertFalse(pool.depositsOpen());
    }

    function test_Initialize_MutualPool() public {
        pool = _deployMutualPool();

        assertEq(pool.name(), "Mutual Pool");
        assertEq(pool.symbol(), "MP");
        assertEq(uint256(pool.poolType()), uint256(RiskPoolV2Upgradeable.PoolType.MUTUAL));
    }

    function test_Initialize_GrantsRoles() public {
        pool = _deployPublicPool();

        // Deployer (this contract) gets admin roles
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(pool.hasRole(pool.ADMIN_ROLE(), address(this)));
        assertTrue(pool.hasRole(pool.UPGRADER_ROLE(), address(this)));
    }

    function test_Initialize_CannotReinitialize() public {
        pool = _deployPublicPool();
        RiskPoolV2Upgradeable.PoolConfig memory config = _createPublicConfig();

        vm.expectRevert();
        pool.initialize(config);
    }

    // ============ Deposit Tests ============

    function test_Deposit_PublicPool_Success() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 1_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), depositAmount);
        assertEq(usdc.balanceOf(address(pool)), depositAmount);
    }

    function test_Deposit_PublicPool_BelowMinimum_Reverts() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 50e6; // Below 100 USDC minimum

        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        vm.expectRevert(RiskPoolV2Upgradeable.BelowMinimumDeposit.selector);
        pool.deposit(depositAmount);
        vm.stopPrank();
    }

    function test_Deposit_PrivatePool_RequiresDepositorRole() public {
        pool = _deployPrivatePool();
        uint256 depositAmount = PRIVATE_MIN_DEPOSIT;

        // Admin needs to open deposits first
        pool.setDepositsOpen(true);

        // Attempt deposit without role
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        vm.expectRevert(RiskPoolV2Upgradeable.NotAuthorized.selector);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // Grant role and deposit
        pool.addDepositor(investor1);

        vm.startPrank(investor1);
        pool.deposit(depositAmount);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), depositAmount);
    }

    function test_Deposit_WhenDepositsNotOpen_Reverts() public {
        pool = _deployPublicPool();

        pool.setDepositsOpen(false);

        vm.startPrank(investor1);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(RiskPoolV2Upgradeable.DepositsNotOpen.selector);
        pool.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_Deposit_WhenPaused_Reverts() public {
        pool = _deployPublicPool();

        pool.pause();

        vm.startPrank(investor1);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert();
        pool.deposit(1_000e6);
        vm.stopPrank();
    }

    // ============ Withdraw Tests ============

    function test_Withdraw_Success() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 1_000e6;

        // Deposit first
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);

        // Withdraw
        uint256 withdrawAmount = 500e6;
        pool.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(investor1), INITIAL_BALANCE - depositAmount + withdrawAmount);
    }

    function test_Withdraw_InsufficientBalance_Reverts() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 1_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);

        vm.expectRevert(RiskPoolV2Upgradeable.InsufficientTokens.selector);
        pool.withdraw(depositAmount + 1);
        vm.stopPrank();
    }

    function test_Withdraw_WhenWithdrawalsNotOpen_Reverts() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 1_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        pool.setWithdrawalsOpen(false);

        vm.startPrank(investor1);
        vm.expectRevert(RiskPoolV2Upgradeable.WithdrawalsNotOpen.selector);
        pool.withdraw(500e6);
        vm.stopPrank();
    }

    // ============ Premium & Payout Tests ============

    function test_CollectPremium_DistributesRevenue() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 10_000e6;
        uint256 premiumAmount = 1_000e6;

        // Grant TREASURY_ROLE to protocolTreasury
        pool.grantRole(pool.TREASURY_ROLE(), protocolTreasury);

        // Deposit first
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // Treasury needs to have the premium and approve the pool
        usdc.mint(protocolTreasury, premiumAmount);
        vm.startPrank(protocolTreasury);
        usdc.approve(address(pool), premiumAmount);
        pool.collectPremium(1, premiumAmount, defaultDistributor);
        vm.stopPrank();

        // Check distributions (70% LP, 12% builder, 10% protocol, 8% distributor)
        uint256 builderShare = (premiumAmount * 12) / 100; // 120
        uint256 protocolShare = (premiumAmount * 10) / 100; // 100
        uint256 distributorShare = (premiumAmount * 8) / 100; // 80
        uint256 lpShare = (premiumAmount * 70) / 100; // 700

        assertEq(usdc.balanceOf(productBuilder), builderShare);
        assertEq(usdc.balanceOf(protocolTreasury), protocolShare);
        assertEq(usdc.balanceOf(defaultDistributor), distributorShare);
        // Pool retains LP share
        assertEq(usdc.balanceOf(address(pool)), depositAmount + lpShare);
    }

    function test_ProcessPayout_Success() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 10_000e6;
        uint256 payoutAmount = 1_000e6;

        // Grant TREASURY_ROLE
        pool.grantRole(pool.TREASURY_ROLE(), protocolTreasury);

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // Process payout (sends to msg.sender which is treasury)
        vm.prank(protocolTreasury);
        pool.processPayout(1, payoutAmount);

        // Treasury receives the payout
        assertEq(usdc.balanceOf(protocolTreasury), payoutAmount);
        assertEq(usdc.balanceOf(address(pool)), depositAmount - payoutAmount);
    }

    // ============ Token Price (NAV) Tests ============

    function test_TokenPrice_InitiallyOne() public {
        pool = _deployPublicPool();
        assertEq(pool.getTokenPrice(), 1e18);
    }

    function test_TokenPrice_IncreasesWithPremiums() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 10_000e6;
        uint256 premiumAmount = 1_000e6;

        // Grant TREASURY_ROLE
        pool.grantRole(pool.TREASURY_ROLE(), protocolTreasury);

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        uint256 priceBefore = pool.getTokenPrice();

        // Treasury collects premium
        usdc.mint(protocolTreasury, premiumAmount);
        vm.startPrank(protocolTreasury);
        usdc.approve(address(pool), premiumAmount);
        pool.collectPremium(1, premiumAmount, defaultDistributor);
        vm.stopPrank();

        uint256 priceAfter = pool.getTokenPrice();
        assertGt(priceAfter, priceBefore);
    }

    function test_TokenPrice_DecreasesWithPayouts() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 10_000e6;
        uint256 payoutAmount = 1_000e6;

        // Grant TREASURY_ROLE
        pool.grantRole(pool.TREASURY_ROLE(), protocolTreasury);

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        uint256 priceBefore = pool.getTokenPrice();

        // Process payout
        vm.prank(protocolTreasury);
        pool.processPayout(1, payoutAmount);

        uint256 priceAfter = pool.getTokenPrice();
        assertLt(priceAfter, priceBefore);
    }

    // ============ NAV-Based Minting Tests ============

    function test_NAVBasedMinting() public {
        pool = _deployPublicPool();
        uint256 deposit1 = 10_000e6;
        uint256 premiumAmount = 1_000e6;
        uint256 deposit2 = 10_000e6;

        // Grant TREASURY_ROLE
        pool.grantRole(pool.TREASURY_ROLE(), protocolTreasury);

        // First investor deposits
        vm.startPrank(investor1);
        usdc.approve(address(pool), deposit1);
        pool.deposit(deposit1);
        vm.stopPrank();

        // Premium collected (price increases)
        usdc.mint(protocolTreasury, premiumAmount);
        vm.startPrank(protocolTreasury);
        usdc.approve(address(pool), premiumAmount);
        pool.collectPremium(1, premiumAmount, defaultDistributor);
        vm.stopPrank();

        uint256 priceAfterPremium = pool.getTokenPrice();
        assertGt(priceAfterPremium, 1e6);

        // Second investor deposits at higher price
        vm.startPrank(investor2);
        usdc.approve(address(pool), deposit2);
        pool.deposit(deposit2);
        vm.stopPrank();

        // Second investor gets fewer tokens due to higher price
        assertLt(pool.balanceOf(investor2), pool.balanceOf(investor1));
    }

    // ============ Exposure Tracking Tests ============

    function test_ExposureTracking() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 100_000e6;
        int256 exposureIncrease = 10_000e6;

        // Grant TREASURY_ROLE
        pool.grantRole(pool.TREASURY_ROLE(), protocolTreasury);

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        assertEq(pool.activeExposure(), 0);
        assertEq(pool.getAvailableLiquidity(), depositAmount);

        // Update exposure
        vm.prank(protocolTreasury);
        pool.updateExposure(1, exposureIncrease);

        assertEq(pool.activeExposure(), uint256(exposureIncrease));
        assertGt(depositAmount, pool.getAvailableLiquidity());
    }

    // ============ Upgrade Tests ============

    function test_Upgrade_OnlyUpgrader() public {
        pool = _deployPublicPool();

        // Deploy new implementation
        RiskPoolV2Upgradeable newImpl = new RiskPoolV2Upgradeable();

        // Non-upgrader cannot upgrade
        vm.prank(investor1);
        vm.expectRevert();
        pool.upgradeToAndCall(address(newImpl), "");

        // Admin (this contract) has UPGRADER_ROLE and can upgrade
        pool.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_PreservesState() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 1_000e6;

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // Upgrade
        RiskPoolV2Upgradeable newImpl = new RiskPoolV2Upgradeable();
        pool.upgradeToAndCall(address(newImpl), "");

        // State preserved
        assertEq(pool.balanceOf(investor1), depositAmount);
        assertEq(pool.name(), "Public Pool");
        assertEq(usdc.balanceOf(address(pool)), depositAmount);
    }

    // ============ Access Control Tests ============

    function test_OnlyAdmin_CanPause() public {
        pool = _deployPublicPool();

        vm.prank(investor1);
        vm.expectRevert();
        pool.pause();

        // Admin (this contract) can pause
        pool.pause();
        assertTrue(pool.paused());
    }

    function test_OnlyAdmin_CanSetDepositsOpen() public {
        pool = _deployPublicPool();

        vm.prank(investor1);
        vm.expectRevert();
        pool.setDepositsOpen(false);

        // Admin (this contract) can set
        pool.setDepositsOpen(false);
        assertFalse(pool.depositsOpen());
    }

    function test_OnlyAdmin_CanAddDepositor() public {
        pool = _deployPrivatePool();

        vm.prank(investor1);
        vm.expectRevert();
        pool.addDepositor(investor2);

        // Admin (this contract) can add
        pool.addDepositor(investor2);
        assertTrue(pool.hasRole(pool.DEPOSITOR_ROLE(), investor2));
    }

    // ============ Mutual Pool Tests ============

    function test_MutualPool_Deposit() public {
        pool = _deployMutualPool();
        uint256 contribution = 1_000e6;

        // Open deposits and add depositor
        pool.setDepositsOpen(true);
        pool.addDepositor(investor1);

        // Deposit at fixed amount
        vm.startPrank(investor1);
        usdc.approve(address(pool), contribution);
        pool.deposit(contribution);
        vm.stopPrank();

        assertEq(pool.balanceOf(investor1), contribution);
    }

    // ============ Pool Summary Tests ============

    function test_GetPoolSummary() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 10_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        (
            uint256 poolValue,
            uint256 supply,
            uint256 tokenPriceVal,
            uint256 premiums,
            uint256 payouts,
            uint256 exposure
        ) = pool.getPoolSummary();

        assertEq(poolValue, depositAmount);
        assertEq(supply, depositAmount);
        assertEq(tokenPriceVal, 1e18);
        assertEq(premiums, 0);
        assertEq(payouts, 0);
        assertEq(exposure, 0);
    }

    // ============ Investor Info Tests ============

    function test_GetInvestorInfo() public {
        pool = _deployPublicPool();
        uint256 depositAmount = 10_000e6;

        vm.startPrank(investor1);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        (
            uint256 deposited,
            uint256 tokensHeld,
            uint256 currentValue,
            int256 roi
        ) = pool.getInvestorInfo(investor1);

        assertEq(deposited, depositAmount);
        assertEq(tokensHeld, depositAmount);
        assertEq(currentValue, depositAmount);
        assertEq(roi, 0);
    }
}
