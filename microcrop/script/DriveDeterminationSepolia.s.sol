// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/**
 * @title DriveDeterminationSepolia  (Batch C — pool-free rehearsal, step 1)
 * @notice Creates and activates a policy on the LIVE Base-Sepolia PolicyManager
 *         using the pool-free Batch C flow (activatePolicy takes NO pool arg).
 *         Prints the on-chain policyId + the exact values the determination step
 *         must bind, so the oracle can sign a determination the live
 *         PayoutReceiver.submitDetermination will accept.
 *
 * Prereqs (all confirmed live on Sepolia): broadcaster holds BACKEND_ROLE on
 * PolicyManager; PolicyManager.policyNFT is set and holds MINTER_ROLE on it.
 *
 * Env (optional):
 *   DRIVE_SUM_INSURED  USDC base units (6dp). Default 100e6 (100 USDC).
 *   DRIVE_FARMER       policy owner address. Default a fixed test address.
 *
 * Usage:
 *   set -a && . ./.env.sepolia && set +a
 *   forge script script/DriveDeterminationSepolia.s.sol \
 *     --rpc-url base_sepolia --private-key "$PRIVATE_KEY" --broadcast
 */
contract DriveDeterminationSepolia is Script {
    address constant POLICY_MANAGER = 0xDb6A11f23b8e357C0505359da4B3448d8EE5291C;
    address constant PAYOUT_RECEIVER = 0x1151621ed6A9830E36fd6b55878a775c824fabd0;
    address constant DEFAULT_FARMER = 0xfa1200000000000000000000000000000000fA12;

    bytes32 constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    function run() external {
        require(block.chainid == 84532, "Must run on Base Sepolia (84532)");

        uint256 sumInsured = vm.envOr("DRIVE_SUM_INSURED", uint256(100_000_000)); // 100 USDC
        address farmer = vm.envOr("DRIVE_FARMER", DEFAULT_FARMER);
        address distributor = msg.sender; // the broadcaster (a valid non-zero EOA)

        PolicyManager pm = PolicyManager(POLICY_MANAGER);
        require(pm.hasRole(BACKEND_ROLE, msg.sender), "broadcaster lacks BACKEND_ROLE on PolicyManager");

        console.log("=== Drive determination (Base Sepolia) pool-free ===");
        console.log("farmer:    ", farmer);
        console.log("sumInsured:", sumInsured);

        vm.startBroadcast();

        // PENDING policy. premium=1 (1 base unit) keeps it cheap; duration 30 days.
        uint256 policyId = pm.createPolicy(farmer, 1, sumInsured, 1, 30, PolicyManager.CoverageType.DROUGHT);

        // Pool-free activation (Batch C): no pool arg. Mints the policy NFT.
        pm.activatePolicy(policyId, distributor, "RehearsalDist", "KE");

        vm.stopBroadcast();

        PolicyManager.Policy memory p = pm.getPolicy(policyId);
        require(p.status == PolicyManager.PolicyStatus.ACTIVE, "policy not ACTIVE");

        console.log("\n=== POLICY ACTIVE (pool-free) ===");
        console.log("onChainPolicyId:", policyId);
        console.log("sumInsured:     ", p.sumInsured);
        console.log("farmer:         ", p.farmer);
        console.log("endDate:        ", p.endDate);
        console.log("\n=== Bind these in the determination (oracle jsParams) ===");
        console.log("onChainPolicyId   =", policyId);
        console.log("sumInsured        =", p.sumInsured, "(must match exactly)");
        console.log("chainId           = 84532");
        console.log("verifyingContract =", PAYOUT_RECEIVER);
        console.log("methodologyVersion= crop-dualindex-1.0");
    }
}
