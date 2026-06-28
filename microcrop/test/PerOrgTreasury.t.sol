// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {Treasury} from "../src/Treasury.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/// @notice Unit tests for the per-org treasury (v3): premiums credit per-org reserves, payouts are
///         solvency-gated to the policy's org reserve, capital deposits + surplus withdrawals, and
///         the per-org fee/ratio parameters.
contract PerOrgTreasuryTest is BaseTest {
    address constant ORG = address(0x019);
    uint256 constant SUM_INSURED = 1_000e6; // 1000 USDC
    uint256 constant PREMIUM = 50e6; // 50 USDC

    function setUp() public {
        _deployContracts();
        vm.startPrank(admin);
        treasury.setPolicyManager(address(policyManager)); // post-upgrade wiring
        treasury.grantRole(treasury.PAYOUT_ROLE(), address(this)); // act as PayoutReceiver
        vm.stopPrank();
        usdc.mint(ORG, 10_000e6);
        vm.prank(ORG);
        usdc.approve(address(treasury), type(uint256).max);
    }

    function _activePolicy() internal returns (uint256 policyId) {
        vm.startPrank(backend);
        policyId = policyManager.createPolicy(farmer, 1, SUM_INSURED, PREMIUM, 30, PolicyManager.CoverageType.DROUGHT, ORG);
        policyManager.activatePolicy(policyId, distributor, DISTRIBUTOR_NAME, REGION);
        vm.stopPrank();
    }

    // ── exposure + reserve requirement ──────────────────────────────────────

    function test_activate_tracksOrgOutstanding_and_reserveRequired() public {
        _activePolicy();
        assertEq(policyManager.orgOutstandingSumInsured(ORG), SUM_INSURED, "outstanding mismatch");
        // default ratio 2000 bps = 20%
        assertEq(treasury.reserveRequired(ORG), (SUM_INSURED * 2000) / 10000, "reserveRequired mismatch");
    }

    function test_claim_releasesOrgOutstanding() public {
        uint256 id = _activePolicy();
        vm.prank(address(payoutReceiver));
        policyManager.markAsClaimed(id);
        assertEq(policyManager.orgOutstandingSumInsured(ORG), 0, "exposure not released on claim");
    }

    // ── premium → org reserve (net of per-org fee) ──────────────────────────

    function test_premium_creditsOrgReserve_netOfFee() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        uint256 fee = (PREMIUM * 1000) / 10000; // default 10%
        assertEq(treasury.orgReserve(ORG), PREMIUM - fee, "org reserve != net premium");
        assertEq(treasury.accumulatedFees(), fee, "platform fee mismatch");
    }

    function test_setOrgFeeBps_changesSplit() public {
        vm.prank(admin);
        treasury.setOrgFeeBps(ORG, 500); // 5%
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        assertEq(treasury.orgReserve(ORG), PREMIUM - (PREMIUM * 500) / 10000, "5% fee not applied");
    }

    // ── deposit reserve capital ─────────────────────────────────────────────

    function test_depositReserve_credits() public {
        vm.prank(ORG);
        treasury.depositReserve(ORG, 600e6);
        assertEq(treasury.orgReserve(ORG), 600e6, "deposit not credited");
    }

    // ── payout: solvency-gated to the org's own reserve ─────────────────────

    function test_payout_fromOrgReserve_success() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM); // sets premiumReceived + seeds reserve
        uint256 net = PREMIUM - (PREMIUM * 1000) / 10000; // 45 USDC
        vm.prank(ORG);
        treasury.depositReserve(ORG, 600e6 - net); // top up to exactly 600 USDC
        uint256 backendBefore = usdc.balanceOf(backendWallet);

        treasury.requestPayout(id, 600e6); // this == PAYOUT_ROLE

        assertEq(treasury.orgReserve(ORG), 0, "org reserve not debited");
        assertEq(treasury.totalOrgReserves(), 0, "totalOrgReserves not debited");
        assertEq(usdc.balanceOf(backendWallet) - backendBefore, 600e6, "payout not disbursed");
    }

    function test_payout_underfunded_reverts_loudly() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        uint256 net = PREMIUM - (PREMIUM * 1000) / 10000; // reserve == net (45 USDC)
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientOrgReserve.selector, ORG, 600e6, net));
        treasury.requestPayout(id, 600e6);
    }

    function test_payout_withoutPremium_reverts() public {
        uint256 id = _activePolicy(); // never received a premium
        vm.prank(ORG);
        treasury.depositReserve(ORG, 600e6); // reserve is funded, but premium not received
        vm.expectRevert(abi.encodeWithSelector(Treasury.PremiumNotReceived.selector, id));
        treasury.requestPayout(id, 600e6);
    }

    // ── withdraw surplus: org-only, solvency-gated ──────────────────────────

    function test_withdrawSurplus_aboveRequired_succeeds() public {
        _activePolicy(); // outstanding 1000 -> required reserve 200
        vm.prank(ORG);
        treasury.depositReserve(ORG, 500e6);
        // required = 200; can withdraw up to 300 surplus
        vm.prank(ORG);
        treasury.withdrawOrgSurplus(300e6, ORG);
        assertEq(treasury.orgReserve(ORG), 200e6, "should leave exactly the required reserve");
    }

    function test_withdrawSurplus_breachingReserve_reverts() public {
        _activePolicy(); // required reserve = 200
        vm.prank(ORG);
        treasury.depositReserve(ORG, 500e6);
        // withdrawing 400 would leave 100 < 200 required
        vm.prank(ORG);
        vm.expectRevert(abi.encodeWithSelector(Treasury.WouldBreachReserve.selector, ORG, 200e6, 100e6));
        treasury.withdrawOrgSurplus(400e6, ORG);
    }

    function test_withdraw_isKeyedToCaller_cannotTouchOthersReserve() public {
        vm.prank(ORG);
        treasury.depositReserve(ORG, 500e6);
        // A different caller withdraws against THEIR own (empty) reserve, not ORG's.
        address other = address(0x0BAD);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientOrgReserve.selector, other, 1e6, 0));
        treasury.withdrawOrgSurplus(1e6, other);
        assertEq(treasury.orgReserve(ORG), 500e6, "ORG reserve untouched");
    }

    // ── admin / param guards ────────────────────────────────────────────────

    function test_setOrgReserveRatioBps_affectsRequired_adminOnly() public {
        _activePolicy();
        vm.prank(admin);
        treasury.setOrgReserveRatioBps(ORG, 3000); // 30%
        assertEq(treasury.reserveRequired(ORG), (SUM_INSURED * 3000) / 10000);

        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.setOrgReserveRatioBps(ORG, 1000);
    }

    function test_createPolicy_zeroOrg_reverts() public {
        vm.prank(backend);
        vm.expectRevert(PolicyManager.ZeroAddressOrg.selector);
        policyManager.createPolicy(farmer, 1, SUM_INSURED, PREMIUM, 30, PolicyManager.CoverageType.DROUGHT, address(0));
    }

    // ── double-operation guards + fee withdrawal ────────────────────────────

    function test_receivePremium_duplicate_reverts() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PremiumAlreadyReceived.selector, id));
        treasury.receivePremium(id, PREMIUM);
    }

    function test_requestPayout_duplicate_reverts() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM);
        treasury.requestPayout(id, 10e6); // < net premium reserve
        vm.expectRevert(abi.encodeWithSelector(Treasury.PayoutAlreadyProcessed.selector, id));
        treasury.requestPayout(id, 10e6);
    }

    // ── audit fixes: emergencyWithdraw cap + legacy org backfill ─────────────

    function test_emergencyWithdraw_cannotTouchOrgReserves() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM); // backed funds in the contract
        uint256 backed = treasury.totalOrgReserves() + treasury.accumulatedFees();
        // Send surplus USDC straight to the contract (e.g. by mistake).
        usdc.mint(address(treasury), 30e6);

        vm.startPrank(admin);
        treasury.pause();
        // Cannot pull more than the unbacked surplus (30).
        vm.expectRevert(abi.encodeWithSelector(Treasury.ExceedsRecoverableSurplus.selector, 31e6, 30e6));
        treasury.emergencyWithdraw(admin, 31e6);
        // Exactly the surplus is recoverable; backed funds remain.
        treasury.emergencyWithdraw(admin, 30e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(treasury)), backed, "backed funds must remain");
        assertEq(treasury.totalOrgReserves(), PREMIUM - (PREMIUM * 1000) / 10000, "org reserves untouched");
    }

    function test_setLegacyPolicyOrg_backfillsOrg() public {
        // A pre-v3 policy id (never created via v3 createPolicy) has _policyOrg == 0.
        uint256 legacyId = 999;
        assertEq(policyManager.policyOrg(legacyId), address(0), "should start unset");
        vm.prank(admin);
        policyManager.setLegacyPolicyOrg(legacyId, ORG);
        assertEq(policyManager.policyOrg(legacyId), ORG, "backfill failed");

        // Cannot overwrite an already-set org.
        uint256 id = _activePolicy();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PolicyManager.OrgAlreadySet.selector, id));
        policyManager.setLegacyPolicyOrg(id, ORG);

        // Non-admin cannot backfill.
        vm.prank(unauthorized);
        vm.expectRevert();
        policyManager.setLegacyPolicyOrg(1234, ORG);
    }

    function test_withdrawFees_toAdmin() public {
        uint256 id = _activePolicy();
        vm.prank(backend);
        treasury.receivePremium(id, PREMIUM); // accrues the platform fee
        uint256 fees = treasury.accumulatedFees();
        assertGt(fees, 0, "no fee accrued");
        uint256 beforeBal = usdc.balanceOf(admin);
        vm.prank(admin);
        treasury.withdrawFees(admin);
        assertEq(treasury.accumulatedFees(), 0, "fees not zeroed");
        assertEq(usdc.balanceOf(admin) - beforeBal, fees, "fees not paid to admin");
    }
}
