// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

/**
 * @title DeployRehearsalSepolia
 * @notice Upgrades the determination-path contracts on Base Sepolia (dev) for an
 *         end-to-end rehearsal of the signed-determination settlement loop:
 *           A. PayoutReceiver v2  — submitDetermination + audit fixes (Findings 2/7)
 *           B. PolicyManager      — PENDING-policy cap (Finding 5)
 *           B. PolicyNFT          — redeploy + rewire (SVG escaping, Finding 6; non-upgradeable)
 *         Treasury is unchanged and not touched.
 *
 * The broadcaster must hold UPGRADER_ROLE + ADMIN_ROLE + DEFAULT_ADMIN_ROLE on the
 * dev PayoutReceiver and PolicyManager proxies (the dev admin key).
 *
 * Env:
 *   DEV_AUTHORIZED_SIGNER  (optional) EVM address of the PKP that signs determinations.
 *                          Default = the conformance test PKP (0xF186…5ABE) for a
 *                          fixture-based rehearsal. Set to your DEV Lit PKP address for
 *                          a full-oracle rehearsal.
 *   DEV_RELAYER_WALLET     (required) the backend wallet that relays determinations
 *                          (gets RELAYER_ROLE). Fund it with Sepolia ETH.
 *
 * Usage:
 *   forge script script/DeployRehearsalSepolia.s.sol \
 *     --rpc-url base_sepolia --account deployer --broadcast --verify
 */
contract DeployRehearsalSepolia is Script {
    // Base Sepolia (dev) proxy addresses
    address constant PAYOUT_RECEIVER_PROXY = 0x1151621ed6A9830E36fd6b55878a775c824fabd0;
    address constant POLICY_MANAGER_PROXY = 0xDb6A11f23b8e357C0505359da4B3448d8EE5291C;

    // Deterministic conformance test PKP (keccak256("microcrop-test-pkp-v1")) — fixture rehearsal default.
    address constant TEST_PKP = 0xF18685788a4261DDA4f036D236066533a91C5ABE;

    function run() external {
        require(block.chainid == 84532, "Must run on Base Sepolia (chain 84532)");

        address authorizedSigner = vm.envOr("DEV_AUTHORIZED_SIGNER", TEST_PKP);
        address relayerWallet = vm.envAddress("DEV_RELAYER_WALLET");

        console.log("=== Determination-path rehearsal upgrade (Base Sepolia) ===");
        console.log("authorizedSigner:", authorizedSigner);
        console.log("relayerWallet:   ", relayerWallet);

        vm.startBroadcast();

        // ── A. PayoutReceiver v2 ──────────────────────────────────────────
        PayoutReceiver prImpl = new PayoutReceiver();
        console.log("PayoutReceiver impl:", address(prImpl));

        PayoutReceiver pr = PayoutReceiver(PAYOUT_RECEIVER_PROXY);
        pr.upgradeToAndCall(address(prImpl), "");
        require(keccak256(bytes(pr.version())) == keccak256(bytes("2.0.0")), "PayoutReceiver upgrade did not take");
        pr.setAuthorizedSigner(authorizedSigner);
        if (!pr.hasRole(pr.RELAYER_ROLE(), relayerWallet)) {
            pr.grantRole(pr.RELAYER_ROLE(), relayerWallet);
        }
        console.log("PayoutReceiver -> v2; authorizedSigner set; RELAYER_ROLE granted");

        // ── B. PolicyManager (PENDING-policy cap) ─────────────────────────
        PolicyManager pmImpl = new PolicyManager();
        console.log("PolicyManager impl:", address(pmImpl));

        PolicyManager pm = PolicyManager(POLICY_MANAGER_PROXY);
        pm.upgradeToAndCall(address(pmImpl), "");
        // Defensive: ensure PayoutReceiver still holds ORACLE_ROLE for markAsClaimed/claim counting.
        if (!pm.hasRole(pm.ORACLE_ROLE(), PAYOUT_RECEIVER_PROXY)) {
            pm.grantRole(pm.ORACLE_ROLE(), PAYOUT_RECEIVER_PROXY);
        }
        console.log("PolicyManager -> upgraded; ORACLE_ROLE confirmed");

        // ── B. PolicyNFT redeploy + rewire (non-upgradeable) ──────────────
        PolicyNFT nft = new PolicyNFT("MicroCrop Insurance Certificate", "mcINS");
        nft.grantRole(nft.MINTER_ROLE(), POLICY_MANAGER_PROXY);
        pm.setPolicyNFT(address(nft));
        // Reverse wiring: PolicyManager is the sole authority for status updates (Finding 6).
        nft.setPolicyManager(POLICY_MANAGER_PROXY);
        require(address(pm.policyNFT()) == address(nft), "setPolicyNFT rewire failed");
        require(nft.policyManager() == POLICY_MANAGER_PROXY, "setPolicyManager rewire failed");
        console.log("PolicyNFT redeployed + rewired:", address(nft));

        vm.stopBroadcast();

        console.log("\n=== Rehearsal upgrade complete ===");
        console.log("PayoutReceiver proxy:", PAYOUT_RECEIVER_PROXY);
        console.log("PolicyManager proxy: ", POLICY_MANAGER_PROXY);
        console.log("PolicyNFT (new):     ", address(nft));
        console.log("\nNext: fund the float (MockInsurer or USDC to Treasury), then drive a");
        console.log("determination through POST /api/internal/determinations on the dev backend.");
    }
}
