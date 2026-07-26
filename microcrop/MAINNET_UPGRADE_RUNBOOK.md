# MAINNET UPGRADE RUNBOOK — Pilot on-chain prep (PayoutReceiver v1.0.0 → v2.1.0)

**Scope:** the three on-chain actions the pilot needs on **Base mainnet** (chain `8453`):

1. **PayoutReceiver UUPS upgrade** v1.0.0 → **v2.1.0** (adds `submitDetermination`, the PKP-signed
   parametric settlement path + security audit batch 1-2 fixes).
2. **Wire the determination path:** `setAuthorizedSigner(prodPKP)` + `grantRole(RELAYER_ROLE, backendRelayerWallet)`.
3. **Migrate admin/upgrader** off the single EOA onto a **Gnosis-Safe-owned TimelockController**
   (grant-then-renounce).

> **This runbook is executed by a human.** Every `forge script` below is shown FIRST as a
> **fork dry-run (NO `--broadcast`)** and SECOND as the real mainnet command (with `--broadcast`).
> Never broadcast until the dry-run output matches what's shown here.

---

## 0. Fixed on-chain facts (verified via `cast` against live mainnet)

| Thing | Value |
|---|---|
| PayoutReceiver **proxy** | `0x522b5Ff31E21CD71C76fedE44297D99e40D820cf` |
| PayoutReceiver impl (current, v1.0.0) | `0xd93947f30596b22360d7a3a85fa1c49f406af1cb` |
| Treasury proxy | `0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f` |
| PolicyManager proxy | `0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F` |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| **Current admin/upgrader EOA** | `0xC5867D3b114f10356bAAb7b77E04783cfA947c44` |
| Conformance **TEST** PKP (must NEVER be prod signer) | `0xF18685788a4261DDA4f036D236066533a91C5ABE` |

The EOA `0xC586…7c44` currently holds `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, and `ADMIN_ROLE` on the
proxy (confirmed live). `version()` currently reads `1.0.0`; `authorizedSigner()` **reverts** (the
function does not exist on v1).

### Placeholders you must fill (never commit real values)

| Placeholder | Meaning |
|---|---|
| `<PROD_PKP>` | EVM address of the **production** Lit PKP (the accredited calculating agent). MUST differ from the TEST PKP. |
| `<BACKEND_RELAYER>` | backend wallet that relays determinations (receives `RELAYER_ROLE`; anti-spam gate only). |
| `<TIMELOCK>` | deployed `TimelockController` address whose sole proposer/executor is the Gnosis Safe. |
| `<SAFE>` | Gnosis Safe multisig address (proposer/executor/canceller on the timelock). |
| `$BASE_MAINNET_RPC_URL` | your Base mainnet RPC (in `.env`; never printed). |

---

## 1. Preconditions (do NOT skip)

- [ ] `git` is on branch `feature/pilot-onchain-prep` (this branch); `forge build` is clean.
- [ ] `src/PayoutReceiver.sol` `version()` returns **`2.1.0`** (`grep 'return "2' src/PayoutReceiver.sol`).
- [ ] The **production** Lit PKP is provisioned; you have its EVM address `<PROD_PKP>` and it is **not**
      the TEST PKP.
- [ ] The **Gnosis Safe** `<SAFE>` and **TimelockController** `<TIMELOCK>` are already deployed on Base
      mainnet, with the Safe as the timelock's proposer + executor + canceller, and a sane `minDelay`
      (recommend ≥ 48h). *(Standing these up is out of scope for these scripts.)*
- [ ] The admin EOA keystore is imported as a foundry account: `cast wallet import admin --interactive`.
- [ ] The EOA has enough ETH for gas (dry-run estimated ≈ `0.00003 ETH` for the upgrade tx set).
- [ ] Fork tests are green (Section 5).

---

## 2. Action 1 + 2 — Upgrade to v2.1.0, set signer, grant relayer

Script: `script/UpgradePayoutReceiverV21Mainnet.s.sol`. It deploys a fresh v2.1.0 impl,
`upgradeToAndCall(impl, "")`, `setAuthorizedSigner(<PROD_PKP>)`, `grantRole(RELAYER_ROLE, <BACKEND_RELAYER>)`,
and asserts `version()==2.1.0`, `authorizedSigner==<PROD_PKP>`, the relayer grant, and that
PayoutReceiver still holds `PAYOUT_ROLE` (Treasury) + `ORACLE_ROLE` (PolicyManager).

### 2a. Fork dry-run (NO broadcast) — REQUIRED before mainnet

```bash
set -a && source .env && set +a
PROD_AUTHORIZED_SIGNER=<PROD_PKP> PROD_RELAYER_WALLET=<BACKEND_RELAYER> \
forge script script/UpgradePayoutReceiverV21Mainnet.s.sol:UpgradePayoutReceiverV21Mainnet \
  --rpc-url "$BASE_MAINNET_RPC_URL" \
  --sender 0xC5867D3b114f10356bAAb7b77E04783cfA947c44 \
  --unlocked
