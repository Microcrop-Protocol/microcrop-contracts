// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/// @notice Minimal PolicyManager stand-in — only the functions submitDetermination calls.
contract MockPolicyManager {
    PolicyManager.Policy private _policy;
    uint256 public claimedId;
    address public claimedFarmer;

    function setPolicy(PolicyManager.Policy calldata p) external { _policy = p; }
    function policyExists(uint256) external pure returns (bool) { return true; }
    function getPolicy(uint256) external view returns (PolicyManager.Policy memory) { return _policy; }
    function canFarmerClaim(address) external pure returns (bool) { return true; }
    function markAsClaimed(uint256 id) external { claimedId = id; }
    function incrementClaimCount(address farmer) external { claimedFarmer = farmer; }
}

/// @notice Minimal Treasury stand-in — records the payout instruction.
contract MockTreasury {
    uint256 public lastPolicyId;
    uint256 public lastAmount;
    function requestPayout(uint256 policyId, uint256 amount) external {
        lastPolicyId = policyId;
        lastAmount = amount;
    }
}

/// @notice Third independent reproduction of the Determination Schema v1.0 conformance vector,
///         at the Solidity/EVM layer. Mirrors conformance-vectors/crop-damage-v1.0.json.
contract PayoutDeterminationTest is Test {
    // ── Frozen fixture values (conformance-vectors/crop-damage-v1.0.json) ──
    uint256 constant FIXTURE_PK          = uint256(keccak256("microcrop-test-pkp-v1"));
    address constant FIXTURE_SIGNER      = 0xF18685788a4261DDA4f036D236066533a91C5ABE;
    bytes32 constant FIXTURE_INPUTS_HASH = 0x00c9518d24a624358f4d8fb8b02334662ffe0c055e2ad47f41a98c27b253ffe2;
    bytes32 constant FIXTURE_PREIMAGE    = 0x6327a4a82c9df61cdd4c391a1250d50c1500d290ec195609654e576ccacb2947;
    // crop-damage-satonly-v1.0.json — weatherPresent=0, satellite=45 -> 4500bp (renormalized)
    bytes32 constant FIXTURE_SATONLY_PREIMAGE = 0x8a67a201014c8131d8a18f79764bc386ed3b1966321a6b52f68f7a6ceeabe1c1;
    // The fixture's domain (§6.3): chainId + verifyingContract are bound into the preimage.
    // To reproduce the literal fixture bytes, the test environment must match BOTH.
    uint256 constant FIXTURE_CHAIN_ID    = 8453;
    address constant FIXTURE_CONTRACT    = 0x522b5Ff31E21CD71C76fedE44297D99e40D820cf;

    PayoutReceiver pr;
    MockPolicyManager pm;
    MockTreasury treasury;
    address admin = address(0xA11CE);
    address relayer = address(0xBEEF);

    event DeterminationVerified(uint256 indexed policyId, bytes32 indexed preimageHash, address indexed signer);

    function setUp() public {
        // Match the fixture domain so the contract reconstructs the EXACT fixture preimage.
        vm.chainId(FIXTURE_CHAIN_ID);

        pm = new MockPolicyManager();
        treasury = new MockTreasury();

        // Place the contract at the fixture's verifyingContract address. Etch sets runtime code
        // without running the constructor, so initializers are NOT disabled and we can initialize.
        PayoutReceiver impl = new PayoutReceiver();
        vm.etch(FIXTURE_CONTRACT, address(impl).code);
        pr = PayoutReceiver(FIXTURE_CONTRACT);
        pr.initialize(address(treasury), address(pm), admin);

        // Policy matching the fixture: id 1234, sumInsured 1e9 (1000 USDC), ACTIVE, far-future end.
        pm.setPolicy(PolicyManager.Policy({
            id: 1234,
            farmer: address(0xFA12),
            plotId: 1,
            sumInsured: 1_000_000_000,
            premium: 1,
            startDate: 1,
            endDate: type(uint256).max,
            coverageType: PolicyManager.CoverageType.DROUGHT,
            status: PolicyManager.PolicyStatus.ACTIVE,
            createdAt: 1
        }));

        vm.startPrank(admin);
        pr.setAuthorizedSigner(FIXTURE_SIGNER);
        pr.grantRole(pr.RELAYER_ROLE(), relayer);
        vm.stopPrank();

        // Freshness window: assessedAt (1718900000) <= now <= +1h
        vm.warp(1_718_900_000 + 600);
    }

    /// @dev Builds the exact fixture determination struct.
    function _fixtureDetermination() internal pure returns (PayoutReceiver.CropDetermination memory) {
        return PayoutReceiver.CropDetermination({
            onChainPolicyId: 1234,
            damagePercentBp: 4800,
            weatherDamage: 40,
            satelliteDamage: 60,
            payoutAmount: 480_000_000,
            assessedAt: 1_718_900_000,
            latitude_e6: -1_286_389,
            longitude_e6: 36_817_223,
            sumInsured: 1_000_000_000,
            ndviScaled: 3100,
            weatherPresent: 1,
            weatherTempC_e2: -350,
            weatherPrecip_e2: 0,
            weatherHumidity: 55,
            weatherWind_e2: 1200
        });
    }

    /// @dev Satellite-only determination (weatherPresent=0): damageBp = satellite*100 (renormalized).
    function _satOnlyDetermination() internal pure returns (PayoutReceiver.CropDetermination memory) {
        return PayoutReceiver.CropDetermination({
            onChainPolicyId: 1234,
            damagePercentBp: 4500, // 45 * 100 (100% satellite weight)
            weatherDamage: 0,
            satelliteDamage: 45,
            payoutAmount: 450_000_000, // 1e9 * 4500 / 10000
            assessedAt: 1_718_900_000,
            latitude_e6: -1_286_389,
            longitude_e6: 36_817_223,
            sumInsured: 1_000_000_000,
            ndviScaled: 3500,
            weatherPresent: 0,
            weatherTempC_e2: 0,
            weatherPrecip_e2: 0,
            weatherHumidity: 0,
            weatherWind_e2: 0
        });
    }

    function _sign(bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FIXTURE_PK, digest); // raw digest, no prefix
        return abi.encodePacked(r, s, v);
    }

    /// @notice The deterministic PKP address derived in Solidity must equal the fixture's.
    function test_signerAddressMatchesFixture() public pure {
        assertEq(vm.addr(FIXTURE_PK), FIXTURE_SIGNER, "PKP address drift");
    }

    /// @notice CORE PROOF: the contract reconstructs preimageHash == fixture and recovers the
    ///         fixture signer. We sign the FIXTURE preimage; the contract rebuilds its own from
    ///         raw fields. If they differ by one byte, recovery fails and this reverts.
    function test_submitDetermination_reconstructsFixtureAndPays() public {
        PayoutReceiver.CropDetermination memory d = _fixtureDetermination();
        bytes memory sig = _sign(FIXTURE_PREIMAGE);

        // Assert the contract emits the EXACT fixture preimageHash and signer.
        vm.expectEmit(true, true, true, true);
        emit DeterminationVerified(1234, FIXTURE_PREIMAGE, FIXTURE_SIGNER);

        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        assertTrue(pr.policyPaid(1234), "policy not marked paid");
        assertTrue(pr.consumedDetermination(FIXTURE_PREIMAGE), "determination not consumed");
        assertEq(treasury.lastAmount(), 480_000_000, "payout amount drift (bp money path)");
        assertEq(treasury.lastPolicyId(), 1234, "payout policy mismatch");
        assertEq(pm.claimedFarmer(), address(0xFA12), "claim count not incremented");
    }

    /// @notice One-byte flip of an evidence field (latitude) changes inputsHash -> preimageHash,
    ///         so recovery yields a different address -> InvalidSignature. (Sign path is exercised
    ///         by the negative latitude / sub-zero temp already in the happy-path fixture.)
    function test_tamperedEvidence_revertsInvalidSignature() public {
        PayoutReceiver.CropDetermination memory d = _fixtureDetermination();
        bytes memory sig = _sign(FIXTURE_PREIMAGE);     // signature over the untampered hash
        d.latitude_e6 = -1_286_390;                     // one unit off

        vm.prank(relayer);
        vm.expectRevert(); // InvalidSignature(recovered, expected)
        pr.submitDetermination(d, sig);
    }

    /// @notice A determination cannot be consumed twice.
    function test_resubmission_reverts() public {
        PayoutReceiver.CropDetermination memory d = _fixtureDetermination();
        bytes memory sig = _sign(FIXTURE_PREIMAGE);

        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.PolicyAlreadyPaid.selector, uint256(1234)));
        pr.submitDetermination(d, sig);
    }

    /// @notice Non-relayer cannot submit (anti-spam gate), independent of signature validity.
    function test_nonRelayer_reverts() public {
        PayoutReceiver.CropDetermination memory d = _fixtureDetermination();
        bytes memory sig = _sign(FIXTURE_PREIMAGE);

        vm.expectRevert(); // AccessControl: missing RELAYER_ROLE
        pr.submitDetermination(d, sig);
    }

    /// @notice DEPLOYMENT GATE: RELAYER_ROLE is NOT auto-granted by initialize — the deploy
    ///         sequence MUST grant it to the relayer wallet, or the first real determination
    ///         reverts at the relayer gate (silently-dead payouts). Makes that visible pre-deploy.
    function test_deployment_relayerGateConfigured() public {
        bytes32 relayerRole = pr.RELAYER_ROLE();
        // initialize() grants admin DEFAULT_ADMIN/ADMIN/UPGRADER but NOT RELAYER_ROLE:
        assertFalse(pr.hasRole(relayerRole, admin), "RELAYER_ROLE must not be auto-granted by initialize");
        // the deploy step (modeled in setUp) explicitly granted it to the relayer wallet:
        assertTrue(pr.hasRole(relayerRole, relayer), "deploy must grant RELAYER_ROLE to the relayer wallet");
        // and an address without the role is blocked at the gate:
        PayoutReceiver.CropDetermination memory d = _fixtureDetermination();
        bytes memory sig = _sign(FIXTURE_PREIMAGE);
        vm.prank(address(0xD15EA5E));
        vm.expectRevert(); // AccessControl: missing RELAYER_ROLE
        pr.submitDetermination(d, sig);
    }

    /// @notice The contract's inputsHash reconstruction matches the fixture (abi.encode path).
    function test_inputsHash_matchesFixture() public pure {
        bytes32 ih = keccak256(abi.encode(
            uint256(1234), int256(-1_286_389), int256(36_817_223), uint256(1_000_000_000),
            int256(3100), uint256(1), int256(-350), uint256(0), uint256(55), uint256(1200)
        ));
        assertEq(ih, FIXTURE_INPUTS_HASH, "inputsHash drift");
    }

    // ── Finding 2: satellite-only (weatherPresent=0) renormalization ──────────────

    /// @notice Satellite-only determination reconstructs the satonly fixture preimage and pays
    ///         the renormalized amount (4500bp / 450 USDC), not the 40%-capped legacy amount.
    function test_satelliteOnly_reconstructsAndPays() public {
        PayoutReceiver.CropDetermination memory d = _satOnlyDetermination();
        bytes memory sig = _sign(FIXTURE_SATONLY_PREIMAGE);

        vm.expectEmit(true, true, true, true);
        emit DeterminationVerified(1234, FIXTURE_SATONLY_PREIMAGE, FIXTURE_SIGNER);

        vm.prank(relayer);
        pr.submitDetermination(d, sig);

        assertTrue(pr.policyPaid(1234), "policy not paid");
        assertEq(treasury.lastAmount(), 450_000_000, "renormalized payout wrong (40% cap regression?)");
    }

    /// @notice weatherPresent=0 with nonzero weatherDamage is rejected (evidence binding).
    function test_satelliteOnly_inconsistentFlag_reverts() public {
        PayoutReceiver.CropDetermination memory d = _satOnlyDetermination();
        d.weatherDamage = 10; // inconsistent with weatherPresent=0
        bytes memory sig = _sign(FIXTURE_SATONLY_PREIMAGE);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.WeatherFlagDamageMismatch.selector, uint256(0), uint256(10)));
        pr.submitDetermination(d, sig);
    }

    /// @notice REGRESSION: the old 60/40 value (1800bp) for a satellite-only determination is
    ///         rejected by the renormalized invariant before the signature is even checked.
    function test_satelliteOnly_oldFormulaValue_reverts() public {
        PayoutReceiver.CropDetermination memory d = _satOnlyDetermination();
        d.damagePercentBp = 1800; // 60*0 + 40*45 — what the pre-fix code would have required
        bytes memory sig = _sign(FIXTURE_SATONLY_PREIMAGE);

        vm.prank(relayer);
        // expected = satellite*100 = 4500; provided = 1800
        vm.expectRevert(abi.encodeWithSelector(PayoutReceiver.InvalidWeightedDamage.selector, uint256(4500), uint256(1800)));
        pr.submitDetermination(d, sig);
    }
}
