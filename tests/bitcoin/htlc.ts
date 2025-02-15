import { IBitcoinWallet, Urgency } from "@catalogfi/wallets";
import * as bitcoin from "bitcoinjs-lib";
import { toHashTree } from "bitcoinjs-lib/src/payments/bip341";
import { sha256, taggedHash } from "bitcoinjs-lib/src/crypto";
import * as ecc from "tiny-secp256k1";
import { generateInternalkey, tweakPubkey } from "./internalkey";
import { Taptree } from "bitcoinjs-lib/src/types";
import { LEAF_VERSION } from "./contants";
import { assert, xOnlyPubkey } from "./utils";
import { serializeScript, sortLeaves } from "./utils";
import { htlcErrors } from "./errors";
import { BitcoinUTXO } from "@catalogfi/wallets/dist/src/lib/bitcoin/provider.interface";

export enum Leaf {
  REFUND,
  REDEEM,
  INSTANT_REFUND,
}

bitcoin.initEccLib(ecc);

export interface IHTLC {
  initiate(amount: number, fee?: number): Promise<string>;
  instantRefund(
    counterPartySigs: { utxo: string; sig: string }[],
    fee?: number
  ): Promise<string>;
  redeem(secret: string, fee?: number): Promise<string>;
  refund(fee?: number): Promise<string>;
}

export class HTLC implements IHTLC {
  /**
   * Signer of the HTLC can be either the initiator or the redeemer
   */
  private signer: IBitcoinWallet;
  private secretHash: string;
  /**
   * redeemer's x-only public key without 02 or 03 prefix
   */
  private redeemerPubkey: string;
  /**
   * initiator's x-only public key without 02 or 03 prefix
   */
  private initiatorPubkey: string;
  private expiry: number;
  /**
   * NUMS internal key which blocks key path spending
   */
  private internalPubkey: Buffer;
  private network: bitcoin.networks.Network;

  /**
   * Note: redeemerAddress and initiatorAddress should be x-only public key without 02 or 03 prefix
   */
  private constructor(
    signer: IBitcoinWallet,
    secretHash: string,
    redeemerPubkey: string,
    initiatorPubkey: string,
    expiry: number,
    network: bitcoin.networks.Network
  ) {
    this.secretHash = secretHash;
    this.redeemerPubkey = redeemerPubkey;
    this.initiatorPubkey = initiatorPubkey;
    this.expiry = expiry;
    this.signer = signer;
    this.network = network;
    this.internalPubkey = generateInternalkey();
  }

  /**
   * Creates a HTLC instance
   * @param signer Bitcoin wallet of the initiator or redeemer
   * @param secretHash 32 bytes secret hash
   * @param initiatorPubkey initiator's x-only public key without 02 or 03 prefix
   * @param redeemerPubkey redeemer's x-only public key without 02 or 03 prefix
   * @param expiry block height after which the funds can be refunded
   * @returns HTLC instance
   *
   *
   * Note: When the signer is the initiator, only refund and instant refund can be done
   * When the signer is the redeemer, only redeem can be done
   */
  static async from(
    signer: IBitcoinWallet,
    secretHash: string,
    initiatorPubkey: string,
    redeemerPubkey: string,
    expiry: number
  ): Promise<HTLC> {
    // trim 0x prefix if present
    secretHash = secretHash.startsWith("0x") ? secretHash.slice(2) : secretHash;

    assert(secretHash.length === 64, htlcErrors.secretHashLenMismatch);
    // initiator and redeemer pubkey should be either x-only 32 bytes or normal 33 bytes pubkey which
    // will be trimmed to x-only pubkey later
    assert(
      initiatorPubkey.length === 64 || initiatorPubkey.length === 66,
      `initiator ${htlcErrors.pubkeyLenMismatch}`
    );
    assert(
      redeemerPubkey.length === 64 || redeemerPubkey.length === 66,
      `redeemer ${htlcErrors.pubkeyLenMismatch}`
    );
    assert(expiry > 0, htlcErrors.zeroOrNegativeExpiry);

    const network = await signer.getNetwork();
    return new HTLC(
      signer,
      secretHash,
      xOnlyPubkey(redeemerPubkey).toString("hex"),
      xOnlyPubkey(initiatorPubkey).toString("hex"),
      expiry,
      network
    );
  }

  /**
   * Generates a taproot address for receiving the funds
   */
  address(): string {
    const { address } = bitcoin.payments.p2tr({
      internalPubkey: this.internalPubkey,
      network: this.network,
      scriptTree: this.leaves() as Taptree,
    });
    if (!address) throw new Error(htlcErrors.htlcAddressGenerationFailed);
    return address;
  }

