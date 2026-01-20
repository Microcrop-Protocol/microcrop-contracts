// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TreasuryV1} from "../src/TreasuryV1.sol";
import {PolicyManagerV1} from "../src/PolicyManagerV1.sol";
import {PayoutReceiverV1} from "../src/PayoutReceiverV1.sol";
import {RiskPoolV1} from "../src/RiskPoolV1.sol";
import {RiskPoolFactoryV1} from "../src/RiskPoolFactoryV1.sol";

/**
 * @title DeployUpgradeable
 * @notice Deployment script for all upgradeable MicroCrop contracts
 * @dev Deploys implementation contracts and ERC1967 proxies
 *
 * Usage:
 *   forge script script/DeployUpgradeable.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast
 */
contract DeployUpgradeable is Script {
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

    function run() external {
        // Get deployment parameters from environment
        address usdc = vm.envAddress("USDC_ADDRESS");
        address backendWallet = vm.envAddress("BACKEND_WALLET");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast();

        // ============ Deploy Implementations ============
        console.log("Deploying implementation contracts...");

        // Treasury Implementation
        treasuryImpl = address(new TreasuryV1());
        console.log("TreasuryV1 implementation:", treasuryImpl);

        // PolicyManager Implementation
        policyManagerImpl = address(new PolicyManagerV1());
        console.log("PolicyManagerV1 implementation:", policyManagerImpl);

        // RiskPool Implementation (for factory to use)
        riskPoolImpl = address(new RiskPoolV1());
        console.log("RiskPoolV1 implementation:", riskPoolImpl);

        // ============ Deploy Treasury Proxy ============
        console.log("\nDeploying proxies...");

        bytes memory treasuryInitData = abi.encodeWithSelector(
            TreasuryV1.initialize.selector,
            usdc,
            backendWallet,
            admin
        );
        treasuryProxy = address(new ERC1967Proxy(treasuryImpl, treasuryInitData));
        console.log("Treasury proxy:", treasuryProxy);

        // ============ Deploy PolicyManager Proxy ============
        bytes memory policyManagerInitData = abi.encodeWithSelector(
            PolicyManagerV1.initialize.selector,
            admin
        );
        policyManagerProxy = address(new ERC1967Proxy(policyManagerImpl, policyManagerInitData));
        console.log("PolicyManager proxy:", policyManagerProxy);

        // ============ Deploy PayoutReceiver Implementation & Proxy ============
        payoutReceiverImpl = address(new PayoutReceiverV1());
        console.log("PayoutReceiverV1 implementation:", payoutReceiverImpl);

        bytes memory payoutReceiverInitData = abi.encodeWithSelector(
            PayoutReceiverV1.initialize.selector,
            treasuryProxy,
            policyManagerProxy,
            admin
        );
        payoutReceiverProxy = address(new ERC1967Proxy(payoutReceiverImpl, payoutReceiverInitData));
        console.log("PayoutReceiver proxy:", payoutReceiverProxy);

        // ============ Deploy RiskPoolFactory ============
        riskPoolFactoryImpl = address(new RiskPoolFactoryV1());
        console.log("RiskPoolFactoryV1 implementation:", riskPoolFactoryImpl);

        bytes memory factoryInitData = abi.encodeWithSelector(
            RiskPoolFactoryV1.initialize.selector,
            usdc,
            treasuryProxy,
            riskPoolImpl,
            admin
        );
        riskPoolFactoryProxy = address(new ERC1967Proxy(riskPoolFactoryImpl, factoryInitData));
        console.log("RiskPoolFactory proxy:", riskPoolFactoryProxy);

        // ============ Grant Cross-Contract Roles ============
        console.log("\nGranting cross-contract roles...");

        // Grant PAYOUT_ROLE to PayoutReceiver on Treasury
        TreasuryV1 treasury = TreasuryV1(treasuryProxy);
        treasury.grantRole(treasury.PAYOUT_ROLE(), payoutReceiverProxy);
        console.log("Granted PAYOUT_ROLE to PayoutReceiver");

        // Grant ORACLE_ROLE to PayoutReceiver on PolicyManager
        PolicyManagerV1 policyManager = PolicyManagerV1(policyManagerProxy);
        policyManager.grantRole(policyManager.ORACLE_ROLE(), payoutReceiverProxy);
        console.log("Granted ORACLE_ROLE to PayoutReceiver");

        vm.stopBroadcast();

        // ============ Print Summary ============
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("IMPLEMENTATIONS:");
        console.log("  TreasuryV1:", treasuryImpl);
        console.log("  PolicyManagerV1:", policyManagerImpl);
        console.log("  PayoutReceiverV1:", payoutReceiverImpl);
        console.log("  RiskPoolV1:", riskPoolImpl);
        console.log("  RiskPoolFactoryV1:", riskPoolFactoryImpl);
        console.log("\nPROXIES (use these for interactions):");
        console.log("  Treasury:", treasuryProxy);
        console.log("  PolicyManager:", policyManagerProxy);
        console.log("  PayoutReceiver:", payoutReceiverProxy);
        console.log("  RiskPoolFactory:", riskPoolFactoryProxy);
        console.log("==========================================");
    }
}
