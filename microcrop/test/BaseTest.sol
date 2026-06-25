// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Treasury} from "../src/Treasury.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title BaseTest
 * @notice Base test contract with common setup for upgradeable contracts
 */
abstract contract BaseTest is Test {
    // ============ Contracts ============
    Treasury public treasuryImpl;
    Treasury public treasury;
    PolicyManager public policyManagerImpl;
    PolicyManager public policyManager;
    PayoutReceiver public payoutReceiverImpl;
    PayoutReceiver public payoutReceiver;
    PolicyNFT public policyNFT;
    MockUSDC public usdc;

    // ============ Proxies ============
    ERC1967Proxy public treasuryProxy;
    ERC1967Proxy public policyManagerProxy;
    ERC1967Proxy public payoutReceiverProxy;

    // ============ Test Addresses ============
    address public admin = address(1);
    address public backend = address(2);
    address public keystoneForwarder = address(3);
    address public backendWallet = address(4);
    address public farmer = address(5);
    address public unauthorized = address(6);
    address public distributor = address(7);

    // ============ Test Constants ============
    string public constant DISTRIBUTOR_NAME = "AgriInsure Kenya";
    string public constant REGION = "Nakuru County";

    /**
     * @notice Deploy all core contracts with proxies
     */
    function _deployContracts() internal {
        vm.startPrank(admin);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy PolicyNFT (non-upgradeable)
        policyNFT = new PolicyNFT("MicroCrop Insurance Certificate", "mcINS");

        // Deploy Treasury implementation and proxy
        treasuryImpl = new Treasury();
        bytes memory treasuryInitData = abi.encodeWithSelector(
            Treasury.initialize.selector,
            address(usdc),
            backendWallet,
            admin
        );
        treasuryProxy = new ERC1967Proxy(address(treasuryImpl), treasuryInitData);
        treasury = Treasury(address(treasuryProxy));

        // Deploy PolicyManager implementation and proxy
        policyManagerImpl = new PolicyManager();
        bytes memory policyManagerInitData = abi.encodeWithSelector(
            PolicyManager.initialize.selector,
            admin
        );
        policyManagerProxy = new ERC1967Proxy(address(policyManagerImpl), policyManagerInitData);
        policyManager = PolicyManager(address(policyManagerProxy));

        // Deploy PayoutReceiver implementation and proxy
        payoutReceiverImpl = new PayoutReceiver();
        bytes memory payoutReceiverInitData = abi.encodeWithSelector(
            PayoutReceiver.initialize.selector,
            address(treasury),
            address(policyManager),
            admin
        );
        payoutReceiverProxy = new ERC1967Proxy(address(payoutReceiverImpl), payoutReceiverInitData);
        payoutReceiver = PayoutReceiver(address(payoutReceiverProxy));

        // Grant cross-contract roles
        treasury.grantRole(treasury.BACKEND_ROLE(), backend);
        treasury.grantRole(treasury.PAYOUT_ROLE(), address(payoutReceiver));
        
        policyManager.grantRole(policyManager.BACKEND_ROLE(), backend);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), address(payoutReceiver));
        
        // Set PolicyNFT on PolicyManager
        policyManager.setPolicyNFT(address(policyNFT));
        policyNFT.grantRole(policyNFT.MINTER_ROLE(), address(policyManager));

        vm.stopPrank();

        // Fund backend for premiums
        usdc.mint(backend, 10_000_000e6);
        vm.prank(backend);
        usdc.approve(address(treasury), type(uint256).max);
    }
}
