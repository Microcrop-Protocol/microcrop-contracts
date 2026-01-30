# MicroCrop Smart Contracts

[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Base Sepolia](https://img.shields.io/badge/Deployed-Base%20Sepolia-0052FF)](https://sepolia.basescan.org/)

**Parametric crop insurance protocol for African farmers powered by Chainlink oracles.**

MicroCrop provides automated, trustless crop insurance that pays out based on verifiable weather and satellite data—no claims adjusters, no paperwork, no delays.

## 🌾 Overview

MicroCrop is a decentralized insurance protocol that:
- **Protects farmers** against drought and flood damage with instant, automated payouts
- **Enables investors** to provide capital to risk pools and earn returns from premiums
- **Uses Chainlink CRE** (Chainlink Runtime Environment) for trustless damage verification
- **Integrates with M-Pesa** for seamless fiat on/off ramps in Kenya

## 📦 Contracts

### Core Insurance Contracts

| Contract | Description |
|----------|-------------|
| `Treasury.sol` | Holds USDC reserves, collects premiums, and disburses payouts |
| `PolicyManager.sol` | Manages insurance policy lifecycle (create, activate, claim, expire) |
| `PayoutReceiver.sol` | Receives damage reports from Chainlink CRE and triggers automatic payouts |
| `PolicyNFT.sol` | ERC721 NFT representing insurance policies for on-chain proof of coverage |

### Tokenization Contracts

| Contract | Description |
|----------|-------------|
| `RiskPool.sol` | ERC20 token representing fractional ownership of an insurance risk pool |
| `RiskPoolFactory.sol` | Factory for creating and managing multiple RiskPool instances |

All contracts use the **UUPS upgradeable proxy pattern** with OpenZeppelin v5.5.0.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        CHAINLINK CRE                            │
│  (Weather APIs + Satellite Data → Damage Assessment)           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PayoutReceiver                              │
│  • Validates damage reports (14 checks)                         │
│  • Triggers automatic payouts                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌──────────────────────┐        ┌──────────────────────┐
│    PolicyManager     │        │      Treasury        │
│  • Policy lifecycle  │        │  • Premium collection│
│  • Farmer tracking   │        │  • Payout disbursement│
│  • Claim limits      │        │  • Reserve management│
└──────────────────────┘        └──────────────────────┘
                                          │
                                          ▼
                              ┌──────────────────────┐
                              │   RiskPoolFactory    │
                              │  • Creates pools     │
                              │  • Registry          │
                              └──────────────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    ▼                     ▼                     ▼
            ┌─────────────┐       ┌─────────────┐       ┌─────────────┐
            │  RiskPool   │       │  RiskPool   │       │  RiskPool   │
            │  (Kenya Q1) │       │  (Uganda Q2)│       │  (Tanzania) │
            └─────────────┘       └─────────────┘       └─────────────┘
```

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/Microcrop-Protocol/microcrop-contracts.git
cd microcrop-contracts/microcrop

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Environment Setup

```bash
cp .env.example .env
# Edit .env with your configuration
```

## 🧪 Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/Treasury.t.sol

# Run with gas reporting
forge test --gas-report

# Generate coverage report
forge coverage --ir-minimum
```

**Test Coverage:** 114 tests passing across all contracts

## 📊 Contract Specifications

### Policy Limits
| Parameter | Value |
|-----------|-------|
| Min Sum Insured | 10,000 USDC |
| Max Sum Insured | 1,000,000 USDC |
| Min Policy Duration | 30 days |
| Max Policy Duration | 365 days |
| Max Active Policies per Farmer | 5 |
| Max Claims per Farmer per Year | 3 |

### Risk Pool Limits
| Parameter | Value |
|-----------|-------|
| Min Investment | 1,000 USDC |
| Max Investment | 100,000 USDC |
| Min Target Capital | 500,000 USDC |
| Max Pool Capital | 2,000,000 USDC |
| Platform Fee | 10% (configurable 5-20%) |

### Damage Thresholds
| Parameter | Value |
|-----------|-------|
| Min Damage for Payout | 30% |
| Weather Weight | 60% |
| Satellite Weight | 40% |
| Report Max Age | 1 hour |

## 🔐 Security

### Access Control Roles
- `DEFAULT_ADMIN_ROLE` - Can grant/revoke all roles (multi-sig recommended)
- `ADMIN_ROLE` - Contract management, fee updates, pause/unpause
- `BACKEND_ROLE` - Policy creation, premium collection
- `ORACLE_ROLE` - Claim processing (PayoutReceiver only)
- `PAYOUT_ROLE` - Payout requests (PayoutReceiver only)
- `TREASURY_ROLE` - Premium/payout operations on RiskPools
- `UPGRADER_ROLE` - Contract upgrade authorization (V1 contracts)

### Security Features
- ReentrancyGuard on all fund-moving functions
- Pausable for emergency situations
- SafeERC20 for all token transfers
- CEI (Checks-Effects-Interactions) pattern
- Comprehensive input validation
- Double-operation prevention

## 📜 Deployment

### Deploy Contracts
```bash
# Using Foundry keystore (recommended)
forge script script/Deploy.s.sol \
  --rpc-url https://sepolia.base.org \
  --account deployer \
  --broadcast

# Or using private key
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Deployed Addresses (Base Sepolia)

| Contract | Proxy Address |
|----------|---------------|
| Treasury | [`0x6B04966167C74e577D9d750BE1055Fa4d25C270c`](https://sepolia.basescan.org/address/0x6B04966167C74e577D9d750BE1055Fa4d25C270c) |
| PolicyManager | [`0xDb6A11f23b8e357C0505359da4B3448d8EE5291C`](https://sepolia.basescan.org/address/0xDb6A11f23b8e357C0505359da4B3448d8EE5291C) |
| PayoutReceiver | [`0x1151621ed6A9830E36fd6b55878a775c824fabd0`](https://sepolia.basescan.org/address/0x1151621ed6A9830E36fd6b55878a775c824fabd0) |
| RiskPoolFactory | [`0xf68AC35ee87783437D77b7B19F824e76e95f73B9`](https://sepolia.basescan.org/address/0xf68AC35ee87783437D77b7B19F824e76e95f73B9) |
| PolicyNFT | [`0xbD93dD9E6182B0C68e13cF408C309538794A339b`](https://sepolia.basescan.org/address/0xbD93dD9E6182B0C68e13cF408C309538794A339b) |

**USDC (Base Sepolia):** `0x036CbD53842c5426634e7929541eC2318f3dCF7e`

## 🔗 Dependencies

- [OpenZeppelin Contracts v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts) - Security standards
- [OpenZeppelin Contracts Upgradeable v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) - UUPS proxy pattern
- [Forge Std](https://github.com/foundry-rs/forge-std) - Testing utilities

## 📁 Project Structure

```
microcrop/
├── src/
│   ├── Treasury.sol              # USDC reserves and payout management
│   ├── PolicyManager.sol         # Policy lifecycle management
│   ├── PayoutReceiver.sol        # Chainlink CRE oracle integration
│   ├── PolicyNFT.sol             # ERC721 policy certificates
│   ├── RiskPool.sol              # ERC20 LP token for risk pools
│   └── RiskPoolFactory.sol       # Risk pool deployment factory
├── test/
│   ├── Treasury.t.sol
│   ├── PolicyManager.t.sol
│   ├── PayoutReceiver.t.sol
│   ├── PolicyNFT.t.sol
│   ├── RiskPool.t.sol
│   ├── RiskPoolFactory.t.sol
│   └── mocks/
│       └── MockUSDC.sol
├── script/
│   └── Deploy.s.sol              # Main deployment script
├── abis/                         # Generated ABIs for backend integration
│   └── addresses.json            # Deployed contract addresses
├── lib/
│   ├── forge-std/
│   ├── openzeppelin-contracts/
│   └── openzeppelin-contracts-upgradeable/
└── foundry.toml
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

**Built with ❤️ for African farmers**
