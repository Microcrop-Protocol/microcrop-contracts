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

interface ITreasuryWiring {
    function policyManager() external view returns (address);
    function payoutReceiver() external view returns (address);
}

/**
 * @title UpgradeAuditV32  (PolicyManager + Treasury 3.1.0 -> 3.2.0)
 * @notice Ships audit findings 8, 10, 11, 12 to the LIVE PolicyManager and Treasury proxies.
 *         Chain-aware: Base mainnet (8453) or Base Sepolia (84532). PayoutReceiver and PolicyNFT
 *         are untouched.
 *
 *   - PolicyManager 3.2.0: rolling 365-day claim window (finding 8); MAX_ACTIVE_POLICIES_PER_FARMER
 *     5 -> 3 (finding 8, PRODUCT-RULE CHANGE); org exposure counted at createPolicy and released on
 *     PENDING cancel (finding 10).
 *   - Treasury 3.2.0: receivePremium only for PENDING/ACTIVE policies (finding 11); reserve ratio
 *     default 20% -> 30% and floor 30% (finding 12).
 *
 * Storage: append-only. PolicyManager appends `_recentClaimTimestamps` (slot 12) and
 * `_exposureCounted` (slot 13), __gap 43 -> 41. Treasury layout is unchanged. Both new mappings
 * default to empty/false, which is the correct starting state, so no initializer or migration runs:
 *   - PENDING policies created before the upgrade have `_exposureCounted == false`; activation adds
 *     their exposure once, and cancelling them releases nothing. At the time of writing mainnet has
 *     0 policies and Sepolia 1 (CLAIMED), so no live policy takes the legacy path.
 *   - Claims paid before the upgrade are NOT counted in the rolling window (it starts empty).
 *   - Any org whose ratio was explicitly set below 3000 bps keeps that stored value but is clamped
 *     to 3000 when applied (effectiveReserveRatioBps).
 *
 * Order: either proxy may go first. Treasury 3.2.0 reads PolicyManager.getPolicy, which every
 * deployed PolicyManager version already has.
 *
 * The broadcaster must hold UPGRADER_ROLE on both proxies.
 *
 * GATES (run before this): forge test green (incl. PerOrgFork mainnet-fork shadow run);
 * `forge inspect PolicyManager storageLayout` / `forge inspect Treasury storageLayout` diffed
 * against the deployed 3.1.0 source: append-only.
 *
 * Usage (Sepolia):
 *   forge script script/UpgradeAuditV32.s.sol --rpc-url base_sepolia --account deployer --broadcast --verify
 * Usage (mainnet):
 *   forge script script/UpgradeAuditV32.s.sol --rpc-url base_mainnet --account admin --broadcast --verify --slow
 */
contract UpgradeAuditV32 is Script {
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

        console.log("=== Audit batch v3.2.0 upgrade:", net, "===");
        console.log("PolicyManager proxy:  ", pmProxy);
        console.log("Treasury proxy:       ", treasuryProxy);

        require(_is(pmProxy, "3.1.0"), "PolicyManager not at 3.1.0");
        require(_is(treasuryProxy, "3.1.0"), "Treasury not at 3.1.0");
        address wiredPm = ITreasuryWiring(treasuryProxy).policyManager();
        address wiredPr = ITreasuryWiring(treasuryProxy).payoutReceiver();

        vm.startBroadcast();

        PolicyManager pmImpl = new PolicyManager();
        Treasury treasuryImpl = new Treasury();
        console.log("PolicyManager impl:   ", address(pmImpl));
        console.log("Treasury impl:        ", address(treasuryImpl));

        IUUPS(pmProxy).upgradeToAndCall(address(pmImpl), "");
        IUUPS(treasuryProxy).upgradeToAndCall(address(treasuryImpl), "");

        vm.stopBroadcast();

        require(_is(pmProxy, "3.2.0"), "PolicyManager upgrade did not take");
        require(_is(treasuryProxy, "3.2.0"), "Treasury upgrade did not take");

        // Wiring + cross-contract roles must survive the upgrade.
        require(ITreasuryWiring(treasuryProxy).policyManager() == wiredPm, "Treasury.policyManager changed");
        require(ITreasuryWiring(treasuryProxy).payoutReceiver() == wiredPr, "Treasury.payoutReceiver changed");
        require(IRoleView(treasuryProxy).hasRole(PAYOUT_ROLE, prProxy), "PayoutReceiver lost PAYOUT_ROLE");
        require(IRoleView(pmProxy).hasRole(ORACLE_ROLE, prProxy), "PayoutReceiver lost ORACLE_ROLE");

        console.log("\n=== PolicyManager + Treasury -> 3.2.0; wiring and roles survived ===");
    }

    function _is(address proxy, string memory v) internal view returns (bool) {
        return keccak256(bytes(IUUPS(proxy).version())) == keccak256(bytes(v));
    }

    function _resolve() internal view returns (address pm, address treasury, address pr, string memory net) {
        if (block.chainid == 8453) return (PM_MAINNET, TREASURY_MAINNET, PR_MAINNET, "Base Mainnet (8453)");
        if (block.chainid == 84532) return (PM_SEPOLIA, TREASURY_SEPOLIA, PR_SEPOLIA, "Base Sepolia (84532)");
        revert("Unsupported chain - use base_mainnet (8453) or base_sepolia (84532)");
    }
}
