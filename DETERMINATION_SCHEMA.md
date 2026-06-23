# MicroCrop — Signed Determination Schema (FROZEN INTERFACE)

**Status:** `v1.0 — FROZEN (both unit + livestock-signer decisions locked)`
**Owner:** Protocol / Oracle
**Consumers (3):** `microcrop-lit-oracle` (producer/signer) · `microcrop-core` (persist + submit) · `microcrop-contracts/PayoutReceiver.sol` (verify + pay)
**Supersedes:** the Chainlink CRE `DamageReport` ingress (dropped per Target-State Spec v3 §8.0).

> This document is the **interface contract** between the three repos. It is referenced by Target-State Spec v3 §P0.1. Once frozen, the byte-level preimage and signature rules in §4–§6 **may not change without a version bump** (§10). Code on all three sides must conform to the same version.

**Locked decisions (this revision):**
- **Damage unit = basis points** for the signed combined value (§8.2). Forced by the contract's own economic math, not merely preferred. The envelope is deliberately **mixed-unit**: combined in bp, weather/satellite sub-scores in whole percent (§3, §5.2).
- **Livestock payout is authorized by a second Lit Action** that signs per-policy determinations; the PKP remains the **sole** signing authority (§8.4).
- **Every preimage binds an `inputsHash`** of the data it was computed from (crop + livestock), so a determination is verifiable against its own inputs (§5.1).
- **Separate PKPs per environment** (dev vs prod), in addition to domain separation (§6.3).

---

## 0. Why this exists (read first)

A "determination" is the signed, timestamped, reproducible output of the accredited calculating agent (Lit). It authorizes a payout and is the record a regulator audits (Spec v3 §4.2B, §6.2). For it to be trustworthy end-to-end, **the bytes the oracle signs must be exactly the bytes the contract recovers, in the unit the payout math consumes.** Today they are not — see §8.

This schema freezes three things:
1. The **off-chain envelope** (the JSON the oracle returns and core stores) — §3.
2. The **on-chain preimage** (the exact ABI encoding that gets hashed and signed) — §5.
3. The **signature + verification** rules (PKP secp256k1, raw digest, `ecrecover`) — §6.

---

## 1. Trust model (post-CRE)

```
Lit Action (inside Lit nodes)
  └─ computes index → if triggered, signs preimage with the THRESHOLD PKP
        │  SignedDetermination (JSON envelope, §3)
        ▼
microcrop-core  (NEW: POST /api/internal/determinations)
  └─ validates envelope, persists Determination row (§7),
     submits on-chain via NEW PayoutReceiver.submitDetermination(...)
        │
        ▼
PayoutReceiver.sol  (NEW path replacing receiveDamageReport)
  └─ recomputes preimage hash, ecrecover(sig) == authorizedSigner(PKP),
     re-validates economics (in bp), bounds-checks, marks policyPaid, instructs settlement
```

**Authority root:** a single configured **`authorizedSigner`** address per environment = the EVM address derived from that environment's threshold **PKP public key** (§6.3). Trust is "this determination was signed by the accredited agent's PKP," recovered on-chain via `ecrecover`. This **replaces** the old "trust whoever the Keystone Forwarder is" model (`PayoutReceiver.receiveDamageReport`, which does no signature recovery — §8.1).

---

## 2. Determination kinds

The envelope is **common**; the signed preimage has **two profiles** selected by `kind`.

| `kind` | Source oracle | Scope | Carries payout? | On-chain effect |
|---|---|---|---|---|
| `CROP_DAMAGE` | `crop-oracle.js` | per **policy** | yes (`payoutAmount`) | direct payout authorization |
| `LIVESTOCK_FORAGE` | `livestock-oracle.js` | per **insurance unit** | no (unit-level trigger) | trigger event recorded; fan-out below |
| `LIVESTOCK_PAYOUT` | **NEW** livestock fan-out Lit Action | per **policy** | yes (`payoutAmount`) | direct payout authorization |

> **Frozen decision (§8.4):** a `LIVESTOCK_FORAGE` unit trigger does not pay. A **second Lit Action** takes that trigger plus the per-policy data (TLU, sum insured) and signs one `LIVESTOCK_PAYOUT` determination per affected policy. The **same PKP** signs all three kinds — there is exactly one signing authority, which is the entire basis of the accredited-calculating-agent claim. No backend key ever authorizes a payout. `LIVESTOCK_PAYOUT` shares the `CROP_DAMAGE` economic shape (§5.4) so `PayoutReceiver` has **one** payout path.

