// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";

interface IAccessControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
}

/**
 * @title MigrateAdminToSafeMainnet  (Pilot on-chain prep — Action 3)
 * @notice Migrates DEFAULT_ADMIN_ROLE + UPGRADER_ROLE (+ ADMIN_ROLE) on the LIVE Base-mainnet
 *         PayoutReceiver off the single EOA 0xc5867d3b… onto a governance owner, using the
 *         standard OpenZeppelin grant-then-renounce pattern:
 *
 *           for each role R in {DEFAULT_ADMIN_ROLE, UPGRADER_ROLE, ADMIN_ROLE}:
 *             1. proxy.grantRole(R, GOV_OWNER)          // add the new holder
 *             2. proxy.renounceRole(R, EOA)             // EOA drops its own copy
 *
 *         GOV_OWNER is intended to be a TimelockController whose sole proposer/executor is a
 *         Gnosis Safe (Safe -> Timelock -> contract). Upgrades then require a Safe multisig
 *         proposal that must age through the timelock delay before it can execute — no single
 *         key can push an implementation swap.
 *
 * ORDERING vs Action 1+2 (HARD REQUIREMENT):
 *   Run the PayoutReceiver v2.1.0 upgrade + setAuthorizedSigner + grantRole FIRST, while the EOA
 *   still holds UPGRADER_ROLE/ADMIN_ROLE. Running THIS script first would strip the EOA of the
 *   very roles the upgrade needs. This script asserts version()==2.1.0 as a guard so it cannot be
 *   run against the un-upgraded v1.0.0 proxy by mistake.
 *
 * SAFETY:
 *   - Renounce is LAST and per-role, AFTER the grant to GOV_OWNER is confirmed on-chain, so the
 *     contract is never left with zero admins (which would permanently freeze upgrades).
 *   - Guarded grants are idempotent; renounce is only attempted if the EOA still holds the role.
 *   - This script does NOT deploy the Safe or the TimelockController — those are stood up out of
 *     band (see the runbook). GOV_OWNER is passed in as the already-deployed timelock address.
 *
 * Env (required):
 *   GOV_OWNER   the TimelockController (or Safe) address that will hold admin + upgrader
 *
 * FORK DRY-RUN (NO broadcast):
 *   GOV_OWNER=0x<timelock> \
 *   forge script script/MigrateAdminToSafeMainnet.s.sol \
 *     --rpc-url "$BASE_MAINNET_RPC_URL"
 *
 * MAINNET EXECUTION (human-run; adds --broadcast + the admin keystore):
 *   GOV_OWNER=0x<timelock> \
 *   forge script script/MigrateAdminToSafeMainnet.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast
 */
contract MigrateAdminToSafeMainnet is Script {
    address constant PAYOUT_RECEIVER_PROXY = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;

    // The single EOA being retired as admin/upgrader.
    address constant ADMIN_EOA = 0xC5867D3b114f10356bAAb7b77E04783cfA947c44;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    function run() external {
        require(block.chainid == 8453, "Must run on Base Mainnet (chain 8453)");

        address govOwner = vm.envAddress("GOV_OWNER");
        require(govOwner != address(0), "GOV_OWNER required");
        require(govOwner != ADMIN_EOA, "GOV_OWNER must differ from the EOA being retired");

        IAccessControl acl = IAccessControl(PAYOUT_RECEIVER_PROXY);
        PayoutReceiver pr = PayoutReceiver(PAYOUT_RECEIVER_PROXY);

        // Guard: refuse to migrate an un-upgraded proxy — the upgrade must land first.
        require(
            keccak256(bytes(pr.version())) == keccak256(bytes("2.1.0")),
            "Run the v2.1.0 upgrade BEFORE migrating admin (version != 2.1.0)"
        );
        // Sanity: the signer of this script must currently be able to grant/renounce.
        require(acl.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA), "EOA no longer holds DEFAULT_ADMIN_ROLE");

        console.log("=== Pilot Action 3: migrate admin/upgrader EOA -> governance (Base Mainnet) ===");
        console.log("proxy:    ", PAYOUT_RECEIVER_PROXY);
        console.log("EOA (out):", ADMIN_EOA);
        console.log("GOV_OWNER:", govOwner);

        vm.startBroadcast();

        // ---- grant all three roles to the governance owner (idempotent) ----
        if (!acl.hasRole(DEFAULT_ADMIN_ROLE, govOwner)) acl.grantRole(DEFAULT_ADMIN_ROLE, govOwner);
        if (!acl.hasRole(UPGRADER_ROLE, govOwner)) acl.grantRole(UPGRADER_ROLE, govOwner);
        if (!acl.hasRole(ADMIN_ROLE, govOwner)) acl.grantRole(ADMIN_ROLE, govOwner);

        // Confirm the new holder is fully wired BEFORE the EOA drops anything.
        require(acl.hasRole(DEFAULT_ADMIN_ROLE, govOwner), "grant DEFAULT_ADMIN_ROLE failed");
        require(acl.hasRole(UPGRADER_ROLE, govOwner), "grant UPGRADER_ROLE failed");
        require(acl.hasRole(ADMIN_ROLE, govOwner), "grant ADMIN_ROLE failed");

        // ---- EOA renounces its own copies (renounce, not revoke: only self) ----
        // Renounce UPGRADER/ADMIN first, DEFAULT_ADMIN last: DEFAULT_ADMIN is the role-admin for
        // the others, so keep it until the end in case a grant needs re-issuing on a partial run.
        if (acl.hasRole(UPGRADER_ROLE, ADMIN_EOA)) acl.renounceRole(UPGRADER_ROLE, ADMIN_EOA);
        if (acl.hasRole(ADMIN_ROLE, ADMIN_EOA)) acl.renounceRole(ADMIN_ROLE, ADMIN_EOA);
        if (acl.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA)) acl.renounceRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA);

        vm.stopBroadcast();

        // ---- final invariants: EOA fully out, governance fully in ----
        require(!acl.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA), "EOA still has DEFAULT_ADMIN_ROLE");
        require(!acl.hasRole(UPGRADER_ROLE, ADMIN_EOA), "EOA still has UPGRADER_ROLE");
        require(!acl.hasRole(ADMIN_ROLE, ADMIN_EOA), "EOA still has ADMIN_ROLE");
        require(acl.hasRole(DEFAULT_ADMIN_ROLE, govOwner), "GOV_OWNER missing DEFAULT_ADMIN_ROLE");
        require(acl.hasRole(UPGRADER_ROLE, govOwner), "GOV_OWNER missing UPGRADER_ROLE");

        console.log("=== Action 3 complete: EOA renounced; %s now holds admin + upgrader ===", govOwner);
    }
}
