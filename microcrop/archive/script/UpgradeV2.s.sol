// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "../src/Treasury.sol";
import {RiskPoolFactory} from "../src/RiskPoolFactory.sol";
import {RiskPool} from "../src/RiskPool.sol";

/**
 * @title UpgradeV2
 * @notice Upgrade Treasury, RiskPoolFactory, and RiskPool implementations on Base Mainnet
 * @dev Applies security audit round 2 fixes:
 *      - Treasury: factory validation, premium accounting in distributePremiumToPool
 *      - RiskPoolFactory: bounded setPolicyManager, per-pool grant function
 *      - RiskPool: round 1 audit fixes (pause guards, dust withdrawal, deposit cap)
 *
 * Usage:
 *   forge script script/UpgradeV2.s.sol \
 *     --rpc-url base_mainnet \
 *     --account deployer \
 *     --broadcast \
 *     --verify
 */
contract UpgradeV2 is Script {
    // Base Mainnet proxy addresses
    address constant TREASURY_PROXY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant FACTORY_PROXY = 0x7A14Aa6f41c2F9107812554b875dC0B52D61eBf2;

    function run() external {
        require(block.chainid == 8453, "Must run on Base Mainnet (chain 8453)");

        console.log("=== MicroCrop V2 Upgrade ===");
        console.log("Chain ID:", block.chainid);
        console.log("Treasury proxy:", TREASURY_PROXY);
        console.log("Factory proxy:", FACTORY_PROXY);

        vm.startBroadcast();

        // 1. Deploy new implementations
        console.log("\n--- Deploying new implementations ---");

        Treasury newTreasuryImpl = new Treasury();
        console.log("Treasury impl:", address(newTreasuryImpl));

        RiskPoolFactory newFactoryImpl = new RiskPoolFactory();
        console.log("RiskPoolFactory impl:", address(newFactoryImpl));

        RiskPool newPoolImpl = new RiskPool();
        console.log("RiskPool impl:", address(newPoolImpl));

        // 2. Upgrade Treasury proxy
        console.log("\n--- Upgrading proxies ---");

        Treasury treasury = Treasury(TREASURY_PROXY);
        treasury.upgradeToAndCall(address(newTreasuryImpl), "");
        console.log("Treasury upgraded");

        // 3. Upgrade RiskPoolFactory proxy
        RiskPoolFactory factory = RiskPoolFactory(FACTORY_PROXY);
        factory.upgradeToAndCall(address(newFactoryImpl), "");
        console.log("RiskPoolFactory upgraded");

        // 4. Post-upgrade configuration
        console.log("\n--- Post-upgrade config ---");

        // Set factory on Treasury for pool validation in distributePremiumToPool
        treasury.setFactory(FACTORY_PROXY);
        console.log("Treasury: factory set to", FACTORY_PROXY);

        // Update RiskPool implementation for new pool deployments
        factory.setPoolImplementation(address(newPoolImpl));
        console.log("Factory: pool implementation updated");

        vm.stopBroadcast();

        // Verification
        console.log("\n========================================");
        console.log("  V2 UPGRADE SUMMARY");
        console.log("========================================");
        console.log("\nNEW IMPLEMENTATIONS:");
        console.log("  Treasury:        ", address(newTreasuryImpl));
        console.log("  RiskPoolFactory: ", address(newFactoryImpl));
        console.log("  RiskPool:        ", address(newPoolImpl));
        console.log("\nPROXIES (unchanged):");
        console.log("  Treasury:        ", TREASURY_PROXY);
        console.log("  RiskPoolFactory: ", FACTORY_PROXY);
        console.log("\nCONFIG:");
        console.log("  treasury.factory:", treasury.factory());
        console.log("  factory.poolImpl:", factory.poolImplementation());
        console.log("========================================");
        console.log("NOTE: Existing pools keep their current RiskPool impl.");
        console.log("New pools will use the updated implementation.");
        console.log("========================================");
    }
}
