// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";

/**
 * @title DeployMicroCrop
 * @notice Deployment script for MicroCrop smart contracts
 * @dev Deploys all three contracts and configures roles properly
 *
 * Environment Variables Required:
 * - USDC_ADDRESS: Address of the USDC token contract
 * - BACKEND_WALLET: Address of the backend wallet for payouts
 * - ADMIN_MULTISIG: Address of the admin multi-sig wallet
 * - KEYSTONE_FORWARDER: Address of the Chainlink Keystone Forwarder
 * - WORKFLOW_ADDRESS: Address of the Chainlink workflow
 * - WORKFLOW_ID: ID of the Chainlink workflow
 *
 * Usage:
 * - Testnet: forge script script/DeployMicroCrop.s.sol --rpc-url base_sepolia --broadcast
 * - Mainnet: forge script script/DeployMicroCrop.s.sol --rpc-url base_mainnet --broadcast --verify
 */
contract DeployMicroCrop is Script {
    // Deployed contract addresses
    PolicyManager public policyManager;
    Treasury public treasury;
    PayoutReceiver public payoutReceiver;

    function run() external {
        // Load environment variables
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        address backendWallet = vm.envAddress("BACKEND_WALLET");
        address adminMultisig = vm.envAddress("ADMIN_MULTISIG");
        address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");
        address workflowAddress = vm.envAddress("WORKFLOW_ADDRESS");
        uint256 workflowId = vm.envUint("WORKFLOW_ID");

        // Validate addresses
        require(usdcAddress != address(0), "Invalid USDC address");
        require(backendWallet != address(0), "Invalid backend wallet");
        require(adminMultisig != address(0), "Invalid admin multisig");
        require(keystoneForwarder != address(0), "Invalid keystone forwarder");
        require(workflowAddress != address(0), "Invalid workflow address");

        console.log("=== MicroCrop Deployment ===");
        console.log("USDC Address:", usdcAddress);
        console.log("Backend Wallet:", backendWallet);
        console.log("Admin Multisig:", adminMultisig);
        console.log("Keystone Forwarder:", keystoneForwarder);
        console.log("Workflow Address:", workflowAddress);
        console.log("Workflow ID:", workflowId);
        console.log("");

        vm.startBroadcast();

        // 1. Deploy PolicyManager
        policyManager = new PolicyManager();
        console.log("PolicyManager deployed at:", address(policyManager));

        // 2. Deploy Treasury
        treasury = new Treasury(usdcAddress, backendWallet);
        console.log("Treasury deployed at:", address(treasury));

        // 3. Deploy PayoutReceiver
        payoutReceiver = new PayoutReceiver(address(treasury), address(policyManager));
        console.log("PayoutReceiver deployed at:", address(payoutReceiver));

        // 4. Configure PayoutReceiver
        payoutReceiver.setKeystoneForwarder(keystoneForwarder);
        payoutReceiver.setWorkflowConfig(workflowAddress, workflowId);
        console.log("PayoutReceiver configured with Keystone Forwarder");

        // 5. Grant roles on PolicyManager
        policyManager.grantRole(policyManager.BACKEND_ROLE(), backendWallet);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), address(payoutReceiver));
        console.log("PolicyManager roles granted");

        // 6. Grant roles on Treasury
        treasury.grantRole(treasury.BACKEND_ROLE(), backendWallet);
        treasury.grantRole(treasury.PAYOUT_ROLE(), address(payoutReceiver));
        console.log("Treasury roles granted");

        // 7. Transfer admin roles to multisig
        // PolicyManager
        policyManager.grantRole(policyManager.DEFAULT_ADMIN_ROLE(), adminMultisig);
        policyManager.grantRole(policyManager.ADMIN_ROLE(), adminMultisig);
        
        // Treasury
        treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), adminMultisig);
        treasury.grantRole(treasury.ADMIN_ROLE(), adminMultisig);
        
        // PayoutReceiver
        payoutReceiver.grantRole(payoutReceiver.DEFAULT_ADMIN_ROLE(), adminMultisig);
        payoutReceiver.grantRole(payoutReceiver.ADMIN_ROLE(), adminMultisig);
        
        console.log("Admin roles transferred to multisig");

        // 8. Renounce deployer's admin roles (optional - uncomment for production)
        // policyManager.renounceRole(policyManager.DEFAULT_ADMIN_ROLE(), msg.sender);
        // policyManager.renounceRole(policyManager.ADMIN_ROLE(), msg.sender);
        // treasury.renounceRole(treasury.DEFAULT_ADMIN_ROLE(), msg.sender);
        // treasury.renounceRole(treasury.ADMIN_ROLE(), msg.sender);
        // payoutReceiver.renounceRole(payoutReceiver.DEFAULT_ADMIN_ROLE(), msg.sender);
        // payoutReceiver.renounceRole(payoutReceiver.ADMIN_ROLE(), msg.sender);
        // console.log("Deployer admin roles renounced");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("PolicyManager:", address(policyManager));
        console.log("Treasury:", address(treasury));
        console.log("PayoutReceiver:", address(payoutReceiver));
        console.log("");
        console.log("=== Role Configuration ===");
        console.log("BACKEND_ROLE on PolicyManager: ", backendWallet);
        console.log("BACKEND_ROLE on Treasury:      ", backendWallet);
        console.log("ORACLE_ROLE on PolicyManager:  ", address(payoutReceiver));
        console.log("PAYOUT_ROLE on Treasury:       ", address(payoutReceiver));
        console.log("DEFAULT_ADMIN_ROLE (all):      ", adminMultisig);
    }
}

/**
 * @title DeployTestnet
 * @notice Simplified deployment script for Base Sepolia testnet
 * @dev Uses hardcoded testnet addresses for convenience
 */
contract DeployTestnet is Script {
    // Base Sepolia USDC
    address constant USDC_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        // For testnet, use msg.sender for all roles
        address deployer = msg.sender;

        console.log("=== Testnet Deployment ===");
        console.log("Deployer:", deployer);
        console.log("USDC:", USDC_SEPOLIA);

        vm.startBroadcast();

        // 1. Deploy PolicyManager
        PolicyManager policyManager = new PolicyManager();
        console.log("PolicyManager:", address(policyManager));

        // 2. Deploy Treasury (deployer is backend wallet for testing)
        Treasury treasury = new Treasury(USDC_SEPOLIA, deployer);
        console.log("Treasury:", address(treasury));

        // 3. Deploy PayoutReceiver
        PayoutReceiver payoutReceiver = new PayoutReceiver(address(treasury), address(policyManager));
        console.log("PayoutReceiver:", address(payoutReceiver));

        // 4. Grant all roles to deployer for testing
        policyManager.grantRole(policyManager.BACKEND_ROLE(), deployer);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), address(payoutReceiver));

        treasury.grantRole(treasury.BACKEND_ROLE(), deployer);
        treasury.grantRole(treasury.PAYOUT_ROLE(), address(payoutReceiver));

        // Configure PayoutReceiver with placeholder values (update after deployment)
        payoutReceiver.setKeystoneForwarder(deployer); // Use deployer for testing
        payoutReceiver.setWorkflowConfig(deployer, 1); // Placeholder

        vm.stopBroadcast();

        console.log("");
        console.log("=== Testnet Deployment Complete ===");
        console.log("Update PayoutReceiver configuration with real Chainlink values:");
        console.log("  payoutReceiver.setKeystoneForwarder(<real_address>)");
        console.log("  payoutReceiver.setWorkflowConfig(<workflow_address>, <workflow_id>)");
    }
}
