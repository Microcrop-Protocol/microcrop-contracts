// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

/**
 * @title UpgradePilotReadinessMainnet  (Batch B — pilot-readiness)
 * @notice Two audit fixes that should land before real farmers, independent of Batch A:
 *           - PolicyManager upgrade: total-open (ACTIVE + PENDING) policy cap (Finding 5)
 *           - PolicyNFT redeploy + rewire: SVG '&' escaping (Finding 6; non-upgradeable)
 *         Does NOT touch the determination path. Can run before or after Batch A.
 *
 * Must be signed by the current admin/upgrader 0xc5867d3b… (UPGRADER_ROLE on the
 * PolicyManager proxy + ADMIN_ROLE to call setPolicyNFT).
 *
 * PRECONDITION: zero PENDING policies on-chain at upgrade time (the on-chain audit
 * showed _policyCounter == 0, so trivially true today; re-confirm before running).
 *
 * Usage:
 *   forge script script/UpgradePilotReadinessMainnet.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify
 */
contract UpgradePilotReadinessMainnet is Script {
    address constant POLICY_MANAGER_PROXY = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant PAYOUT_RECEIVER_PROXY = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;

    function run() external {
        require(block.chainid == 8453, "Must run on Base Mainnet (chain 8453)");

        console.log("=== Batch B: PolicyManager upgrade + PolicyNFT redeploy (Base Mainnet) ===");

        vm.startBroadcast();

        // ── PolicyManager upgrade (PENDING-policy cap) ────────────────────
        PolicyManager pmImpl = new PolicyManager();
        console.log("PolicyManager impl:", address(pmImpl));

        PolicyManager pm = PolicyManager(POLICY_MANAGER_PROXY);
        pm.upgradeToAndCall(address(pmImpl), "");
        // Defensive: PayoutReceiver must retain ORACLE_ROLE for markAsClaimed/claim counting.
        if (!pm.hasRole(pm.ORACLE_ROLE(), PAYOUT_RECEIVER_PROXY)) {
            pm.grantRole(pm.ORACLE_ROLE(), PAYOUT_RECEIVER_PROXY);
        }
        console.log("PolicyManager -> upgraded; ORACLE_ROLE confirmed");

        // ── PolicyNFT redeploy + rewire (non-upgradeable) ─────────────────
        // Name/symbol match the existing certificate. Previously minted NFTs keep the
        // old renderer; the audit showed zero live NFTs, so none are stranded.
        PolicyNFT nft = new PolicyNFT("MicroCrop Insurance Certificate", "mcINS");
        nft.grantRole(nft.MINTER_ROLE(), POLICY_MANAGER_PROXY);
        pm.setPolicyNFT(address(nft));
        require(address(pm.policyNFT()) == address(nft), "setPolicyNFT rewire failed");
        console.log("PolicyNFT redeployed + rewired:", address(nft));

        vm.stopBroadcast();

        console.log("\n=== Batch B complete ===");
        console.log("PolicyManager proxy:", POLICY_MANAGER_PROXY);
        console.log("PolicyNFT (new):    ", address(nft));
        console.log("VERIFY post-run: mint a policy whose name contains '&' and confirm tokenURI is valid.");
    }
}
