// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

/**
 * @title UpgradePolicyManager
 * @notice Upgrades PolicyManager and redeploys PolicyNFT on Base Sepolia
 *
 * Fixes:
 *   1. CoverageType enum: adds EXCESS_RAIN(3) and COMPREHENSIVE(4)
 *   2. MIN_SUM_INSURED: lowered from 10,000 to 100 USDC for micro-insurance
 *   3. PolicyNFT: redeployed with matching CoverageType enum
 *   4. BACKEND_ROLE: granted to deployer wallet
 *
 * Usage:
 *   forge script script/UpgradePolicyManager.s.sol:UpgradePolicyManager \
 *     --rpc-url https://sepolia.base.org \
 *     --account deployer \
 *     --broadcast
 */
contract UpgradePolicyManager is Script {
    // Base Sepolia deployed addresses
    address constant POLICY_MANAGER_PROXY = 0xDb6A11f23b8e357C0505359da4B3448d8EE5291C;
    address constant PAYOUT_RECEIVER_PROXY = 0x1151621ed6A9830E36fd6b55878a775c824fabd0;

    function run() external {
        console.log("=== Upgrading PolicyManager + Redeploying PolicyNFT ===");
        console.log("PolicyManager proxy:", POLICY_MANAGER_PROXY);

        vm.startBroadcast();

        // 1. Deploy new PolicyManager implementation
        PolicyManager newPolicyManagerImpl = new PolicyManager();
        console.log("New PolicyManager impl:", address(newPolicyManagerImpl));

        // 2. Upgrade PolicyManager proxy
        PolicyManager proxy = PolicyManager(POLICY_MANAGER_PROXY);
        proxy.upgradeToAndCall(address(newPolicyManagerImpl), "");
        console.log("PolicyManager upgraded");

        // 3. Deploy new PolicyNFT (non-upgradeable, has updated CoverageType enum)
        PolicyNFT newPolicyNFT = new PolicyNFT(
            "MicroCrop Insurance Certificate",
            "mcINS"
        );
        console.log("New PolicyNFT:", address(newPolicyNFT));

        // 4. Set new PolicyNFT on PolicyManager
        proxy.setPolicyNFT(address(newPolicyNFT));
        console.log("PolicyNFT set on PolicyManager");

        // 5. Grant MINTER_ROLE to PolicyManager on new PolicyNFT
        newPolicyNFT.grantRole(
            newPolicyNFT.MINTER_ROLE(),
            POLICY_MANAGER_PROXY
        );
        console.log("MINTER_ROLE granted to PolicyManager");

        // 6. Grant BACKEND_ROLE to deployer (msg.sender) on PolicyManager
        proxy.grantRole(proxy.BACKEND_ROLE(), msg.sender);
        console.log("BACKEND_ROLE granted to deployer");

        // 7. Re-grant ORACLE_ROLE to PayoutReceiver on PolicyManager
        //    (preserved through upgrade, but verify)
        if (!proxy.hasRole(proxy.ORACLE_ROLE(), PAYOUT_RECEIVER_PROXY)) {
            proxy.grantRole(proxy.ORACLE_ROLE(), PAYOUT_RECEIVER_PROXY);
            console.log("ORACLE_ROLE re-granted to PayoutReceiver");
        }

        vm.stopBroadcast();

        // Verify
        console.log("\n========== UPGRADE SUMMARY ==========");
        console.log("PolicyManager Proxy:      ", POLICY_MANAGER_PROXY);
        console.log("New PolicyManager Impl:   ", address(newPolicyManagerImpl));
        console.log("New PolicyNFT:            ", address(newPolicyNFT));
        console.log("MIN_SUM_INSURED:           100 USDC (was 10,000)");
        console.log("CoverageType:              0-4 (added EXCESS_RAIN, COMPREHENSIVE)");
        console.log("BACKEND_ROLE granted:      yes");
        console.log("======================================");
    }
}
