// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/// @notice Minimal PolicyManager stand-in for the drought path — settable claim gate so the
///         farmer-limit branch can be exercised.
contract DroughtMockPolicyManager {
    PolicyManager.Policy private _policy;
    uint256 public claimedId;
    address public claimedFarmer;
    bool private _canClaim = true;

    function setPolicy(PolicyManager.Policy calldata p) external {
        _policy = p;
    }

    function setCanClaim(bool v) external {
        _canClaim = v;
    }

    function policyExists(uint256) external pure returns (bool) {
        return true;
    }

    function getPolicy(uint256) external view returns (PolicyManager.Policy memory) {
        return _policy;
    }

    function canFarmerClaim(address) external view returns (bool) {
        return _canClaim;
    }

    function markAsClaimed(uint256 id) external {
        claimedId = id;
    }

    function incrementClaimCount(address farmer) external {
        claimedFarmer = farmer;
    }
}

/// @notice Minimal Treasury stand-in — records the payout instruction.
contract DroughtMockTreasury {
    uint256 public lastPolicyId;
    uint256 public lastAmount;

    function requestPayout(uint256 policyId, uint256 amount) external {
        lastPolicyId = policyId;
        lastAmount = amount;
    }
}

/// @notice Solidity/EVM-layer conformance + settlement tests for the CROP_DROUGHT path (v2.2.0).
///         Mirrors PayoutDetermination.t.sol. The test independently reproduces the frozen §2
///         hashing spec (13-field abi.encode inputsHash; 11-field abi.encodePacked preimage),
///         signs the reproduced preimage, and asserts the CONTRACT reconstructs the identical
///         hash and settles — a one-byte drift breaks recovery and the call reverts.
contract PayoutDroughtDeterminationTest is Test {
    // Frozen domain constants — must equal the contract's private constants.
    bytes32 constant SCHEMA_VERSION_HASH = keccak256("1.0");
    bytes32 constant KIND_DROUGHT_HASH = keccak256("CROP_DROUGHT");
    bytes32 constant METHODOLOGY_DROUGHT_HASH = keccak256("crop-drought-rdi-1.0");

    uint256 constant FIXTURE_PK = uint256(keccak256("microcrop-test-pkp-v1"));
    address constant FIXTURE_SIGNER = 0xF18685788a4261DDA4f036D236066533a91C5ABE;
    uint256 constant WRONG_PK = uint256(keccak256("microcrop-test-pkp-imposter"));

    uint256 constant FIXTURE_CHAIN_ID = 8453;
    address constant FIXTURE_CONTRACT = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;

    uint256 constant ASSESSED_AT = 1_718_900_000;
    uint256 constant SUM_INSURED = 1_000_000_000; // 1000 USDC (6dp)

    PayoutReceiver pr;
    DroughtMockPolicyManager pm;
    DroughtMockTreasury treasury;
    address admin = address(0xA11CE);
    address relayer = address(0xBEEF);
    address farmer = address(0xFA12);

    event DeterminationVerified(uint256 indexed policyId, bytes32 indexed preimageHash, address indexed signer);

    function setUp() public {
        vm.chainId(FIXTURE_CHAIN_ID);

        pm = new DroughtMockPolicyManager();
        treasury = new DroughtMockTreasury();

        PayoutReceiver impl = new PayoutReceiver();
        vm.etch(FIXTURE_CONTRACT, address(impl).code);
        pr = PayoutReceiver(FIXTURE_CONTRACT);
        pr.initialize(address(treasury), address(pm), admin);

        pm.setPolicy(
            PolicyManager.Policy({
                id: 1234,
                farmer: farmer,
                plotId: 1,
                sumInsured: SUM_INSURED,
                premium: 1,
                startDate: 1,
                endDate: type(uint256).max,
                coverageType: PolicyManager.CoverageType.DROUGHT,
                status: PolicyManager.PolicyStatus.ACTIVE,
                createdAt: 1
            })
        );

        vm.startPrank(admin);
        pr.setAuthorizedSigner(FIXTURE_SIGNER);
        pr.grantRole(pr.RELAYER_ROLE(), relayer);
        vm.stopPrank();

        vm.warp(ASSESSED_AT + 600); // within MAX_REPORT_AGE (1h)
    }

    /// @dev Canonical drought determination: droughtDamage 48% -> 4800bp -> 480 USDC.
    function _drought() internal pure returns (PayoutReceiver.DroughtDetermination memory) {
        return PayoutReceiver.DroughtDetermination({
            onChainPolicyId: 1234,
            damagePercentBp: 4800,
            droughtDamage: 48,
            payoutAmount: 480_000_000, // 1e9 * 4800 / 10000
            assessedAt: ASSESSED_AT,
            latitude_e6: -1_286_389,
            longitude_e6: 36_817_223,
            sumInsured: SUM_INSURED,
            seasonStartEpoch: 1_710_000_000,
            lgpDays: 180,
            rainW1_e2: 4_500,
            rainRefW1_e2: 12_000,
            rainW2_e2: 3_000,
            rainRefW2_e2: 11_000,
            cddW2Days: 21,
            sourceHash: keccak256("drought-source-fixture"),
            methodologyParamsHash: keccak256("drought-params-fixture")
        });
    }

    /// @dev Independent reproduction of the §2 inputsHash (13-field abi.encode).
    function _inputsHash(PayoutReceiver.DroughtDetermination memory d) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                d.onChainPolicyId,
                d.latitude_e6,
                d.longitude_e6,
                d.sumInsured,
                d.seasonStartEpoch,
                d.lgpDays,
                d.rainW1_e2,
                d.rainRefW1_e2,
                d.rainW2_e2,
                d.rainRefW2_e2,
                d.cddW2Days,
                d.sourceHash,
                d.methodologyParamsHash
            )
        );
    }

    /// @dev Independent reproduction of the §2 preimageHash (11-field abi.encodePacked).
    function _preimage(PayoutReceiver.DroughtDetermination memory d) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                SCHEMA_VERSION_HASH,
                KIND_DROUGHT_HASH,
                METHODOLOGY_DROUGHT_HASH,
                block.chainid,
                address(pr),
                _inputsHash(d),
                d.onChainPolicyId,
                d.damagePercentBp,
                d.droughtDamage,
                d.payoutAmount,
                d.assessedAt
            )
        );
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest); // raw digest, no prefix
        return abi.encodePacked(r, s, v);
    }

    // ── happy path ────────────────────────────────────────────────────────────────

    /// @notice CORE PROOF: contract reconstructs the same preimage, recovers the signer, pays.
    function test_submitDrought_reconstructsAndPays() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes32 preimage = _preimage(d);
        bytes memory sig = _sign(FIXTURE_PK, preimage);

        vm.expectEmit(true, true, true, true);
        emit DeterminationVerified(1234, preimage, FIXTURE_SIGNER);

        vm.prank(relayer);
        pr.submitDroughtDetermination(d, sig);

        assertTrue(pr.policyPaid(1234), "policy not marked paid");
        assertTrue(pr.consumedDetermination(preimage), "determination not consumed");
        assertEq(treasury.lastAmount(), 480_000_000, "payout amount drift");
        assertEq(treasury.lastPolicyId(), 1234, "payout policy mismatch");
        assertEq(pm.claimedFarmer(), farmer, "claim count not incremented");
    }

    // ── damage-block guards (drought-specific) ─────────────────────────────────────

    /// @notice Single-score invariant: damagePercentBp must equal droughtDamage * 100.
    function test_singleScoreInvariant_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        d.damagePercentBp = 4700; // != 48 * 100
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.InvalidDroughtDamage.selector, uint256(4800), uint256(4700)));
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice droughtDamage above 100 (whole percent) is rejected before the invariant.
    function test_droughtScoreOutOfRange_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        d.droughtDamage = 101;
        d.damagePercentBp = 10_100; // keep invariant self-consistent so bounds is what trips
        // damageBp > MAX first -> DamageExceedsMaximum; force damageBp within range to hit score bound
        d.damagePercentBp = 10_000;
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.DroughtScoreOutOfRange.selector, uint256(101)));
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice Below the 30% (3000bp) threshold is rejected.
    function test_belowThreshold_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        d.droughtDamage = 20;
        d.damagePercentBp = 2000; // 20 * 100, invariant holds
        d.payoutAmount = (SUM_INSURED * 2000) / 10000;
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.DamageBelowThreshold.selector, uint256(2000), uint256(3000)));
        pr.submitDroughtDetermination(d, sig);
    }

    // ── shared guards (mirror CROP_DAMAGE) ─────────────────────────────────────────

    /// @notice Evidence sumInsured must bind the real policy.
    function test_sumInsuredMismatch_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        d.sumInsured = SUM_INSURED + 1;
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.SumInsuredMismatch.selector, SUM_INSURED + 1, SUM_INSURED)
        );
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice payoutAmount must equal sumInsured * damageBp / 10000 (re-derived on-chain).
    function test_payoutReDerivation_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        d.payoutAmount = 479_000_000; // wrong
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.InvalidPayoutCalculation.selector, uint256(479_000_000), uint256(480_000_000)
            )
        );
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice Future-dated determination is rejected.
    function test_future_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        d.assessedAt = block.timestamp + 1;
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutReceiver.ReportInFuture.selector, block.timestamp + 1, block.timestamp)
        );
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice Stale determination (older than MAX_REPORT_AGE) is rejected.
    function test_stale_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));
        vm.warp(d.assessedAt + 1 hours + 1);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutReceiver.ReportTooOld.selector, d.assessedAt, block.timestamp, uint256(1 hours)
            )
        );
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice A wrong signer (not authorizedSigner) is rejected.
    function test_wrongSigner_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes memory sig = _sign(WRONG_PK, _preimage(d)); // signed by imposter

        vm.prank(relayer);
        vm.expectRevert(); // InvalidSignature(recovered, expected)
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice A settled policy cannot be settled again (replay caught by policy state).
    function test_replay_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        pr.submitDroughtDetermination(d, sig);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.PolicyAlreadyPaid.selector, uint256(1234)));
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice Farmer over the yearly claim limit is rejected.
    function test_farmerClaimLimit_reverts() public {
        pm.setCanClaim(false);
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.FarmerClaimLimitExceeded.selector, farmer));
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice Non-relayer cannot submit (anti-spam gate), independent of signature validity.
    function test_nonRelayer_reverts() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d));

        vm.expectRevert(); // AccessControl: missing RELAYER_ROLE
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice One-byte flip of an evidence field changes inputsHash -> preimage -> InvalidSignature.
    function test_tamperedEvidence_revertsInvalidSignature() public {
        PayoutReceiver.DroughtDetermination memory d = _drought();
        bytes memory sig = _sign(FIXTURE_PK, _preimage(d)); // over untampered
        d.rainW1_e2 = 4_501; // one unit off — not re-signed

        vm.prank(relayer);
        vm.expectRevert(); // InvalidSignature
        pr.submitDroughtDetermination(d, sig);
    }

    /// @notice version() reflects the drought path.
    function test_version_isV220() public view {
        assertEq(pr.version(), "2.2.0", "version not bumped");
    }
}
