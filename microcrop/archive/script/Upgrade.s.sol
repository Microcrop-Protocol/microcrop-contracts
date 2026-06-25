// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RiskPoolFactory} from "../src/RiskPoolFactory.sol";
import {RiskPool} from "../src/RiskPool.sol";

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

    // Treasury proxy (receives 10% protocol fee from premiums)
    address constant PROTOCOL_TREASURY = 0x6B04966167C74e577D9d750BE1055Fa4d25C270c;

    function run() external {
        console.log("=== Upgrading RiskPoolFactory + Redeploying RiskPool ===");
        console.log("Factory proxy:", RISK_POOL_FACTORY_PROXY);

        vm.startBroadcast();

        // 1. Deploy new RiskPool implementation (with updated CoverageType enum)
        RiskPool newPoolImpl = new RiskPool();
        console.log("New RiskPool implementation:", address(newPoolImpl));

        // 2. Deploy new RiskPoolFactory implementation (with setProtocolTreasury)
        RiskPoolFactory newFactoryImpl = new RiskPoolFactory();
        console.log("New RiskPoolFactory implementation:", address(newFactoryImpl));

        // 3. Upgrade factory proxy to new implementation
        RiskPoolFactory proxy = RiskPoolFactory(RISK_POOL_FACTORY_PROXY);
        proxy.upgradeToAndCall(address(newFactoryImpl), "");
        console.log("Factory proxy upgraded");

        // 4. Point factory to new pool implementation
        proxy.setPoolImplementation(address(newPoolImpl));
        console.log("Pool implementation updated");

        // 5. Fix protocolTreasury (was set to admin EOA during initial deploy)
        proxy.setProtocolTreasury(PROTOCOL_TREASURY);
        console.log("Protocol treasury updated");

        vm.stopBroadcast();

        // Verify
        console.log("\n========== UPGRADE SUMMARY ==========");
        console.log("Factory Proxy:            ", RISK_POOL_FACTORY_PROXY);
        console.log("New Factory Impl:         ", address(newFactoryImpl));
        console.log("New RiskPool Impl:        ", address(newPoolImpl));
        console.log("Pool Implementation (set):", proxy.poolImplementation());
        console.log("Protocol Treasury (set):  ", proxy.protocolTreasury());
        console.log("======================================");
    }
}
