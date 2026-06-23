// MicroCrop — CROP_DAMAGE satellite-only conformance vector (Determination Schema v1.0).
// Companion to crop-damage-v1.0.json. Exercises the weatherPresent==0 branch (Finding 2):
// the weighted invariant renormalizes to 100% satellite weight. Regression marker: the chosen
// satelliteDamage PAYS under renormalization but would NOT under the old 60/40 formula.
import { ethers } from "ethers";

const id = (s) => ethers.id(s);
const abi = ethers.AbiCoder.defaultAbiCoder();
const packKeccak = ethers.solidityPackedKeccak256;

// ── Frozen domain (same as the primary vector) ──────────────────────────────
const SCHEMA_VERSION     = "1.0";
const KIND               = "CROP_DAMAGE";
const METHODOLOGY        = "crop-dualindex-1.0";
const CHAIN_ID           = 8453n;
const VERIFYING_CONTRACT = "0x522b5Ff31E21CD71C76fedE44297D99e40D820cf";
const WEATHER_WEIGHT = 60n, SATELLITE_WEIGHT = 40n, THRESHOLD_BP = 3000n, MAX_BP = 10000n, WEIGHT_DENOM = 100n;

// ── Field values — SATELLITE-ONLY (weatherPresent = 0, weather fields = 0) ───
const onChainPolicyId  = 1234n;
const latitude_e6      = -1286389n;     // int256 (Nairobi)
const longitude_e6     = 36817223n;     // int256
const sumInsured       = 1000000000n;   // 1000 USDC (6dp)
const ndviScaled       = 3500n;         // int256 (NDVI ~0.35; satellite-observed loss)
const weatherPresent   = 0n;            // satellite-only
const weatherTempC_e2  = 0n;            // weather absent -> zeroed
const weatherPrecip_e2 = 0n;
const weatherHumidity  = 0n;
const weatherWind_e2   = 0n;
const assessedAt       = 1718900000n;

// ── Damage: renormalized to 100% satellite weight (bp = satellite% * 100) ────
const weatherDamage   = 0n;             // MUST be 0 when weatherPresent == 0 (on-chain bound)
const satelliteDamage = 45n;            // whole percent
const damagePercentBp = satelliteDamage * WEIGHT_DENOM;        // 4500 bp = 45.00%
const payoutAmount    = (sumInsured * damagePercentBp) / MAX_BP; // 450 USDC
const oldFormulaBp    = WEATHER_WEIGHT * weatherDamage + SATELLITE_WEIGHT * satelliteDamage; // 1800 (regression marker)

// ── inputsHash (abi.encode) — identical field order to the primary vector ────
const INPUTS_TYPES = ["uint256","int256","int256","uint256","int256","uint256","int256","uint256","uint256","uint256"];
const INPUTS_VALUES = [onChainPolicyId, latitude_e6, longitude_e6, sumInsured, ndviScaled,
                       weatherPresent, weatherTempC_e2, weatherPrecip_e2, weatherHumidity, weatherWind_e2];
const inputsHash = ethers.keccak256(abi.encode(INPUTS_TYPES, INPUTS_VALUES));

// ── settlement preimage (abi.encodePacked) ──────────────────────────────────
const PRE_TYPES = ["bytes32","bytes32","bytes32","uint256","address","bytes32",
                   "uint256","uint256","uint256","uint256","uint256","uint256"];
const PRE_VALUES = [id(SCHEMA_VERSION), id(KIND), id(METHODOLOGY), CHAIN_ID, VERIFYING_CONTRACT, inputsHash,
                    onChainPolicyId, damagePercentBp, weatherDamage, satelliteDamage, payoutAmount, assessedAt];
const preimageHash = packKeccak(PRE_TYPES, PRE_VALUES);

// ── sign raw digest with the deterministic test PKP ─────────────────────────
const TEST_PKP_PRIVKEY = ethers.id("microcrop-test-pkp-v1");
const wallet = new ethers.Wallet(TEST_PKP_PRIVKEY);
const authorizedSigner = wallet.address;
const sig = wallet.signingKey.sign(preimageHash);
const recovered = ethers.recoverAddress(preimageHash, sig);

const checks = {
  "weatherPresent == 0":                       weatherPresent === 0n,
  "weatherDamage == 0 (bound)":                weatherDamage === 0n,
  "renorm: damageBp == satellite*100":         damagePercentBp === satelliteDamage * WEIGHT_DENOM,
  "renorm PAYS: damageBp >= 3000":             damagePercentBp >= THRESHOLD_BP,
  "REGRESSION: old 60/40 would NOT pay":       oldFormulaBp < THRESHOLD_BP,
  "REGRESSION: renorm != old formula":         damagePercentBp !== oldFormulaBp,
  "payout: sumInsured*damageBp/10000":         payoutAmount === (sumInsured * damagePercentBp) / MAX_BP,
  "signer: recovered == authorized":           recovered === authorizedSigner,
};

console.log(JSON.stringify({
  domain: { schemaVersion: SCHEMA_VERSION, kind: KIND, methodologyVersion: METHODOLOGY,
            chainId: Number(CHAIN_ID), verifyingContract: VERIFYING_CONTRACT },
  fieldValues: {
    onChainPolicyId: onChainPolicyId.toString(), latitude_e6: latitude_e6.toString(),
    longitude_e6: longitude_e6.toString(), sumInsured: sumInsured.toString(),
    ndviScaled: ndviScaled.toString(), weatherPresent: Number(weatherPresent),
    weatherTempC_e2: weatherTempC_e2.toString(), weatherPrecip_e2: weatherPrecip_e2.toString(),
    weatherHumidity: weatherHumidity.toString(), weatherWind_e2: weatherWind_e2.toString(),
    weatherDamage_pct: Number(weatherDamage), satelliteDamage_pct: Number(satelliteDamage),
    damagePercent_bp: Number(damagePercentBp), payoutAmount: payoutAmount.toString(),
    assessedAt: assessedAt.toString() },
  regression: { oldFormulaBp: Number(oldFormulaBp), renormBp: Number(damagePercentBp), thresholdBp: Number(THRESHOLD_BP) },
  inputsHash,
  preimageHash,
  signature: { r: sig.r, s: sig.s, v: sig.v, yParity: sig.yParity, serialized: sig.serialized },
  testPkpPrivKey: TEST_PKP_PRIVKEY,
  authorizedSigner,
  recovered,
  checks,
  allPassed: Object.values(checks).every(Boolean),
}, null, 2));