  /**
   * Builds a raw unsigned transaction with utxos from htlc address
   * and uses signer's address as the output address
   */
  private async buildRawTx(fee?: number) {
    const tx = new bitcoin.Transaction();
    tx.version = 2;

    const address = this.address();
    const provider = await this.signer.getProvider();
    const utxos = await provider.getUTXOs(address);
    const balance = utxos.reduce((acc, utxo) => acc + utxo.value, 0);
    if (balance === 0) throw new Error(`${address} ${htlcErrors.notFunded}`);

    for (let i = 0; i < utxos.length; i++) {
      tx.addInput(Buffer.from(utxos[i].txid, "hex").reverse(), utxos[i].vout);
    }

    fee ??= await provider.suggestFee(address, balance, Urgency.MEDIUM);
    tx.addOutput(
      bitcoin.address.toOutputScript(
        await this.signer.getAddress(),
        this.network
      ),
      balance - fee
    );

    return { tx, usedUtxos: utxos };
  }

  /**
   * prevout script for the htlc address
   */
  private getOutputScript() {
    return bitcoin.address.toOutputScript(this.address(), this.network);
  }

  async initiate(amount: number, fee?: number): Promise<string> {
    fee ??= await (
      await this.signer.getProvider()
    ).suggestFee(await this.signer.getAddress(), amount, Urgency.MEDIUM);

    return await this.signer.send(this.address(), amount, fee);
  }

  /**
   * Instantly refunds the funds to the initiator given the counterparty's signatures and pubkey
   *
   * Note: If there are multiple UTXOs being spend, there should be a signature for each UTXO in counterPartySigs
   */
  async instantRefund(
    counterPartySigs: { utxo: string; sig: string }[],
    fee?: number
  ) {
    assert(counterPartySigs.length > 0, htlcErrors.noCounterpartySigs);

    const { tx, usedUtxos } = await this.buildRawTx(fee);

    for (const utxo of usedUtxos) {
      if (!counterPartySigs.find((sig) => sig.utxo === utxo.txid)) {
        throw new Error(htlcErrors.counterPartySigNotFound(utxo.txid));
      }
    }

    const output = this.getOutputScript();

    const hashType = bitcoin.Transaction.SIGHASH_DEFAULT;
    const instantRefundLeafHash = this.leafHash(Leaf.INSTANT_REFUND);

    const values = usedUtxos.map((utxo) => utxo.value);
    const outputs = generateOutputs(output, usedUtxos.length);

    for (let i = 0; i < tx.ins.length; i++) {
      const hash = tx.hashForWitnessV1(
        i,
        outputs,
        values,
        hashType,
        instantRefundLeafHash
      );
      if (
        !ecc.verifySchnorr(
          hash,
          Buffer.from(this.redeemerPubkey, "hex"),
          Buffer.from(counterPartySigs[i].sig, "hex")
        )
      ) {
        throw new Error(
          htlcErrors.invalidCounterpartySigForUTXO(counterPartySigs[i].utxo)
        );
      }

      const signature = await this.signer.signSchnorr(hash);
      const txid = Buffer.from(tx.ins[i].hash).reverse().toString("hex");
      const counterPartySig = counterPartySigs.find((sig) => sig.utxo === txid);
      if (!counterPartySig)
        throw new Error(htlcErrors.counterPartySigNotFound(txid));

      tx.setWitness(i, [
        Buffer.from(counterPartySig.sig, "hex"),
        signature,
        this.instantRefundLeaf(),
        this.generateControlBlockFor(Leaf.INSTANT_REFUND),
      ]);
    }

    const provider = await this.signer.getProvider();
    return await provider.broadcast(tx.toHex());
  }

  /**
   * Reveals the secret and redeems the HTLC
   */
  async redeem(secret: string, fee?: number): Promise<string> {
    assert(
      sha256(Buffer.from(secret, "hex")).toString("hex") === this.secretHash,
      htlcErrors.secretMismatch
    );

    const { tx, usedUtxos: utxos } = await this.buildRawTx(fee);

    // Revealing leaf hash
    const redeemLeafHash = this.leafHash(Leaf.REDEEM);

    const values = utxos.map((utxo) => utxo.value);
    const outputs = generateOutputs(this.getOutputScript(), utxos.length);

    // sign the transaction
    const hashType = bitcoin.Transaction.SIGHASH_DEFAULT;
    for (let i = 0; i < tx.ins.length; i++) {
      const hash = tx.hashForWitnessV1(
        i,
        outputs,
        values,
        hashType,
        redeemLeafHash
      );
      const signature = await this.signer.signSchnorr(hash);

      tx.setWitness(i, [
        signature,
        Buffer.from(secret, "hex"),
        this.redeemLeaf(),
        this.generateControlBlockFor(Leaf.REDEEM),
      ]);
    }
    // broadcast the transaction
    const provider = await this.signer.getProvider();
    return await provider.broadcast(tx.toHex());
  }

  /**
   * Refunds the funds back to the initiator if the expiry block height + 1 is reached
   */
  async refund(fee?: number): Promise<string> {
    const { tx, usedUtxos } = await this.buildRawTx(fee);

    const [canRefund, needMoreBlocks] = await this.canRefund(usedUtxos);
    if (!canRefund) {
      throw new Error(htlcErrors.htlcNotExpired(needMoreBlocks));
    }

    const refundLeafHash = this.leafHash(Leaf.REFUND);

    const values = usedUtxos.map((utxo) => utxo.value);
    const outputs = generateOutputs(this.getOutputScript(), usedUtxos.length);

    const hashType = bitcoin.Transaction.SIGHASH_DEFAULT;

    for (let i = 0; i < tx.ins.length; i++) {
      tx.ins[i].sequence = this.expiry;
      const hash = tx.hashForWitnessV1(
        i,
        outputs,
        values,
        hashType,
        refundLeafHash
      );
      const signature = await this.signer.signSchnorr(hash);

      tx.setWitness(i, [
        signature,
        this.redundLeaf(),
        this.generateControlBlockFor(Leaf.REFUND),
      ]);
    }

    const provider = await this.signer.getProvider();
    return await provider.broadcast(tx.toHex());
  }

