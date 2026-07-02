// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function version() external view returns (string memory);
}

interface IRoleView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ITreasuryAudit {
    function setPayoutReceiver(address _payoutReceiver) external;
    function payoutReceiver() external view returns (address);
}

interface IPolicyManagerAudit {
    function setPolicyNFT(address _policyNFT) external;
    function policyNFT() external view returns (address);
}

/**
 * @title UpgradeAuditBatchMainnet  (v3.1 — audit batch, PayoutReceiver EXCLUDED)
 * @notice Mainnet-only variant of UpgradeAuditBatch. Ships the audit fixes that live in
 *         PolicyManager, Treasury, and PolicyNFT, and does NOT touch PayoutReceiver.
 *
 * WHY THIS EXISTS: mainnet PayoutReceiver is still at 1.0.0 — the determination-settlement
 * upgrade (UpgradeDeterminationMainnet.s.sol → 2.0.0, which also wires PROD_AUTHORIZED_SIGNER)
 * was never applied on mainnet. Jumping it straight to 2.1.0 here would skip that signer
 * wiring and hasn't been validated as a single-step migration. PayoutReceiver's only audit
 * change is the minor ReportInFuture error, so it is deferred to a separate run once the
 * determination rollout decision is made. All material findings (#1-#8) are in the three
 * contracts this script does upgrade.
 *
 * What this does, in order:
 *   1. Upgrade the PolicyManager + Treasury UUPS proxies (storage-layout-preserving,
 *      append-only; no initializer, no migration — new slots default to correct zero state).
 *   2. Redeploy PolicyNFT (non-upgradeable) and rewire it (setPolicyNFT, grant MINTER_ROLE,
 *      and setPolicyManager for the Finding-6 authority).
 *   3. Call Treasury.setPayoutReceiver(existing PR proxy) so the Finding-4 caller-validation
 *      guard is ACTIVE. This only records the address; it works regardless of the PR version.
 *
 * Version gates: PolicyManager/Treasury 3.0.0 -> 3.1.0. PayoutReceiver is NOT gated or touched.
 *
 * The broadcaster must hold on Base mainnet:
 *   - UPGRADER_ROLE on the PolicyManager + Treasury proxies (to upgrade)
 *   - ADMIN_ROLE on PolicyManager (setPolicyNFT) and Treasury (setPayoutReceiver)
 *   (The broadcaster deploys the new PolicyNFT, so it is that contract's admin by construction.)
 *
 * GATES (run before this): forge test green; storage-layout diff confirmed append-only for
 * the PolicyManager + Treasury proxies.
 *
 * NOTE ON LIVE NFTs: PolicyNFT is redeployed at a NEW address; certificates minted on the
 * prior contract are NOT migrated. Confirm there are no live certificates that must survive
 * before running (the pilot-readiness runbook recorded zero).
 *
 * Usage:
 *   forge script script/UpgradeAuditBatchMainnet.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify --slow
 */
contract UpgradeAuditBatchMainnet is Script {
    // Base mainnet (8453)
    address constant PM_MAINNET = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY_MAINNET = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant PR_MAINNET = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;

    bytes32 constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");
    bytes32 constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    function run() external {
        require(block.chainid == 8453, "Mainnet-only (chain 8453); Sepolia is already fully upgraded");

        console.log("=== Audit batch (v3.1, PayoutReceiver excluded): Base Mainnet (8453) ===");
        console.log("PolicyManager proxy:  ", PM_MAINNET);
        console.log("Treasury proxy:       ", TREASURY_MAINNET);
        console.log("PayoutReceiver proxy: ", PR_MAINNET, "(NOT upgraded; stays at its current version)");

        // ── Preconditions: the two proxies we upgrade must be at the current live version ──
        require(
            keccak256(bytes(IUUPS(PM_MAINNET).version())) == keccak256(bytes("3.0.0")),
            "PolicyManager not at 3.0.0 (v3 expected before audit batch)"
        );
        require(
            keccak256(bytes(IUUPS(TREASURY_MAINNET).version())) == keccak256(bytes("3.0.0")),
            "Treasury not at 3.0.0 (v3 expected before audit batch)"
        );

        vm.startBroadcast();

        // ── 1. Deploy new implementations + storage-safe upgrades (no initializer) ──
        PolicyManager pmImpl = new PolicyManager();
        Treasury treasuryImpl = new Treasury();
        console.log("PolicyManager impl:   ", address(pmImpl));
        console.log("Treasury impl:        ", address(treasuryImpl));

        IUUPS(PM_MAINNET).upgradeToAndCall(address(pmImpl), "");
        IUUPS(TREASURY_MAINNET).upgradeToAndCall(address(treasuryImpl), "");

        require(
            keccak256(bytes(IUUPS(PM_MAINNET).version())) == keccak256(bytes("3.1.0")),
            "PolicyManager upgrade did not take"
        );
        require(
            keccak256(bytes(IUUPS(TREASURY_MAINNET).version())) == keccak256(bytes("3.1.0")),
            "Treasury upgrade did not take"
        );

        // ── 2. Redeploy PolicyNFT (non-upgradeable) + rewire ──
        PolicyNFT nft = new PolicyNFT("MicroCrop Insurance Certificate", "mcINS");
        IPolicyManagerAudit(PM_MAINNET).setPolicyNFT(address(nft));
        nft.grantRole(nft.MINTER_ROLE(), PM_MAINNET);
        // Finding 6: status updates are PolicyManager-only; wire the authority both ways.
        nft.setPolicyManager(PM_MAINNET);
        require(IPolicyManagerAudit(PM_MAINNET).policyNFT() == address(nft), "setPolicyNFT rewire failed");
        require(nft.policyManager() == PM_MAINNET, "setPolicyManager rewire failed");
        require(nft.hasRole(nft.MINTER_ROLE(), PM_MAINNET), "MINTER_ROLE grant failed");
        console.log("PolicyNFT redeployed + rewired:", address(nft));

        // ── 3. Finding 4: activate the requestPayout caller-validation guard ──
        //      Records the existing PayoutReceiver proxy as the sole authorized caller.
        //      Independent of the PR implementation version.
        ITreasuryAudit(TREASURY_MAINNET).setPayoutReceiver(PR_MAINNET);
        require(ITreasuryAudit(TREASURY_MAINNET).payoutReceiver() == PR_MAINNET, "Treasury.setPayoutReceiver did not take");

        // ── Role survival: upgrades must not disturb cross-contract grants ──
        require(IRoleView(TREASURY_MAINNET).hasRole(PAYOUT_ROLE, PR_MAINNET), "PayoutReceiver lost PAYOUT_ROLE on Treasury");
        require(IRoleView(PM_MAINNET).hasRole(ORACLE_ROLE, PR_MAINNET), "PayoutReceiver lost ORACLE_ROLE on PolicyManager");

        vm.stopBroadcast();

        console.log("\n=== Audit batch (mainnet, PayoutReceiver excluded) complete ===");
        console.log("PM+Treasury -> 3.1.0; PolicyNFT redeployed + rewired; payoutReceiver set (Finding 4 live).");
        console.log("PayoutReceiver left at its current version - upgrade it separately after the determination decision.");
    }
}
