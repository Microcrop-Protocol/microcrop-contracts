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

interface ITreasuryV3 {
    function setPolicyManager(address _policyManager) external;
    function policyManager() external view returns (address);
}

/**
 * @title UpgradePerOrgTreasury  (v3 — per-org treasury)
 * @notice Upgrades the LIVE PolicyManager + Treasury proxies from 2.0.0 (Batch C,
 *         RiskPool-removed) to 3.0.0 (per-org treasury: solvency-enforced per-org
 *         reserves). Chain-aware: resolves the proxy set for Base mainnet (8453)
 *         or Base Sepolia (84532).
 *
 * Storage-layout-preserving UUPS upgrades (append-only / deprecate-in-place): no
 * initializer runs, live state is untouched. After the upgrades, the Treasury is
 * wired to the PolicyManager proxy via setPolicyManager so requestPayout can
 * resolve a policy's org and enforce its reserve requirement. PayoutReceiver is
 * unaffected and is NOT upgraded here.
 *
 * The broadcaster must hold, on the resolved chain:
 *   - UPGRADER_ROLE on BOTH proxies (to upgrade)
 *   - ADMIN_ROLE on the Treasury proxy (to call setPolicyManager)
 *   Base mainnet: the admin/upgrader 0xC5867D3b…  (run with --slow; EIP-7702 1-tx limit)
 *   Base Sepolia: the dev admin 0xC63ABe…2f8A8
 *
 * GATES (run before this): forge test green (incl. PerOrgFork mainnet-fork shadow run),
 * storage-layout diff confirmed append-only.
 *
 * AFTER this script (separate steps): run the backend backfill-legacy-policy-org
 * script to set each existing policy's org, then set per-org reserve ratios.
 *
 * Usage (Sepolia):
 *   forge script script/UpgradePerOrgTreasury.s.sol \
 *     --rpc-url base_sepolia --account deployer --broadcast --verify
 * Usage (mainnet):
 *   forge script script/UpgradePerOrgTreasury.s.sol \
 *     --rpc-url base_mainnet --account admin --broadcast --verify --slow
 */
contract UpgradePerOrgTreasury is Script {
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

        console.log("=== Per-org treasury (v3) upgrade:", net, "===");
        console.log("PolicyManager proxy:", pmProxy);
        console.log("Treasury proxy:     ", treasuryProxy);

        // Precondition: both proxies must currently be at 2.0.0 (Batch C).
        require(
            keccak256(bytes(IUUPS(pmProxy).version())) == keccak256(bytes("2.0.0")),
            "PolicyManager not at 2.0.0 (Batch C expected before v3)"
        );
        require(
            keccak256(bytes(IUUPS(treasuryProxy).version())) == keccak256(bytes("2.0.0")),
            "Treasury not at 2.0.0 (Batch C expected before v3)"
        );

        vm.startBroadcast();

        // ── Deploy new v3 implementations ──
        PolicyManager pmImpl = new PolicyManager();
        Treasury treasuryImpl = new Treasury();
        console.log("PolicyManager impl: ", address(pmImpl));
        console.log("Treasury impl:      ", address(treasuryImpl));

        // ── Storage-safe upgrades (no initializer — append-only) ──
        IUUPS(pmProxy).upgradeToAndCall(address(pmImpl), "");
        IUUPS(treasuryProxy).upgradeToAndCall(address(treasuryImpl), "");

        require(
            keccak256(bytes(IUUPS(pmProxy).version())) == keccak256(bytes("3.0.0")),
            "PolicyManager upgrade did not take"
        );
        require(
            keccak256(bytes(IUUPS(treasuryProxy).version())) == keccak256(bytes("3.0.0")),
            "Treasury upgrade did not take"
        );

        // ── v3 wiring: Treasury must know the PolicyManager to resolve a policy's org ──
        ITreasuryV3(treasuryProxy).setPolicyManager(pmProxy);
        require(
            ITreasuryV3(treasuryProxy).policyManager() == pmProxy,
            "Treasury.setPolicyManager did not take"
        );

        // ── Role survival: the upgrades must not disturb cross-contract grants ──
        require(
            IRoleView(treasuryProxy).hasRole(PAYOUT_ROLE, prProxy),
            "PayoutReceiver lost PAYOUT_ROLE on Treasury"
        );
        require(
            IRoleView(pmProxy).hasRole(ORACLE_ROLE, prProxy),
            "PayoutReceiver lost ORACLE_ROLE on PolicyManager"
        );

        vm.stopBroadcast();

        console.log("\n=== Per-org treasury (v3) upgrade complete ===");
        console.log("PolicyManager + Treasury -> 3.0.0; Treasury wired to PM; roles survived.");
        console.log("Next: run backend backfill-legacy-policy-org, then set per-org reserve ratios.");
    }

    function _resolve()
        internal
        view
        returns (address pm, address treasury, address pr, string memory net)
    {
        if (block.chainid == 8453) return (PM_MAINNET, TREASURY_MAINNET, PR_MAINNET, "Base Mainnet (8453)");
        if (block.chainid == 84532) return (PM_SEPOLIA, TREASURY_SEPOLIA, PR_SEPOLIA, "Base Sepolia (84532)");
        revert("Unsupported chain - use base_mainnet (8453) or base_sepolia (84532)");
    }
}