---

## 3. Off-chain envelope (JSON)

The Lit Action `setResponse` payload and the core persistence row share this shape. `null` for fields not applicable to the `kind`.

```jsonc
{
  "schemaVersion": "1.0",            // string, == this doc's version
  "kind": "CROP_DAMAGE",             // "CROP_DAMAGE" | "LIVESTOCK_FORAGE" | "LIVESTOCK_PAYOUT"
  "methodologyVersion": "crop-dualindex-1.0", // §9 — pins weights/thresholds/buckets
  "domain": {                        // §6.3 replay/domain separation (FROZEN)
    "chainId": 8453,                 // uint256 — Base mainnet
    "verifyingContract": "0x522b5Ff31E21CD71C76fedE44297D99e40D820cf" // PayoutReceiver
  },
  "subject": {
    "onChainPolicyId": "1234",       // payout kinds: required; LIVESTOCK_FORAGE: null
    "unitCode": null                 // LIVESTOCK_FORAGE/PAYOUT: unit ref; CROP_DAMAGE: null
  },
  "result": {
    "damagePercent": 6480,           // BASIS POINTS, 0..10000 (signed value) — see units note
    "weatherDamage": 60,             // WHOLE PERCENT 0..100, CROP_DAMAGE only; else null
    "satelliteDamage": 72,           // WHOLE PERCENT 0..100, CROP_DAMAGE only; else null
    "ndviScaled": null,              // LIVESTOCK_FORAGE only (ndvi*10000); else null
    "payoutAmount": "648000000"      // payout kinds, USDC 6dp decimal string; else null
  },
  "evidence": {                      // §5.1 — RAW inputsHash inputs (REQUIRED on the wire)
    "latitude_e6": -1286389,         // the verifier reconstructs inputsHash from THESE on-chain,
    "longitude_e6": 36817223,        // so they must travel oracle→core→contract, not just the hash.
    "sumInsured": "1000000000",      // CROP_DAMAGE field set per §5.1; signed fields as int.
    "ndviScaled": 3100,
    "weatherPresent": 1,
    "weatherTempC_e2": -350,
    "weatherPrecip_e2": 0,
    "weatherHumidity": 55,
    "weatherWind_e2": 1200
  },
  "inputsHash": "0x…",               // §5.1 — keccak of `evidence` (binds determination to its evidence)
  "assessedAt": "1718900000",        // uint256 unix seconds, decimal string
  "preimageHash": "0x…",             // keccak256 of the §5 preimage (what was signed)
  "signature": { "r": "0x…", "s": "0x…", "v": 27, "signature": "0x…" } // §6
}
```

**UNITS (frozen — this is the bug-class killer, §8.2):**
- `damagePercent` is the **signed combined value in basis points (0..10000)**. It is the same unit the on-chain payout math consumes (`/10000`) — so signed-value and money-input are byte-identical and **no conversion exists anywhere on the settlement path.**
- `weatherDamage` / `satelliteDamage` are **whole percent (0..100)** — required by the on-chain weighted invariant (§5.2). The envelope is intentionally mixed-unit.
- **Invariant (enforced on-chain):** `damagePercent == 60·weatherDamage + 40·satelliteDamage`. With sub-scores in 0..100 this yields 0..10000 = bp. Weights `60/40` are pinned by `methodologyVersion` (§8.6).
- `payoutAmount` = USDC base units (6 dp) = `sumInsured_baseUnits · damagePercent / 10000`.

**Encoding rules (frozen):**
- Integers in the on-chain preimage travel as **decimal strings** in JSON to avoid JS precision loss (`payoutAmount`, `assessedAt`, `onChainPolicyId`, large `damagePercent`). Bounded ints may be JSON numbers but are `uint256` in the preimage.

---

## 4. What is signed (overview)

The signer signs `keccak256(preimage)` as a **raw 32-byte digest** — **no** EIP-191 prefix. Matches the current Lit Action (`signEcdsa({ toSign: arrayify(payloadHash) })`). The contract therefore verifies with `ecrecover(preimageHash, v, r, s)` directly (not `toEthSignedMessageHash`). Frozen; §6.2.

