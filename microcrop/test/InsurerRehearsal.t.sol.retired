// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";
import {MockInsurer} from "./harness/MockInsurer.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IERC20R {
    function balanceOf(address) external view returns (uint256);
}

interface ITreasuryR {
    function backendWallet() external view returns (address);
}

/// @notice End-to-end rehearsal of the determination → settlement loop with a (mock) licensed
/// insurer as the capital source — the Schema §8.5 mitigation that unblocks engineering while
/// the real signed insurer is pending. Rehearses the §3 principle: MicroCrop holds NO risk
/// capital; the insurer pre-funds a segregated float and every payout is drawn from it.
///
/// Run: forge test --match-path test/InsurerRehearsal.t.sol -vv  (forks mainnet.base.org)
contract InsurerRehearsalTest is Test {
    // Live Base mainnet deployment
    address constant PAYOUT_RECEIVER = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;
    address constant POLICY_MANAGER = 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F;
    address constant TREASURY = 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f;
    address constant POLICY_NFT = 0xD2D40067B6D763C562F95fA402961efF8ee276cD;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    bytes32 constant ACL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    uint256 constant TEST_PK = uint256(keccak256("microcrop-test-pkp-v1"));

    PayoutReceiver pr;
    PolicyManager pm;
    MockInsurer insurer;
    address insurerOwner = address(0x1115);
    address signer;
    address relayer = address(0xBEEF);
    address farmer = address(0xFA12);

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        pr = PayoutReceiver(PAYOUT_RECEIVER);
        pm = PolicyManager(POLICY_MANAGER);
        signer = vm.addr(TEST_PK);

        vm.prank(insurerOwner);
        insurer = new MockInsurer(USDC);
    }

    function test_insurerFundedSettlement() public {
        // ── 0. Baseline: MicroCrop holds NO risk capital (Treasury empty on mainnet) ──
        assertEq(IERC20R(USDC).balanceOf(TREASURY), 0, "Treasury should hold no capital at baseline");

        // ── 1. Insurer capitalizes itself (external balance sheet — the one allowed `deal`) ──
        uint256 insurerCapital = 1_000_000_000; // 1000 USDC
        deal(USDC, address(insurer), insurerCapital);
        assertEq(insurer.capital(), insurerCapital, "insurer not capitalized");

        // ── 2. Insurer underwrites a product and accepts the policy ──
        uint256 sumInsured = 1_000_000_000; // 1000 USDC
        vm.startPrank(insurerOwner);
        uint256 productId = insurer.underwriteProduct(
            keccak256("DROUGHT"), keccak256("KE"), 3000, sumInsured, 800 // trigger 30%, premium 8%
        );
        vm.stopPrank();
        assertTrue(insurer.acceptPolicy(productId, sumInsured), "underwriting rejected the policy");

        // ── 3. Insurer pre-funds the segregated payout float (sink = Treasury today) ──
        vm.prank(insurerOwner);
        insurer.fundFloat(TREASURY, insurerCapital);
        assertEq(IERC20R(USDC).balanceOf(TREASURY), insurerCapital, "float not funded into Treasury");
        assertEq(insurer.floatFunded(), insurerCapital, "float accounting wrong");
        assertEq(insurer.capital(), 0, "insurer capital not moved to float");

        // ── 4. Deploy/configure the determination path (Batch A, fork-cheated roles) ──
        _grant(PAYOUT_RECEIVER, UPGRADER_ROLE, address(this));
        PayoutReceiver newImpl = new PayoutReceiver();
        IUUPS(PAYOUT_RECEIVER).upgradeToAndCall(address(newImpl), "");
        _grant(PAYOUT_RECEIVER, ADMIN_ROLE, address(this));
        pr.setAuthorizedSigner(signer);
        _grant(PAYOUT_RECEIVER, RELAYER_ROLE, relayer);
        _grant(POLICY_MANAGER, BACKEND_ROLE, address(this));

        // ── 5. Real ACTIVE policy (status flip bypasses pool coupling; NFT minted for real) ──
        uint256 policyId = pm.createPolicy(farmer, 1, sumInsured, 1, 30, PolicyManager.CoverageType.DROUGHT);
        _forcePolicyActive(policyId);
        PolicyManager.Policy memory p = pm.getPolicy(policyId);
        vm.prank(POLICY_MANAGER);
        PolicyNFT(POLICY_NFT).mintPolicy(
            farmer, policyId, address(this), "Farmers & Co", sumInsured, 1,
            p.startDate, p.endDate, PolicyNFT.CoverageType.DROUGHT, "KE", 1
        );

        // ── 6. Determination fires; payout drawn from the insurer-funded float ──
        uint256 damageBp = 4800; // 60*40 + 40*60
        uint256 payout = (sumInsured * damageBp) / 10000; // 480 USDC
        address backend = ITreasuryR(TREASURY).backendWallet();
        uint256 backendBefore = IERC20R(USDC).balanceOf(backend);
        uint256 floatBefore = IERC20R(USDC).balanceOf(TREASURY);

        PayoutReceiver.CropDetermination memory d = PayoutReceiver.CropDetermination({
            onChainPolicyId: policyId, damagePercentBp: damageBp, weatherDamage: 40, satelliteDamage: 60,
            payoutAmount: payout, assessedAt: block.timestamp,
            latitude_e6: -1_286_389, longitude_e6: 36_817_223, sumInsured: sumInsured,
            ndviScaled: 3100, weatherPresent: 1, weatherTempC_e2: -350,
            weatherPrecip_e2: 0, weatherHumidity: 55, weatherWind_e2: 1200
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PK, _preimage(d));
        vm.prank(relayer);
        pr.submitDetermination(d, abi.encodePacked(r, s, v));

        // insurer reconciles the draw against its float (provider reports this in production)
        vm.prank(insurerOwner);
        insurer.recordDraw(payout);

        // ── 7. Assert: the farmer's payout came from INSURER capital, not MicroCrop's ──
        assertEq(IERC20R(USDC).balanceOf(backend) - backendBefore, payout, "payout did not reach off-ramp wallet");
        assertEq(floatBefore - IERC20R(USDC).balanceOf(TREASURY), payout, "payout not drawn from the insurer-funded float");
        assertEq(insurer.availableFloat(), insurerCapital - payout, "insurer float exposure not reconciled");
        assertEq(uint8(pm.getPolicy(policyId).status), uint8(PolicyManager.PolicyStatus.CLAIMED), "policy not CLAIMED");
    }

    // ── helpers (mirror PayoutDeterminationFork.t.sol) ──

    function _grant(address target, bytes32 role, address account) internal {
        bytes32 roleSlot = keccak256(abi.encode(role, ACL_STORAGE));
        vm.store(target, keccak256(abi.encode(account, roleSlot)), bytes32(uint256(1)));
    }

    function _forcePolicyActive(uint256 policyId) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(policyId, uint256(1)))) + 7);
        uint256 word = uint256(vm.load(POLICY_MANAGER, slot));
        word = (word & ~(uint256(0xff) << 8)) | (uint256(uint8(PolicyManager.PolicyStatus.ACTIVE)) << 8);
        vm.store(POLICY_MANAGER, slot, bytes32(word));
    }

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