```

**Expected logs (must see):**

```
version (before):  1.0.0
new impl:          0x....
version (after):   2.1.0
=== Action 1+2 complete: v2.1.0; authorizedSigner set; RELAYER_ROLE granted; roles survived ===
...
SIMULATION COMPLETE. To broadcast these transactions, add --broadcast ...
```

### 2b. Mainnet execution (broadcast)

```bash
PROD_AUTHORIZED_SIGNER=<PROD_PKP> PROD_RELAYER_WALLET=<BACKEND_RELAYER> \
forge script script/UpgradePayoutReceiverV21Mainnet.s.sol:UpgradePayoutReceiverV21Mainnet \
  --rpc-url base_mainnet --account admin --broadcast --verify
```

### 2c. Post-run `cast` verification

```bash
PROXY=0x522b5Ff31E21CD71C76fedE44297D99e40D820cf
# version() == 2.1.0
cast call $PROXY "version()(string)" --rpc-url base_mainnet          # -> "2.1.0"
# authorizedSigner == <PROD_PKP>
cast call $PROXY "authorizedSigner()(address)" --rpc-url base_mainnet # -> <PROD_PKP>
# relayer holds RELAYER_ROLE
cast call $PROXY "hasRole(bytes32,address)(bool)" \
  $(cast keccak "RELAYER_ROLE") <BACKEND_RELAYER> --rpc-url base_mainnet  # -> true
# money-path roles survived
cast call 0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f "hasRole(bytes32,address)(bool)" \
  $(cast keccak "PAYOUT_ROLE") $PROXY --rpc-url base_mainnet              # -> true
cast call 0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ORACLE_ROLE") $PROXY --rpc-url base_mainnet              # -> true
# implementation slot points at the NEW impl (EIP-1967)
cast storage $PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url base_mainnet                                                  # -> new impl addr
```

**STOP if `authorizedSigner` is `0x0`** — the determination path will refuse all payouts
(`SignerNotConfigured`) until it is set. Re-run `setAuthorizedSigner` before proceeding.

---

## 3. Action 3 — Migrate admin/upgrader EOA → Safe + Timelock

Script: `script/MigrateAdminToSafeMainnet.s.sol`. Grant-then-renounce of `DEFAULT_ADMIN_ROLE`,
`UPGRADER_ROLE`, and `ADMIN_ROLE` from the EOA to `<TIMELOCK>`. It **guards on `version()==2.1.0`**, so
it refuses to run before Action 1 lands. After it, only a Safe-approved, timelock-delayed proposal can
upgrade or administer the contract.

> **Run this AFTER Action 1+2.** Running it first would strip the EOA of the `UPGRADER_ROLE`/`ADMIN_ROLE`
> the upgrade needs. The script's version guard enforces this ordering (it reverts on a v1.0.0 proxy).

### 3a. Fork dry-run (NO broadcast)

Because Action 3 requires the proxy to already be v2.1.0, dry-run it on a **local anvil fork** where you
first apply Action 1, or rely on the fork test (`test_action3…`, Section 5) which upgrades then migrates.
Standalone against un-upgraded live state it will (correctly) revert with
`Run the v2.1.0 upgrade BEFORE migrating admin`.

Local anvil sequence (optional, most faithful):

```bash
anvil --fork-url "$BASE_MAINNET_RPC_URL" &        # terminal 1
# terminal 2 — impersonate the admin EOA and run Action 1 then Action 3 against the local fork:
cast rpc anvil_impersonateAccount 0xC5867D3b114f10356bAAb7b77E04783cfA947c44 --rpc-url http://localhost:8545
PROD_AUTHORIZED_SIGNER=<PROD_PKP> PROD_RELAYER_WALLET=<BACKEND_RELAYER> \
forge script script/UpgradePayoutReceiverV21Mainnet.s.sol --rpc-url http://localhost:8545 \
  --sender 0xC5867D3b114f10356bAAb7b77E04783cfA947c44 --unlocked --broadcast   # broadcast = to the LOCAL fork only
GOV_OWNER=<TIMELOCK> \
forge script script/MigrateAdminToSafeMainnet.s.sol --rpc-url http://localhost:8545 \
  --sender 0xC5867D3b114f10356bAAb7b77E04783cfA947c44 --unlocked --broadcast   # LOCAL fork only