  /**
   * Given a list of UTXOs, checks if the HTLC can be refunded
   */
  private async canRefund(utxos: BitcoinUTXO[]): Promise<[boolean, number]> {
    const provider = await this.signer.getProvider();
    const currentBlockHeight = await provider.getLatestTip();

    // ensure all utxos are expired
    for (const utxo of utxos) {
      let needMoreBlocks = 0;
      if (
        utxo.status.confirmed &&
        utxo.status.block_height + this.expiry > currentBlockHeight
      ) {
        needMoreBlocks =
          utxo.status.block_height + this.expiry - currentBlockHeight + 1;
      } else if (!utxo.status.confirmed) {
        needMoreBlocks = this.expiry + 1;
      }
      if (needMoreBlocks > 0) {
        return [false, needMoreBlocks];
      }
    }

    return [true, 0];
  }

  /**
   * Given a leaf, generates the control block necessary for spending the leaf
   */
  private generateControlBlockFor(leaf: Leaf) {
    const { hash } = toHashTree(this.leaves() as Taptree);
    const tweakedPubkey = tweakPubkey(this.internalPubkey, hash);

    return Buffer.concat([
      Buffer.from([LEAF_VERSION | tweakedPubkey.parity]),
      this.internalPubkey,
      ...this.generateMerkleProofFor(leaf),
    ]);
  }
  /**
   * Generates the hash of the leaf script
   * @param leaf Use leaf enum or pass 0 for refund, 1 for redeem, 2 for instant refund
   * @returns hash of the leaf script
   */
  leafHash(leaf: Leaf): Buffer {
    let leafScript = this.redeemLeaf();
    if (leaf === Leaf.REFUND) leafScript = this.redundLeaf();
    if (leaf === Leaf.INSTANT_REFUND) leafScript = this.instantRefundLeaf();
    return taggedHash("TapLeaf", serializeScript(leafScript));
  }

  private redundLeaf(): Buffer {
    return bitcoin.script.fromASM(
      `
			${bitcoin.script.number.encode(this.expiry).toString("hex")}
			OP_CHECKSEQUENCEVERIFY
			OP_DROP
			${this.initiatorPubkey}	
			OP_CHECKSIG
			`
        .trim()
        .replace(/\s+/g, " ")
    );
  }

  private redeemLeaf(): Buffer {
    return bitcoin.script.fromASM(
      `
			OP_SHA256
			${this.secretHash}
			OP_EQUALVERIFY
			${this.redeemerPubkey}
			OP_CHECKSIG
			`
        .trim()
        .replace(/\s+/g, " ")
    );
  }

  private instantRefundLeaf(): Buffer {
    return bitcoin.script.fromASM(
      `
			${this.initiatorPubkey}
			OP_CHECKSIG
			${this.redeemerPubkey}
			OP_CHECKSIGADD
			OP_2
			OP_NUMEQUAL
			`
        .trim()
        .replace(/\s+/g, " ")
    );
  }

  private leaves() {
    return [
      // most probable leaf (redeem)
      {
        version: LEAF_VERSION,
        output: this.redeemLeaf(),
      },
      [
        {
          version: LEAF_VERSION,
          output: this.redundLeaf(),
        },
        {
          version: LEAF_VERSION,
          output: this.instantRefundLeaf(),
        },
      ],
    ];
  }

  /**
   * Generates the merkle proof for the leaf script
   */
  private generateMerkleProofFor(leaf: Leaf) {
    const redeemLeafHash = this.leafHash(Leaf.REDEEM);
    const instantRefundLeafHash = this.leafHash(Leaf.INSTANT_REFUND);
    const refundLeafHash = this.leafHash(Leaf.REFUND);
    switch (leaf) {
      case Leaf.REDEEM:
        const sortedRefundLeaves = sortLeaves(
          refundLeafHash,
          instantRefundLeafHash
        );
        return [taggedHash("TapBranch", Buffer.concat(sortedRefundLeaves))];
      case Leaf.REFUND:
        return [instantRefundLeafHash, redeemLeafHash];
      case Leaf.INSTANT_REFUND:
        return [refundLeafHash, redeemLeafHash];
      default:
        throw new Error(htlcErrors.invalidLeaf);
    }
  }
}

/**
 * We only have one output script aka scriptpubkey, hence we generate the same output for signing
 */
function generateOutputs(output: Buffer, count: number): Buffer[] {
  const outputs: Buffer[] = [];
  for (let i = 0; i < count; i++) {
    outputs.push(output);
  }
  return outputs;
}
