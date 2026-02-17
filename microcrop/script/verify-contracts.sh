#!/bin/bash

export ETHERSCAN_API_KEY=$BASESCAN_API_KEY

echo "Verifying Treasury implementation..."
forge verify-contract 0xe416CA2822Ed2e81c7ef7ED7A08E5C629802A4f1 src/Treasury.sol:Treasury --chain base-sepolia --watch

echo ""
echo "Verifying PolicyManager implementation..."
forge verify-contract 0x710C6d82149b13eCBd29a2fB982bd571233b3317 src/PolicyManager.sol:PolicyManager --chain base-sepolia --watch

echo ""
echo "Verifying PayoutReceiver implementation..."
forge verify-contract 0x047c8aAF3c0E0b4bBC8ad148B3CA844f1b3a4b70 src/PayoutReceiver.sol:PayoutReceiver --chain base-sepolia --watch

echo ""
echo "Verifying RiskPool implementation..."
forge verify-contract 0xC32C931519De4eb82f287723fdF145fAabb7f51c src/RiskPool.sol:RiskPool --chain base-sepolia --watch

echo ""
echo "Verifying RiskPoolFactory implementation..."
forge verify-contract 0xA21bE4bFB3eBCDace02651Cf71EC55B26e7E95A4 src/RiskPoolFactory.sol:RiskPoolFactory --chain base-sepolia --watch

echo ""
echo "Verifying PolicyNFT..."
forge verify-contract 0xbD93dD9E6182B0C68e13cF408C309538794A339b src/PolicyNFT.sol:PolicyNFT --chain base-sepolia --watch --constructor-args $(cast abi-encode "constructor(string,string)" "MicroCrop Insurance Certificate" "mcINS")

echo ""
echo "Verification complete!"
