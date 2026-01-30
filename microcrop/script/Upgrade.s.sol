// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RiskPoolFactory} from "../src/RiskPoolFactory.sol";

/**
 * @title Upgrade
 * @notice Upgrade script for MicroCrop upgradeable contracts
 *
 * Usage:
 *   forge script script/Upgrade.s.sol:UpgradeRiskPoolFactory \
 *     --rpc-url https://sepolia.base.org \
 *     --account deployer \
 *     --broadcast
 */
contract UpgradeRiskPoolFactory is Script {
    // Base Sepolia deployed proxy address
    address constant RISK_POOL_FACTORY_PROXY = 0xf68AC35ee87783437D77b7B19F824e76e95f73B9;

    function run() external {
        console.log("Upgrading RiskPoolFactory...");
        console.log("Proxy address:", RISK_POOL_FACTORY_PROXY);

        vm.startBroadcast();

        // Deploy new implementation
        RiskPoolFactory newImplementation = new RiskPoolFactory();
        console.log("New implementation deployed:", address(newImplementation));

        // Upgrade proxy to new implementation
        RiskPoolFactory proxy = RiskPoolFactory(RISK_POOL_FACTORY_PROXY);
        proxy.upgradeToAndCall(address(newImplementation), "");
        console.log("Proxy upgraded successfully!");

        vm.stopBroadcast();

        // Verify upgrade
        console.log("\n========== UPGRADE SUMMARY ==========");
        console.log("Proxy:", RISK_POOL_FACTORY_PROXY);
        console.log("New Implementation:", address(newImplementation));
        console.log("======================================");
    }
}
