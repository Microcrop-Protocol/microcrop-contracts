// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutReceiver} from "../src/PayoutReceiver.sol";
import {PolicyManager} from "../src/PolicyManager.sol";

/// @notice Minimal PolicyManager stand-in for the canonical drought conformance vector.
contract ConfMockPolicyManager {
    PolicyManager.Policy private _policy;
    address public claimedFarmer;

    function setPolicy(PolicyManager.Policy calldata p) external {
        _policy = p;
    }

    function policyExists(uint256) external pure returns (bool) {
        return true;
    }

    function getPolicy(uint256) external view returns (PolicyManager.Policy memory) {
        return _policy;
    }

    function canFarmerClaim(address) external pure returns (bool) {
        return true;
    }

    function markAsClaimed(uint256) external {}

    function incrementClaimCount(address farmer) external {
        claimedFarmer = farmer;
    }
}

/// @notice Minimal Treasury stand-in — records the payout instruction.
contract ConfMockTreasury {
    uint256 public lastPolicyId;
    uint256 public lastAmount;

    function requestPayout(uint256 policyId, uint256 amount) external {
        lastPolicyId = policyId;
        lastAmount = amount;
    }
}

/// @notice CROSS-IMPLEMENTATION byte-conformance vector for the CROP_DROUGHT path (v2.2.0).
///
///         This is the Solidity leg of the tri-lateral conformance proof. It pins ONE canonical
///         drought determination fixture (V22_CROP_DROUGHT_PATH_SCOPE §2) and the two hashes that
///         the ORACLE (lit-actions/drought-oracle.js, ethers v5) and the BACKEND
///         (determination.service.js reconstructDrought, ethers v6) independently produce for that
///         exact fixture. It then drives the REAL contract path (submitDroughtDetermination) and
///         asserts the contract's OWN on-chain reconstruction equals the pinned preimage:
///
///           - the signature is over the PINNED preimage (FIXTURE_PREIMAGE);
///           - the contract rebuilds its own preimage from the raw struct fields, chain id, and
///             address(this), then recovers the signer from THAT hash;
///           - if the contract's reconstruction differed from the pinned value by one byte,
///             ecrecover would yield a non-authorized address and the call would revert.
///
///         So a green run proves: contract preimage == oracle preimage == backend preimage, and
///         likewise for inputsHash. Any field-order / type / packing drift in any of the three
///         implementations turns this red.
///
///         SINGLE canonical fixture: microcrop-backend tests/fixtures/drought-determination.fixture.json
///         (also pinned by that repo's determination-drought.test.js). Keep all three in lockstep.
contract DroughtConformanceTest is Test {
    // ── Canonical fixture domain (bound into the preimage) ──
    uint256 constant FIXTURE_CHAIN_ID = 8453;
    address constant FIXTURE_CONTRACT = 0x1111111111111111111111111111111111111111;

    // Deterministic PKP test key; its address is the authorized signer.
    uint256 constant FIXTURE_PK = uint256(keccak256("microcrop-test-pkp-v1"));
    address constant FIXTURE_SIGNER = 0xF18685788a4261DDA4f036D236066533a91C5ABE;

    // ── Canonical fixture: result/subject ──
    uint256 constant ONCHAIN_POLICY_ID = 12345;
    uint256 constant DAMAGE_BP = 4500; // == droughtDamage * 100, >= 3000
    uint256 constant DROUGHT_DAMAGE = 45; // whole percent
    uint256 constant SUM_INSURED = 1_000_000_000; // 1000 USDC (6dp)
    uint256 constant PAYOUT = 450_000_000; // 1e9 * 4500 / 10000
    uint256 constant ASSESSED_AT = 1_717_200_000;

    // ── Canonical fixture: evidence (inputsHash order 2..13) ──
    int256 constant LAT_E6 = -1_286_389;
    int256 constant LON_E6 = 36_817_223;
    uint256 constant SEASON_START = 1_710_460_800;
    uint256 constant LGP_DAYS = 180;
    uint256 constant RAIN_W1 = 12_500;
    uint256 constant RAIN_REF_W1 = 20_000;
    uint256 constant RAIN_W2 = 3_000;
    uint256 constant RAIN_REF_W2 = 18_000;
    uint256 constant CDD_W2 = 21;
    bytes32 constant SOURCE_HASH = 0x0914c3741661d9f021ffd84f45a6a87b43023ee2bc8caba7f294a419748441b0;
    bytes32 constant METHODOLOGY_PARAMS_HASH = 0x22ff3772b000bcf21ae06e8321f6e9eadb2d1ec524fea06f65d60f4b39940ffb;

    // ── PINNED cross-impl hashes (oracle + backend produce these for this exact fixture) ──
    bytes32 constant FIXTURE_INPUTS_HASH = 0xe6e25b7654138fdface20c80b1b4c20cbc63d95d198d93331c4dc24cb9022976;
    bytes32 constant FIXTURE_PREIMAGE = 0x99bb3f9190ccda217c466ba6d4541a7758174d49100cae72f81a8abdd4323f37;

    PayoutReceiver pr;
    ConfMockPolicyManager pm;
    ConfMockTreasury treasury;
    address admin = address(0xA11CE);
    address relayer = address(0xBEEF);
    address farmer = address(0xFA12);

    event DeterminationVerified(uint256 indexed policyId, bytes32 indexed preimageHash, address indexed signer);

    function setUp() public {
        vm.chainId(FIXTURE_CHAIN_ID);

        pm = new ConfMockPolicyManager();
        treasury = new ConfMockTreasury();

        // Place the contract at the fixture's verifyingContract so address(this) matches the
        // value bound into the pinned preimage.
        PayoutReceiver impl = new PayoutReceiver();
        vm.etch(FIXTURE_CONTRACT, address(impl).code);
        pr = PayoutReceiver(FIXTURE_CONTRACT);
        pr.initialize(address(treasury), address(pm), admin);

        pm.setPolicy(
            PolicyManager.Policy({
                id: ONCHAIN_POLICY_ID,
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

    function _fixture() internal pure returns (PayoutReceiver.DroughtDetermination memory) {
        return PayoutReceiver.DroughtDetermination({
            onChainPolicyId: ONCHAIN_POLICY_ID,
            damagePercentBp: DAMAGE_BP,
            droughtDamage: DROUGHT_DAMAGE,
            payoutAmount: PAYOUT,
            assessedAt: ASSESSED_AT,
            latitude_e6: LAT_E6,
            longitude_e6: LON_E6,
            sumInsured: SUM_INSURED,
            seasonStartEpoch: SEASON_START,
            lgpDays: LGP_DAYS,
            rainW1_e2: RAIN_W1,
            rainRefW1_e2: RAIN_REF_W1,
            rainW2_e2: RAIN_W2,
            rainRefW2_e2: RAIN_REF_W2,
            cddW2Days: CDD_W2,
            sourceHash: SOURCE_HASH,
            methodologyParamsHash: METHODOLOGY_PARAMS_HASH
        });
    }

    function _sign(bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FIXTURE_PK, digest); // raw digest, no EIP-191 prefix
        return abi.encodePacked(r, s, v);
    }

    /// @notice The test PKP address (Solidity-derived) equals the pinned signer.
    function test_signerAddressMatchesFixture() public pure {
        assertEq(vm.addr(FIXTURE_PK), FIXTURE_SIGNER, "PKP address drift");
    }

    /// @notice inputsHash: Solidity abi.encode of the 13-field fixture == the oracle/backend value.
    ///         (Byte-identical abi.encode across ethers v5, ethers v6, and solc.)
    function test_inputsHash_matchesCrossImpl() public pure {
        bytes32 ih = keccak256(
            abi.encode(
                ONCHAIN_POLICY_ID,
                LAT_E6,
                LON_E6,
                SUM_INSURED,
                SEASON_START,
                LGP_DAYS,
                RAIN_W1,
                RAIN_REF_W1,
                RAIN_W2,
                RAIN_REF_W2,
                CDD_W2,
                SOURCE_HASH,
                METHODOLOGY_PARAMS_HASH
            )
        );
        assertEq(ih, FIXTURE_INPUTS_HASH, "inputsHash drift vs oracle/backend");
    }

    /// @notice preimageHash: Solidity abi.encodePacked of the 11-field body == the oracle/backend
    ///         value, using the fixture domain (chainid + this contract's address).
    function test_preimageHash_matchesCrossImpl() public view {
        bytes32 ih = keccak256(
            abi.encode(
                ONCHAIN_POLICY_ID, LAT_E6, LON_E6, SUM_INSURED, SEASON_START, LGP_DAYS,
                RAIN_W1, RAIN_REF_W1, RAIN_W2, RAIN_REF_W2, CDD_W2, SOURCE_HASH, METHODOLOGY_PARAMS_HASH
            )
        );
        bytes32 ph = keccak256(
            abi.encodePacked(
                keccak256("1.0"),
                keccak256("CROP_DROUGHT"),
                keccak256("crop-drought-rdi-1.0"),
                block.chainid,
                FIXTURE_CONTRACT, // domain verifyingContract bound into the preimage
                ih,
                ONCHAIN_POLICY_ID,
                DAMAGE_BP,
                DROUGHT_DAMAGE,
                PAYOUT,
                ASSESSED_AT
            )
        );
        assertEq(ph, FIXTURE_PREIMAGE, "preimageHash drift vs oracle/backend");
    }

    /// @notice CORE PROOF: the deployed contract's OWN on-chain reconstruction equals the pinned
    ///         cross-impl preimage. Signature is over FIXTURE_PREIMAGE; the contract rebuilds its
    ///         own preimage from raw fields + block.chainid + address(this) and recovers the signer
    ///         from it. Emitting the exact pinned preimage (and not reverting) proves the contract's
    ///         reconstruction is byte-identical to the oracle's and backend's.
    function test_contractReconstructsPinnedPreimage_andPays() public {
        PayoutReceiver.DroughtDetermination memory d = _fixture();
        bytes memory sig = _sign(FIXTURE_PREIMAGE);

        vm.expectEmit(true, true, true, true);
        emit DeterminationVerified(ONCHAIN_POLICY_ID, FIXTURE_PREIMAGE, FIXTURE_SIGNER);

        vm.prank(relayer);
        pr.submitDroughtDetermination(d, sig);

        assertTrue(pr.policyPaid(ONCHAIN_POLICY_ID), "policy not marked paid");
        assertTrue(pr.consumedDetermination(FIXTURE_PREIMAGE), "determination not consumed");
        assertEq(treasury.lastAmount(), PAYOUT, "payout amount drift");
        assertEq(treasury.lastPolicyId(), ONCHAIN_POLICY_ID, "payout policy mismatch");
        assertEq(pm.claimedFarmer(), farmer, "claim count not incremented");
    }
}
