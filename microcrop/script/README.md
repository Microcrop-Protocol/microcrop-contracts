# Deployment & Upgrade Scripts

Operator reference for the MicroCrop contracts on Base. **Which script to run, when, and signed by whom.**
The fuller procedure (preconditions, verification, rollback) lives in the team's local `ROLLOUT_RUNBOOK.md`.

> RPC + verify aliases come from `foundry.toml`: `base_mainnet` / `base_sepolia` (need `BASE_MAINNET_RPC_URL`,
> `BASE_SEPOLIA_RPC_URL`, `BASESCAN_API_KEY` in env). Signing uses a foundry keystore (`--account <name>`,
> set up via `cast wallet import`).

---

## The determination-path rollout (current work)

Three batches, deployable independently. **A is the determination settlement path; B is audit-fix
hardening; they don't depend on each other.** (Batch C — RiskPool/Factory removal + Treasury narrowing —
is not yet scripted.)

| Script | Network | Batch | What it does | Signer |
|---|---|---|---|---|
| `DeployRehearsalSepolia.s.sol` | Sepolia | A + B | One-shot dev rehearsal: PayoutReceiver v2 + signer/relayer, PolicyManager, PolicyNFT redeploy+rewire | dev deployer `0xC63ABe09…` |
| `UpgradeDeterminationMainnet.s.sol` | Mainnet | **A** | PayoutReceiver → v2, `setAuthorizedSigner`, grant `RELAYER_ROLE`, role-survival asserts | admin `0xc5867d3b…` |
| `UpgradePilotReadinessMainnet.s.sol` | Mainnet | **B** | PolicyManager upgrade (PENDING cap) + PolicyNFT redeploy+rewire (SVG escaping) | admin `0xc5867d3b…` |

### 1. Rehearse on Base Sepolia (do this first)

No production prerequisites — the dev proxies are admin'd by the deployer key (not rotated). Defaults
`authorizedSigner` to the conformance **test PKP** so you can drive fixture-based determinations.

```bash
DEV_RELAYER_WALLET=0x<backend-dev-wallet> \
forge script script/DeployRehearsalSepolia.s.sol \
  --rpc-url base_sepolia --account deployer --broadcast --verify
```
- `DEV_RELAYER_WALLET` (required) — wallet that relays determinations; fund with Sepolia ETH.
- `DEV_AUTHORIZED_SIGNER` (optional) — set to your **dev Lit PKP** address for a full-oracle rehearsal;
  omit for a fixture rehearsal (defaults to the test PKP `0xF186…5ABE`).

After it runs: fund the float (deal/transfer USDC to the dev Treasury, or deploy `MockInsurer`), then
drive a determination through `POST /api/internal/determinations` on the dev backend.

### 2. Mainnet — Batch A (determination rollout)

**Prerequisite:** the production Lit PKP is provisioned and its EVM address is known. The script
**requires** `PROD_AUTHORIZED_SIGNER` and **refuses the test PKP** — it cannot go live with a test signer.

```bash
PROD_AUTHORIZED_SIGNER=0x<prod-PKP-evm-addr> \
PROD_RELAYER_WALLET=0x<backend-relayer-wallet> \
forge script script/UpgradeDeterminationMainnet.s.sol \
  --rpc-url base_mainnet --account admin --broadcast --verify
```
Verifies in-script: `version()=="2.0.0"`, `PAYOUT_ROLE` (Treasury) + `ORACLE_ROLE` (PolicyManager) survived.

### 3. Mainnet — Batch B (pilot-readiness)

**Precondition:** zero PENDING policies on-chain (audit showed `_policyCounter == 0`; re-confirm). Independent
of Batch A — run before or after.

```bash
forge script script/UpgradePilotReadinessMainnet.s.sol \
  --rpc-url base_mainnet --account admin --broadcast --verify
```
Post-run: mint a policy whose name contains `&` and confirm `tokenURI` returns valid output (Finding 6 check).
Note: PolicyNFT is **redeployed** (new address) — record it and update the backend's `CONTRACT_POLICY_NFT`.

---

## Addresses

| | Base Mainnet (8453) | Base Sepolia (84532) |
|---|---|---|
| PayoutReceiver (proxy) | `0x522b5Ff31E21CD71C76fedE44297D99e40D820cf` | `0x1151621ed6A9830E36fd6b55878a775c824fabd0` |
| PolicyManager (proxy) | `0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F` | `0xDb6A11f23b8e357C0505359da4B3448d8EE5291C` |
| Treasury (proxy) | `0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f` | `0x6B04966167C74e577D9d750BE1055Fa4d25C270c` |
| PolicyNFT (non-upgradeable) | `0xD2D40067B6D763C562F95fA402961efF8ee276cD` | redeployed by the script |
| Admin / upgrader | `0xc5867d3b114f10356baAb7b77e04783cfa947c44` | `0xC63ABe092aeaB15102c3d6A4879A8BF77a21f8A8` |

> The mainnet admin is an EIP-7702 single key (no multisig) and is the sole `DEFAULT_ADMIN`/`UPGRADER`
> across PayoutReceiver, PolicyManager, and Treasury. Migrating these roles to a multisig before real
> capital is in play is recommended (separate from any upgrade).

---

## Notes on upgrades vs redeploys

- PayoutReceiver, PolicyManager, Treasury are **UUPS proxies** → `upgradeToAndCall` a new impl; the proxy
  address is stable. Always confirm the storage layout is append-only before upgrading
  (`forge inspect <C> storage-layout` vs the deployed impl).
- PolicyNFT is **non-upgradeable** (deployed without a proxy) → fixes require a **redeploy + `setPolicyNFT`
  rewire**, and a new address. Previously minted certificates keep the old renderer.
- These scripts can't be dry-run without the admin key (the access-controlled calls revert under a
  non-admin sender). The upgrade→settlement flow is fork-proven by `test/PayoutDeterminationFork.t.sol`.

---

## Other scripts (context)

- `Deploy.s.sol` — initial full-stack deployment.
- `Upgrade.s.sol`, `UpgradeV2.s.sol`, `UpgradePolicyManager.s.sol` — prior upgrade rounds (historical).
- `UpgradeFactory.s.sol` (local), `upgrade-factory.sh` — RiskPool/Factory (tokenization path slated for
  removal in Batch C; do not extend).
- `grant-roles.sh`, `grant-backend-role.sh`, `verify-contracts.sh` — role-grant + verification helpers.
