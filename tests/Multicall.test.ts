import {
  Account,
  cairo,
  CallData,
  Contract,
  RpcProvider,
  shortString,
  TypedData,
  WeierstrassSignatureType,
  TypedDataRevision,
  stark as sn,
  hash,
} from "starknet";
import { generateOrderId, getCompiledCode, hexToU32Array } from "./utils";
import { ethers, parseEther } from "ethers";
import { randomBytes } from "crypto";

describe("Starknet Multicall", () => {
  const starknetProvider = new RpcProvider({
    nodeUrl: "http://127.0.0.1:8547/rpc",
  });

  // Prefund accounts from devnet
  const accounts = [
    {
      address:
        "0x0260a8311b4f1092db620b923e8d7d20e76dedcc615fb4b6fdf28315b81de201",
      privateKey:
        "0x00000000000000000000000000000000c10662b7b247c7cecf7e8a30726cff12",
      publicKey:
        "0x02aa653a9328480570f628492a951c07621878fa429ac08bdbf2c9c388ae88b7",
    },
    {
      address:
        "0x014923a0e03ec4f7484f600eab5ecf3e4eacba20ffd92d517b213193ea991502",
      privateKey:
        "0x00000000000000000000000000000000e5852452e0757e16b127975024ade3eb",
      publicKey:
        "0x055c96342ff1304a2807755209735a35a7220ec18153cb516e376d47e6471083",
    },
  ];

  // Token address
  const STARK =
    "0x4718F5A0FC34CC1AF16A1CDEE98FFB20C31F5CD61D6AB07201858F4287C938D";

  const ETH =
    "0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7";

  let stark: Contract;
  let eth: Contract;
  let starknetHTLC: Contract;
  let multicall: Contract;
  let multicall_data: CallData;
  let htlc_data: CallData;

  let alice: Account;
  let bob: Account;

  let CHAIN_ID: string;

  let sierraCode, casmCode;

  const deployContracts = async () => {
    try {
      // Deploy HTLC
      ({ sierraCode, casmCode } = await getCompiledCode("starknet_htlc_HTLC"));
      htlc_data = new CallData(sierraCode.abi);
      const constructor = htlc_data.compile("constructor", {
        token: STARK,
      });

      const deployResponse = await alice.declareAndDeploy({
        contract: sierraCode,
        casm: casmCode,
        constructorCalldata: constructor,
        salt: sn.randomAddress(),
      });
      starknetHTLC = new Contract(
        sierraCode.abi,
        deployResponse.deploy.contract_address,
        starknetProvider
      );

      console.log("Starknet HTLC : ", starknetHTLC.address);

      // Deploy Multicall
      ({ sierraCode, casmCode } = await getCompiledCode(
        "starknet_htlc_Multicall"
      ));
      multicall_data = new CallData(sierraCode.abi);
      const multicallDeploy = await alice.declareAndDeploy({
        contract: sierraCode,
        casm: casmCode,
        salt: sn.randomAddress(),
      });

      multicall = new Contract(
        sierraCode.abi,
        multicallDeploy.deploy.contract_address,
        starknetProvider
      );
      console.log("Multicall Contract : ", multicall.address);
    } catch (error: any) {
      console.log("Failed to deploy contracts:", error);
      process.exit(1);
    }
  };

  const createInitiateData = async (count: number, timelock: number) => {
    const INITIATE_TYPE = {
      StarknetDomain: [
        { name: "name", type: "shortstring" },
        { name: "version", type: "shortstring" },
        { name: "chainId", type: "shortstring" },
        { name: "revision", type: "shortstring" },
      ],
      Initiate: [
        { name: "redeemer", type: "ContractAddress" },
        { name: "amount", type: "u256" },
        { name: "timelock", type: "u128" },
        { name: "secretHash", type: "u128*" },
      ],
    };

    const DOMAIN = {
      name: "HTLC",
      version: shortString.encodeShortString("1"),
      chainId: "0x534e5f5345504f4c4941", // SN_SEPOLIA
      revision: TypedDataRevision.ACTIVE,
    };

    const secrets = Array.from({ length: count }, () => randomBytes(32));
    const secretHashes = secrets.map((secret) =>
      hexToU32Array(ethers.sha256(secret))
    );

    const ordersData = await Promise.all(
      secretHashes.map(async (secretHash, index) => {
        const initiate: TypedData = {
          domain: DOMAIN,
          primaryType: "Initiate",
          types: INITIATE_TYPE,
          message: {
            redeemer: bob.address,
            amount: cairo.uint256(parseEther("1")),
            timelock: BigInt(timelock),
            secretHash: secretHash,
          },
        };

        const signature = (await alice.signMessage(
          initiate
        )) as WeierstrassSignatureType;

        return {
          initiator: alice.address,
          redeemer: bob.address,
          timelock: BigInt(timelock),
          amount: parseEther("1"),
          secret: hexToU32Array(secrets[index].toString("hex")),
          secret_hash: secretHash,
          signature: [signature.r, signature.s],
        };
      })
    );
    return ordersData;
  };
  const mineBlocks = async (blocks: number) => {
    let minedBlockes = 0;
    stark.connect(alice);
    while (minedBlockes < blocks) {
      await stark.transfer(alice.address, parseEther("0.0001"));   // Dummy transactions to mine blocks
      minedBlockes++;
    }
  };

  beforeAll(async () => {
    CHAIN_ID = (await starknetProvider.getChainId()).toString();

    alice = new Account(
      starknetProvider,
      accounts[0].address,
      accounts[0].privateKey
    );
    bob = new Account(
      starknetProvider,
      accounts[1].address,
      accounts[1].privateKey
    );

    const contractData = await starknetProvider.getClassAt(STARK);
    stark = new Contract(contractData.abi, STARK, starknetProvider);
    await deployContracts();

    const ethData = await starknetProvider.getClassAt(ETH);
    eth = new Contract(ethData.abi, ETH, starknetProvider);

    // allowance for HTLC
    stark.connect(alice);
    await stark.approve(starknetHTLC.address, parseEther("15"));

    eth.connect(bob);
    await eth.transfer(multicall.address, parseEther("5"));

  }, 100000);

  describe("Multicall Tests", () => {
    let initiateData: any[];

    it("Should be able to execute multiple inits", async () => {
      // Create data for 10 initiations
      initiateData = await createInitiateData(10, 10);
      let { low, high } = cairo.uint256(initiateData[0].amount);
      
      let initiate_callData = multicall_data.compile("multicall", {
        address: starknetHTLC.address,
        call_data: initiateData.map((data) => {
          return [
            BigInt(hash.getSelectorFromName("initiate_with_signature")),
            alice.address,
            bob.address,
            BigInt(data.timelock),
            BigInt(low),
            BigInt(high),
            ...data.secret_hash.map(BigInt),
            2n,
            ...data.signature.map(BigInt),
          ];
        }),
      });

      await alice.execute({
        contractAddress: multicall.address,
        entrypoint: "multicall",
        calldata: initiate_callData,
      });
    });

    it("Should be able to execute multiple redeems", async () => {
      const bobBalanceBeforeRedeem = await stark.balanceOf(bob.address);

      const redeem_callData = multicall_data.compile("multicall", {
        address: starknetHTLC.address,
        call_data: initiateData.slice(0, 5).map((data) => {
          const orderId = generateOrderId(
            CHAIN_ID,
            data.secret_hash,
            alice.address
          );
          return [
            BigInt(hash.getSelectorFromName("redeem")),
            BigInt(orderId),
            8n,
            ...data.secret.map(BigInt),
          ];
        }),
      });

      await bob.execute({
        contractAddress: multicall.address,
        entrypoint: "multicall",
        calldata: redeem_callData,
      });

      const bobBalanceAfterRedeem = await stark.balanceOf(bob.address);
      expect(bobBalanceAfterRedeem - bobBalanceBeforeRedeem).toEqual(
        parseEther("5")
      );
    });

    it("Should be able to execute multiple refunds", async () => {
      // Mine blocks to pass timelock
      await mineBlocks(10);
      const aliceBalanceBeforeRefund = await stark.balanceOf(alice.address);

      const refund_callData = multicall_data.compile("multicall", {
        address: starknetHTLC.address,
        call_data: initiateData.slice(5, 10).map((data) => {
          const orderId = generateOrderId(
            CHAIN_ID,
            data.secret_hash,
            alice.address
          );
          return [
            BigInt(hash.getSelectorFromName("refund")),
            BigInt(orderId),
          ];
        }),
      });

      await alice.execute({
        contractAddress: multicall.address,
        entrypoint: "multicall",
        calldata: refund_callData,
      });

      const aliceBalanceAfterRefund = await stark.balanceOf(alice.address);
      expect(aliceBalanceAfterRefund - aliceBalanceBeforeRefund).toEqual(
        parseEther("5")
      );
    },10000);

    it("Should be able to execute initiate and redeem in single call", async () => {

        const initiateData = await createInitiateData(1, 100);
        let { low, high } = cairo.uint256(initiateData[0].amount);

        const callData = multicall_data.compile("multicall", {
          address: starknetHTLC.address,
          call_data: [
            // Initiate call
            ...initiateData.map((data) => {
              return [
                BigInt(hash.getSelectorFromName("initiate_with_signature")),
                alice.address,
                bob.address,
                BigInt(data.timelock),
                BigInt(low),
                BigInt(high),
                ...data.secret_hash.map(BigInt),
                2n,
                ...data.signature.map(BigInt),
              ];
            }),
            // Redeem call
            ...initiateData.map((data) => {
              const orderId = generateOrderId(
                CHAIN_ID,
                data.secret_hash,
                alice.address
              );
              return [
                BigInt(hash.getSelectorFromName("redeem")),
                BigInt(orderId),
                8n,
                ...data.secret.map(BigInt),
              ];
            })
          ],
        });

        await alice.execute({
          contractAddress: multicall.address,
          entrypoint: "multicall",
          calldata: callData,
        });
        
      },10000);


  });
});
