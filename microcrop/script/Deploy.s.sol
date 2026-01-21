// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Treasury} from "../src/Treasury.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {RiskPool} from "../src/RiskPool.sol";
import {RiskPoolFactory} from "../src/RiskPoolFactory.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

/**
 * @title Deploy
 * @notice Deployment script for all MicroCrop upgradeable contracts
 * @dev Deploys implementation contracts and ERC1967 proxies using UUPS pattern
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast
 *
 * Environment Variables:
 *   USDC_ADDRESS: Address of USDC token
 *   BACKEND_WALLET: Address for backend operations
 *   ADMIN_ADDRESS: Address for admin roles (should be multi-sig)
 *   PROTOCOL_WALLET: Address for protocol fees
 */
contract Deploy is Script {
    // Deployed contract addresses
    address public treasuryImpl;
    address public treasuryProxy;
    address public policyManagerImpl;
    address public policyManagerProxy;
    address public payoutReceiverImpl;
    address public payoutReceiverProxy;
    address public riskPoolImpl;
    address public riskPoolFactoryImpl;
    address public riskPoolFactoryProxy;
    address public policyNFT;

    function run() external {
        // Get deployment parameters from environment
        address usdc = vm.envAddress("USDC_ADDRESS");
        address backendWallet = vm.envAddress("BACKEND_WALLET");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address protocolWallet = vm.envOr("PROTOCOL_WALLET", admin);

        vm.startBroadcast();

        // ============ Deploy Implementations ============
        console.log("Deploying implementation contracts...");

        // Treasury Implementation
        treasuryImpl = address(new Treasury());
        console.log("Treasury implementation:", treasuryImpl);

        // PolicyManager Implementation
        policyManagerImpl = address(new PolicyManager());
        console.log("PolicyManager implementation:", policyManagerImpl);

        // RiskPool Implementation (for factory to use)
        riskPoolImpl = address(new RiskPool());
        console.log("RiskPool implementation:", riskPoolImpl);

        // ============ Deploy PolicyNFT (non-upgradeable) ============
        policyNFT = address(new PolicyNFT("MicroCrop Insurance Certificate", "mcINS"));
        console.log("PolicyNFT:", policyNFT);

        // ============ Deploy Treasury Proxy ============
        console.log("\nDeploying proxies...");

        bytes memory treasuryInitData = abi.encodeWithSelector(
            Treasury.initialize.selector,
            usdc,
            backendWallet,
            admin
        );
        treasuryProxy = address(new ERC1967Proxy(treasuryImpl, treasuryInitData));
        console.log("Treasury proxy:", treasuryProxy);

        // ============ Deploy PolicyManager Proxy ============
        bytes memory policyManagerInitData = abi.encodeWithSelector(
            PolicyManager.initialize.selector,
            admin
        );
        policyManagerProxy = address(new ERC1967Proxy(policyManagerImpl, policyManagerInitData));
        console.log("PolicyManager proxy:", policyManagerProxy);

        // ============ Deploy PayoutReceiver Implementation & Proxy ============
        payoutReceiverImpl = address(new PayoutReceiver());
        console.log("PayoutReceiver implementation:", payoutReceiverImpl);

        bytes memory payoutReceiverInitData = abi.encodeWithSelector(
            PayoutReceiver.initialize.selector,
            treasuryProxy,
            policyManagerProxy,
            admin
        );
        payoutReceiverProxy = address(new ERC1967Proxy(payoutReceiverImpl, payoutReceiverInitData));
        console.log("PayoutReceiver proxy:", payoutReceiverProxy);

        // ============ Deploy RiskPoolFactory ============
        riskPoolFactoryImpl = address(new RiskPoolFactory());
        console.log("RiskPoolFactory implementation:", riskPoolFactoryImpl);

        bytes memory factoryInitData = abi.encodeWithSelector(
            RiskPoolFactory.initialize.selector,
            usdc,
            treasuryProxy,
            protocolWallet,
            riskPoolImpl,
            admin
        );
        riskPoolFactoryProxy = address(new ERC1967Proxy(riskPoolFactoryImpl, factoryInitData));
        console.log("RiskPoolFactory proxy:", riskPoolFactoryProxy);

        // ============ Grant Cross-Contract Roles ============
        console.log("\nGranting cross-contract roles...");

        // Grant PAYOUT_ROLE to PayoutReceiver on Treasury
        Treasury treasury = Treasury(treasuryProxy);
        treasury.grantRole(treasury.PAYOUT_ROLE(), payoutReceiverProxy);
        console.log("Granted PAYOUT_ROLE to PayoutReceiver");

        // Grant ORACLE_ROLE to PayoutReceiver on PolicyManager
        PolicyManager policyManager = PolicyManager(policyManagerProxy);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), payoutReceiverProxy);
        console.log("Granted ORACLE_ROLE to PayoutReceiver");

        // Set PolicyNFT on PolicyManager
        policyManager.setPolicyNFT(policyNFT);
        console.log("Set PolicyNFT on PolicyManager");

        // Grant MINTER_ROLE to PolicyManager on PolicyNFT
        PolicyNFT(policyNFT).grantRole(PolicyNFT(policyNFT).MINTER_ROLE(), policyManagerProxy);
        console.log("Granted MINTER_ROLE to PolicyManager");

        vm.stopBroadcast();

        // ============ Print Summary ============
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("IMPLEMENTATIONS:");
        console.log("  Treasury:", treasuryImpl);
        console.log("  PolicyManager:", policyManagerImpl);
        console.log("  PayoutReceiver:", payoutReceiverImpl);
        console.log("  RiskPool:", riskPoolImpl);
        console.log("  RiskPoolFactory:", riskPoolFactoryImpl);
        console.log("\nPROXIES (use these for interactions):");
        console.log("  Treasury:", treasuryProxy);
        console.log("  PolicyManager:", policyManagerProxy);
        console.log("  PayoutReceiver:", payoutReceiverProxy);
        console.log("  RiskPoolFactory:", riskPoolFactoryProxy);
        console.log("\nOTHER CONTRACTS:");
        console.log("  PolicyNFT:", policyNFT);
        console.log("==========================================");
    }
}
