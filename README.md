# **Cairo HTLC for Garden Finance**  

## **Introduction**  

This repository contains the Cairo smart contract implementation for the **Garden Finance** project. It enables **Hashed Time-Locked Contract (HTLC)** functionality on **Starknet**, facilitating secure cross-chain transactions.  

## **Prerequisites**  

Ensure you have the following dependencies installed:  

- **Node.js** (v16 or higher)  
- **Yarn** (package manager)  
- **Starknet Devnet** (for local testing)  
- **Hardhat** (for Ethereum testing)  
- **Cairo** - [Cairo setup guide][cairo-book]

[cairo-book]: https://book.cairo-lang.org/


## **Getting Started**  

Follow these steps to set up your development environment:  

### **1. Install Dependencies**  
Run the following command to install required packages:  

```bash
yarn install
```

### **2. Compile the Contract**  
Use Scarb to compile the Cairo smart contract: 

```bash
scarb build
```
### **3. Start Development Networks**  
Run merry to start a Multichain local environment for testing:

```bash
merry go
```
### **4. Run Tests**  
Execute the test suite to ensure everything is working correctly:

```bash
yarn test
```

## **Deployment**  

### Prerequisites
- Node.js and Yarn installed
- `.env` file with the following variables:
DEPLOYER_PRIVATE_KEY=your_private_key
DEPLOYER_ADDRESS=your_account_address

### **1. Install Dependencies**  
Run the following command to install required packages:  

```bash
yarn install
```

### **2.Build the contract**  
```bash
scarb build
```
### **3.Deploy Contract**  
Launch a local Starknet development environment:

```bash
# Sepolia Testnet
yarn deploy sepolia "https://starknet-sepolia.public.blastapi.io" <token_address>

# Mainnet
yarn deploy mainnet "https://your-mainnet-rpc" <token_address>

# Local Devnet
yarn deploy devnet "http://127.0.0.1:5050" <token_address>

# Example
yarn deploy sepolia "https://starknet-sepolia.public.blastapi.io" 0x4718F5A0FC34CC1AF16A1CDEE98FFB20C31F5CD61D6AB07201858F4287C938D
```
After successful deployment, a JSON file named .<network>_<contract_address>.json will be created in the project root directory containing all deployment details including contract address, transaction hash, and network information.