```

### 3b. Mainnet execution (broadcast)

```bash
GOV_OWNER=<TIMELOCK> \
forge script script/MigrateAdminToSafeMainnet.s.sol:MigrateAdminToSafeMainnet \
  --rpc-url base_mainnet --account admin --broadcast
```

### 3c. Post-run `cast` verification

```bash
PROXY=0x522b5Ff31E21CD71C76fedE44297D99e40D820cf
EOA=0xC5867D3b114f10356bAAb7b77E04783cfA947c44
DEFAULT_ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
# EOA has NO roles left
cast call $PROXY "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN $EOA --rpc-url base_mainnet            # false
cast call $PROXY "hasRole(bytes32,address)(bool)" $(cast keccak "UPGRADER_ROLE") $EOA --rpc-url base_mainnet  # false
cast call $PROXY "hasRole(bytes32,address)(bool)" $(cast keccak "ADMIN_ROLE") $EOA --rpc-url base_mainnet     # false
# Timelock now holds them
cast call $PROXY "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN <TIMELOCK> --rpc-url base_mainnet            # true
cast call $PROXY "hasRole(bytes32,address)(bool)" $(cast keccak "UPGRADER_ROLE") <TIMELOCK> --rpc-url base_mainnet  # true
```

From this point, upgrades go: **Safe** proposes `timelock.schedule(...)` → wait `minDelay` →
**Safe** calls `timelock.execute(...)`, whose target is `proxy.upgradeToAndCall(newImpl, data)`.

---

## 4. Idempotency / money-path safety notes

- The upgrade only swaps the implementation pointer. It **does not touch** `policyPaid` or
  `consumedDetermination`, so no in-flight or historical payout can be replayed or stranded by the
  upgrade. (Proven end-to-end by the fork test `test_endToEnd_determinationStillPaysAfterFullSequence`,
  which also asserts a re-submitted determination reverts instead of double-paying.)
- `setAuthorizedSigner` is last-write-wins on one slot; safe to re-run.
- `grantRole` calls are guarded by `hasRole`, so re-running any script is a no-op, not a revert.
- The migration renounces **last** and only after the timelock grant is confirmed on-chain, so the
  contract is never left with zero admins (which would permanently freeze upgrades).

---

## 5. Fork tests (run these before touching mainnet)

```bash
set -a && source .env && set +a
forge test --match-path test/PilotUpgradeFork.t.sol -vv   # uses BASE_MAINNET_RPC_URL, falls back to public RPC
```

All four must pass:
- `test_action1_upgrade_v1_to_v21` — live proxy `1.0.0` → `2.1.0`.
- `test_action2_setSignerAndRelayer_afterUpgrade` — `authorizedSigner` unset pre-upgrade, set post-upgrade; relayer granted.
- `test_action3_migrateAdminToTimelock` — grant-then-renounce; retired EOA can no longer upgrade, timelock can.
- `test_endToEnd_determinationStillPaysAfterFullSequence` — after the FULL sequence a PKP-signed
  determination still settles a payout, and a re-submit cannot double-pay.

---

## 6. Rollback

**Action 1+2 (implementation swap).** UUPS upgrades are reversible: the holder of `UPGRADER_ROLE`
can `upgradeToAndCall(<OLD_IMPL>, "")` to point back at the previous implementation
`0xd93947f30596b22360d7a3a85fa1c49f406af1cb` (v1.0.0). Because v2.1.0 only **appends** storage
(`authorizedSigner`, `consumedDetermination`, `__gap` reduced 50→48), reverting to v1.0.0 leaves the
existing `policyPaid` slots intact — no payout state is lost. Note v1.0.0 has no `submitDetermination`,
so the determination path simply goes dark until you re-upgrade; no funds move.
- **BEFORE Action 3:** rollback is a single EOA tx.
- **AFTER Action 3:** rollback is a Safe→timelock proposal (`schedule` → wait → `execute`) targeting the
  old impl. Keep `<OLD_IMPL>` = `0xd93947f30596b22360d7a3a85fa1c49f406af1cb` on hand.

**Emergency stop (no rollback needed):** `ADMIN_ROLE` (the timelock, or the EOA pre-migration) can
`pause()` the PayoutReceiver, halting `submitDetermination` immediately without an implementation change.
Un-pause with `unpause()`.

**Action 3 (admin migration) is intentionally hard to reverse** — that is the point of moving off a single
key. If the Safe/timelock is later found mis-configured, the timelock (via Safe) can re-grant
`DEFAULT_ADMIN_ROLE`/`UPGRADER_ROLE`/`ADMIN_ROLE` to a corrected owner and renounce the old one. There is
**no** path back to the retired EOA unless the timelock re-grants to it. **Do not run Action 3 until the
Safe + timelock have been rehearsed on Sepolia and a test upgrade has flowed Safe → timelock → proxy.**
