import { Account, CallData, Contract, RpcProvider, stark } from "starknet";
import { promises as fs } from "fs";
import path from "path";
import * as dotenv from "dotenv";
dotenv.config();

type NetworkType = "sepolia" | "mainnet" | "devnet";

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 3) {
    console.error(
      "Usage: ts-node deploy.ts <network> <rpc_url> <token_address>"
    );
    process.exit(1);
  }

  const [network, rpcUrl, tokenAddress] = args;
  if (!["sepolia", "mainnet", "devnet"].includes(network as NetworkType)) {
    console.error(
      `Invalid network. Supported networks: sepolia, mainnet, devnet`
    );
    process.exit(1);
  }

  const provider = new RpcProvider({
    nodeUrl: rpcUrl,
  });

  console.log(`Deploying to ${network}...`);
  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Token address: ${tokenAddress}`);

  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  const accountAddress = process.env.DEPLOYER_ADDRESS;

  if (!privateKey || !accountAddress) {
    console.error("Missing DEPLOYER_PRIVATE_KEY or DEPLOYER_ADDRESS in .env");
    process.exit(1);
  }

  const account = new Account(provider, accountAddress, privateKey);
  console.log("Account connected:", accountAddress);

  try {
    const { sierraCode, casmCode } = await getCompiledCode(
      "starknet_htlc_HTLC"
    );

    const callData = new CallData(sierraCode.abi);
    const constructor = callData.compile("constructor", {
      token: tokenAddress,
    });
    console.log("Declaring and deploying contract...");
    const deployResponse = await account.declareAndDeploy({
      contract: sierraCode,
      casm: casmCode,
      constructorCalldata: constructor,
      salt: stark.randomAddress(),
    });

    const htlcContract = new Contract(
      sierraCode.abi,
      deployResponse.deploy.contract_address,
      provider
    );

    console.log("✅ Contract deployed successfully!");
    console.log("Contract address:", htlcContract.address);
    console.log("Transaction hash:", deployResponse.deploy.transaction_hash);

    // Save deployment info
    const deployInfo = {
      network,
      contractAddress: htlcContract.address,
      tokenAddress,
      deploymentHash: deployResponse.deploy.transaction_hash,
      timestamp: new Date().toISOString(),
    };

    // Create deployments directory if it doesn't exist
    await fs.mkdir('./deployments', { recursive: true });
    
    const deploymentPath = `./deployments/${network}_${htlcContract.address}.json`;
    try {
      await fs.access(deploymentPath);
      console.log('Deployment file already exists');
    } catch (error) {
      // File doesn't exist, create it
      await fs.writeFile(
        deploymentPath,
        JSON.stringify(deployInfo, null, 2)
      );
      console.log('Created deployment file:', deploymentPath);
    }
  } catch (error: any) {
    console.error("Deployment failed:", error.message);
    process.exit(1);
  }
}

export async function getCompiledCode(filename: string) {
  const sierraFilePath = path.join(
    __dirname,
    `../target/dev/${filename}.contract_class.json`
  );
  const casmFilePath = path.join(
    __dirname,
    `../target/dev/${filename}.compiled_contract_class.json`
  );

  const code = [sierraFilePath, casmFilePath].map(async (filePath) => {
    const file = await fs.readFile(filePath);
    return JSON.parse(file.toString("ascii"));
  });

  const [sierraCode, casmCode] = await Promise.all(code);

  return {
    sierraCode,
    casmCode,
  };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});
