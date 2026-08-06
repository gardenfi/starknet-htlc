import { cairo, hash } from "starknet";
import { promises as fs } from "fs";
import path from "path";
import { BigNumberish } from "ethers";
import axios from "axios";
import { STARKNET_DEVNET_URL } from "./config";

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

export function hexToU32Array(
  hexString: string,
  endian: "big" | "little" = "big"
): number[] {
  // Remove 0x prefix if present
  hexString = hexString.replace("0x", "");

  // Ensure we have 64 characters (32 bytes, will make 8 u32s)
  if (hexString.length !== 64) {
    throw new Error("Invalid hash length");
  }

  const result: number[] = [];

  // Process 8 bytes (32 bits) at a time to create each u32
  for (let i = 0; i < 8; i++) {
    // Take 8 hex characters (4 bytes/32 bits)
    const chunk = hexString.slice(i * 8, (i + 1) * 8);

    // Split into bytes
    const bytes = chunk.match(/.{2}/g)!;

    // Handle endianness
    if (endian === "little") {
      bytes.reverse();
    }

    const finalHex = bytes.join("");
    result.push(parseInt(finalHex, 16));
  }

  return result; // Will be array of 8 u32 values
}

export function u32ArrayToHex(
  u32Array: number[],
  endian: "big" | "little" = "big"
): string {
  if (u32Array.length !== 8) {
    throw new Error("Array must contain exactly 8 u32 values");
  }

  let hexString = "";

  for (let i = 0; i < u32Array.length; i++) {
    // Convert number to 8 character hex string (4 bytes)
    let hexChunk = u32Array[i].toString(16).padStart(8, "0");

    // Split into bytes
    const bytes = hexChunk.match(/.{2}/g)!;

    // Handle endianness
    if (endian === "little") {
      bytes.reverse();
    }

    hexString += bytes.join("");
  }

  // Add 0x prefix
  return "0x" + hexString;
}

/**
 * Converts 8 u32 values to 2 u128 values, matching Cairo's conversion logic:
 * u128[0] = h0 << 96 | h1 << 64 | h2 << 32 | h3
 * u128[1] = h4 << 96 | h5 << 64 | h6 << 32 | h7
 */
export function u32ArrayToU128Pair(u32Array: number[]): [bigint, bigint] {
  if (u32Array.length !== 8) {
    throw new Error("Array must contain exactly 8 u32 values");
  }
  
  const toU128 = (h0: number, h1: number, h2: number, h3: number): bigint => {
    return (BigInt(h0) << 96n) | (BigInt(h1) << 64n) | (BigInt(h2) << 32n) | BigInt(h3);
  };
  
  return [
    toU128(u32Array[0], u32Array[1], u32Array[2], u32Array[3]),
    toU128(u32Array[4], u32Array[5], u32Array[6], u32Array[7]),
  ];
}

export function generateOrderId(
  chainId: string,
  secretHash: number[] | [bigint, bigint],
  initiatorAddress: string,
  redeemerAddress: string,
  timelock: BigInt,
  amount: BigInt,
  contractAddress: string
): bigint {
  const amountCairo = cairo.uint256(amount as BigNumberish);
  
  // Convert secretHash to [u128; 2] format if it's still in u32 array format
  let secretHashU128: [bigint, bigint];
  if (Array.isArray(secretHash) && secretHash.length === 8 && typeof secretHash[0] === 'number') {
    secretHashU128 = u32ArrayToU128Pair(secretHash as number[]);
  } else {
    secretHashU128 = secretHash as [bigint, bigint];
  }
  
  // Order must match contract: chainId, secretHash[0], secretHash[1], initiator, redeemer, timelock, amount.low, amount.high, contractAddress
  const inputs = [
    BigInt(chainId),
    secretHashU128[0],
    secretHashU128[1],
    initiatorAddress,
    redeemerAddress,
    timelock as BigNumberish,
    amountCairo.low,
    amountCairo.high,
    contractAddress
  ];
  const orderId = hash.computePoseidonHashOnElements(inputs);
  return BigInt(orderId);
}

export const mineStarknetBlocks = async (blocks: number) => {
  try {
    for (let i = 0; i < blocks; i++) {
      await axios.post(STARKNET_DEVNET_URL, {
        "jsonrpc": "2.0",
        "id": "1",
        "method": "devnet_createBlock"
      });
    }
  } catch (error) {
    console.log("Mining failed : ", error);
  }
}
