// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TreasuryV1} from "../src/TreasuryV1.sol";
import {PolicyManagerV1} from "../src/PolicyManagerV1.sol";
import {PayoutReceiverV1} from "../src/PayoutReceiverV1.sol";
import {RiskPoolV1} from "../src/RiskPoolV1.sol";
import {RiskPoolFactoryV1} from "../src/RiskPoolFactoryV1.sol";

/**
 * @title UpgradeContract
 * @notice Script for upgrading MicroCrop contracts to new implementations
 * @dev Example usage for upgrading Treasury:
 *
 *   forge script script/UpgradeContract.s.sol \
 *     --rpc-url <RPC_URL> \
 *     --private-key <PRIVATE_KEY> \
 *     --broadcast \
 *     -s "upgradeTreasury(address,address)" <PROXY_ADDRESS> <NEW_IMPL_ADDRESS>
 *
 * IMPORTANT: The caller must have UPGRADER_ROLE on the proxy contract.
 */
contract UpgradeContract is Script {
    /**
     * @notice Upgrade Treasury proxy to a new implementation
     * @param proxyAddress Current Treasury proxy address
     * @param newImplementation New TreasuryV2+ implementation address
     */
    function upgradeTreasury(address proxyAddress, address newImplementation) external {
        console.log("Upgrading Treasury...");
        console.log("  Proxy:", proxyAddress);
        console.log("  New Implementation:", newImplementation);

        vm.startBroadcast();
        
        TreasuryV1 treasury = TreasuryV1(proxyAddress);
        treasury.upgradeToAndCall(newImplementation, "");
        
        vm.stopBroadcast();

        console.log("Treasury upgraded successfully!");
        console.log("  New version:", TreasuryV1(proxyAddress).version());
    }

    /**
     * @notice Upgrade PolicyManager proxy to a new implementation
     * @param proxyAddress Current PolicyManager proxy address
     * @param newImplementation New PolicyManagerV2+ implementation address
     */
    function upgradePolicyManager(address proxyAddress, address newImplementation) external {
        console.log("Upgrading PolicyManager...");
        console.log("  Proxy:", proxyAddress);
        console.log("  New Implementation:", newImplementation);

        vm.startBroadcast();
        
        PolicyManagerV1 policyManager = PolicyManagerV1(proxyAddress);
        policyManager.upgradeToAndCall(newImplementation, "");
        
        vm.stopBroadcast();

        console.log("PolicyManager upgraded successfully!");
        console.log("  New version:", PolicyManagerV1(proxyAddress).version());
    }

    /**
     * @notice Upgrade PayoutReceiver proxy to a new implementation
     * @param proxyAddress Current PayoutReceiver proxy address
     * @param newImplementation New PayoutReceiverV2+ implementation address
     */
    function upgradePayoutReceiver(address proxyAddress, address newImplementation) external {
        console.log("Upgrading PayoutReceiver...");
        console.log("  Proxy:", proxyAddress);
        console.log("  New Implementation:", newImplementation);

        vm.startBroadcast();
        
        PayoutReceiverV1 payoutReceiver = PayoutReceiverV1(proxyAddress);
        payoutReceiver.upgradeToAndCall(newImplementation, "");
        
        vm.stopBroadcast();

        console.log("PayoutReceiver upgraded successfully!");
        console.log("  New version:", PayoutReceiverV1(proxyAddress).version());
    }

    /**
     * @notice Upgrade RiskPoolFactory proxy to a new implementation
     * @param proxyAddress Current RiskPoolFactory proxy address
     * @param newImplementation New RiskPoolFactoryV2+ implementation address
     */
    function upgradeRiskPoolFactory(address proxyAddress, address newImplementation) external {
        console.log("Upgrading RiskPoolFactory...");
        console.log("  Proxy:", proxyAddress);
        console.log("  New Implementation:", newImplementation);

        vm.startBroadcast();
        
        RiskPoolFactoryV1 factory = RiskPoolFactoryV1(proxyAddress);
        factory.upgradeToAndCall(newImplementation, "");
        
        vm.stopBroadcast();

        console.log("RiskPoolFactory upgraded successfully!");
        console.log("  New version:", RiskPoolFactoryV1(proxyAddress).version());
    }

    /**
     * @notice Upgrade a specific RiskPool proxy to a new implementation
     * @param poolProxyAddress RiskPool proxy address to upgrade
     * @param newImplementation New RiskPoolV2+ implementation address
     */
    function upgradeRiskPool(address poolProxyAddress, address newImplementation) external {
        console.log("Upgrading RiskPool...");
        console.log("  Pool Proxy:", poolProxyAddress);
        console.log("  New Implementation:", newImplementation);

        vm.startBroadcast();
        
        RiskPoolV1 pool = RiskPoolV1(poolProxyAddress);
        pool.upgradeToAndCall(newImplementation, "");
        
        vm.stopBroadcast();

        console.log("RiskPool upgraded successfully!");
        console.log("  New version:", RiskPoolV1(poolProxyAddress).version());
    }

    /**
     * @notice Update the RiskPool implementation in the factory
     * @dev This sets the implementation for NEW pools, doesn't upgrade existing ones
     * @param factoryProxyAddress RiskPoolFactory proxy address
     * @param newRiskPoolImplementation New RiskPoolV2+ implementation address
     */
    function updateFactoryRiskPoolImplementation(
        address factoryProxyAddress,
        address newRiskPoolImplementation
    ) external {
        console.log("Updating RiskPool implementation in factory...");
        console.log("  Factory:", factoryProxyAddress);
        console.log("  New RiskPool Implementation:", newRiskPoolImplementation);

        vm.startBroadcast();
        
        RiskPoolFactoryV1 factory = RiskPoolFactoryV1(factoryProxyAddress);
        factory.setRiskPoolImplementation(newRiskPoolImplementation);
        
        vm.stopBroadcast();

        console.log("Factory updated successfully!");
        console.log("  New pools will use:", newRiskPoolImplementation);
    }
}
