# **Cairo HTLC for Garden Finance**

## **Introduction**

This repository contains the Cairo smart contract implementation for the **Garden Finance** project. It enables **Hashed Time-Locked Contract (HTLC)** functionality on **Starknet**, facilitating secure cross-chain atomic swaps. One contract instance is deployed per ERC-20 token.

## **Prerequisites**

The toolchain versions are pinned in [`.tool-versions`](.tool-versions) and are best installed with [asdf](https://asdf-vm.com/):

- **Scarb** — the Cairo package manager / build tool
- **Starknet Foundry** — provides `snforge` (tests) and `sncast` (declare/deploy)
- **Cairo** — see the [Cairo setup guide](https://book.cairo-lang.org/)

```bash
asdf install
```

## **Getting Started**

### **1. Build the contract**

```bash
scarb build
```

Sierra and CASM artifacts are emitted to `target/dev/`.

### **2. Run the tests**

The contract is tested entirely with native Cairo tests (`snforge`); no external
devnet, Node.js, or cross-chain services are required.

```bash
snforge test
```

Format the Cairo sources with:

```bash
scarb fmt
```

## **Deployment**

Deployment is done with `sncast` via [`scripts/deploy.sh`](scripts/deploy.sh). One
HTLC instance is deployed per ERC-20 token; the constructor takes that token's
address.

### **1. Configure a deployer account**

Import (or create) an account known to `sncast`. The default account name is
`deployer` (see [`snfoundry.toml`](snfoundry.toml)):

```bash
sncast account import \
  --name deployer \
  --address 0x<account_address> \
  --private-key 0x<private_key> \
  --type oz
```

### **2. Deploy**

```bash
# ./scripts/deploy.sh <rpc_url> <token_address>

# Sepolia example
./scripts/deploy.sh https://starknet-sepolia.public.blastapi.io 0x4718F5A0FC34CC1AF16A1CDEE98FFB20C31F5CD61D6AB07201858F4287C938D
```

The script builds the contract, declares the `HTLC` class, and deploys an instance
bound to the given token, printing the resulting class hash and contract address.
Override the account name with the `SNCAST_ACCOUNT` environment variable.
