// MicroCrop — CROP_DAMAGE conformance vector generator (Determination Schema v1.0)
// Computes REAL bytes: keccak over abi.encode/encodePacked, raw-digest sig, ecrecover.
// Deterministic test PKP so all three repos can reproduce identical bytes.
import { ethers } from "ethers";

const id = (s) => ethers.id(s);                       // keccak256(utf8 bytes(s))
const abi = ethers.AbiCoder.defaultAbiCoder();
const packKeccak = ethers.solidityPackedKeccak256;

// ── Frozen domain ───────────────────────────────────────────────────────────
const SCHEMA_VERSION     = "1.0";
const KIND               = "CROP_DAMAGE";
const METHODOLOGY        = "crop-dualindex-1.0";   // pins weights 60/40, threshold 3000bp
const CHAIN_ID           = 8453n;                  // Base mainnet
const VERIFYING_CONTRACT = "0x522b5Ff31E21CD71C76fedE44297D99e40D820cf"; // prod PayoutReceiver
const WEATHER_WEIGHT = 60n, SATELLITE_WEIGHT = 40n, THRESHOLD_BP = 3000n, MAX_BP = 10000n;

// ── Field values — ADVERSARIAL: negative latitude + sub-zero temp ────────────
// field            unit            multiplier  int type  width  signed
const onChainPolicyId  = 1234n;          // count          x1        uint256 32B  unsigned
const latitude_e6      = -1286389n;      // degrees        x1e6      int256  32B  SIGNED  (Nairobi -1.286389°)
const longitude_e6     = 36817223n;      // degrees        x1e6      int256  32B  SIGNED  (+36.817223°)
const sumInsured       = 1000000000n;    // USDC base(6dp) x1        uint256 32B  unsigned (1000 USDC)
const ndviScaled       = 3100n;          // NDVI           x1e4      int256  32B  SIGNED  (0.31; NDVI may be <0)
const weatherPresent   = 1n;             // flag 0|1       --        uint256 32B  unsigned
const weatherTempC_e2  = -350n;          // °C             x1e2      int256  32B  SIGNED  (-3.50°C highland frost)
const weatherPrecip_e2 = 0n;             // mm/h           x1e2      uint256 32B  unsigned
const weatherHumidity  = 55n;            // % RH           x1        uint256 32B  unsigned
const weatherWind_e2   = 1200n;          // km/h           x1e2      uint256 32B  unsigned (12.00)
const assessedAt       = 1718900000n;    // unix seconds   x1        uint256 32B  unsigned

// ── Dual-index scores (sub-scores WHOLE PERCENT, combined BASIS POINTS) ───────
const weatherDamage   = 40n;  // whole %  (temp -3.5 < 5 → +40)
const satelliteDamage = 60n;  // whole %  (ndvi 0.31 ∈ [0.3,0.4) → 60)
const damagePercentBp = WEATHER_WEIGHT * weatherDamage + SATELLITE_WEIGHT * satelliteDamage; // 4800 bp = 48.00%
const payoutAmount    = (sumInsured * damagePercentBp) / MAX_BP;                              // 480 USDC

// ── inputsHash preimage: abi.encode (32B-padded, two's-complement for int256) ─
// Using abi.encode (NOT encodePacked) so signed fields + boundaries are unambiguous.
const INPUTS_TYPES = ["uint256","int256","int256","uint256","int256","uint256","int256","uint256","uint256","uint256"];
const INPUTS_VALUES = [onChainPolicyId, latitude_e6, longitude_e6, sumInsured, ndviScaled,
                       weatherPresent, weatherTempC_e2, weatherPrecip_e2, weatherHumidity, weatherWind_e2];
const inputsEncoded = abi.encode(INPUTS_TYPES, INPUTS_VALUES);
const inputsHash    = ethers.keccak256(inputsEncoded);

// ── §5.2 settlement preimage: abi.encodePacked (solidityPackedKeccak256) ──────
const PRE_TYPES = ["bytes32","bytes32","bytes32","uint256","address","bytes32",
                   "uint256","uint256","uint256","uint256","uint256","uint256"];
const PRE_VALUES = [id(SCHEMA_VERSION), id(KIND), id(METHODOLOGY), CHAIN_ID, VERIFYING_CONTRACT, inputsHash,
                    onChainPolicyId, damagePercentBp, weatherDamage, satelliteDamage, payoutAmount, assessedAt];
const preimageHash = packKeccak(PRE_TYPES, PRE_VALUES);

// ── Sign the RAW digest (no EIP-191 prefix) with deterministic test PKP ───────
const TEST_PKP_PRIVKEY = ethers.id("microcrop-test-pkp-v1"); // reproducible by anyone
const wallet = new ethers.Wallet(TEST_PKP_PRIVKEY);
const authorizedSigner = wallet.address;
const sig = wallet.signingKey.sign(preimageHash);            // raw 32-byte digest
const recovered = ethers.recoverAddress(preimageHash, sig);  // == on-chain ECDSA.recover(preimageHash, sig)

// ── Invariant assertions (the contract will enforce these on-chain) ───────────
const checks = {
  "bounds: damageBp <= 10000":            damagePercentBp <= MAX_BP,
  "bounds: weather/sat <= 100":           weatherDamage <= 100n && satelliteDamage <= 100n,
  "weighted: 60w+40s == damageBp":        damagePercentBp === WEATHER_WEIGHT*weatherDamage + SATELLITE_WEIGHT*satelliteDamage,
  "threshold: damageBp >= 3000":          damagePercentBp >= THRESHOLD_BP,
  "payout: sumInsured*damageBp/10000":    payoutAmount === (sumInsured*damagePercentBp)/MAX_BP,
  "signer: recovered == authorized":      recovered === authorizedSigner,
};

// ── Collision check: missing-weather MUST hash differently from zero readings ─
const satelliteOnly = ethers.keccak256(abi.encode(INPUTS_TYPES,
  [onChainPolicyId, latitude_e6, longitude_e6, sumInsured, ndviScaled, 0n, 0n, 0n, 0n, 0n])); // weatherPresent=0
const zeroReadings = ethers.keccak256(abi.encode(INPUTS_TYPES,
  [onChainPolicyId, latitude_e6, longitude_e6, sumInsured, ndviScaled, 1n, 0n, 0n, 0n, 0n])); // present=1, zeros
checks["collision: satOnly != zeroReadings"] = satelliteOnly !== zeroReadings;

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
  inputsEncoded_len_bytes: (inputsEncoded.length - 2) / 2,
  inputsHash,
  preimageHash,
  signature: { r: sig.r, s: sig.s, v: sig.v, yParity: sig.yParity, serialized: sig.serialized },
  testPkpPrivKey: TEST_PKP_PRIVKEY,
  authorizedSigner,
  recovered,
  collision: { satelliteOnly, zeroReadings },
  checks,
  allPassed: Object.values(checks).every(Boolean),
}, null, 2));
