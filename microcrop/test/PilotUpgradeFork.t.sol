// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";

interface IAccessControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
}

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice FORK dry-run proving the pilot on-chain prep works against LIVE Base-mainnet state,
///         with NO broadcast. Impersonates the REAL admin/upgrader EOA (0xc5867d3b…) — no cheat
///         storage writes for the roles under test — and runs the exact sequence the scripts run:
///
///   Action 1: proxy is v1.0.0 pre-upgrade; deploy v2.1.0 impl; upgradeToAndCall; assert v2.1.0.
///   Action 2: setAuthorizedSigner(prodPKP) + grantRole(RELAYER_ROLE, relayer); assert AFTER upgrade.
///   Action 3: grant DEFAULT_ADMIN/UPGRADER/ADMIN to a mock timelock, EOA renounces; assert handover.
///   Money-path: after the FULL sequence, a PKP-signed determination still settles a payout end to
///               end (proves the upgrade preserved PAYOUT_ROLE/ORACLE_ROLE and idempotency state).
///
/// Run: forge test --match-path test/PilotUpgradeFork.t.sol -vvv --fork-url "$BASE_MAINNET_RPC_URL"
///  (or set BASE_MAINNET_RPC_URL and: forge test --match-path test/PilotUpgradeFork.t.sol -vvv)
contract PilotUpgradeForkTest is Test {
    address constant PAYOUT_RECEIVER = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Live admin/upgrader EOA on the proxy (verified via cast: holds DEFAULT_ADMIN/UPGRADER/ADMIN).
    address constant ADMIN_EOA = 0xC5867D3b114f10356bAAb7b77E04783cfA947c44;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    bytes32 constant ACL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    // Production PKP placeholder for the fork run — a deterministic, non-test key.
    uint256 constant PROD_PK = uint256(keccak256("microcrop-PROD-pkp-fork-dryrun"));

    PayoutReceiver pr;
    address prodSigner;
    address relayer = address(0xBEEF);
    address timelock = address(0x71E10C); // stands in for the Gnosis-Safe-owned TimelockController

    function setUp() public {
        // Fork Base mainnet. Prefers BASE_MAINNET_RPC_URL; falls back to the public endpoint so the
        // dry-run works even without a configured secret.
        string memory rpc = vm.envOr("BASE_MAINNET_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc);
        pr = PayoutReceiver(PAYOUT_RECEIVER);
        prodSigner = vm.addr(PROD_PK);
    }

    /// @notice ACTION 1: the live proxy is v1.0.0 and the upgrade lifts it to v2.1.0.
    function test_action1_upgrade_v1_to_v21() public {
        assertEq(pr.version(), "1.0.0", "fork precondition: live proxy should be v1.0.0");

        vm.startPrank(ADMIN_EOA);
        PayoutReceiver impl = new PayoutReceiver();
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(impl), "");
        vm.stopPrank();

        assertEq(pr.version(), "2.1.0", "version() must read 2.1.0 after the upgrade");
    }

    /// @notice ACTION 2: authorizedSigner is UNSET before the upgrade (fn reverts on v1) and is set
    ///         to the prod PKP AFTER; RELAYER_ROLE is granted to the backend relayer.
    function test_action2_setSignerAndRelayer_afterUpgrade() public {
        // Pre-upgrade: authorizedSigner() does not exist on v1 -> low-level call fails.
        (bool okBefore,) = PAYOUT_RECEIVER.staticcall(abi.encodeWithSignature("authorizedSigner()"));
        assertFalse(okBefore, "v1 must not expose authorizedSigner()");

        vm.startPrank(ADMIN_EOA);
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(new PayoutReceiver()), "");

        // AFTER the upgrade: signer defaults to zero, then we set it to the prod PKP.
        assertEq(pr.authorizedSigner(), address(0), "authorizedSigner should default to 0 post-upgrade");
        pr.setAuthorizedSigner(prodSigner);
        pr.grantRole(RELAYER_ROLE, relayer);
        vm.stopPrank();

        assertEq(pr.authorizedSigner(), prodSigner, "authorizedSigner must be the prod PKP after set");
        assertTrue(pr.hasRole(RELAYER_ROLE, relayer), "relayer must hold RELAYER_ROLE");
    }

    /// @notice ACTION 3: grant-then-renounce moves DEFAULT_ADMIN + UPGRADER + ADMIN from the EOA to
    ///         the timelock; the EOA ends with none, the timelock with all.
    function test_action3_migrateAdminToTimelock() public {
        // Must upgrade first (the migration script guards on version()==2.1.0).
        vm.startPrank(ADMIN_EOA);
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(new PayoutReceiver()), "");

        IAccessControl acl = IAccessControl(PAYOUT_RECEIVER);
        acl.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        acl.grantRole(UPGRADER_ROLE, timelock);
        acl.grantRole(ADMIN_ROLE, timelock);
        acl.renounceRole(UPGRADER_ROLE, ADMIN_EOA);
        acl.renounceRole(ADMIN_ROLE, ADMIN_EOA);
        acl.renounceRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA);
        vm.stopPrank();

        // EOA fully out.
        assertFalse(acl.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA), "EOA still DEFAULT_ADMIN");
        assertFalse(acl.hasRole(UPGRADER_ROLE, ADMIN_EOA), "EOA still UPGRADER");
        assertFalse(acl.hasRole(ADMIN_ROLE, ADMIN_EOA), "EOA still ADMIN");
        // Timelock fully in.
        assertTrue(acl.hasRole(DEFAULT_ADMIN_ROLE, timelock), "timelock missing DEFAULT_ADMIN");
        assertTrue(acl.hasRole(UPGRADER_ROLE, timelock), "timelock missing UPGRADER");
        assertTrue(acl.hasRole(ADMIN_ROLE, timelock), "timelock missing ADMIN");

        // The retired EOA can no longer upgrade — proves the handover actually revoked power.
        // Deploy the impl OUTSIDE the prank: `new` is a CREATE that would otherwise consume the
        // single-shot vm.prank before the upgrade call under test even runs.
        address freshImpl = address(new PayoutReceiver());
        vm.prank(ADMIN_EOA);
        vm.expectRevert(); // AccessControlUnauthorizedAccount: EOA no longer holds UPGRADER_ROLE
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(freshImpl, "");

        // The timelock CAN upgrade (re-upgrade to a fresh v2.1.0 impl is a valid no-op change).
        address timelockImpl = address(new PayoutReceiver());
        vm.prank(timelock);
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(timelockImpl, "");
        assertEq(pr.version(), "2.1.0", "timelock upgrade did not take");
    }

    /// @notice MONEY-PATH: after the FULL Action-1+2+3 sequence, a real PKP-signed determination
    ///         still settles a payout end to end. Proves the upgrade preserved the money-path roles
    ///         and did not corrupt policyPaid / consumedDetermination idempotency state.
    function test_endToEnd_determinationStillPaysAfterFullSequence() public {
        PolicyManager pm = PolicyManager(POLICY_MANAGER);
        Treasury treasury = Treasury(TREASURY);
        address farmer = address(0xFA12);
        address distributor = address(0xD157);
        address org = address(0x6009);
        uint256 SUM_INSURED = 1_000e6;

        // ── Full pilot sequence, signed by the real EOA then migrated to the timelock. ──
        vm.startPrank(ADMIN_EOA);
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(new PayoutReceiver()), "");
        assertEq(pr.version(), "2.1.0");
        pr.setAuthorizedSigner(prodSigner);
        pr.grantRole(RELAYER_ROLE, relayer);
        // migrate admin -> timelock (Action 3)
        IAccessControl acl = IAccessControl(PAYOUT_RECEIVER);
        acl.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        acl.grantRole(UPGRADER_ROLE, timelock);
        acl.grantRole(ADMIN_ROLE, timelock);
        acl.renounceRole(UPGRADER_ROLE, ADMIN_EOA);
        acl.renounceRole(ADMIN_ROLE, ADMIN_EOA);
        acl.renounceRole(DEFAULT_ADMIN_ROLE, ADMIN_EOA);
        vm.stopPrank();

        // ── Drive a payout on live per-org-treasury (v3) state. Roles for the harness are
        //    cheat-granted via storage (these are NOT the roles under test). ──
        _cheatGrant(TREASURY, ADMIN_ROLE, address(this));
        _cheatGrant(TREASURY, BACKEND_ROLE, address(this));
        _cheatGrant(POLICY_MANAGER, BACKEND_ROLE, address(this));
        treasury.setPolicyManager(POLICY_MANAGER);

        // Fund the org reserve and create an active policy backed by it.
        deal(USDC, address(this), 520e6);
        IERC20(USDC).approve(TREASURY, type(uint256).max);
        treasury.depositReserve(org, 500e6);
        uint256 policyId = pm.createPolicy(farmer, 1, SUM_INSURED, 1e6, 30, PolicyManager.CoverageType.DROUGHT, org);
        pm.activatePolicy(policyId, distributor, "dist", "KE");
        treasury.receivePremium(policyId, 1e6);

        // Prod-PKP-signed determination (48% damage -> 480 USDC payout).
        (PayoutReceiver.CropDetermination memory d, bytes memory sig) = _determination(policyId, 4800, SUM_INSURED);
        address backend = treasury.backendWallet();
        uint256 backendBefore = IERC20(USDC).balanceOf(backend);

        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        assertTrue(pr.policyPaid(policyId), "policy not marked paid after full sequence");
        assertEq(IERC20(USDC).balanceOf(backend) - backendBefore, d.payoutAmount, "payout not disbursed");

        // IDEMPOTENCY: the same determination cannot double-pay. The first settlement marked the
        // policy CLAIMED (markAsClaimed), so a re-submit reverts at the policy-state guard
        // (PolicyNotActive) which fires BEFORE the policyPaid/consumedDetermination guards. Any of
        // these three guards blocks the double-pay; PolicyNotActive is simply the earliest.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.PolicyNotActive.selector, policyId, PolicyManager.PolicyStatus.CLAIMED
            )
        );
        pr.submitDetermination(d, sig);
    }

    // ── helpers ──

    function _determination(uint256 policyId, uint256 damageBp, uint256 sumInsured)
        internal
        view
        returns (PayoutReceiver.CropDetermination memory d, bytes memory sig)
    {
        d = PayoutReceiver.CropDetermination({
            onChainPolicyId: policyId,
            damagePercentBp: damageBp,
            weatherDamage: 40,
            satelliteDamage: 60,
            payoutAmount: (sumInsured * damageBp) / 10000,
            assessedAt: block.timestamp,
            latitude_e6: -1_286_389,
            longitude_e6: 36_817_223,
            sumInsured: sumInsured,
            ndviScaled: 3100,
            weatherPresent: 1,
            weatherTempC_e2: -350,
            weatherPrecip_e2: 0,
            weatherHumidity: 55,
            weatherWind_e2: 1200
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROD_PK, _preimage(d));
        sig = abi.encodePacked(r, s, v);
    }

    function _cheatGrant(address target, bytes32 role, address account) internal {
        bytes32 roleSlot = keccak256(abi.encode(role, ACL_STORAGE));
        vm.store(target, keccak256(abi.encode(account, roleSlot)), bytes32(uint256(1)));
    }

    function _preimage(PayoutReceiver.CropDetermination memory d) internal view returns (bytes32) {
        bytes32 inputsHash = keccak256(
            abi.encode(
                d.onChainPolicyId,
                d.latitude_e6,
                d.longitude_e6,
                d.sumInsured,
                d.ndviScaled,
                d.weatherPresent,
                d.weatherTempC_e2,
                d.weatherPrecip_e2,
                d.weatherHumidity,
                d.weatherWind_e2
            )
        );
        return keccak256(
            abi.encodePacked(
                keccak256("1.0"),
                keccak256("CROP_DAMAGE"),
                keccak256("crop-dualindex-1.0"),
                block.chainid,
                PAYOUT_RECEIVER,
                inputsHash,
                d.onChainPolicyId,
                d.damagePercentBp,
                d.weatherDamage,
                d.satelliteDamage,
                d.payoutAmount,
                d.assessedAt
            )
        );
    }
}
