#!/usr/bin/env bash
#
# Deploy the HTLC contract with sncast (starknet-foundry).
#
# One HTLC instance is deployed per ERC-20 token; the constructor takes that
# token's address as its only argument.
#
# Prerequisites
# -------------
#   * scarb + starknet-foundry on PATH (versions pinned in .tool-versions).
#   * An account known to sncast. Configure it once, e.g.:
#         sncast account import \
#             --name deployer \
#             --address 0x<account_address> \
#             --private-key 0x<private_key> \
#             --type oz
#     The account name defaults to "deployer" (matching snfoundry.toml); override
#     it with the SNCAST_ACCOUNT environment variable.
#
# Usage
# -----
#   ./scripts/deploy.sh <rpc_url> <token_address>
#
# Example
# -------
#   ./scripts/deploy.sh https://starknet-sepolia.public.blastapi.io 0x047...c938d

set -euo pipefail

RPC_URL="${1:?rpc url required, e.g. https://starknet-sepolia.public.blastapi.io}"
TOKEN="${2:?ERC-20 token address required}"
ACCOUNT="${SNCAST_ACCOUNT:-deployer}"

echo "==> Building contract"
scarb build

echo "==> Declaring HTLC (account: $ACCOUNT)"
DECLARE_OUT=$(sncast --account "$ACCOUNT" declare \
  --url "$RPC_URL" \
  --contract-name HTLC 2>&1 || true)
echo "$DECLARE_OUT"

# Pick up the class hash whether it was freshly declared or already on chain.
CLASS_HASH=$(echo "$DECLARE_OUT" | grep -oiE 'class[_ ]hash[":= ]*0x[0-9a-f]+' | grep -oiE '0x[0-9a-f]+' | head -1)
if [ -z "${CLASS_HASH:-}" ]; then
  CLASS_HASH=$(echo "$DECLARE_OUT" | grep -oiE '0x[0-9a-f]{60,}' | head -1)
fi
if [ -z "${CLASS_HASH:-}" ]; then
  echo "error: could not determine the class hash from the declare output above" >&2
  exit 1
fi
echo "class_hash = $CLASS_HASH"

echo "==> Deploying HTLC (token: $TOKEN)"
sncast --account "$ACCOUNT" deploy \
  --url "$RPC_URL" \
  --class-hash "$CLASS_HASH" \
  --constructor-calldata "$TOKEN"
