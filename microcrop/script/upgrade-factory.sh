#!/bin/bash
# Upgrade RiskPoolFactory to add ORGANIZATION_ROLE

forge script script/Upgrade.s.sol:UpgradeRiskPoolFactory \
  --rpc-url https://sepolia.base.org \
  --account deployer \
  --broadcast
