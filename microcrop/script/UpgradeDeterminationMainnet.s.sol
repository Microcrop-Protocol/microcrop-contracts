// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";

interface IRoleView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @title UpgradeDeterminationMainnet  (Batch A — determination rollout)
 * @notice Upgrades the LIVE Base-mainnet PayoutReceiver to v2 (submitDetermination +
 *         audit fixes), sets the production calculating-agent PKP as authorizedSigner,
 *         and grants RELAYER_ROLE to the backend relayer wallet. Highest-urgency batch.
 *
 * Must be signed by the current admin/upgrader 0xc5867d3b… (holds UPGRADER_ROLE +
 * ADMIN_ROLE + DEFAULT_ADMIN_ROLE on the PayoutReceiver proxy).
 *
 * PREREQUISITE: the production Lit PKP must be provisioned and its EVM address set in
 * PROD_AUTHORIZED_SIGNER. The script refuses to run without it, and refuses the
 * conformance TEST PKP, so the determination path can never go live with a test signer.
 *
 * Env (both required):
 *   PROD_AUTHORIZED_SIGNER  EVM address of the production PKP (!= test PKP)
 *   PROD_RELAYER_WALLET     backend wallet that relays determinations (gets RELAYER_ROLE)
 *
 * Usage:
 *   PROD_AUTHORIZED_SIGNER=0x… PROD_RELAYER_WALLET=0x… \
 *   forge script script/UpgradeDeterminationMainnet.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify
 */
contract UpgradeDeterminationMainnet is Script {
    address constant PAYOUT_RECEIVER_PROXY = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;

    // Deterministic conformance TEST PKP — must NEVER be the mainnet authorizedSigner.
    address constant TEST_PKP = 0xF18685788a4261DDA4f036D236066533a91C5ABE;

    function run() external {
        require(block.chainid == 8453, "Must run on Base Mainnet (chain 8453)");

        address authorizedSigner = vm.envAddress("PROD_AUTHORIZED_SIGNER");
        address relayerWallet = vm.envAddress("PROD_RELAYER_WALLET");
        require(authorizedSigner != address(0), "PROD_AUTHORIZED_SIGNER required");
        require(authorizedSigner != TEST_PKP, "Refusing to set the conformance TEST PKP on mainnet");

        console.log("=== Batch A: PayoutReceiver v2 (Base Mainnet) ===");
        console.log("authorizedSigner:", authorizedSigner);
        console.log("relayerWallet:   ", relayerWallet);

        vm.startBroadcast();

        PayoutReceiver prImpl = new PayoutReceiver();
        console.log("PayoutReceiver impl:", address(prImpl));

        PayoutReceiver pr = PayoutReceiver(PAYOUT_RECEIVER_PROXY);
        pr.upgradeToAndCall(address(prImpl), "");
        require(
            keccak256(bytes(pr.version())) == keccak256(bytes("2.0.0")),
            "PayoutReceiver upgrade did not take"
        );

        pr.setAuthorizedSigner(authorizedSigner);
        if (!pr.hasRole(pr.RELAYER_ROLE(), relayerWallet)) {
            pr.grantRole(pr.RELAYER_ROLE(), relayerWallet);
        }

        // Role survival — the upgrade must not have disturbed the grants in the other contracts.
        require(
            IRoleView(TREASURY).hasRole(keccak256("PAYOUT_ROLE"), PAYOUT_RECEIVER_PROXY),
            "PayoutReceiver lost PAYOUT_ROLE on Treasury"
        );
        require(
            IRoleView(POLICY_MANAGER).hasRole(keccak256("ORACLE_ROLE"), PAYOUT_RECEIVER_PROXY),
            "PayoutReceiver lost ORACLE_ROLE on PolicyManager"
        );

        vm.stopBroadcast();

        console.log("\n=== Batch A complete ===");
        console.log("PayoutReceiver -> v2; authorizedSigner set; RELAYER_ROLE granted; roles survived");
    }
}
