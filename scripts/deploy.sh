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
#   # Estimate only — nothing is submitted to the network:
#   DRY_RUN=1 ./scripts/deploy.sh <rpc_url> <token_address>
#
# Example
# -------
#   ./scripts/deploy.sh https://starknet-sepolia.public.blastapi.io 0x047...c938d

set -euo pipefail

RPC_URL="${1:?rpc url required, e.g. https://starknet-sepolia.public.blastapi.io}"
TOKEN="${2:?ERC-20 token address required}"
ACCOUNT="${SNCAST_ACCOUNT:-deployer}"

DRY_RUN_FLAG=""
if [ "${DRY_RUN:-0}" != "0" ]; then
  DRY_RUN_FLAG="--dry-run"
  echo "==> DRY RUN: transactions will be estimated, not submitted"
fi

echo "==> Building contract"
scarb build

# The class hash is derived deterministically from the compiled Sierra, offline —
# no network or account needed, and it is identical whether or not the class is
# already declared on chain.
echo "==> Computing class hash (offline)"
CLASS_HASH=$(sncast utils class-hash --contract-name HTLC \
  | grep -i 'class hash' | grep -oiE '0x[0-9a-f]+' | head -1)
if [ -z "${CLASS_HASH:-}" ]; then
  echo "error: could not compute the HTLC class hash" >&2
  exit 1
fi
echo "class_hash = $CLASS_HASH"

# Declaring a class that already exists on chain is a no-op error; tolerate it so
# a re-deploy against the same class still proceeds to the deploy step.
echo "==> Declaring HTLC (account: $ACCOUNT)"
sncast --account "$ACCOUNT" declare \
  --url "$RPC_URL" \
  --contract-name HTLC \
  $DRY_RUN_FLAG \
  || echo "   (declare skipped — class already declared, or see error above)"

echo "==> Deploying HTLC (token: $TOKEN)"
if [ -n "$DRY_RUN_FLAG" ]; then
  # A dry-run declare does not persist the class on chain, so the deploy can only
  # be simulated once the class is actually declared. Treat "not declared" as an
  # expected outcome of the combined dry run rather than a failure.
  sncast --account "$ACCOUNT" deploy \
    --url "$RPC_URL" \
    --class-hash "$CLASS_HASH" \
    --constructor-calldata "$TOKEN" \
    --dry-run \
    || echo "   note: deploy is simulated only after the class is declared on chain; the declare estimate above is the meaningful dry-run result."
else
  sncast --account "$ACCOUNT" deploy \
    --url "$RPC_URL" \
    --class-hash "$CLASS_HASH" \
    --constructor-calldata "$TOKEN"
fi
