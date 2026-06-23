// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface ITreasury {
    function hasRole(bytes32, address) external view returns (bool);
    function backendWallet() external view returns (address);
    function getAvailableForPayouts() external view returns (uint256);
}

/// @notice Fork integration test: upgrades the LIVE Base-mainnet PayoutReceiver proxy to v2,
///         proves role grants survived the upgrade, and settles a determination end-to-end
///         through the REAL Treasury + PolicyManager — actual USDC moves to backendWallet.
///
/// Run: forge test --match-path test/PayoutDeterminationFork.t.sol -vv
/// (forks https://mainnet.base.org in setUp; no CLI flag required)
contract PayoutDeterminationForkTest is Test {
    // Live Base mainnet deployment (DeployMainnet.s.sol/8453)
    address constant PAYOUT_RECEIVER = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant POLICY_NFT = 0xD2D40067B6D763C562F95fA402961efF8ee276cD;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ADMIN = 0xC63ABe092aeaB15102c3d6A4879A8BF77a21f8A8; // deployer / _admin

    bytes32 constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");
    bytes32 constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // OZ v5 AccessControlUpgradeable ERC-7201 storage root (for cheat-granting roles on a fork).
    bytes32 constant ACL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    uint256 constant TEST_PK = uint256(keccak256("microcrop-test-pkp-v1"));

    PayoutReceiver pr;
    PolicyManager pm;
    address signer;
    address relayer = address(0xBEEF);
    address farmer = address(0xFA12);

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        pr = PayoutReceiver(PAYOUT_RECEIVER);
        pm = PolicyManager(POLICY_MANAGER);
        signer = vm.addr(TEST_PK);
    }

    function test_forkUpgradeRoleSurvivalAndSettle() public {
        // ── 1. Role survival on the REAL contracts (read live state, pre-upgrade) ──
        // These are the grants the upgrade must not disturb (roles live in the OTHER contracts).
        assertTrue(
            ITreasury(TREASURY).hasRole(PAYOUT_ROLE, PAYOUT_RECEIVER),
            "PayoutReceiver missing PAYOUT_ROLE on Treasury"
        );
        assertTrue(
            pm.hasRole(ORACLE_ROLE, PAYOUT_RECEIVER),
            "PayoutReceiver missing ORACLE_ROLE on PolicyManager"
        );

        // FINDING (operational gate): the deployer was the _admin at init but admin/upgrader
        // were ROTATED post-deploy. The deployer can no longer authorize an upgrade — the real
        // V2 upgrade must be run by the CURRENT UPGRADER_ROLE holder (identify before mainnet).
        assertFalse(pr.hasRole(UPGRADER_ROLE, ADMIN), "deployer still holds UPGRADER_ROLE (rotation reverted?)");

        // For the fork we cheat-grant the needed roles via storage, then exercise the REAL
        // upgrade function + contract logic. Authorization is proven separately (above); this
        // proves storage compatibility and end-to-end settlement.
        _grant(PAYOUT_RECEIVER, UPGRADER_ROLE, address(this));

        // ── 2. Upgrade the live proxy to v2 (real UUPS upgrade against real storage) ──
        PayoutReceiver newImpl = new PayoutReceiver();
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(newImpl), "");
        assertEq(pr.version(), "2.0.0", "upgrade did not take effect");

        // Pre-existing state must still read correctly after the storage-layout-preserving upgrade.
        assertEq(pr.authorizedSigner(), address(0), "authorizedSigner unexpectedly set");

        // ── 3. Configure v2 (signer = authority root; relayer = anti-spam) ──
        _grant(PAYOUT_RECEIVER, ADMIN_ROLE, address(this));
        pr.setAuthorizedSigner(signer);
        _grant(PAYOUT_RECEIVER, RELAYER_ROLE, relayer);
        _grant(POLICY_MANAGER, BACKEND_ROLE, address(this)); // so this test can create a policy

        // ── 4. Real ACTIVE policy. createPolicy is real (PENDING); we flip status->ACTIVE via
        //      vm.store to bypass pool-exposure coupling (validated separately), keeping the
        //      money path, getPolicy, markAsClaimed and claim accounting fully real. ──
        uint256 sumInsured = 1_000_000_000; // 1000 USDC (6dp)
        uint256 policyId =
            pm.createPolicy(farmer, 1, sumInsured, 1, 30, PolicyManager.CoverageType.DROUGHT);
        _forcePolicyActive(policyId);

        PolicyManager.Policy memory p = pm.getPolicy(policyId);
        assertEq(uint8(p.status), uint8(PolicyManager.PolicyStatus.ACTIVE), "policy not ACTIVE");
        assertEq(p.sumInsured, sumInsured, "sumInsured mismatch");
        assertEq(p.farmer, farmer, "farmer mismatch");

        // Mint the policy NFT (done in activatePolicy in the real flow, which we bypassed) so
        // markAsClaimed's downstream updatePolicyStatus bookkeeping succeeds. PolicyNFT is
        // NON-upgradeable (no proxy), so its AccessControl isn't at the ERC-7201 slot _grant
        // uses — instead we prank PolicyManager, the real MINTER_ROLE holder.
        vm.prank(POLICY_MANAGER);
        PolicyNFT(POLICY_NFT).mintPolicy(
            farmer, policyId, address(this), "test-dist", sumInsured, 1,
            p.startDate, p.endDate, PolicyNFT.CoverageType.DROUGHT, "KE", 1
        );

        // ── 5. Fund Treasury (mainnet peakPremiums == 0, so required reserve == 0) ──
        deal(USDC, TREASURY, 1_000_000_000);
        address backend = ITreasury(TREASURY).backendWallet();
        uint256 backendBefore = IERC20(USDC).balanceOf(backend);

        // ── 6. Build + sign a determination for the REAL policyId on this fork ──
        uint256 damageBp = 4800; // 60*40 + 40*60
        uint256 payout = (sumInsured * damageBp) / 10000; // 480e6
        PayoutReceiver.CropDetermination memory d = PayoutReceiver.CropDetermination({
            onChainPolicyId: policyId,
            damagePercentBp: damageBp,
            weatherDamage: 40,
            satelliteDamage: 60,
            payoutAmount: payout,
            assessedAt: block.timestamp, // fresh (within MAX_REPORT_AGE)
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PK, _preimage(d));
        bytes memory sig = abi.encodePacked(r, s, v);

        // ── 7. Submit through the relayer and assert MONEY MOVED ──
        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        assertEq(
            IERC20(USDC).balanceOf(backend) - backendBefore,
            payout,
            "Treasury did not disburse payout to backendWallet"
        );
        assertTrue(pr.policyPaid(policyId), "policy not marked paid");
        assertEq(
            uint8(pm.getPolicy(policyId).status),
            uint8(PolicyManager.PolicyStatus.CLAIMED),
            "policy not CLAIMED on real PolicyManager"
        );
    }

    /// @dev Cheat-grant an AccessControl role on a fork. OZ v5 stores roles under a namespaced
    /// root: _roles[role].hasRole[account]. RoleData.hasRole is at offset 0 of the struct, so the
    /// member slot is keccak256(account, keccak256(role, ACL_STORAGE)).
    function _grant(address target, bytes32 role, address account) internal {
        bytes32 roleSlot = keccak256(abi.encode(role, ACL_STORAGE));
        bytes32 memberSlot = keccak256(abi.encode(account, roleSlot));
        vm.store(target, memberSlot, bytes32(uint256(1)));
    }

    /// @dev Flip Policy.status -> ACTIVE in real PolicyManager storage.
    /// _policies mapping is at slot 1; struct base = keccak256(policyId, 1).
    /// Field offsets: id(0) farmer(1) plotId(2) sumInsured(3) premium(4) startDate(5)
    /// endDate(6) {coverageType(byte0), status(byte1)}(7) createdAt(8). ACTIVE = 1.
    function _forcePolicyActive(uint256 policyId) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(policyId, uint256(1)))) + 7);
        uint256 word = uint256(vm.load(POLICY_MANAGER, slot));
        word = (word & ~(uint256(0xff) << 8))
            | (uint256(uint8(PolicyManager.PolicyStatus.ACTIVE)) << 8);
        vm.store(POLICY_MANAGER, slot, bytes32(word));
    }

    /// @dev Reconstruct the settlement preimage identically to PayoutReceiver (Schema §5).
    function _preimage(PayoutReceiver.CropDetermination memory d) internal view returns (bytes32) {
        bytes32 inputsHash = keccak256(
            abi.encode(
                d.onChainPolicyId, d.latitude_e6, d.longitude_e6, d.sumInsured, d.ndviScaled,
                d.weatherPresent, d.weatherTempC_e2, d.weatherPrecip_e2, d.weatherHumidity, d.weatherWind_e2
            )
        );
        return keccak256(
            abi.encodePacked(
                keccak256("1.0"), keccak256("CROP_DAMAGE"), keccak256("crop-dualindex-1.0"),
                block.chainid, PAYOUT_RECEIVER, inputsHash,
                d.onChainPolicyId, d.damagePercentBp, d.weatherDamage, d.satelliteDamage,
                d.payoutAmount, d.assessedAt
            )
        );
    }
}
