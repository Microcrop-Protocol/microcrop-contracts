// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TreasuryTest is Test {
    Treasury public treasuryImpl;
    Treasury public treasury;
    MockUSDC public usdc;

    address public admin = makeAddr("admin");
    address public backendWallet = makeAddr("backendWallet");
    address public backendRole = makeAddr("backendRole");
    address public payoutRole = makeAddr("payoutRole");
    address public farmer = makeAddr("farmer");
    address public user = makeAddr("user");

    uint256 public constant PREMIUM_AMOUNT = 100e6;
    uint256 public constant PAYOUT_AMOUNT = 50e6;
    uint256 public constant INITIAL_BALANCE = 1_000_000e6;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    bytes32 public constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    event PremiumReceived(
        uint256 indexed policyId, uint256 grossAmount, uint256 platformFee, uint256 netAmount, address indexed from
    );
    event PayoutSent(uint256 indexed policyId, uint256 amount, address indexed recipient);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        treasuryImpl = new Treasury();
        bytes memory initData =
            abi.encodeWithSelector(Treasury.initialize.selector, address(usdc), backendWallet, admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(treasuryImpl), initData);
        treasury = Treasury(address(proxy));

        vm.startPrank(admin);
        treasury.grantRole(BACKEND_ROLE, backendRole);
        treasury.grantRole(PAYOUT_ROLE, payoutRole);
        vm.stopPrank();

        usdc.mint(farmer, INITIAL_BALANCE);
        usdc.mint(backendRole, INITIAL_BALANCE);
        usdc.mint(address(treasury), INITIAL_BALANCE);

        vm.prank(farmer);
        usdc.approve(address(treasury), type(uint256).max);
        vm.prank(backendRole);
        usdc.approve(address(treasury), type(uint256).max);
    }

    function test_Initialize() public view {
        assertEq(address(treasury.usdc()), address(usdc));
        assertEq(treasury.backendWallet(), backendWallet);
        assertEq(treasury.platformFeePercent(), 10);
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(treasury.hasRole(ADMIN_ROLE, admin));
    }

    // NOTE: receivePremium / requestPayout happy paths, duplicate guards, and per-org behavior
    // are covered in PerOrgTreasury.t.sol (v3 needs a wired PolicyManager + a funded org reserve).
    // The zero-amount guards below run before org resolution, so they stay here.

    function test_ReceivePremium_RevertOnZeroAmount() public {
        vm.prank(backendRole);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.receivePremium(1, 0);
    }

    function test_RequestPayout_RevertOnZeroAmount() public {
        vm.prank(payoutRole);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.requestPayout(1, 0);
    }

    function test_UpdatePlatformFee() public {
        vm.prank(admin);
        treasury.setPlatformFee(15);
        assertEq(treasury.platformFeePercent(), 15);
    }

    function test_UpdatePlatformFee_RevertOnTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.FeeTooHigh.selector, 21, 20));
        treasury.setPlatformFee(21);
    }

    function test_WithdrawFees_RevertOnNoFees() public {
        vm.prank(admin);
        vm.expectRevert(Treasury.NoFeesToWithdraw.selector);
        treasury.withdrawFees(admin);
    }

    function test_Pause() public {
        vm.prank(admin);
        treasury.pause();
        assertTrue(treasury.paused());
    }

    function test_Unpause() public {
        vm.prank(admin);
        treasury.pause();
        vm.prank(admin);
        treasury.unpause();
        assertFalse(treasury.paused());
    }

    function test_CalculatePlatformFee() public view {
        uint256 amount = 1000e6;
        uint256 expectedFee = (amount * 10) / 100;
        assertEq(treasury.calculatePlatformFee(amount), expectedFee);
    }

    function test_GetAvailableForPayouts() public view {
        uint256 available = treasury.getAvailableForPayouts();
        assertGt(available, 0);
    }

    function test_GetBalance() public view {
        uint256 balance = treasury.getBalance();
        assertGt(balance, 0);
    }
}
