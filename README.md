# MicroCrop Smart Contracts

[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

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

### Tokenization Contracts

| Contract | Description |
|----------|-------------|
| `RiskPool.sol` | ERC20 token representing fractional ownership of an insurance risk pool |
| `RiskPoolFactory.sol` | Factory for creating and managing multiple RiskPool instances |

### Upgradeable Contracts (UUPS Pattern)

All contracts have upgradeable versions with the `V1` suffix:
- `TreasuryV1.sol`
- `PolicyManagerV1.sol`
- `PayoutReceiverV1.sol`
- `RiskPoolV1.sol`
- `RiskPoolFactoryV1.sol`

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
│  • Validates damage reports (13 checks)                         │
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

**Test Coverage:** 96%+ across all contracts (282 tests)

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

### Deploy Core Contracts
```bash
forge script script/DeployMicroCrop.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Deploy Upgradeable Contracts
```bash
forge script script/DeployUpgradeable.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Upgrade a Contract
```bash
forge script script/UpgradeContract.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -s "upgradeTreasury(address,address)" $PROXY_ADDRESS $NEW_IMPL_ADDRESS
```

## 🔗 Dependencies

- [OpenZeppelin Contracts v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts) - Security standards
- [OpenZeppelin Contracts Upgradeable v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) - UUPS proxy pattern
- [Forge Std](https://github.com/foundry-rs/forge-std) - Testing utilities

## 📁 Project Structure

```
microcrop/
├── src/
│   ├── Treasury.sol              # Core treasury
│   ├── PolicyManager.sol         # Policy lifecycle
│   ├── PayoutReceiver.sol        # Chainlink CRE integration
│   ├── RiskPool.sol              # ERC20 pool token
│   ├── RiskPoolFactory.sol       # Pool factory
│   ├── TreasuryV1.sol            # Upgradeable treasury
│   ├── PolicyManagerV1.sol       # Upgradeable policy manager
│   ├── PayoutReceiverV1.sol      # Upgradeable payout receiver
│   ├── RiskPoolV1.sol            # Upgradeable pool token
│   └── RiskPoolFactoryV1.sol     # Upgradeable factory
├── test/
│   ├── Treasury.t.sol
│   ├── PolicyManager.t.sol
│   ├── PayoutReceiver.t.sol
│   ├── RiskPool.t.sol
│   ├── RiskPoolFactory.t.sol
│   └── mocks/
│       └── MockUSDC.sol
├── script/
│   ├── DeployMicroCrop.s.sol
│   ├── DeployUpgradeable.s.sol
│   └── UpgradeContract.s.sol
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
