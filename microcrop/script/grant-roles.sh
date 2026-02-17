#!/bin/bash

export ETH_RPC_URL=https://sepolia.base.org

echo "Granting BACKEND_ROLE on Treasury..."
cast send 0x6B04966167C74e577D9d750BE1055Fa4d25C270c \
  "grantRole(bytes32,address)" \
  0x61a3517f153a09154844ed8be639dabc6e78dc22315c2d9a91f7eddf9398c002 \
  0xC5867D3b114f10356bAAb7b77E04783cfA947c44 \
  --account deployer

echo ""
echo "Granting BACKEND_ROLE on PolicyManager..."
cast send 0xDb6A11f23b8e357C0505359da4B3448d8EE5291C \
  "grantRole(bytes32,address)" \
  0x61a3517f153a09154844ed8be639dabc6e78dc22315c2d9a91f7eddf9398c002 \
  0xC5867D3b114f10356bAAb7b77E04783cfA947c44 \
  --account deployer

echo ""
echo "Done!"
