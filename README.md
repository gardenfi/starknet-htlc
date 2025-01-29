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
Launch a local Starknet development environment:

```bash
yarn start:devnet
```

Start a local Ethereum test network using Hardhat:
```bash
yarn start:hardhat
```
### **4. Run Tests**  
Execute the test suite to ensure everything is working correctly:

```bash
yarn test
```