---

## 5. On-chain preimage (FROZEN — byte-exact)

`solidityKeccak256(types, values)` (== `abi.encodePacked` then keccak256). **Field order, types, and values below are normative.** Lit Action and `PayoutReceiver` MUST construct this identically.

### 5.1 Common prefix (all kinds)

| # | type | value |
|---|---|---|
| 0 | `bytes32` | `keccak256(bytes(schemaVersion))` |
| 1 | `bytes32` | `keccak256(bytes(kind))` |
| 2 | `bytes32` | `keccak256(bytes(methodologyVersion))` |
| 3 | `uint256` | `domain.chainId` |
| 4 | `address` | `domain.verifyingContract` |
| 5 | `bytes32` | `inputsHash` |

**`inputsHash` (frozen):** keccak256 over the canonical input set the determination was computed from, so the determination is **verifiable against its own evidence** (closes the "but the inputs came from your server" gap a sharp accreditor raises).

**Encoding rule (frozen, differs from §5 deliberately):** `inputsHash` uses **`abi.encode`** (every field 32-byte padded, `int256` two's-complement for signed values) — **not** `abi.encodePacked` — so signed fields and field boundaries are unambiguous. The §5 settlement preimage stays `abi.encodePacked` (all its fields are fixed-width and unsigned). These two encodings are distinct on purpose; do not unify them.

**`CROP_DAMAGE` field set + scales (FROZEN — ratified by `conformance-vectors/crop-damage-v1.0.json`):**

| # | field | unit | multiplier | type | signed | note |
|---|---|---|---|---|---|---|
| 0 | `onChainPolicyId` | count | ×1 | `uint256` | no | |
| 1 | `latitude_e6` | degrees | ×1e6 | `int256` | **yes** | ~11 cm res; S-hemisphere negative |
| 2 | `longitude_e6` | degrees | ×1e6 | `int256` | **yes** | |
| 3 | `sumInsured` | USDC base units (6dp) | ×1 | `uint256` | no | |
| 4 | `ndviScaled` | NDVI | ×1e4 | `int256` | **yes** | NDVI may be < 0 (water/cloud) |
| 5 | `weatherPresent` | flag 0\|1 | — | `uint256` | no | **null-handling, see below** |
| 6 | `weatherTempC_e2` | **°C** | ×1e2 | `int256` | **yes** | Celsius; sub-zero representable |
| 7 | `weatherPrecip_e2` | mm/h | ×1e2 | `uint256` | no | rate ≥ 0 |
| 8 | `weatherHumidity` | % RH | ×1 | `uint256` | no | 0..100 |
| 9 | `weatherWind_e2` | km/h | ×1e2 | `uint256` | no | ≥ 0 |

`inputsHash = keccak256(abi.encode(field0 … field9))` in the exact order above.

**Null-handling (frozen):** WeatherXM "nearest station within 10 km" can miss. When weather is absent the determination is **satellite-only**: set `weatherPresent = 0` and fields 6–9 to `0`. The `weatherPresent` flag guarantees this hashes **differently** from a real reading that happened to be `0` (`weatherPresent = 1`, fields 6–9 = `0`) — there is no collision between a missing measurement and a zero measurement. The vector proves this (`collision: satOnly != zeroReadings`).

> `LIVESTOCK_PAYOUT`: `keccak256(abi.encode(forageTriggerRef, onChainPolicyId, tluCount, sumInsured))`.
> `LIVESTOCK_FORAGE`: `keccak256(abi.encode(unitCode, bboxHash, ndviLookbackDays))`.
> Their scales are frozen the same way when their vectors are produced (§10).

### 5.2 `CROP_DAMAGE` body (per policy)

Appended after the common prefix (fields 0–5):

| # | type | value | unit |
|---|---|---|---|
| 6 | `uint256` | `onChainPolicyId` | — |
| 7 | `uint256` | `damagePercent` (combined) | **basis points 0..10000** |
| 8 | `uint256` | `weatherDamage` | **whole percent 0..100** |
| 9 | `uint256` | `satelliteDamage` | **whole percent 0..100** |
| 10 | `uint256` | `payoutAmount` (USDC 6dp) | — |
| 11 | `uint256` | `assessedAt` | unix s |

Reference construction:

```js
const preimageHash = ethers.utils.solidityKeccak256(
  ["bytes32","bytes32","bytes32","uint256","address","bytes32",
   "uint256","uint256","uint256","uint256","uint256","uint256"],
  [ keccak("1.0"), keccak("CROP_DAMAGE"), keccak(methodologyVersion), chainId, verifyingContract, inputsHash,
    onChainPolicyId, damagePercentBp, weatherDamage, satelliteDamage, payoutAmount, assessedAt ]
);
```

```solidity
bytes32 h = keccak256(abi.encodePacked(
    keccak256(bytes(SCHEMA_VERSION)), keccak256(bytes(KIND_CROP)), keccak256(bytes(methodologyVersion)),
    block.chainid, address(this), inputsHash,
    policyId, damagePercentBp, weatherDamage, satelliteDamage, payoutAmount, assessedAt
));
```

**On-chain re-validation for this body (all required):**
```solidity
if (damagePercentBp > 10000) revert DamageExceedsMaximum(...);            // bounds
if (weatherDamage > 100 || satelliteDamage > 100) revert OutOfRange(...); // bounds
if (weatherPresent > 1) revert InvalidWeatherFlag(...);                   // bounds
// evidence binding: a satellite-only determination MUST zero weatherDamage
if (weatherPresent == 0 && weatherDamage != 0) revert WeatherFlagDamageMismatch(...);
// weighted invariant (bp, NO /WEIGHT_DENOMINATOR — §8.2). Renormalize when weather is absent
// so a total satellite loss during a WeatherXM outage is not capped at 40% (Finding 2):
uint256 expectedBp = weatherPresent == 0
    ? satelliteDamage * 100                                  // satellite-only: 100% weight
    : 60*weatherDamage + 40*satelliteDamage;                 // dual-index
if (damagePercentBp != expectedBp) revert InvalidWeightedDamage(...);
if (damagePercentBp < MIN_DAMAGE_THRESHOLD) revert DamageBelowThreshold(...); // 3000 = 30%
if (payoutAmount != policy.sumInsured * damagePercentBp / 10000) revert InvalidPayoutCalculation(...);
```
> **Two weighted formulas, one methodology.** `crop-dualindex-1.0` covers both the dual-index
> case (weather present) and the satellite-only renormalization (`weatherPresent == 0`). The
> `weatherPresent` flag — bound into the preimage — selects the formula, so no schema-version
> bump is needed, but the methodology doc (§9) records both formulas for accreditation.

### 5.3 `LIVESTOCK_FORAGE` body (per unit — trigger only, no payout)

| # | type | value |
|---|---|---|
| 6 | `string` | `unitCode` |
| 7 | `uint256` | `ndviScaled` (ndvi × 10000) |
| 8 | `uint256` | `assessedAt` |

Verified and recorded on-chain (audit); does **not** call payout. Core fans it out to `LIVESTOCK_PAYOUT` determinations.

### 5.4 `LIVESTOCK_PAYOUT` body (per policy)

Identical layout to `CROP_DAMAGE` (§5.2) **except** fields 8/9 (weather/satellite) are `0` and the weighted-damage invariant is **not** applied (livestock damage derives from forage deficit, not the dual index). `damagePercent` is still **basis points** and the payout/threshold/bounds checks in §5.2 apply unchanged. `kind = "LIVESTOCK_PAYOUT"` and `methodologyVersion = "livestock-ibli-1.0"` distinguish it in the preimage, so a livestock determination can never be replayed as a crop one.

**Idempotency model (FROZEN — one trigger → many policies):** a single `LIVESTOCK_FORAGE` unit trigger fans out to **N independent `LIVESTOCK_PAYOUT` determinations, one per policy.** Each MUST be its own determination with its own `onChainPolicyId`, its own `inputsHash` (binding that policy's `tluCount`/`sumInsured`, §5.1), and therefore its own distinct `preimageHash` and its own `policyPaid`/`consumedDetermination` guard. The on-chain guards are per-policy and independent: paying policy A must not mark policy B consumed, and a re-fan-out that re-pays A must revert without suppressing B. **Forbidden:** reusing one unit-level determination/`preimageHash` to authorize multiple policies — that would let a single `consumedDetermination` mark suppress sibling payouts (and break per-policy economics). The fan-out Lit Action signs N times, not once. This gets the same idempotency scrutiny as crop when `LIVESTOCK_PAYOUT` lands.

---

## 6. Signature & verification

### 6.1 Signature
- secp256k1, Lit `signEcdsa` with the environment's **threshold PKP**.
- Signs the **raw** `preimageHash` (32 bytes), no prefix.
- Envelope carries `r`, `s`, `v` and the 65-byte `signature`. Normalize Lit `recid` 0/1 → `v` 27/28 in core before submit.

### 6.2 On-chain verification (NEW in PayoutReceiver)
```solidity
address recovered = ECDSA.recover(preimageHash, signature); // OZ; rejects malleable high-s
if (recovered != authorizedSigner) revert InvalidSignature(recovered, authorizedSigner);
```
Use OZ `ECDSA.recover` over the raw digest (not `toEthSignedMessageHash`) — gives low-`s`/`v` malleability protection for free. `authorizedSigner` is a role-gated settable state var = the PKP's EVM address.

### 6.3 Replay / domain separation + key isolation (FROZEN, belt-and-suspenders)
1. **Domain prefix** (§5.1 fields 0–5) binds each determination to `(schemaVersion, kind, methodologyVersion, chainId, verifyingContract, inputsHash)`.
2. **Separate PKP per environment.** Dev and prod use **different** threshold PKPs ⇒ different `authorizedSigner`. A dev key compromise cannot even produce a prod-recoverable signature — removes the shared-authority root cause, not just the replayability.
3. **`policyPaid[policyId]`** (existing) blocks double-pay per policy.
4. **`assessedAt` + `MAX_REPORT_AGE`** (existing, 1h) bounds freshness.

Layers 1 and 2 are independent; ship both.

---

## 7. Persistence (microcrop-core — NEW)

Add a `Determination` model (only `Payout` exists today). Minimum columns:

```prisma
model Determination {
  id                 String   @id @default(cuid())
  kind               String   // CROP_DAMAGE | LIVESTOCK_FORAGE | LIVESTOCK_PAYOUT
  schemaVersion      String
  methodologyVersion String
  onChainPolicyId    String?
  unitCode           String?
  damagePercentBp    Int                 // basis points
  weatherDamage      Int?                // whole percent
  satelliteDamage    Int?                // whole percent
  ndviScaled         Int?
  payoutAmount       String?             // USDC base units
  inputsHash         String              // §5.1
  assessedAt         DateTime
  chainId            Int
  verifyingContract  String
  preimageHash       String   @unique    // idempotency key
  signature          String              // 65-byte hex
  signerAddress      String              // recovered; must == env authorizedSigner
  submittedTxHash    String?
  status             String              // RECEIVED | SUBMITTED | CONFIRMED | REJECTED
  rawEnvelope        Json                // full §3 object, for regulator export §6.2
  createdAt          DateTime @default(now())
}
```
- **Ingress:** `POST /api/internal/determinations` (auth like `/api/internal/active-policies`). Validate envelope, recover signer locally (defense in depth), reject on mismatch, dedupe on `preimageHash`, enqueue submit.
- **Submit:** new `payoutReceiver.writer.js` → `submitDetermination(...)` via the existing nonce manager.
- `rawEnvelope` feeds the regulator-export artifact (Spec v3 §6.2).

---

## 8. Findings the freeze exposed (status)

### 8.1 `PayoutReceiver` has no signature verification — `microcrop-contracts` — **TRUE P0**
`receiveDamageReport(...)` trusts `msg.sender == keystoneForwarderAddress` + workflow id; **no `ecrecover`**. Until `submitDetermination(...)` (§5/§6) exists, dropping CRE leaves **no secure settlement entrypoint at all** — the oracle signs into nothing. Everything else sequences behind this. Add the new path; remove the Keystone path (Spec v3 §4.1/§8.0); keep `policyPaid`, freshness, and policy-state checks.

### 8.2 Damage unit — **RESOLVED → basis points (forced, not chosen)**
The contract is **internally inconsistent today**: threshold (`3000`) and payout (`/10000`) assume **bp**, but the weighted-damage check `(60w+40s)/100 == damage` assumes **whole percent**. Fed the oracle's current whole-percent `combined` (~64), the contract **reverts at the threshold check** — **a crop claim cannot be paid at all right now.** Resolution: sign the combined value in **bp**; **remove the `/WEIGHT_DENOMINATOR`** from the weighted check so it yields bp; keep weather/satellite sub-scores in whole percent (§5.2). Net: one unit on the entire money path, conversion structurally absent, plus explicit bounds reverts (§5.2). Oracle change is one line: emit `combined_bp = 60·wDamage + 40·sDamage`, `payout = sumInsured·combined_bp/10000`, gate `>= 3000`.

### 8.3 Domain separation absent — both repos — **RESOLVED**
Neither preimage bound `chainId`/`verifyingContract`; dev (`0x1151…fabd0`) + prod (`0x522b…820cf`) + one PKP ⇒ dev→prod replay. Closed by §6.3 layers 1 **and** 2 (separate PKP per env).

### 8.4 Livestock → payout signer — **RESOLVED → second Lit Action, PKP sole authority**
A backend signer would create a second signing authority MicroCrop controls and undercut the accredited-agent claim that justified dropping CRE. Instead, a fan-out Lit Action signs per-policy `LIVESTOCK_PAYOUT` determinations (§2, §5.4), bound to inputs via `inputsHash` (§5.1). Data needed (TLU, sumInsured, county, farmerWallet) is already served by `/api/internal/active-policies`.

### 8.5 Open loop today — `microcrop-core` — **must build (§7)**
No ingress route, no `PayoutReceiver` writer. Until §7 ships, signed determinations go nowhere.

### 8.6 Configurable weights vs hardcoded constants — `microcrop-lit-oracle` ↔ `microcrop-contracts` — **RESOLVED → pin to methodology**
Oracle weights are params (default `0.6/0.4`); contract hardcodes `60/40`. A non-default config silently breaks the §5.2 weighted invariant. v1.0: weights `60/40` are **part of `crop-dualindex-1.0`**; the orchestrator MUST pass 0.6/0.4; any weight change ⇒ new `methodologyVersion` + contract upgrade. (Alternative — carry weights in the determination and read on-chain — deferred to a future version.)

---

## 9. Methodology versioning

`methodologyVersion` (preimage field 2) pins the determination to the exact methodology in force — weights, NDVI buckets, thresholds, cadence — for audit reproducibility (Spec v3 §4.2B/§4.3). Registry in `microcrop-lit-oracle`:
- `crop-dualindex-1.0` — 30% threshold (3000 bp), NDVI buckets per `crop-oracle.js`, weights pinned 60/40 (§8.6). **Two weighted-damage formulas, selected by `weatherPresent`:**
  - **Weather present** (`weatherPresent = 1`): `damageBp = 60·weatherDamage% + 40·satelliteDamage%` (WeatherXM 60% + Sentinel-2 40%).
  - **Satellite-only** (`weatherPresent = 0`, e.g. no WeatherXM station within 10 km): renormalized to 100% satellite weight, `damageBp = 100·satelliteDamage%`, with `weatherDamage` required to be 0. Without this renormalization a total satellite-observed loss during a weather-data outage would be capped at 40% (Finding 2). Both formulas are part of this single methodology version; the accreditation package must present both.
- `livestock-ibli-1.0` — NDVI deficit vs unit baseline, strike per `InsuranceUnit`.

Changing weights/buckets/thresholds ⇒ **new version**, not an edit; historical determinations stay verifiable.

---

## 10. Change control

- The **§5 preimage** (incl. `inputsHash` field definitions), **§6 signature rules**, and **§3 envelope units** are frozen at `v1.0`.
- Any change to field order, types, units, hashing, or signing prefix ⇒ **bump `schemaVersion`**. Old determinations remain verifiable under their stamped version.
- All three repos pin the version they implement. **CI conformance vector:** one determination per kind, its `inputsHash`, its `preimageHash`, and the recovered signer — the Lit Action, a core unit test, and a Foundry test must all reproduce the **same** `preimageHash` and recover the **same** signer. This vector is the executable definition of "frozen" and **`submitDetermination` is coded to pass it.**
- **`CROP_DAMAGE` vector — RATIFIED:** `conformance-vectors/crop-damage-v1.0.json` (generator: `gen-crop-damage-v1.0.mjs`). It is deliberately adversarial: negative `latitude_e6 = -1286389`, sub-zero `weatherTempC_e2 = -350`, and a missing-weather collision check. Independently reproduced **byte-for-byte by two encoders** (ethers v6 and Foundry `cast`):
  - `inputsHash  = 0x00c9518d24a624358f4d8fb8b02334662ffe0c055e2ad47f41a98c27b253ffe2`
  - `preimageHash = 0x6327a4a82c9df61cdd4c391a1250d50c1500d290ec195609654e576ccacb2947`
  - test PKP `0x7a294768…` (deterministic, = `keccak256("microcrop-test-pkp-v1")`) → `authorizedSigner = 0xF18685788a4261DDA4f036D236066533a91C5ABE`; `ecrecover` over the **raw** `preimageHash` returns the same address.
  - reproduced on-chain by `test/PayoutDetermination.t.sol` (Foundry `ECDSA.recover` → `0xF186…5ABE`).
- **`CROP_DAMAGE` satellite-only vector — RATIFIED:** `conformance-vectors/crop-damage-satonly-v1.0.json` (generator: `gen-crop-damage-satonly-v1.0.mjs`). Covers the `weatherPresent = 0` renormalization branch (Finding 2) the primary vector did not exercise. Chosen so the renormalized value **pays** but the legacy 60/40 value would **not** — the embedded regression marker:
  - `inputsHash  = 0x94b89f2f4c39c24355b52c7a8e9e9287cfffb813e3d7fbca468a36ebcca97535`
  - `preimageHash = 0x8a67a201014c8131d8a18f79764bc386ed3b1966321a6b52f68f7a6ceeabe1c1`
  - `satelliteDamage = 45 → damageBp 4500` (renorm, ≥3000 pays) vs `60·0 + 40·45 = 1800` (legacy, <3000 would not pay).
  - Reproduced byte-for-byte by ethers v6 + Foundry `cast`; tested on-chain by `test_satelliteOnly_*` (pays, flag-binding revert, old-formula regression revert).
- Both `CROP_DAMAGE` vectors (weather-present and satellite-only) MUST pass — they are not alternatives.
- `LIVESTOCK_FORAGE` / `LIVESTOCK_PAYOUT` vectors to be produced the same way before their code lands.

---

## Appendix A — required changes by repo (P0.1 checklist)

**microcrop-contracts** *(true P0 — §8.1)*
- [ ] `submitDetermination(...)` with §5 preimage + §6 OZ `ECDSA.recover` + per-env `authorizedSigner` (role-gated setter).
- [ ] Weighted check **without** `/WEIGHT_DENOMINATOR`; damage in bp; explicit bounds reverts (§5.2).
- [ ] Remove Keystone/CRE `receiveDamageReport` path (Spec v3 §4.1/§8.0).
- [ ] Storage-layout-safe UUPS upgrade (append-only; existing 50-slot gap).
- [ ] Emit + reproduce the shared conformance vector (§10).

**microcrop-lit-oracle**
- [ ] Emit `combined` in **bp** (`60·wDamage + 40·sDamage`), payout `/10000`, threshold `3000`.
- [ ] Add common prefix (§5.1) incl. `inputsHash` to crop + livestock preimages; full §3 envelope.
- [ ] New fan-out Lit Action → per-policy `LIVESTOCK_PAYOUT` (§2/§5.4).
- [ ] Pin weights 0.6/0.4 (§8.6); methodology registry + ids (§9).
- [ ] Normalize `v` to 27/28; separate PKP per env (§6.3).

**microcrop-core**
- [ ] `Determination` model + migration (§7).
- [ ] `POST /api/internal/determinations` ingress (auth, validate, local recover, dedupe).
- [ ] `payoutReceiver.writer.js` → `submitDetermination` via nonce manager.
- [ ] Livestock fan-out orchestration (trigger → invoke fan-out Lit Action → submit each).
- [ ] Wire `rawEnvelope` into regulator-export; core copy of the conformance vector (§10).
