// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
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
 * @title UpgradeAuditBatch  (v3.1 — security audit batches 1 & 2)
 * @notice Ships the security-audit fixes to the LIVE deployment in one run. Chain-aware:
 *         resolves the proxy set for Base mainnet (8453) or Base Sepolia (84532).
 *
 * What this does, in order:
 *   1. Upgrade the three UUPS proxies (PolicyManager, Treasury, PayoutReceiver) to new
 *      implementations. These are storage-layout-preserving, append-only upgrades — no
 *      initializer runs and live state is untouched. New storage slots (orgFeeSet,
 *      orgRatioSet, payoutReceiver, _pendingCounted) default to zero/false, which is the
 *      correct initial state, so no migration or reinitializer is required.
 *   2. Redeploy PolicyNFT (non-upgradeable ERC721 — it cannot be upgraded in place) and
 *      rewire it: PolicyManager.setPolicyNFT, grant MINTER_ROLE to PolicyManager, and the
 *      new PolicyNFT.setPolicyManager (Finding 6 — status updates are PolicyManager-only).
 *   3. Wire Treasury.setPayoutReceiver so the Finding-4 caller-validation guard is ACTIVE
 *      (until set, payoutReceiver == address(0) and the guard is skipped).
 *
 * Version gates: proxies must be at their pre-upgrade versions before, and their audit-fix
 * versions after (PolicyManager/Treasury 3.0.0 -> 3.1.0, PayoutReceiver 2.0.0 -> 2.1.0).
 *
 * The broadcaster must hold, on the resolved chain:
 *   - UPGRADER_ROLE on all three proxies (to upgrade)
 *   - ADMIN_ROLE on the PolicyManager proxy (setPolicyNFT) and Treasury proxy (setPayoutReceiver)
 *   (The broadcaster deploys the new PolicyNFT, so it is that contract's admin by construction.)
 *
 * GATES (run before this): forge test green (incl. PerOrgFork mainnet-fork shadow run);
 * storage-layout diff confirmed append-only for all three proxies.
 *
 * NOTE ON LIVE NFTs: PolicyNFT is redeployed at a NEW address; certificates minted on the
 * prior contract are NOT migrated. Confirm there are no live certificates that must survive
 * before running on mainnet (the pilot-readiness runbook recorded zero).
 *
 * Usage (Sepolia):
 *   forge script script/UpgradeAuditBatch.s.sol \
 *     --rpc-url base_sepolia --account deployer --broadcast --verify
 * Usage (mainnet):
 *   forge script script/UpgradeAuditBatch.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify --slow
 */
contract UpgradeAuditBatch is Script {
    // Base mainnet (8453)
    address constant PM_MAINNET = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY_MAINNET = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant PR_MAINNET = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;

    // Base Sepolia (84532)
    address constant PM_SEPOLIA = 0xDb6A11f23b8e357C0505359da4B3448d8EE5291C;
    address constant TREASURY_SEPOLIA = 0x6B04966167C74e577D9d750BE1055Fa4d25C270c;
    address constant PR_SEPOLIA = 0x1151621ed6A9830E36fd6b55878a775c824fabd0;

    bytes32 constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");
    bytes32 constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    function run() external {
        (address pmProxy, address treasuryProxy, address prProxy, string memory net) = _resolve();

        console.log("=== Security audit batch (v3.1) upgrade:", net, "===");
        console.log("PolicyManager proxy:  ", pmProxy);
        console.log("Treasury proxy:       ", treasuryProxy);
        console.log("PayoutReceiver proxy: ", prProxy);

        // ── Preconditions: proxies must be at their current live versions ──
        require(
            keccak256(bytes(IUUPS(pmProxy).version())) == keccak256(bytes("3.0.0")),
            "PolicyManager not at 3.0.0 (v3 expected before audit batch)"
        );
        require(
            keccak256(bytes(IUUPS(treasuryProxy).version())) == keccak256(bytes("3.0.0")),
            "Treasury not at 3.0.0 (v3 expected before audit batch)"
        );
        require(
            keccak256(bytes(IUUPS(prProxy).version())) == keccak256(bytes("2.0.0")),
            "PayoutReceiver not at 2.0.0 (expected before audit batch)"
        );

        vm.startBroadcast();

        // ── 1. Deploy new implementations + storage-safe upgrades (no initializer) ──
        PolicyManager pmImpl = new PolicyManager();
        Treasury treasuryImpl = new Treasury();
        PayoutReceiver prImpl = new PayoutReceiver();
        console.log("PolicyManager impl:   ", address(pmImpl));
        console.log("Treasury impl:        ", address(treasuryImpl));
        console.log("PayoutReceiver impl:  ", address(prImpl));

        IUUPS(pmProxy).upgradeToAndCall(address(pmImpl), "");
        IUUPS(treasuryProxy).upgradeToAndCall(address(treasuryImpl), "");
        IUUPS(prProxy).upgradeToAndCall(address(prImpl), "");

        require(
            keccak256(bytes(IUUPS(pmProxy).version())) == keccak256(bytes("3.1.0")),
            "PolicyManager upgrade did not take"
        );
        require(
            keccak256(bytes(IUUPS(treasuryProxy).version())) == keccak256(bytes("3.1.0")),
            "Treasury upgrade did not take"
        );
        require(
            keccak256(bytes(IUUPS(prProxy).version())) == keccak256(bytes("2.1.0")),
            "PayoutReceiver upgrade did not take"
        );

        // ── 2. Redeploy PolicyNFT (non-upgradeable) + rewire ──
        PolicyNFT nft = new PolicyNFT("MicroCrop Insurance Certificate", "mcINS");
        IPolicyManagerAudit(pmProxy).setPolicyNFT(address(nft));
        nft.grantRole(nft.MINTER_ROLE(), pmProxy);
        // Finding 6: status updates are PolicyManager-only; wire the authority both ways.
        nft.setPolicyManager(pmProxy);
        require(IPolicyManagerAudit(pmProxy).policyNFT() == address(nft), "setPolicyNFT rewire failed");
        require(nft.policyManager() == pmProxy, "setPolicyManager rewire failed");
        require(nft.hasRole(nft.MINTER_ROLE(), pmProxy), "MINTER_ROLE grant failed");
        console.log("PolicyNFT redeployed + rewired:", address(nft));

        // ── 3. Finding 4: activate the requestPayout caller-validation guard ──
        ITreasuryAudit(treasuryProxy).setPayoutReceiver(prProxy);
        require(ITreasuryAudit(treasuryProxy).payoutReceiver() == prProxy, "Treasury.setPayoutReceiver did not take");

        // ── Role survival: upgrades must not disturb cross-contract grants ──
        require(IRoleView(treasuryProxy).hasRole(PAYOUT_ROLE, prProxy), "PayoutReceiver lost PAYOUT_ROLE on Treasury");
        require(IRoleView(pmProxy).hasRole(ORACLE_ROLE, prProxy), "PayoutReceiver lost ORACLE_ROLE on PolicyManager");

        vm.stopBroadcast();

        console.log("\n=== Security audit batch (v3.1) upgrade complete ===");
        console.log("PM+Treasury -> 3.1.0, PayoutReceiver -> 2.1.0; PolicyNFT redeployed + rewired;");
        console.log("Treasury.payoutReceiver set (Finding 4 guard active); roles survived.");
    }

    function _resolve() internal view returns (address pm, address treasury, address pr, string memory net) {
        if (block.chainid == 8453) return (PM_MAINNET, TREASURY_MAINNET, PR_MAINNET, "Base Mainnet (8453)");
        if (block.chainid == 84532) return (PM_SEPOLIA, TREASURY_SEPOLIA, PR_SEPOLIA, "Base Sepolia (84532)");
        revert("Unsupported chain - use base_mainnet (8453) or base_sepolia (84532)");
    }
}
