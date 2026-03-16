# MicroCrop Smart Contract Integration Guide

> **Backend Integration Documentation for Chainlink CRE**
>
> Version: 2.0.0 | Last Updated: March 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Contract Addresses](#3-contract-addresses)
4. [Backend Responsibilities](#4-backend-responsibilities)
5. [Chainlink CRE Integration](#5-chainlink-cre-integration)
6. [API Reference](#6-api-reference)
7. [Events to Listen For](#7-events-to-listen-for)
8. [Error Handling](#8-error-handling)
9. [Security Considerations](#9-security-considerations)
10. [Testing Guide](#10-testing-guide)

---

## 1. Overview

MicroCrop is a parametric crop insurance platform for Kenyan farmers. The smart contracts handle:

- **Policy lifecycle management** (create → activate → claim/expire)
- **Premium collection** (USDC with platform fee deduction)
- **Premium distribution** to RiskPools for LP revenue sharing
- **Automatic payouts** via Chainlink CRE damage reports
- **NFT certificates** for farmers as proof of coverage
- **Risk pool management** (public, private, mutual pools)

### Key Flow

```
Farmer Purchase → Backend creates policy → Backend collects premium
                                        → Backend distributes premium to RiskPool
                                        → Backend activates policy
                                        → NFT minted to farmer

Weather Event → Chainlink CRE assesses damage → Report sent to PayoutReceiver
                                              → Validation passes
                                              → Treasury sends USDC to Backend Wallet
                                              → Backend converts to M-Pesa for farmer
```

---

## 2. Architecture

### Contract Relationships

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ADMIN (Multi-sig)                           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
┌──────────────┐  ┌────────────────────┐  ┌──────────────────┐
│  PolicyNFT   │  │   PolicyManager    │  │     Treasury     │
│   (ERC721)   │◄─│   (UUPS Proxy)     │  │   (UUPS Proxy)   │
└──────────────┘  └────────────────────┘  └──────────────────┘
                           │                    │        │
                           │                    │        │ distributePremiumToPool()
                           ▼                    ▼        ▼
                  ┌──────────────────┐  ┌──────────────────────┐
                  │  PayoutReceiver  │  │   RiskPoolFactory    │
                  │  (UUPS Proxy)    │  │    (UUPS Proxy)      │
                  │                  │  │         │             │
                  │  ◄── Chainlink   │  │    ┌────┴────┐       │
                  │    Keystone ──   │  │    ▼         ▼       │
                  └──────────────────┘  │ RiskPool  RiskPool   │
                                        └──────────────────────┘
```

### All Contracts Use UUPS Upgradeable Proxy Pattern

- Implementation contracts are deployed behind ERC1967 proxies
- State is preserved across upgrades
- Upgrades require `UPGRADER_ROLE`

---

## 3. Contract Addresses

### Base Mainnet (Production) - Deployed March 2026

| Contract | Proxy Address | Implementation (V2) |
|----------|---------------|---------------------|
| Treasury | `0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f` | `0x9f9C3ddeABeA7ecD61592ED68dBc274f48b0a27e` |
| PolicyManager | `0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F` | `0x3092Ae20Fe5307A197c20139D8A9122654F6d2f5` |
| PayoutReceiver | `0x522b5Ff31E21CD71C76fedE44297D99e40D820cf` | `0xD93947F30596b22360d7A3a85FA1c49F406AF1cb` |
| RiskPoolFactory | `0x7A14Aa6f41c2F9107812554b875dC0B52D61eBf2` | `0xbE4167C83fAEeB319B01dF1865d4271eC7e719C8` |
| PolicyNFT | `0xD2D40067B6D763C562F95fA402961efF8ee276cD` | N/A (non-upgradeable) |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | N/A |

### Base Sepolia (Testnet)

| Contract | Proxy Address |
|----------|---------------|
| Treasury | `0x6B04966167C74e577D9d750BE1055Fa4d25C270c` |
| PolicyManager | `0xDb6A11f23b8e357C0505359da4B3448d8EE5291C` |
| PayoutReceiver | `0x1151621ed6A9830E36fd6b55878a775c824fabd0` |
| RiskPoolFactory | `0xf68AC35ee87783437D77b7B19F824e76e95f73B9` |
| PolicyNFT | `0xFe9e345f3D2B1BeBcD99182b33ddb70Ec95a344a` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

### Key Addresses (Mainnet)

| Role | Address |
|------|---------|
| Admin | `0xC5867D3b114f10356bAAb7b77E04783cfA947c44` |
| Deployer | `0xC63ABe092aeaB15102c3d6A4879A8BF77a21f8A8` |
| Backend Wallet | `0xdeB2Bb07FbF9B5eC6051C1b2143dC31aD9A8D11E` |

### ABIs

Full ABIs for all contracts are available in the `microcrop/abi/` directory:

```
abi/
├── Treasury.json
├── PolicyManager.json
├── PayoutReceiver.json
├── RiskPoolFactory.json
├── RiskPool.json
└── PolicyNFT.json
```

---

## 4. Backend Responsibilities

### Roles Required

The backend wallet needs these roles:

| Contract | Role | Role Hash | Purpose |
|----------|------|-----------|---------|
| PolicyManager | `BACKEND_ROLE` | `keccak256("BACKEND_ROLE")` | Create & activate policies |
| Treasury | `BACKEND_ROLE` | `keccak256("BACKEND_ROLE")` | Receive premiums, distribute to pools |

### 4.1 Policy Creation Flow

```solidity
// Step 1: Create the policy (PENDING status)
uint256 policyId = policyManager.createPolicy(
    address farmer,           // Farmer's wallet address
    uint256 plotId,           // Off-chain plot reference ID
    uint256 sumInsured,       // Coverage amount (e.g., 50_000e6 for $50K USDC)
    uint256 premium,          // Premium to pay (e.g., 5_000e6 for $5K USDC)
    uint256 durationDays,     // Policy duration (30-365 days)
    CoverageType coverage     // 0=DROUGHT, 1=FLOOD, 2=BOTH, 3=EXCESS_RAIN, 4=COMPREHENSIVE
);
```

### 4.2 Premium Collection

> **BREAKING CHANGE (V2):** `receivePremium` now takes only 2 parameters. The `from` parameter has been removed — USDC is transferred from `msg.sender` (the backend wallet) directly.

```solidity
// Step 2: Backend wallet must hold USDC and approve Treasury
usdc.approve(treasuryAddress, premiumAmount);

// Step 3: Record premium payment (deducts platform fee from gross amount)
// The caller (msg.sender) must hold and have approved the USDC
treasury.receivePremium(
    uint256 policyId,      // From step 1
    uint256 amount         // Gross premium in USDC (6 decimals)
);
```

### 4.3 Premium Distribution to RiskPool

> **NEW (V2):** After collecting premiums, distribute them to the relevant RiskPool for LP revenue sharing.

```solidity
// Step 3b: Distribute premium to the appropriate RiskPool
// The pool must be a valid factory-registered pool
treasury.distributePremiumToPool(
    address pool,          // RiskPool proxy address (must be factory-registered)
    uint256 policyId,      // Policy identifier
    uint256 grossPremium,  // Amount to distribute (USDC 6 decimals)
    address distributor    // Distributor address for revenue share
);
```

**Important:** The pool address is validated against the RiskPoolFactory registry. Passing an unregistered address will revert with `InvalidPool`.

### 4.4 Policy Activation

```solidity
// Step 4: Activate policy and mint NFT to farmer
policyManager.activatePolicy(
    uint256 policyId,           // From step 1
    address distributor,        // Distributor/provider address
    string distributorName,     // "AgriInsure Kenya"
    string region               // "Nakuru County"
);
```

### 4.5 Receiving Payouts

When a claim is processed, USDC is sent to the configured `backendWallet` in Treasury:

```solidity
// Treasury.requestPayout sends USDC here
address backendWallet = treasury.backendWallet();
```

**Backend must then convert USDC → M-Pesa for the farmer.**

---

## 5. Chainlink CRE Integration

### 5.1 Configuration Required

Before Chainlink CRE can send reports, configure PayoutReceiver:

```solidity
// Set the Keystone Forwarder address (provided by Chainlink)
payoutReceiver.setKeystoneForwarder(address keystoneForwarder);

// Set the workflow configuration
payoutReceiver.setWorkflowConfig(
    address workflowAddress,  // Chainlink workflow contract
    uint256 workflowId        // Unique workflow identifier
);
```

### 5.2 DamageReport Structure

The Chainlink CRE workflow must send this exact structure:

```solidity
struct DamageReport {
    uint256 policyId;           // Policy being assessed
    uint256 damagePercentage;   // Damage in basis points (0-10000 = 0-100%)
    uint256 weatherDamage;      // Weather component (basis points)
    uint256 satelliteDamage;    // Satellite/NDVI component (basis points)
    uint256 payoutAmount;       // Pre-calculated payout in USDC (6 decimals)
    uint256 assessedAt;         // Unix timestamp of assessment
}
```

### 5.3 Validation Rules (ALL must pass)

| # | Validation | Requirement | Error if Failed |
|---|------------|-------------|-----------------|
| 1 | Caller | `msg.sender == keystoneForwarderAddress` | `UnauthorizedForwarder` |
| 2 | Workflow Address | `reportedWorkflowAddress == workflowAddress` | `InvalidWorkflowAddress` |
| 3 | Workflow ID | `reportedWorkflowId == workflowId` | `InvalidWorkflowId` |
| 4 | Policy Exists | `policyManager.policyExists(policyId)` | `PolicyDoesNotExist` |
| 5 | Policy Active | `policy.status == ACTIVE` | `PolicyNotActive` |
| 6 | Not Expired | `block.timestamp <= policy.endDate` | `PolicyExpired` |
| 7 | Not Paid | `!policyPaid[policyId]` | `PolicyAlreadyPaid` |
| 8 | Damage Threshold | `damagePercentage >= 3000` (30%) | `DamageBelowThreshold` |
| 9 | Damage Maximum | `damagePercentage <= 10000` (100%) | `DamageExceedsMaximum` |
| 10 | Payout Calculation | `payoutAmount == (sumInsured * damagePercentage) / 10000` | `InvalidPayoutCalculation` |
| 11 | Weighted Damage | `(60 * weather + 40 * satellite) / 100 == damage` | `InvalidWeightedDamage` |
| 12 | Report Freshness | `block.timestamp <= assessedAt + 1 hour` | `ReportTooOld` |
| 13 | Farmer Claim Limit | Farmer has < 3 claims this year | `FarmerClaimLimitExceeded` |

### 5.4 Damage Calculation Formula

```
damagePercentage = (WEATHER_WEIGHT * weatherDamage + SATELLITE_WEIGHT * satelliteDamage) / 100

Where:
  WEATHER_WEIGHT = 60
  SATELLITE_WEIGHT = 40
```

**Example:**
- Weather damage: 7000 (70%)
- Satellite damage: 5000 (50%)
- Total: (60 x 7000 + 40 x 5000) / 100 = (420000 + 200000) / 100 = **6200 (62%)**

### 5.5 Payout Calculation

```
payoutAmount = (sumInsured * damagePercentage) / 10000
```

**Example:**
- Sum insured: 50,000 USDC (50_000_000_000 with 6 decimals)
- Damage: 6200 (62%)
- Payout: (50_000_000_000 x 6200) / 10000 = **31,000 USDC**

### 5.6 Chainlink Workflow Call

The Keystone Forwarder calls:

```solidity
payoutReceiver.receiveDamageReport(
    DamageReport calldata report,
    address reportedWorkflowAddress,
    uint256 reportedWorkflowId
);
```

---

## 6. API Reference

### 6.1 PolicyManager Functions

#### Create Policy
```solidity
function createPolicy(
    address farmer,
    uint256 plotId,
    uint256 sumInsured,      // Min: 10_000e6, Max: 1_000_000e6
    uint256 premium,
    uint256 durationDays,    // Min: 30, Max: 365
    CoverageType coverageType // 0=DROUGHT, 1=FLOOD, 2=BOTH, 3=EXCESS_RAIN, 4=COMPREHENSIVE
) external returns (uint256 policyId)
```
**Required Role:** `BACKEND_ROLE`

#### Activate Policy
```solidity
function activatePolicy(
    uint256 policyId,
    address distributor,
    string calldata distributorName,
    string calldata region
) external
```
**Required Role:** `BACKEND_ROLE`

#### Read Functions (No Role Required)
```solidity
function getPolicy(uint256 policyId) external view returns (Policy memory)
function policyExists(uint256 policyId) external view returns (bool)
function getFarmerPolicies(address farmer) external view returns (uint256[] memory)
function getFarmerActivePolicyCount(address farmer) external view returns (uint256)
function isPolicyActive(uint256 policyId) external view returns (bool)
function canFarmerClaim(address farmer) external view returns (bool)
```

### 6.2 Treasury Functions

#### Receive Premium
```solidity
function receivePremium(
    uint256 policyId,
    uint256 amount           // Gross amount in USDC (6 decimals)
) external
```
**Required Role:** `BACKEND_ROLE`
**Note:** USDC is transferred from `msg.sender`. The caller must hold and approve the USDC to Treasury before calling.

#### Distribute Premium to Pool
```solidity
function distributePremiumToPool(
    address pool,            // Must be a factory-registered pool
    uint256 policyId,
    uint256 grossPremium,    // Amount to distribute (USDC 6 decimals)
    address distributor      // Distributor for revenue share
) external
```
**Required Role:** `BACKEND_ROLE`
**Note:** Validates `pool` against RiskPoolFactory registry. Reverts with `InvalidPool` if not registered.

#### Read Functions
```solidity
function getBalance() external view returns (uint256)
function getAvailableForPayouts() public view returns (uint256)
function calculatePlatformFee(uint256 premium) public view returns (uint256)
function premiumReceived(uint256 policyId) external view returns (bool)
function payoutProcessed(uint256 policyId) external view returns (bool)
function factory() external view returns (address)
```

### 6.3 PayoutReceiver Functions

#### Receive Damage Report (Chainlink CRE Only)
```solidity
function receiveDamageReport(
    DamageReport calldata report,
    address reportedWorkflowAddress,
    uint256 reportedWorkflowId
) external
```
**Required:** Called by Keystone Forwarder only

#### Read Functions
```solidity
function getReport(uint256 policyId) external view returns (DamageReport memory)
function isPolicyPaid(uint256 policyId) external view returns (bool)
function policyPaid(uint256 policyId) external view returns (bool)
function getWorkflowConfig() external view returns (address, uint256)
```

### 6.4 RiskPoolFactory Functions (Admin Only)

```solidity
function isValidPool(address poolAddress) external view returns (bool)
function getAllPools() external view returns (address[] memory)
function getPoolById(uint256 poolId) external view returns (address)
function getPoolCount() external view returns (uint256)
function getPoolsByType(PoolType) external view returns (address[] memory)
```

---

## 7. Events to Listen For

### 7.1 Policy Lifecycle Events

```solidity
// PolicyManager
event PolicyCreated(
    uint256 indexed policyId,
    address indexed farmer,
    uint256 indexed plotId,
    uint256 sumInsured,
    uint256 premium,
    uint256 startDate,
    uint256 endDate,
    CoverageType coverageType
);

event PolicyActivated(uint256 indexed policyId, uint256 activatedAt);
event PolicyClaimed(uint256 indexed policyId, uint256 claimedAt);
event PolicyCancelled(uint256 indexed policyId, uint256 cancelledAt);
```

### 7.2 Treasury Events

```solidity
event PremiumReceived(
    uint256 indexed policyId,
    uint256 grossAmount,
    uint256 platformFee,
    uint256 netAmount,
    address indexed from     // msg.sender (backend wallet)
);

event PayoutSent(
    uint256 indexed policyId,
    uint256 amount,
    address indexed recipient  // backendWallet
);
```

### 7.3 PayoutReceiver Events

```solidity
event DamageReportReceived(
    uint256 indexed policyId,
    uint256 damagePercentage,
    uint256 payoutAmount,
    address indexed farmer
);

event PayoutInitiated(uint256 indexed policyId, uint256 amount);
```

### 7.4 NFT Events

```solidity
// PolicyNFT
event PolicyNFTMinted(
    uint256 indexed tokenId,
    uint256 indexed policyId,
    address indexed farmer,
    address distributor,
    uint256 sumInsured
);

event PolicyStatusUpdated(uint256 indexed tokenId, bool isActive);
```

---

## 8. Error Handling

### 8.1 Common Errors

| Error | Contract | Cause | Resolution |
|-------|----------|-------|------------|
| `ZeroAddress` | All | Zero address provided | Use valid addresses |
| `ZeroAmount` | Treasury | Amount is 0 | Provide non-zero amount |
| `PolicyDoesNotExist` | PM/PR | Invalid policy ID | Check policy exists |
| `InvalidPolicyStatus` | PM | Wrong status for action | Check current status |
| `PremiumAlreadyReceived` | Treasury | Double payment | Policy already funded |
| `PayoutAlreadyProcessed` | Treasury | Double payout | Claim already processed |
| `InvalidPool` | Treasury | Pool not registered in factory | Use a valid factory pool address |

### 8.2 Policy Creation Errors

| Error | Cause |
|-------|-------|
| `ZeroAddressFarmer` | Farmer address is zero |
| `SumInsuredTooLow` | Below 10,000 USDC |
| `SumInsuredTooHigh` | Above 1,000,000 USDC |
| `ZeroPremium` | Premium is 0 |
| `InvalidDuration` | Duration outside 30-365 days |
| `TooManyActivePolicies` | Farmer has 5+ active policies |

### 8.3 Chainlink CRE Errors

| Error | Cause | Backend Action |
|-------|-------|----------------|
| `UnauthorizedForwarder` | Wrong caller | Check Keystone config |
| `InvalidWorkflowAddress` | Workflow mismatch | Verify workflow address |
| `InvalidWorkflowId` | ID mismatch | Verify workflow ID |
| `DamageBelowThreshold` | Damage < 30% | No payout triggered |
| `InvalidPayoutCalculation` | Math error | Fix calculation |
| `InvalidWeightedDamage` | Weight formula wrong | Fix weighted calculation |
| `ReportTooOld` | Report > 1 hour old | Submit fresh report |
| `FarmerClaimLimitExceeded` | 3+ claims this year | Cannot claim again |

---

## 9. Security Considerations

### 9.1 Role Security

```
Role Hierarchy:
├── DEFAULT_ADMIN_ROLE (Multi-sig recommended)
│   ├── Can grant/revoke all roles
│   └── Should be held by secure multi-sig wallet
├── ADMIN_ROLE
│   ├── Update fees, pause/unpause
│   └── Configure Keystone Forwarder
├── BACKEND_ROLE
│   ├── Create/activate policies
│   ├── Receive premiums
│   └── Distribute premiums to pools
├── ORACLE_ROLE (PayoutReceiver only)
│   ├── Mark policies as claimed
│   └── Granted to PayoutReceiver contract
├── PAYOUT_ROLE (Treasury only)
│   ├── Request payouts
│   └── Granted to PayoutReceiver contract
└── UPGRADER_ROLE
    └── Authorize contract upgrades
```

### 9.2 Backend Wallet Security

- **Never expose private keys** in frontend or logs
- Use **hardware wallet** or **cloud HSM** for production
- Implement **rate limiting** on policy creation
- Monitor for **unusual activity patterns**

### 9.3 USDC Approvals

```solidity
// Before receiving premiums, backend must approve Treasury
usdc.approve(treasuryAddress, type(uint256).max);  // Or specific amount
```

### 9.4 Pausable Contracts

All contracts can be paused in emergencies:

```solidity
// Admin can pause
contract.pause();

// Admin can unpause
contract.unpause();
```

When paused:
- No new premiums can be received
- No payouts can be processed
- No damage reports accepted
- No premium distributions to pools

---

## 10. Testing Guide

### 10.1 Local Testing

```bash
cd microcrop
forge test -vvv
```

### 10.2 Integration Test Checklist

| # | Test | Expected Result |
|---|------|-----------------|
| 1 | Create policy with valid params | Policy created, ID returned |
| 2 | Create policy with invalid sum | Revert with `SumInsuredTooLow/High` |
| 3 | Receive premium (2 params) | USDC transferred from caller, fee deducted |
| 4 | Double premium | Revert with `PremiumAlreadyReceived` |
| 5 | Distribute premium to valid pool | Premium sent to RiskPool, revenue split |
| 6 | Distribute premium to invalid pool | Revert with `InvalidPool` |
| 7 | Activate policy | Status = ACTIVE, NFT minted |
| 8 | Receive damage report (valid) | Payout sent, policy claimed |
| 9 | Receive damage report (< 30%) | Revert with `DamageBelowThreshold` |
| 10 | Double payout | Revert with `PolicyNotActive` |
| 11 | Expired policy payout | Revert with `PolicyExpired` |

### 10.3 Chainlink CRE Simulation

```javascript
// Simulate Keystone Forwarder call
const report = {
    policyId: 1,
    damagePercentage: 5000,  // 50%
    weatherDamage: 5000,      // 50%
    satelliteDamage: 5000,    // 50%
    payoutAmount: ethers.parseUnits("25000", 6),  // $25K
    assessedAt: Math.floor(Date.now() / 1000)
};

// Call as Keystone Forwarder
await payoutReceiver.connect(keystoneForwarder).receiveDamageReport(
    report,
    workflowAddress,
    workflowId
);
```

---

## 11. TypeScript/JavaScript Integration

### 11.1 Installation

```bash
npm install viem
# or
yarn add viem
```

### 11.2 Setup & Configuration

```typescript
// config.ts
import { createPublicClient, createWalletClient, http } from 'viem';
import { base } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

// Contract addresses (Base Mainnet)
export const CONTRACTS = {
  TREASURY: '0x3EA1865dcfb4CbFF3b1bD7aDbca4E04D3BFC0d8f' as const,
  POLICY_MANAGER: '0xA975AaC390ab9f0fF017108B5F7Ab155E601a52F' as const,
  PAYOUT_RECEIVER: '0x522b5Ff31E21CD71C76fedE44297D99e40D820cf' as const,
  RISK_POOL_FACTORY: '0x7A14Aa6f41c2F9107812554b875dC0B52D61eBf2' as const,
  POLICY_NFT: '0xD2D40067B6D763C562F95fA402961efF8ee276cD' as const,
  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as const,
};

// Create clients
export const publicClient = createPublicClient({
  chain: base,
  transport: http(process.env.RPC_URL),
});

// Backend wallet client (use environment variable for private key)
const account = privateKeyToAccount(process.env.BACKEND_PRIVATE_KEY as `0x${string}`);

export const walletClient = createWalletClient({
  account,
  chain: base,
  transport: http(process.env.RPC_URL),
});
```

### 11.3 ABIs

Import full ABIs from `microcrop/abi/` directory, or use the minimal ABIs below:

```typescript
// abis.ts
export const POLICY_MANAGER_ABI = [
  {
    name: 'createPolicy',
    type: 'function',
    inputs: [
      { name: 'farmer', type: 'address' },
      { name: 'plotId', type: 'uint256' },
      { name: 'sumInsured', type: 'uint256' },
      { name: 'premium', type: 'uint256' },
      { name: 'durationDays', type: 'uint256' },
      { name: 'coverageType', type: 'uint8' },
    ],
    outputs: [{ name: 'policyId', type: 'uint256' }],
  },
  {
    name: 'activatePolicy',
    type: 'function',
    inputs: [
      { name: 'policyId', type: 'uint256' },
      { name: 'distributor', type: 'address' },
      { name: 'distributorName', type: 'string' },
      { name: 'region', type: 'string' },
    ],
    outputs: [],
  },
  {
    name: 'getPolicy',
    type: 'function',
    inputs: [{ name: 'policyId', type: 'uint256' }],
    outputs: [
      {
        name: 'policy',
        type: 'tuple',
        components: [
          { name: 'id', type: 'uint256' },
          { name: 'farmer', type: 'address' },
          { name: 'plotId', type: 'uint256' },
          { name: 'sumInsured', type: 'uint256' },
          { name: 'premium', type: 'uint256' },
          { name: 'startDate', type: 'uint256' },
          { name: 'endDate', type: 'uint256' },
          { name: 'coverageType', type: 'uint8' },
          { name: 'status', type: 'uint8' },
          { name: 'createdAt', type: 'uint256' },
        ],
      },
    ],
  },
  {
    name: 'PolicyCreated',
    type: 'event',
    inputs: [
      { name: 'policyId', type: 'uint256', indexed: true },
      { name: 'farmer', type: 'address', indexed: true },
      { name: 'plotId', type: 'uint256', indexed: true },
      { name: 'sumInsured', type: 'uint256', indexed: false },
      { name: 'premium', type: 'uint256', indexed: false },
      { name: 'startDate', type: 'uint256', indexed: false },
      { name: 'endDate', type: 'uint256', indexed: false },
      { name: 'coverageType', type: 'uint8', indexed: false },
    ],
  },
] as const;

export const TREASURY_ABI = [
  {
    name: 'receivePremium',
    type: 'function',
    inputs: [
      { name: 'policyId', type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'distributePremiumToPool',
    type: 'function',
    inputs: [
      { name: 'pool', type: 'address' },
      { name: 'policyId', type: 'uint256' },
      { name: 'grossPremium', type: 'uint256' },
      { name: 'distributor', type: 'address' },
    ],
    outputs: [],
  },
  {
    name: 'PremiumReceived',
    type: 'event',
    inputs: [
      { name: 'policyId', type: 'uint256', indexed: true },
      { name: 'grossAmount', type: 'uint256', indexed: false },
      { name: 'platformFee', type: 'uint256', indexed: false },
      { name: 'netAmount', type: 'uint256', indexed: false },
      { name: 'from', type: 'address', indexed: true },
    ],
  },
  {
    name: 'PayoutSent',
    type: 'event',
    inputs: [
      { name: 'policyId', type: 'uint256', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'recipient', type: 'address', indexed: true },
    ],
  },
] as const;

export const ERC20_ABI = [
  {
    name: 'approve',
    type: 'function',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'balanceOf',
    type: 'function',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const;
```

### 11.4 Policy Creation Service

```typescript
// policyService.ts
import { parseUnits, formatUnits } from 'viem';
import { publicClient, walletClient, CONTRACTS } from './config';
import { POLICY_MANAGER_ABI, TREASURY_ABI, ERC20_ABI } from './abis';

// Coverage types
export enum CoverageType {
  DROUGHT = 0,
  FLOOD = 1,
  BOTH = 2,
  EXCESS_RAIN = 3,
  COMPREHENSIVE = 4,
}

// Policy status
export enum PolicyStatus {
  PENDING = 0,
  ACTIVE = 1,
  EXPIRED = 2,
  CANCELLED = 3,
  CLAIMED = 4,
}

interface CreatePolicyParams {
  farmerAddress: string;
  plotId: number;
  sumInsuredUSD: number;      // e.g., 50000 for $50,000
  premiumUSD: number;         // e.g., 5000 for $5,000
  durationDays: number;       // 30-365
  coverageType: CoverageType;
  distributorAddress: string;
  distributorName: string;
  region: string;
  poolAddress?: string;       // RiskPool to distribute premium to (optional)
}

export async function createAndActivatePolicy(params: CreatePolicyParams): Promise<{
  policyId: bigint;
  txHashes: { create: string; premium: string; distribute?: string; activate: string };
}> {
  const {
    farmerAddress,
    plotId,
    sumInsuredUSD,
    premiumUSD,
    durationDays,
    coverageType,
    distributorAddress,
    distributorName,
    region,
    poolAddress,
  } = params;

  // Convert USD to USDC (6 decimals)
  const sumInsured = parseUnits(sumInsuredUSD.toString(), 6);
  const premium = parseUnits(premiumUSD.toString(), 6);

  console.log(`Creating policy for farmer ${farmerAddress}...`);
  console.log(`  Sum Insured: $${sumInsuredUSD} (${sumInsured} wei)`);
  console.log(`  Premium: $${premiumUSD} (${premium} wei)`);

  // Step 1: Create policy
  const createHash = await walletClient.writeContract({
    address: CONTRACTS.POLICY_MANAGER,
    abi: POLICY_MANAGER_ABI,
    functionName: 'createPolicy',
    args: [
      farmerAddress as `0x${string}`,
      BigInt(plotId),
      sumInsured,
      premium,
      BigInt(durationDays),
      coverageType,
    ],
  });

  console.log(`  Create TX: ${createHash}`);
  const createReceipt = await publicClient.waitForTransactionReceipt({ hash: createHash });

  // Extract policyId from event logs
  const policyCreatedLog = createReceipt.logs.find(
    log => log.address.toLowerCase() === CONTRACTS.POLICY_MANAGER.toLowerCase()
  );
  const policyId = BigInt(policyCreatedLog?.topics[1] || 0);
  console.log(`  Policy ID: ${policyId}`);

  // Step 2: Approve USDC for Treasury
  const approveHash = await walletClient.writeContract({
    address: CONTRACTS.USDC,
    abi: ERC20_ABI,
    functionName: 'approve',
    args: [CONTRACTS.TREASURY, premium],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  // Step 3: Pay premium (V2: only 2 params, USDC transferred from msg.sender)
  const premiumHash = await walletClient.writeContract({
    address: CONTRACTS.TREASURY,
    abi: TREASURY_ABI,
    functionName: 'receivePremium',
    args: [policyId, premium],
  });

  console.log(`  Premium TX: ${premiumHash}`);
  await publicClient.waitForTransactionReceipt({ hash: premiumHash });

  // Step 3b: Distribute premium to RiskPool (if pool specified)
  let distributeHash: string | undefined;
  if (poolAddress) {
    distributeHash = await walletClient.writeContract({
      address: CONTRACTS.TREASURY,
      abi: TREASURY_ABI,
      functionName: 'distributePremiumToPool',
      args: [
        poolAddress as `0x${string}`,
        policyId,
        premium,
        distributorAddress as `0x${string}`,
      ],
    });
    console.log(`  Distribute TX: ${distributeHash}`);
    await publicClient.waitForTransactionReceipt({ hash: distributeHash });
  }

  // Step 4: Activate policy (mints NFT to farmer)
  const activateHash = await walletClient.writeContract({
    address: CONTRACTS.POLICY_MANAGER,
    abi: POLICY_MANAGER_ABI,
    functionName: 'activatePolicy',
    args: [policyId, distributorAddress as `0x${string}`, distributorName, region],
  });

  console.log(`  Activate TX: ${activateHash}`);
  await publicClient.waitForTransactionReceipt({ hash: activateHash });

  console.log(`Policy ${policyId} created and activated!`);

  return {
    policyId,
    txHashes: {
      create: createHash,
      premium: premiumHash,
      distribute: distributeHash,
      activate: activateHash,
    },
  };
}

// Get policy details
export async function getPolicy(policyId: bigint) {
  const policy = await publicClient.readContract({
    address: CONTRACTS.POLICY_MANAGER,
    abi: POLICY_MANAGER_ABI,
    functionName: 'getPolicy',
    args: [policyId],
  });

  return {
    id: policy.id,
    farmer: policy.farmer,
    plotId: policy.plotId,
    sumInsured: formatUnits(policy.sumInsured, 6),
    premium: formatUnits(policy.premium, 6),
    startDate: new Date(Number(policy.startDate) * 1000),
    endDate: new Date(Number(policy.endDate) * 1000),
    coverageType: CoverageType[policy.coverageType],
    status: PolicyStatus[policy.status],
  };
}
```

### 11.5 Event Listening Service

```typescript
// eventListener.ts
import { publicClient, CONTRACTS } from './config';
import { TREASURY_ABI, POLICY_MANAGER_ABI } from './abis';

// Listen for payouts (to trigger M-Pesa conversion)
export function watchPayouts(callback: (policyId: bigint, amount: bigint) => void) {
  return publicClient.watchContractEvent({
    address: CONTRACTS.TREASURY,
    abi: TREASURY_ABI,
    eventName: 'PayoutSent',
    onLogs: (logs) => {
      for (const log of logs) {
        const { policyId, amount } = log.args;
        if (policyId && amount) {
          console.log(`Payout received: Policy ${policyId}, Amount: ${amount}`);
          callback(policyId, amount);
        }
      }
    },
  });
}

// Listen for new policies
export function watchPolicyCreated(callback: (policyId: bigint, farmer: string) => void) {
  return publicClient.watchContractEvent({
    address: CONTRACTS.POLICY_MANAGER,
    abi: POLICY_MANAGER_ABI,
    eventName: 'PolicyCreated',
    onLogs: (logs) => {
      for (const log of logs) {
        const { policyId, farmer } = log.args;
        if (policyId && farmer) {
          console.log(`New policy: ${policyId} for ${farmer}`);
          callback(policyId, farmer);
        }
      }
    },
  });
}
```

### 11.6 Environment Variables

```bash
# .env
BACKEND_PRIVATE_KEY=0x...your_private_key...
RPC_URL=https://mainnet.base.org
```

---

## V2 Migration Notes

### Breaking Changes

1. **`receivePremium` signature changed** — Now takes 2 params `(policyId, amount)` instead of 3. The `from` parameter was removed; USDC is transferred from `msg.sender`.

2. **`CoverageType` enum expanded** — Added `EXCESS_RAIN` (3) and `COMPREHENSIVE` (4). Existing values unchanged.

### New Features

1. **`distributePremiumToPool`** — Distributes collected premiums to RiskPools for LP revenue sharing. Pool addresses are validated against the factory registry.

2. **Pool validation** — Treasury now validates pool addresses via `RiskPoolFactory.isValidPool()`. The factory address is stored in `treasury.factory()`.

---

## Quick Reference Card

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MIN_DAMAGE_THRESHOLD` | 3000 | 30% minimum for payout |
| `MAX_DAMAGE_PERCENTAGE` | 10000 | 100% maximum |
| `WEATHER_WEIGHT` | 60 | 60% weather component |
| `SATELLITE_WEIGHT` | 40 | 40% satellite component |
| `MAX_REPORT_AGE` | 3600 | 1 hour freshness |
| `MIN_SUM_INSURED` | 10,000 USDC | Minimum coverage |
| `MAX_SUM_INSURED` | 1,000,000 USDC | Maximum coverage |
| `MIN_DURATION_DAYS` | 30 | Minimum policy length |
| `MAX_DURATION_DAYS` | 365 | Maximum policy length |
| `MAX_ACTIVE_POLICIES` | 5 | Per farmer |
| `MAX_CLAIMS_PER_YEAR` | 3 | Per farmer |
| `PLATFORM_FEE` | 10% | Default fee |

### Function Quick Reference

```solidity
// Policy Creation Flow
policyId = policyManager.createPolicy(farmer, plotId, sumInsured, premium, duration, coverage);
treasury.receivePremium(policyId, amount);
treasury.distributePremiumToPool(pool, policyId, amount, distributor);  // optional
policyManager.activatePolicy(policyId, distributor, name, region);

// Payout Flow (Chainlink CRE)
payoutReceiver.receiveDamageReport(report, workflowAddr, workflowId);
// -> Treasury.requestPayout(policyId, amount) -> USDC to backendWallet
// -> PolicyManager.markAsClaimed(policyId)
```

---

## Support

For technical questions, contact the smart contract team or open an issue in the repository.

**Repository:** https://github.com/Microcrop-Protocol/microcrop-contracts
