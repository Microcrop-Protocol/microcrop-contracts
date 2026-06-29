// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function version() external view returns (string memory);
}

interface IRoleView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @title UpgradeBatchC  (Batch C — RiskPool removal & Treasury narrowing)
 * @notice Upgrades the LIVE PolicyManager + Treasury proxies to the Batch C
 *         (RiskPool-removed) implementations. Chain-aware: resolves the right
 *         proxy set for Base mainnet (8453) or Base Sepolia (84532).
 *
 * These are storage-layout-preserving UUPS upgrades (deprecate-in-place): the
 * removed pool storage slots are retained as `__deprecated_*`, so NO initializer
 * runs and live state is untouched. PayoutReceiver is unaffected by Batch C and
 * is NOT upgraded here.
 *
 * The broadcaster must hold UPGRADER_ROLE on BOTH proxies:
 *   - Base mainnet: the current admin/upgrader (0xc5867d3b…)
 *   - Base Sepolia: the dev admin 0xC63ABe…2f8A8
 *
 * GATES (run before this): storage-layout diff byte-identical, forge test green,
 * mainnet-fork shadow-run (BatchCFork.t.sol) green, capital wind-down re-confirmed.
 *
 * Usage (Sepolia):
 *   forge script script/UpgradeBatchC.s.sol \
 *     --rpc-url base_sepolia --account dev --broadcast --verify
 * Usage (mainnet):
 *   forge script script/UpgradeBatchC.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify
 */
contract UpgradeBatchC is Script {
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

        console.log("=== Batch C upgrade:", net, "===");
        console.log("PolicyManager proxy:", pmProxy);
        console.log("Treasury proxy:     ", treasuryProxy);

        vm.startBroadcast();

        // ── Deploy new implementations ──
        PolicyManager pmImpl = new PolicyManager();
        Treasury treasuryImpl = new Treasury();
        console.log("PolicyManager impl: ", address(pmImpl));
        console.log("Treasury impl:      ", address(treasuryImpl));

        // ── Storage-safe upgrades (no initializer — deprecate-in-place) ──
        IUUPS(pmProxy).upgradeToAndCall(address(pmImpl), "");
        IUUPS(treasuryProxy).upgradeToAndCall(address(treasuryImpl), "");

        require(
            keccak256(bytes(IUUPS(pmProxy).version())) == keccak256(bytes("2.0.0")),
            "PolicyManager upgrade did not take"
        );
        require(
            keccak256(bytes(IUUPS(treasuryProxy).version())) == keccak256(bytes("2.0.0")),
            "Treasury upgrade did not take"
        );

        // ── Role survival: the upgrades must not disturb cross-contract grants ──
        require(IRoleView(treasuryProxy).hasRole(PAYOUT_ROLE, prProxy), "PayoutReceiver lost PAYOUT_ROLE on Treasury");
        require(IRoleView(pmProxy).hasRole(ORACLE_ROLE, prProxy), "PayoutReceiver lost ORACLE_ROLE on PolicyManager");

        vm.stopBroadcast();

        console.log("\n=== Batch C complete ===");
        console.log("PolicyManager + Treasury -> 2.0.0 (RiskPool removed); roles survived.");
        console.log("activatePolicy is now pool-free; remove the backend factory binding next.");
    }

    function _resolve() internal view returns (address pm, address treasury, address pr, string memory net) {
        if (block.chainid == 8453) return (PM_MAINNET, TREASURY_MAINNET, PR_MAINNET, "Base Mainnet (8453)");
        if (block.chainid == 84532) return (PM_SEPOLIA, TREASURY_SEPOLIA, PR_SEPOLIA, "Base Sepolia (84532)");
        revert("Unsupported chain - use base_mainnet (8453) or base_sepolia (84532)");
    }
}
