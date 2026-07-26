// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";

interface IRoleView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @title UpgradePayoutReceiverV21Mainnet  (Pilot on-chain prep — Action 1 + 2)
 * @notice Upgrades the LIVE Base-mainnet PayoutReceiver proxy from v1.0.0 to v2.1.0
 *         (submitDetermination + audit batch 1-2 fixes) via the UUPS proxy, then wires the
 *         determination path: sets the PRODUCTION PKP as authorizedSigner and grants
 *         RELAYER_ROLE to the backend relayer wallet.
 *
 *         Step-by-step this script performs three on-chain effects, in order:
 *           (1) deploy a fresh PayoutReceiver v2.1.0 implementation
 *           (2) proxy.upgradeToAndCall(newImpl, "")   [UUPS; UPGRADER_ROLE gated]
 *           (3) proxy.setAuthorizedSigner(prodPKP)     [ADMIN_ROLE gated]
 *           (4) proxy.grantRole(RELAYER_ROLE, relayer) [DEFAULT_ADMIN_ROLE gated]
 *
 * MUST be signed by the current admin/upgrader EOA 0xc5867d3b114f10356baAb7b77e04783cfa947c44
 * (holds UPGRADER_ROLE + ADMIN_ROLE + DEFAULT_ADMIN_ROLE on the proxy). Run the admin-migration
 * script (MigrateAdminToSafeMainnet) AFTER this one so the migration doesn't strip the EOA of the
 * roles it needs here.
 *
 * IDEMPOTENCY / MONEY-PATH SAFETY:
 *   - The upgrade only swaps the implementation pointer; it does NOT touch policyPaid /
 *     consumedDetermination state, so no payout can be replayed or stranded by the upgrade.
 *   - setAuthorizedSigner is idempotent (last-write-wins on a single slot).
 *   - grantRole is guarded by hasRole so a re-run is a no-op, not a revert.
 *   - Post-upgrade asserts that PayoutReceiver retains PAYOUT_ROLE (Treasury) and ORACLE_ROLE
 *     (PolicyManager); without them the FIRST real determination would revert mid-payout.
 *
 * PREREQUISITE: the production Lit PKP must be provisioned and its EVM address set in
 * PROD_AUTHORIZED_SIGNER. The script refuses to run without it, and refuses the deterministic
 * conformance TEST PKP, so the determination path can never go live with a test signer.
 *
 * Env (both required):
 *   PROD_AUTHORIZED_SIGNER  EVM address of the production PKP (!= test PKP, != zero)
 *   PROD_RELAYER_WALLET     backend wallet that relays determinations (gets RELAYER_ROLE)
 *
 * FORK DRY-RUN (NO broadcast):
 *   PROD_AUTHORIZED_SIGNER=0x<prodPKP> PROD_RELAYER_WALLET=0x<relayer> \
 *   forge script script/UpgradePayoutReceiverV21Mainnet.s.sol \
 *     --rpc-url "$BASE_MAINNET_RPC_URL"
 *
 * MAINNET EXECUTION (human-run; adds --broadcast --verify + the admin keystore):
 *   PROD_AUTHORIZED_SIGNER=0x<prodPKP> PROD_RELAYER_WALLET=0x<relayer> \
 *   forge script script/UpgradePayoutReceiverV21Mainnet.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify
 */
contract UpgradePayoutReceiverV21Mainnet is Script {
    address constant PAYOUT_RECEIVER_PROXY = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;

    // Target version after the upgrade — asserted so a stale/mismatched impl can never "take".
    string constant TARGET_VERSION = "2.1.0";

    // Deterministic conformance TEST PKP — must NEVER be the mainnet authorizedSigner.
    address constant TEST_PKP = 0xF18685788a4261DDA4f036D236066533a91C5ABE;

    function run() external {
        require(block.chainid == 8453, "Must run on Base Mainnet (chain 8453)");

        address authorizedSigner = vm.envAddress("PROD_AUTHORIZED_SIGNER");
        address relayerWallet = vm.envAddress("PROD_RELAYER_WALLET");
        require(authorizedSigner != address(0), "PROD_AUTHORIZED_SIGNER required");
        require(relayerWallet != address(0), "PROD_RELAYER_WALLET required");
        require(authorizedSigner != TEST_PKP, "Refusing to set the conformance TEST PKP on mainnet");

        PayoutReceiver pr = PayoutReceiver(PAYOUT_RECEIVER_PROXY);

        console.log("=== Pilot Action 1+2: PayoutReceiver v1.0.0 -> v2.1.0 (Base Mainnet) ===");
        console.log("proxy:            ", PAYOUT_RECEIVER_PROXY);
        console.log("version (before): ", pr.version());
        console.log("authorizedSigner: ", authorizedSigner);
        console.log("relayerWallet:    ", relayerWallet);

        vm.startBroadcast();

        // (1) deploy new implementation
        PayoutReceiver prImpl = new PayoutReceiver();
        console.log("new impl:         ", address(prImpl));

        // (2) UUPS upgrade — empty calldata: no reinitializer, v2.1.0 appends storage only.
        pr.upgradeToAndCall(address(prImpl), "");
        require(
            keccak256(bytes(pr.version())) == keccak256(bytes(TARGET_VERSION)),
            "PayoutReceiver upgrade did not take (version != 2.1.0)"
        );

        // (3) set the production PKP authority root
        pr.setAuthorizedSigner(authorizedSigner);
        require(pr.authorizedSigner() == authorizedSigner, "authorizedSigner not set");

        // (4) grant RELAYER_ROLE (anti-spam gate) to the backend relayer — idempotent
        if (!pr.hasRole(pr.RELAYER_ROLE(), relayerWallet)) {
            pr.grantRole(pr.RELAYER_ROLE(), relayerWallet);
        }
        require(pr.hasRole(pr.RELAYER_ROLE(), relayerWallet), "RELAYER_ROLE not granted");

        // Role survival — the upgrade must not have disturbed the money-path grants elsewhere.
        require(
            IRoleView(TREASURY).hasRole(keccak256("PAYOUT_ROLE"), PAYOUT_RECEIVER_PROXY),
            "PayoutReceiver lost PAYOUT_ROLE on Treasury"
        );
        require(
            IRoleView(POLICY_MANAGER).hasRole(keccak256("ORACLE_ROLE"), PAYOUT_RECEIVER_PROXY),
            "PayoutReceiver lost ORACLE_ROLE on PolicyManager"
        );

        vm.stopBroadcast();

        console.log("version (after):  ", pr.version());
        console.log("=== Action 1+2 complete: v2.1.0; authorizedSigner set; RELAYER_ROLE granted; roles survived ===");
    }
}
