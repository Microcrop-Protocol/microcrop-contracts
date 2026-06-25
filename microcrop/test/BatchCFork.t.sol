// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {Treasury} from "../src/Treasury.sol";
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
}

/// @notice Batch C shadow-run. Forks Base mainnet, upgrades the LIVE PolicyManager + Treasury
///         proxies to the Batch C (RiskPool-removed) implementations and PayoutReceiver to v2,
///         then drives the REAL pool-free activatePolicy through to a settled determination
///         payout — no vm.store status hack. Proves the storage-safe upgrades preserve live
///         state and the pool-free activation + payout path works end-to-end on real storage.
///
/// Run: forge test --match-path test/BatchCFork.t.sol -vv
contract BatchCForkTest is Test {
    // Live Base mainnet deployment (8453)
    address constant PAYOUT_RECEIVER = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant POLICY_NFT = 0xD2D40067B6D763C562F95fA402961efF8ee276cD;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 constant PAYOUT_ROLE = keccak256("PAYOUT_ROLE");
    bytes32 constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // OZ v5 AccessControlUpgradeable ERC-7201 storage root (cheat-granting roles on a fork).
    bytes32 constant ACL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    uint256 constant TEST_PK = uint256(keccak256("microcrop-test-pkp-v1"));

    PayoutReceiver pr;
    PolicyManager pm;
    Treasury treasury;
    address signer;
    address relayer = address(0xBEEF);
    address farmer = address(0xFA12);
    address distributor = address(0xD157);

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        pr = PayoutReceiver(PAYOUT_RECEIVER);
        pm = PolicyManager(POLICY_MANAGER);
        treasury = Treasury(TREASURY);
        signer = vm.addr(TEST_PK);
    }

    function test_batchCUpgrade_poolFreeActivation_settles() public {
        // ── 1. Cross-contract grants the upgrades must NOT disturb (read live, pre-upgrade) ──
        assertTrue(ITreasury(TREASURY).hasRole(PAYOUT_ROLE, PAYOUT_RECEIVER), "PayoutReceiver lost PAYOUT_ROLE");
        assertTrue(pm.hasRole(ORACLE_ROLE, PAYOUT_RECEIVER), "PayoutReceiver lost ORACLE_ROLE");

        // Cheat-grant UPGRADER_ROLE so we can exercise the REAL upgrade fns (auth proven elsewhere).
        _grant(POLICY_MANAGER, UPGRADER_ROLE, address(this));
        _grant(TREASURY, UPGRADER_ROLE, address(this));
        _grant(PAYOUT_RECEIVER, UPGRADER_ROLE, address(this));

        // ── 2. The real Batch C upgrades against live storage ──
        IUUPS(POLICY_MANAGER).upgradeToAndCall(address(new PolicyManager()), "");
        IUUPS(TREASURY).upgradeToAndCall(address(new Treasury()), "");
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(new PayoutReceiver()), "");

        assertEq(pm.version(), "2.0.0", "PolicyManager not on Batch C impl");
        assertEq(treasury.version(), "2.0.0", "Treasury not on Batch C impl");
        assertEq(pr.version(), "2.0.0", "PayoutReceiver not on v2 impl");

        // State survived the storage-safe upgrades.
        assertTrue(ITreasury(TREASURY).hasRole(PAYOUT_ROLE, PAYOUT_RECEIVER), "PAYOUT_ROLE lost in upgrade");
        assertTrue(pm.hasRole(ORACLE_ROLE, PAYOUT_RECEIVER), "ORACLE_ROLE lost in upgrade");

        // ── 3. Configure v2 + grant this test the BACKEND_ROLE to create/activate ──
        _grant(PAYOUT_RECEIVER, ADMIN_ROLE, address(this));
        pr.setAuthorizedSigner(signer);
        _grant(PAYOUT_RECEIVER, RELAYER_ROLE, relayer);
        _grant(POLICY_MANAGER, BACKEND_ROLE, address(this));

        // ── 4. REAL pool-free flow: create (PENDING) → activate (ACTIVE + mints NFT) ──
        uint256 sumInsured = 1_000_000_000; // 1000 USDC (6dp)
        uint256 policyId = pm.createPolicy(farmer, 1, sumInsured, 1, 30, PolicyManager.CoverageType.DROUGHT);

        // The whole point of Batch C: activatePolicy takes NO pool argument and needs no factory.
        pm.activatePolicy(policyId, distributor, "test-dist", "KE");

        PolicyManager.Policy memory p = pm.getPolicy(policyId);
        assertEq(uint8(p.status), uint8(PolicyManager.PolicyStatus.ACTIVE), "policy not ACTIVE via pool-free activate");
        assertEq(p.farmer, farmer, "farmer mismatch");
        assertEq(pm.getPolicyPool(policyId), address(0), "getPolicyPool should be the Batch C zero stub");
        // NFT was minted by the real activatePolicy path.
        assertEq(PolicyNFT(POLICY_NFT).ownerOf(policyId), farmer, "activatePolicy did not mint the policy NFT");

        // ── 5. Fund Treasury and capture backend balance ──
        deal(USDC, TREASURY, sumInsured);
        address backend = ITreasury(TREASURY).backendWallet();
        uint256 backendBefore = IERC20(USDC).balanceOf(backend);

        // ── 6. Build + sign a determination for the REAL policyId ──
        uint256 damageBp = 4800; // 60*40 + 40*60
        uint256 payout = (sumInsured * damageBp) / 10000; // 480e6
        PayoutReceiver.CropDetermination memory d = PayoutReceiver.CropDetermination({
            onChainPolicyId: policyId,
            damagePercentBp: damageBp,
            weatherDamage: 40,
            satelliteDamage: 60,
            payoutAmount: payout,
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PK, _preimage(d));
        bytes memory sig = abi.encodePacked(r, s, v);

        // ── 7. Submit through the relayer; assert money moved + policy CLAIMED ──
        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        assertEq(IERC20(USDC).balanceOf(backend) - backendBefore, payout, "Treasury did not disburse payout");
        assertTrue(pr.policyPaid(policyId), "policy not marked paid");
        assertEq(
            uint8(pm.getPolicy(policyId).status),
            uint8(PolicyManager.PolicyStatus.CLAIMED),
            "policy not CLAIMED"
        );
    }

    /// @dev Cheat-grant an AccessControl role on a fork (OZ v5 ERC-7201 layout).
    function _grant(address target, bytes32 role, address account) internal {
        bytes32 roleSlot = keccak256(abi.encode(role, ACL_STORAGE));
        bytes32 memberSlot = keccak256(abi.encode(account, roleSlot));
        vm.store(target, memberSlot, bytes32(uint256(1)));
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
