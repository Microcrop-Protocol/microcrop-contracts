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
    function approve(address, uint256) external returns (bool);
}

/// @notice Per-org treasury (v3) shadow-run. Forks Base mainnet, upgrades the LIVE PolicyManager +
///         Treasury to v3 and PayoutReceiver to v2, wires them, then runs the per-org money loop on
///         real state: fund an org's reserve → create/activate a policy backed by that org →
///         determination settles a payout FROM THAT ORG'S RESERVE → and proves an underfunded org's
///         payout reverts loudly. Confirms the storage-safe upgrades preserve roles/state.
///
/// Run: forge test --match-path test/PerOrgFork.t.sol -vv
contract PerOrgForkTest is Test {
    address constant PAYOUT_RECEIVER = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant POLICY_NFT = 0xD2D40067B6D763C562F95fA402961efF8ee276cD;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 constant ACL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    uint256 constant TEST_PK = uint256(keccak256("microcrop-test-pkp-v1"));
    uint256 constant SUM_INSURED = 1_000e6;

    PayoutReceiver pr;
    PolicyManager pm;
    Treasury treasury;
    address signer;
    address relayer = address(0xBEEF);
    address farmer = address(0xFA12);
    address distributor = address(0xD157);
    address org = address(0x6009);

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        pr = PayoutReceiver(PAYOUT_RECEIVER);
        pm = PolicyManager(POLICY_MANAGER);
        treasury = Treasury(TREASURY);
        signer = vm.addr(TEST_PK);

        // Cheat-grant UPGRADER then run the REAL v3 upgrades against live storage.
        _grant(POLICY_MANAGER, UPGRADER_ROLE, address(this));
        _grant(TREASURY, UPGRADER_ROLE, address(this));
        _grant(PAYOUT_RECEIVER, UPGRADER_ROLE, address(this));
        IUUPS(POLICY_MANAGER).upgradeToAndCall(address(new PolicyManager()), "");
        IUUPS(TREASURY).upgradeToAndCall(address(new Treasury()), "");
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(new PayoutReceiver()), "");
        assertEq(pm.version(), "3.0.0");
        assertEq(treasury.version(), "3.0.0");
        assertEq(pr.version(), "2.0.0");

        // Wire v3 + grant this test the roles to drive the flow.
        _grant(TREASURY, ADMIN_ROLE, address(this));
        _grant(TREASURY, BACKEND_ROLE, address(this));
        _grant(POLICY_MANAGER, BACKEND_ROLE, address(this));
        _grant(PAYOUT_RECEIVER, ADMIN_ROLE, address(this));
        _grant(PAYOUT_RECEIVER, RELAYER_ROLE, relayer);
        treasury.setPolicyManager(POLICY_MANAGER);
        pr.setAuthorizedSigner(signer);
    }

    function _newActivePolicy() internal returns (uint256 policyId) {
        policyId = pm.createPolicy(farmer, 1, SUM_INSURED, 1e6, 30, PolicyManager.CoverageType.DROUGHT, org);
        pm.activatePolicy(policyId, distributor, "dist", "KE");
    }

    function test_perOrg_settlesFromOrgReserve() public {
        // Org funds its own reserve (insurer capital), plus headroom for the premium.
        deal(USDC, address(this), 520e6);
        IERC20(USDC).approve(TREASURY, type(uint256).max);
        treasury.depositReserve(org, 500e6);

        uint256 policyId = _newActivePolicy();
        treasury.receivePremium(policyId, 1e6); // premium received (guard) + seeds reserve
        // 20% default reserve ratio on 1000 sum insured.
        assertEq(treasury.reserveRequired(org), 200e6, "reserveRequired");

        (PayoutReceiver.CropDetermination memory d, bytes memory sig) = _determination(policyId, 4800);
        uint256 payout = d.payoutAmount; // 480e6
        address backend = treasury.backendWallet();
        uint256 backendBefore = IERC20(USDC).balanceOf(backend);
        uint256 reserveBefore = treasury.orgReserve(org);

        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        assertEq(treasury.orgReserve(org), reserveBefore - payout, "org reserve not debited by payout");
        assertEq(IERC20(USDC).balanceOf(backend) - backendBefore, payout, "payout not disbursed");
        assertTrue(pr.policyPaid(policyId), "not marked paid");
        assertEq(uint8(pm.getPolicy(policyId).status), uint8(PolicyManager.PolicyStatus.CLAIMED), "not CLAIMED");
        assertEq(pm.orgOutstandingSumInsured(org), 0, "exposure not released");
    }

    function test_perOrg_underfunded_reverts() public {
        // Only the premium funds the reserve (no capital deposited) — far short of the payout.
        deal(USDC, address(this), 1e6);
        IERC20(USDC).approve(TREASURY, type(uint256).max);
        uint256 policyId = _newActivePolicy();
        treasury.receivePremium(policyId, 1e6); // only the premium funds the reserve
        uint256 reserve = treasury.orgReserve(org); // net premium (fee per live config)
        (PayoutReceiver.CropDetermination memory d, bytes memory sig) = _determination(policyId, 4800);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientOrgReserve.selector, org, d.payoutAmount, reserve));
        pr.submitDetermination(d, sig);
    }

    function _determination(uint256 policyId, uint256 damageBp)
        internal
        view
        returns (PayoutReceiver.CropDetermination memory d, bytes memory sig)
    {
        d = PayoutReceiver.CropDetermination({
            onChainPolicyId: policyId,
            damagePercentBp: damageBp,
            weatherDamage: 40,
            satelliteDamage: 60,
            payoutAmount: (SUM_INSURED * damageBp) / 10000,
            assessedAt: block.timestamp,
            latitude_e6: -1_286_389,
            longitude_e6: 36_817_223,
            sumInsured: SUM_INSURED,
            ndviScaled: 3100,
            weatherPresent: 1,
            weatherTempC_e2: -350,
            weatherPrecip_e2: 0,
            weatherHumidity: 55,
            weatherWind_e2: 1200
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PK, _preimage(d));
        sig = abi.encodePacked(r, s, v);
    }

    function _grant(address target, bytes32 role, address account) internal {
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
