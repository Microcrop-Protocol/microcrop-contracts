// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {Treasury} from "../src/Treasury.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// @notice Regression tests for the v3.2.0 audit batch (PolicyManager + Treasury):
///         - finding 8:  rolling 365-day claim window (+ open-policy cap == claim cap)
///         - finding 10: org exposure counted at createPolicy, so a PENDING policy's premium
///                       cannot be withdrawn as surplus
///         - finding 11: receivePremium only for PENDING / ACTIVE policies
///         - finding 12: 30% reserve-ratio default and floor
contract AuditBatchV32Test is BaseTest {
    using stdStorage for StdStorage;

    address constant ORG = address(0x019);
    uint256 constant SUM_INSURED = 1_000e6;
    uint256 constant PREMIUM = 50e6;

    /// @dev 2026-12-18 00:00:00 UTC — an exact multiple of 365 days since the epoch, i.e. the
    ///      edge of the legacy fixed claim bucket (bucket 56 -> 57).
    uint256 constant BUCKET_EDGE = 1_797_552_000;

    /// @dev Storage slots (from `forge inspect <C> storageLayout`), used to reproduce
    ///      pre-upgrade state. The tests assert through public views that each write landed.
    uint256 constant PM_SLOT_EXPOSURE_COUNTED = 13;
    uint256 constant TREASURY_SLOT_ORG_RATIO_SET = 16;

    function setUp() public {
        _deployContracts();
        vm.prank(admin);
        treasury.setPolicyManager(address(policyManager));
        usdc.mint(ORG, 10_000e6);
        vm.prank(ORG);
        usdc.approve(address(treasury), type(uint256).max);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _create(address _farmer, uint256 sumInsured) internal returns (uint256 id) {
        vm.prank(backend);
        id = policyManager.createPolicy(_farmer, 1, sumInsured, PREMIUM, 30, PolicyManager.CoverageType.DROUGHT, ORG);
    }

    function _activate(uint256 id) internal {
        vm.prank(backend);
        policyManager.activatePolicy(id, distributor, DISTRIBUTOR_NAME, REGION);
    }

    function _claim(address _farmer) internal {
        vm.prank(address(payoutReceiver));
        policyManager.incrementClaimCount(_farmer);
    }

    function _expectClaimLimit(address _farmer) internal {
        vm.prank(address(payoutReceiver));
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManager.TooManyClaimsThisYear.selector, _farmer, block.timestamp / 365 days, 3, 3
            )
        );
        policyManager.incrementClaimCount(_farmer);
    }

    /// @dev Reproduce a PENDING policy created by v3.1.0: org + pending-count set, but exposure
    ///      NOT counted (v3.1.0 counted it only at activation) and no _exposureCounted flag.
    function _makePreUpgradePending(uint256 id) internal {
        vm.store(address(policyManager), keccak256(abi.encode(id, PM_SLOT_EXPOSURE_COUNTED)), bytes32(0));
        assertFalse(policyManager.exposureCounted(id), "slot write missed _exposureCounted");
        uint256 outstanding = policyManager.orgOutstandingSumInsured(ORG);
        uint256 si = policyManager.getPolicy(id).sumInsured;
        stdstore.target(address(policyManager)).sig("orgOutstandingSumInsured(address)").with_key(ORG).checked_write(
            outstanding - si
        );
    }

    // ═══════════════════ Finding 8: rolling claim window ═══════════════════

    /// @notice The exact scenario from the finding: 3 claims seconds before the 2026-12-18 bucket
    ///         edge used to allow 3 more seconds after it. The rolling window blocks the 4th.
    function test_claimWindow_bucketEdge_2026_12_18_blocksFourthClaim() public {
        vm.warp(BUCKET_EDGE - 3);
        uint256 yearBefore = policyManager.getCurrentYear();
        _claim(farmer);
        vm.warp(BUCKET_EDGE - 2);
        _claim(farmer);
        vm.warp(BUCKET_EDGE - 1);
        _claim(farmer);
        assertFalse(policyManager.canFarmerClaim(farmer), "cap reached before edge");

        vm.warp(BUCKET_EDGE + 1);
        assertEq(policyManager.getCurrentYear(), yearBefore + 1, "legacy bucket rolled over");
        // Under the old fixed bucket this was a fresh year with 0 claims; now it is still blocked.
        assertFalse(policyManager.canFarmerClaim(farmer), "edge must not reset capacity");
        _expectClaimLimit(farmer);
        assertEq(policyManager.getFarmerClaimsInWindow(farmer), 3);

        // Capacity returns exactly 365 days after the OLDEST claim, one claim at a time.
        vm.warp(BUCKET_EDGE - 3 + 365 days - 1);
        assertFalse(policyManager.canFarmerClaim(farmer));
        _expectClaimLimit(farmer);

        vm.warp(BUCKET_EDGE - 3 + 365 days);
        assertTrue(policyManager.canFarmerClaim(farmer), "oldest claim aged out");
        _claim(farmer);
        assertFalse(policyManager.canFarmerClaim(farmer), "only one slot freed");
        _expectClaimLimit(farmer);
    }

    /// @notice Claims spread across the window free up one at a time, oldest first.
    function test_claimWindow_rollsOldestFirst() public {
        uint256 t0 = BUCKET_EDGE - 200 days;
        vm.warp(t0);
        _claim(farmer);
        vm.warp(t0 + 100 days);
        _claim(farmer);
        vm.warp(t0 + 200 days); // crosses the legacy bucket edge
        _claim(farmer);
        _expectClaimLimit(farmer);

        vm.warp(t0 + 365 days);
        _claim(farmer); // replaces t0
        vm.warp(t0 + 100 days + 365 days - 1);
        _expectClaimLimit(farmer);
        vm.warp(t0 + 100 days + 365 days);
        _claim(farmer); // replaces t0 + 100d

        uint256[3] memory ts = policyManager.getFarmerRecentClaimTimestamps(farmer);
        uint256 sum = ts[0] + ts[1] + ts[2];
        assertEq(sum, (t0 + 200 days) + (t0 + 365 days) + (t0 + 465 days), "ring holds the 3 latest claims");
    }

    /// @notice Farmers are independent.
    function test_claimWindow_perFarmer() public {
        vm.warp(BUCKET_EDGE);
        _claim(farmer);
        _claim(farmer);
        _claim(farmer);
        address other = address(0xF2);
        assertTrue(policyManager.canFarmerClaim(other));
        _claim(other);
        assertEq(policyManager.getFarmerClaimsInWindow(other), 1);
    }

    /// @notice canFarmerClaim agrees with incrementClaimCount, and both agree with a reference
    ///         rolling-window model, over arbitrary claim timings.
    function testFuzz_claimWindow_matchesReferenceModel(uint32[10] memory gaps) public {
        vm.warp(BUCKET_EDGE - 400 days);
        uint256[] memory paid = new uint256[](gaps.length);
        uint256 nPaid;
        for (uint256 i = 0; i < gaps.length; i++) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 200 days));
            uint256 inWindow;
            for (uint256 j = 0; j < nPaid; j++) {
                if (block.timestamp - paid[j] < 365 days) inWindow++;
            }
            bool expected = inWindow < 3;
            assertEq(policyManager.getFarmerClaimsInWindow(farmer), inWindow, "window count");
            assertEq(policyManager.canFarmerClaim(farmer), expected, "canFarmerClaim vs model");

            vm.prank(address(payoutReceiver));
            try policyManager.incrementClaimCount(farmer) {
                assertTrue(expected, "claim succeeded past the cap");
                paid[nPaid++] = block.timestamp;
            } catch {
                assertFalse(expected, "claim refused under the cap");
            }
        }
    }

    /// @notice Product rule (finding 8b): open-policy cap equals the claim cap, so every open
    ///         policy whose premium was paid can pay out in the same window.
    function test_openPolicyCap_equalsClaimCap_allOpenPoliciesCanPay() public {
        assertEq(policyManager.MAX_ACTIVE_POLICIES_PER_FARMER(), 3);
        assertEq(policyManager.MAX_ACTIVE_POLICIES_PER_FARMER(), policyManager.MAX_CLAIMS_PER_FARMER_PER_YEAR());

        vm.warp(BUCKET_EDGE - 10 days);
        uint256[3] memory ids;
        for (uint256 i = 0; i < 3; i++) {
            ids[i] = _create(farmer, SUM_INSURED);
            _activate(ids[i]);
        }
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(PolicyManager.TooManyActivePolicies.selector, farmer, 3, 3));
        policyManager.createPolicy(farmer, 1, SUM_INSURED, PREMIUM, 30, PolicyManager.CoverageType.DROUGHT, ORG);

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(policyManager.canFarmerClaim(farmer), "an open policy could not pay");
            vm.startPrank(address(payoutReceiver));
            policyManager.markAsClaimed(ids[i]);
            policyManager.incrementClaimCount(farmer);
            vm.stopPrank();
        }
    }

    /// @notice Reviewer repro (finding 8, follow-up): 3 policies pay out at t; at t+1 day the
    ///         farmer has 0 open policies but 3 claims in the window. A 4th policy could never pay,
    ///         so createPolicy must refuse it until the oldest claim leaves the window.
    function test_openPolicyCap_countsClaimsInWindow() public {
        // Explicit times (not `block.timestamp` reads, which via-IR may re-evaluate after a warp).
        uint256 t0 = BUCKET_EDGE - 10 days;
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(t0 + i * 1 hours);
            uint256 id = _create(farmer, SUM_INSURED);
            _activate(id);
            vm.startPrank(address(payoutReceiver));
            policyManager.markAsClaimed(id);
            policyManager.incrementClaimCount(farmer);
            vm.stopPrank();
        }
        assertEq(policyManager.getFarmerActiveCount(farmer), 0);
        assertEq(policyManager.getFarmerClaimsInWindow(farmer), 3);

        vm.warp(t0 + 1 days);
        _expectCapRevert(farmer, 3);

        // One second before the oldest claim leaves the window: still refused.
        vm.warp(t0 + 365 days - 1);
        _expectCapRevert(farmer, 3);

        // Oldest claim leaves the window: exactly one slot frees up, and that policy can pay.
        vm.warp(t0 + 365 days);
        uint256 next = _create(farmer, SUM_INSURED);
        _expectCapRevert(farmer, 3);
        _activate(next);
        assertTrue(policyManager.canFarmerClaim(farmer), "the new policy could not pay");
        vm.startPrank(address(payoutReceiver));
        policyManager.markAsClaimed(next);
        policyManager.incrementClaimCount(farmer);
        vm.stopPrank();
    }

    /// @notice Mixed state: open policies and recent claims share the same 3 slots.
    function test_openPolicyCap_openPlusClaimsShareSlots() public {
        uint256 a = _create(farmer, SUM_INSURED);
        _activate(a);
        vm.startPrank(address(payoutReceiver));
        policyManager.markAsClaimed(a);
        policyManager.incrementClaimCount(farmer);
        vm.stopPrank();

        _create(farmer, SUM_INSURED); // PENDING
        uint256 c = _create(farmer, SUM_INSURED);
        _activate(c); // 1 claim + 1 PENDING + 1 ACTIVE
        _expectCapRevert(farmer, 3);

        // Cancelling an open policy frees a slot even though the claim stays in the window.
        vm.prank(backend);
        policyManager.cancelPolicy(c);
        _create(farmer, SUM_INSURED);
        _expectCapRevert(farmer, 3);

        // Another farmer is unaffected.
        _create(address(0xBEEF), SUM_INSURED);
    }

    function _expectCapRevert(address _farmer, uint256 used) internal {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(PolicyManager.TooManyActivePolicies.selector, _farmer, used, 3));
        policyManager.createPolicy(_farmer, 1, SUM_INSURED, PREMIUM, 30, PolicyManager.CoverageType.DROUGHT, ORG);
    }

    // ══════════════ Finding 10: exposure counted at createPolicy ══════════════

    function test_exposure_countedAtCreate_notDoubleCountedAtActivate() public {
        uint256 id = _create(farmer, SUM_INSURED);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), SUM_INSURED, "PENDING exposure");
        assertTrue(policyManager.exposureCounted(id));
        assertEq(treasury.reserveRequired(ORG), (SUM_INSURED * 3000) / 10000);

        _activate(id);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), SUM_INSURED, "activation double-counted");
    }

    /// @notice The exploit from the finding: premium credited while PENDING, then withdrawn as
    ///         "surplus" before activation. Now the PENDING exposure holds it in reserve.
    function test_exposure_pendingPremiumCannotBeWithdrawn() public {
        uint256 id = _create(farmer, SUM_INSURED);
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        uint256 net = treasury.orgReserve(ORG); // 45 USDC
        uint256 required = treasury.reserveRequired(ORG); // 300 USDC
        assertGt(required, net);

        vm.prank(ORG);
        vm.expectRevert(abi.encodeWithSelector(Treasury.WouldBreachReserve.selector, ORG, required, 0));
        treasury.withdrawOrgSurplus(net, ORG);

        // Only capital above the requirement is withdrawable.
        vm.prank(ORG);
        treasury.depositReserve(ORG, 400e6);
        uint256 surplus = treasury.orgReserve(ORG) - required;
        vm.prank(ORG);
        treasury.withdrawOrgSurplus(surplus, ORG);
        assertEq(treasury.orgReserve(ORG), required);
    }

    function test_exposure_cancelPending_releases() public {
        uint256 keep = _create(farmer, 2_000e6);
        uint256 id = _create(farmer, SUM_INSURED);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 3_000e6);

        vm.prank(backend);
        policyManager.cancelPolicy(id);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 2_000e6, "PENDING cancel did not release");
        assertFalse(policyManager.exposureCounted(id));
        assertTrue(policyManager.exposureCounted(keep));
    }

    function test_exposure_cancelActive_and_expire_release() public {
        uint256 a = _create(farmer, SUM_INSURED);
        _activate(a);
        uint256 b = _create(farmer, 2_000e6);
        _activate(b);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 3_000e6);

        vm.prank(backend);
        policyManager.cancelPolicy(a);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 2_000e6, "ACTIVE cancel");
        assertFalse(policyManager.exposureCounted(a), "flag left set after ACTIVE cancel");
        assertTrue(policyManager.exposureCounted(b));

        vm.warp(policyManager.getPolicy(b).endDate + 1);
        vm.prank(backend);
        policyManager.expirePolicy(b);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 0, "expire");
        assertFalse(policyManager.exposureCounted(b), "flag left set after expire");
    }

    function test_exposure_claim_releases() public {
        uint256 id = _create(farmer, SUM_INSURED);
        _activate(id);
        vm.prank(address(payoutReceiver));
        policyManager.markAsClaimed(id);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 0);
        assertFalse(policyManager.exposureCounted(id), "flag left set after claim");
    }

    /// @notice A PENDING policy created before v3.2.0 (no creation-time exposure) adds its
    ///         exposure exactly once, at activation, and releases exactly that on exit.
    function test_exposure_preUpgradePending_activationAddsOnce() public {
        uint256 other = _create(farmer, 2_000e6); // post-upgrade policy, counted at create
        uint256 legacy = _create(farmer, SUM_INSURED);
        _makePreUpgradePending(legacy);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 2_000e6, "legacy PENDING has no exposure");

        _activate(legacy);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 3_000e6, "activation must add legacy exposure");
        assertTrue(policyManager.exposureCounted(legacy));

        _activate(other); // post-upgrade policy: no second add
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 3_000e6);

        vm.warp(policyManager.getPolicy(legacy).endDate + 1);
        vm.prank(backend);
        policyManager.expirePolicy(legacy);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 2_000e6, "legacy release");
        assertFalse(policyManager.exposureCounted(legacy));
    }

    /// @notice Cancelling a pre-upgrade PENDING policy releases nothing — it never added any —
    ///         so it cannot strip exposure that belongs to another policy of the same org.
    function test_exposure_preUpgradePending_cancelReleasesNothing() public {
        _create(farmer, 2_000e6);
        uint256 legacy = _create(farmer, SUM_INSURED);
        _makePreUpgradePending(legacy);

        vm.prank(backend);
        policyManager.cancelPolicy(legacy);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 2_000e6, "stole another policy's exposure");
    }

    // ══════════════ Finding 11: premium only for open policies ══════════════

    function test_receivePremium_pendingAndActive_ok() public {
        uint256 p = _create(farmer, SUM_INSURED);
        vm.prank(backend);
        treasury.receivePremium(p, PREMIUM);

        uint256 a = _create(farmer, SUM_INSURED);
        _activate(a);
        vm.prank(backend);
        treasury.receivePremium(a, PREMIUM);
        assertTrue(treasury.premiumReceived(p) && treasury.premiumReceived(a));
    }

    function test_receivePremium_cancelled_reverts() public {
        uint256 id = _create(farmer, SUM_INSURED);
        vm.prank(backend);
        policyManager.cancelPolicy(id);
        _expectNotOpen(id, PolicyManager.PolicyStatus.CANCELLED);
    }

    function test_receivePremium_expired_reverts() public {
        uint256 id = _create(farmer, SUM_INSURED);
        _activate(id);
        vm.warp(policyManager.getPolicy(id).endDate + 1);
        vm.prank(backend);
        policyManager.expirePolicy(id);
        _expectNotOpen(id, PolicyManager.PolicyStatus.EXPIRED);
    }

    function test_receivePremium_claimed_reverts() public {
        uint256 id = _create(farmer, SUM_INSURED);
        _activate(id);
        vm.prank(address(payoutReceiver));
        policyManager.markAsClaimed(id);
        _expectNotOpen(id, PolicyManager.PolicyStatus.CLAIMED);
    }

    /// @notice Reviewer follow-up: an ACTIVE policy past endDate that the backend has not yet
    ///         expired backs no further coverage, so it cannot take a premium either.
    function test_receivePremium_activePastEndDate_notYetExpired_reverts() public {
        uint256 id = _create(farmer, SUM_INSURED);
        _activate(id);
        uint256 endDate = policyManager.getPolicy(id).endDate;

        vm.warp(endDate + 1);
        assertEq(uint8(policyManager.getPolicy(id).status), uint8(PolicyManager.PolicyStatus.ACTIVE));
        uint256 reserveBefore = treasury.orgReserve(ORG);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PolicyCoverageEnded.selector, id, endDate));
        treasury.receivePremium(id, PREMIUM);
        assertEq(treasury.orgReserve(ORG), reserveBefore);
        assertFalse(treasury.premiumReceived(id));

        // A PENDING policy whose original endDate has passed is still open (activation resets it).
        uint256 pend = _create(farmer, SUM_INSURED);
        vm.warp(policyManager.getPolicy(pend).endDate + 1);
        vm.prank(backend);
        treasury.receivePremium(pend, PREMIUM);
        assertTrue(treasury.premiumReceived(pend));
    }

    function test_receivePremium_activeAtEndDate_ok() public {
        uint256 id = _create(farmer, SUM_INSURED);
        _activate(id);
        vm.warp(policyManager.getPolicy(id).endDate);
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        assertTrue(treasury.premiumReceived(id));
    }

    function _expectNotOpen(uint256 id, PolicyManager.PolicyStatus status) internal {
        uint256 reserveBefore = treasury.orgReserve(ORG);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PolicyNotOpen.selector, id, status));
        treasury.receivePremium(id, PREMIUM);
        assertEq(treasury.orgReserve(ORG), reserveBefore);
        assertFalse(treasury.premiumReceived(id));
    }

    // ══════════════ Finding 12: 30% reserve ratio default + floor ══════════════

    function test_reserveRatio_default_coversSmallestPayout() public {
        assertEq(treasury.DEFAULT_RESERVE_RATIO_BPS(), 3000);
        assertEq(treasury.MIN_RESERVE_RATIO_BPS(), 3000);
        assertEq(treasury.DEFAULT_RESERVE_RATIO_BPS(), payoutReceiver.MIN_DAMAGE_THRESHOLD());
        assertEq(treasury.effectiveReserveRatioBps(ORG), 3000);

        _create(farmer, SUM_INSURED);
        uint256 smallestPayout = (SUM_INSURED * payoutReceiver.MIN_DAMAGE_THRESHOLD()) / 10000;
        assertEq(treasury.reserveRequired(ORG), smallestPayout);
    }

    function test_setOrgReserveRatioBps_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.BpsTooLow.selector, 0, 3000));
        treasury.setOrgReserveRatioBps(ORG, 0);
        vm.expectRevert(abi.encodeWithSelector(Treasury.BpsTooLow.selector, 2999, 3000));
        treasury.setOrgReserveRatioBps(ORG, 2999);
        vm.expectRevert(abi.encodeWithSelector(Treasury.BpsTooHigh.selector, 10001, 10000));
        treasury.setOrgReserveRatioBps(ORG, 10001);

        treasury.setOrgReserveRatioBps(ORG, 3000);
        assertEq(treasury.effectiveReserveRatioBps(ORG), 3000);
        treasury.setOrgReserveRatioBps(ORG, 10000);
        assertEq(treasury.effectiveReserveRatioBps(ORG), 10000);
        vm.stopPrank();
    }

    /// @notice An org whose ratio was explicitly set below the floor before v3.2.0 (orgRatioSet
    ///         true, stored 0 or 2000) is clamped up to the floor — the presence flag cannot keep
    ///         a sub-floor requirement alive across the upgrade.
    function test_reserveRatio_legacySubFloorExplicitValue_isClamped() public {
        _create(farmer, SUM_INSURED);
        uint256[2] memory legacy = [uint256(0), 2000];
        for (uint256 i = 0; i < 2; i++) {
            stdstore.target(address(treasury)).sig("orgReserveRatioBps(address)").with_key(ORG).checked_write(legacy[i]);
            vm.store(address(treasury), keccak256(abi.encode(ORG, TREASURY_SLOT_ORG_RATIO_SET)), bytes32(uint256(1)));
            assertEq(treasury.orgReserveRatioBps(ORG), legacy[i], "stored legacy ratio");
            assertEq(treasury.effectiveReserveRatioBps(ORG), 3000, "sub-floor ratio not clamped");
            assertEq(treasury.reserveRequired(ORG), (SUM_INSURED * 3000) / 10000);
        }
        // Sanity: the slot write really set the presence flag — an explicit above-floor stored
        // value is honored as-is.
        stdstore.target(address(treasury)).sig("orgReserveRatioBps(address)").with_key(ORG).checked_write(uint256(4500));
        assertEq(treasury.effectiveReserveRatioBps(ORG), 4500, "orgRatioSet slot write missed");
    }

    // ═══════════════════════════ versions ═══════════════════════════

    function test_versions() public view {
        assertEq(policyManager.version(), "3.2.0");
        assertEq(treasury.version(), "3.2.0");
    }
}
