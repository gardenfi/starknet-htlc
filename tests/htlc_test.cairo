//! Native Cairo (`snforge`) test suite for the HTLC contract.
//!
//! Ported from the original `tests/HTLC.test.ts` starknet.js suite. Covers every
//! entrypoint — including the SNIP-12 signature-authorised paths — using a mock
//! ERC-20 as the locked token and mock SRC-6 accounts as the signers. The
//! cross-chain (EVM/Bitcoin) scenarios from the TS suite are intentionally not
//! ported: this repo tests only the Starknet contract.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use core::sha256::compute_sha256_u32_array;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_number_global,
    start_cheat_caller_address, start_cheat_chain_id_global, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starknet_htlc::interface::struct_hash::{Initiate, instantRefund};
use starknet_htlc::interface::{IHTLCDispatcher, IHTLCDispatcherTrait, IMessageHash};

// -------------------------------------------------------------------------
// Constants
// -------------------------------------------------------------------------

const CHAIN_ID: felt252 = 'SN_SEPOLIA';
const TIMELOCK: u128 = 10;
const AMOUNT: u256 = 1_000_000_000_000_000_000; // 1e18
const BASE_BLOCK: u64 = 100;

// -------------------------------------------------------------------------
// Test fixtures
// -------------------------------------------------------------------------

#[derive(Drop, Copy)]
struct Actor {
    address: ContractAddress,
    key_pair: snforge_std::signature::KeyPair<felt252, felt252>,
}

#[derive(Drop, Copy)]
struct Env {
    htlc: ContractAddress,
    token: ContractAddress,
    alice: Actor,
    bob: Actor,
    charlie: Actor,
}

fn deploy_erc20() -> ContractAddress {
    let class = declare("MockERC20").unwrap().contract_class();
    let (addr, _) = class.deploy(@array![]).unwrap();
    addr
}

fn deploy_htlc(token: ContractAddress) -> ContractAddress {
    let class = declare("HTLC").unwrap().contract_class();
    let (addr, _) = class.deploy(@array![token.into()]).unwrap();
    addr
}

fn new_actor() -> Actor {
    let key_pair = KeyPairTrait::<felt252, felt252>::generate();
    let class = declare("MockAccount").unwrap().contract_class();
    let (address, _) = class.deploy(@array![key_pair.public_key]).unwrap();
    Actor { address, key_pair }
}

fn setup() -> Env {
    // Bind the chain id the contract captures at construction, so order ids and
    // signatures computed here match what the contract derives.
    start_cheat_chain_id_global(CHAIN_ID);
    start_cheat_block_number_global(BASE_BLOCK);

    let token = deploy_erc20();
    let alice = new_actor();
    let bob = new_actor();
    let charlie = new_actor();
    let htlc = deploy_htlc(token);

    let erc20 = IERC20Dispatcher { contract_address: token };
    let funding: u256 = AMOUNT * 1000;
    for a in array![alice.address, bob.address, charlie.address] {
        // mint (open mint on the mock)
        let mock = IMockMintDispatcher { contract_address: token };
        mock.mint(a, funding);
        // approve the htlc
        start_cheat_caller_address(token, a);
        erc20.approve(htlc, funding);
        stop_cheat_caller_address(token);
    }

    Env { htlc, token, alice, bob, charlie }
}

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

/// Mirror of the contract's `generate_order_id`, so tests can address orders.
fn order_id(
    secret_hash: [u128; 2],
    initiator: ContractAddress,
    redeemer: ContractAddress,
    timelock: u128,
    amount: u256,
    contract: ContractAddress,
) -> felt252 {
    let mut state = PoseidonTrait::new();
    state = state.update(CHAIN_ID);
    state = state.update_with(secret_hash);
    state = state.update(initiator.into());
    state = state.update(redeemer.into());
    state = state.update(timelock.into());
    state = state.update(amount.low.into());
    state = state.update(amount.high.into());
    state = state.update(contract.into());
    state.finalize()
}

/// SHA-256 of a 256-bit secret, packed into the `[u128; 2]` the contract expects.
fn hash_secret(secret: [u32; 8]) -> [u128; 2] {
    let [s0, s1, s2, s3, s4, s5, s6, s7] = secret;
    let h = compute_sha256_u32_array(array![s0, s1, s2, s3, s4, s5, s6, s7], 0, 0);
    let [h0, h1, h2, h3, h4, h5, h6, h7] = h;
    [
        h0.into() * 0x1000000000000000000000000_u128
            + h1.into() * 0x10000000000000000_u128
            + h2.into() * 0x100000000_u128
            + h3.into(),
        h4.into() * 0x1000000000000000000000000_u128
            + h5.into() * 0x10000000000000000_u128
            + h6.into() * 0x100000000_u128
            + h7.into(),
    ]
}

fn secret_of(seed: u32) -> [u32; 8] {
    [seed, seed + 1, seed + 2, seed + 3, seed + 4, seed + 5, seed + 6, seed + 7]
}

fn htlc_of(env: @Env) -> IHTLCDispatcher {
    IHTLCDispatcher { contract_address: *env.htlc }
}

fn balance_of(env: @Env, who: ContractAddress) -> u256 {
    IERC20Dispatcher { contract_address: *env.token }.balance_of(who)
}

fn sign_initiate(
    signer: Actor,
    htlc: ContractAddress,
    redeemer: ContractAddress,
    amount: u256,
    timelock: u128,
    secret_hash: [u128; 2],
    valid_until: u128,
) -> Array<felt252> {
    let initiate = Initiate {
        redeemer, amount, timelock, secretHash: secret_hash, verifyingContract: htlc, valid_until,
    };
    let hash = initiate.get_message_hash(CHAIN_ID, signer.address);
    let (r, s) = signer.key_pair.sign(hash).unwrap();
    array![r, s]
}

fn sign_instant_refund(signer: Actor, htlc: ContractAddress, id: felt252) -> Array<felt252> {
    let refund = instantRefund { orderID: id, verifyingContract: htlc };
    let hash = refund.get_message_hash(CHAIN_ID, signer.address);
    let (r, s) = signer.key_pair.sign(hash).unwrap();
    array![r, s]
}

// Dispatcher for the mock's open `mint`.
#[starknet::interface]
trait IMockMint<T> {
    fn mint(ref self: T, recipient: ContractAddress, amount: u256);
}

// -------------------------------------------------------------------------
// Pre-conditions
// -------------------------------------------------------------------------

#[test]
fn htlc_starts_empty_with_correct_token() {
    let env = setup();
    assert!(htlc_of(@env).token() == env.token, "wrong token");
    assert!(balance_of(@env, env.htlc) == 0, "htlc not empty");
}

// -------------------------------------------------------------------------
// initiate
// -------------------------------------------------------------------------

#[test]
#[should_panic(expected: "HTLC: zero address redeemer")]
fn initiate_rejects_zero_redeemer() {
    let env = setup();
    let zero: ContractAddress = 0.try_into().unwrap();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(zero, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
}

#[test]
#[should_panic(expected: "HTLC: zero amount")]
fn initiate_rejects_zero_amount() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, 0, hash_secret(secret_of(1)));
}

#[test]
#[should_panic(expected: "HTLC: zero timelock")]
fn initiate_rejects_zero_timelock() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, 0, AMOUNT, hash_secret(secret_of(1)));
}

#[test]
#[should_panic(expected: "HTLC: same initiator & redeemer")]
fn initiate_rejects_same_initiator_and_redeemer() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.alice.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
}

#[test]
#[should_panic(expected: 'ERC20: insufficient allowance')]
fn initiate_rejects_amount_over_allowance() {
    let env = setup();
    // amount exceeds the allowance granted in setup
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT * 100000, hash_secret(secret_of(1)));
}

#[test]
#[should_panic(expected: 'ERC20: insufficient balance')]
fn initiate_rejects_amount_over_balance() {
    let env = setup();
    // raise the allowance well above balance so the balance check is what fails
    start_cheat_caller_address(env.token, env.alice.address);
    IERC20Dispatcher { contract_address: env.token }.approve(env.htlc, AMOUNT * 1_000_000);
    stop_cheat_caller_address(env.token);

    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT * 100000, hash_secret(secret_of(1)));
}

#[test]
fn initiate_succeeds_and_locks_funds() {
    let env = setup();
    let before = balance_of(@env, env.htlc);
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    assert!(balance_of(@env, env.htlc) == before + AMOUNT, "funds not locked");
}

#[test]
#[should_panic(expected: "HTLC: duplicate order")]
fn initiate_rejects_duplicate_order() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    let sh = hash_secret(secret_of(1));
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, sh);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, sh);
}

// -------------------------------------------------------------------------
// initiate_on_behalf
// -------------------------------------------------------------------------

#[test]
fn initiate_on_behalf_succeeds() {
    let env = setup();
    // charlie funds an order whose initiator (refund recipient) is alice
    start_cheat_caller_address(env.htlc, env.charlie.address);
    let before = balance_of(@env, env.charlie.address);
    htlc_of(@env)
        .initiate_on_behalf(
            env.alice.address, env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(2)),
        );
    assert!(balance_of(@env, env.charlie.address) == before - AMOUNT, "funder not charged");
}

#[test]
#[should_panic(expected: "HTLC: zero address redeemer")]
fn initiate_on_behalf_rejects_zero_redeemer() {
    let env = setup();
    let zero: ContractAddress = 0.try_into().unwrap();
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env)
        .initiate_on_behalf(env.alice.address, zero, TIMELOCK, AMOUNT, hash_secret(secret_of(2)));
}

// -------------------------------------------------------------------------
// redeem
// -------------------------------------------------------------------------

#[test]
#[should_panic(expected: "HTLC: order not initiated")]
fn redeem_rejects_unknown_order() {
    let env = setup();
    htlc_of(@env).redeem(0x1234, secret_of(9));
}

#[test]
#[should_panic(expected: "HTLC: incorrect secret")]
fn redeem_rejects_wrong_secret() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    htlc_of(@env).redeem(id, secret_of(42)); // wrong secret
}

#[test]
fn redeem_pays_redeemer_and_anyone_can_call() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    let bob_before = balance_of(@env, env.bob.address);

    // charlie (a third party) redeems; funds still go to bob
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env).redeem(id, secret_of(1));

    assert!(balance_of(@env, env.bob.address) == bob_before + AMOUNT, "redeemer not paid");
}

#[test]
#[should_panic(expected: "HTLC: order fulfilled")]
fn redeem_rejects_already_redeemed() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    htlc_of(@env).redeem(id, secret_of(1));
    htlc_of(@env).redeem(id, secret_of(1));
}

// -------------------------------------------------------------------------
// refund
// -------------------------------------------------------------------------

#[test]
#[should_panic(expected: "HTLC: order not initiated")]
fn refund_rejects_unknown_order() {
    let env = setup();
    htlc_of(@env).refund(0xdead);
}

#[test]
#[should_panic(expected: "HTLC: order not expired")]
fn refund_rejects_before_timelock() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    htlc_of(@env).refund(id); // still at BASE_BLOCK
}

#[test]
fn refund_pays_initiator_after_timelock() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    let alice_before = balance_of(@env, env.alice.address);

    // advance past the timelock; charlie triggers the refund, funds go to alice
    start_cheat_block_number_global(BASE_BLOCK + TIMELOCK.try_into().unwrap() + 1);
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env).refund(id);

    assert!(balance_of(@env, env.alice.address) == alice_before + AMOUNT, "initiator not refunded");
}

#[test]
#[should_panic(expected: "HTLC: order fulfilled")]
fn refund_rejects_after_redeem() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    htlc_of(@env).redeem(id, secret_of(1));

    start_cheat_block_number_global(BASE_BLOCK + TIMELOCK.try_into().unwrap() + 1);
    htlc_of(@env).refund(id);
}

// -------------------------------------------------------------------------
// instant_refund
// -------------------------------------------------------------------------

#[test]
fn instant_refund_by_redeemer_needs_no_signature() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    let alice_before = balance_of(@env, env.alice.address);

    // bob is the redeemer; he can instant-refund with an empty signature
    start_cheat_caller_address(env.htlc, env.bob.address);
    htlc_of(@env).instant_refund(id, array![]);

    assert!(balance_of(@env, env.alice.address) == alice_before + AMOUNT, "initiator not refunded");
}

#[test]
#[should_panic(expected: "HTLC: invalid redeemer signature")]
fn instant_refund_by_third_party_needs_signature() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env).instant_refund(id, array![]);
}

#[test]
fn instant_refund_with_redeemer_signature() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    let sig = sign_instant_refund(env.bob, env.htlc, id);
    let alice_before = balance_of(@env, env.alice.address);

    // alice submits the redeemer's signature
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).instant_refund(id, sig);

    assert!(balance_of(@env, env.alice.address) == alice_before + AMOUNT, "initiator not refunded");
}

#[test]
#[should_panic(expected: "HTLC: invalid redeemer signature")]
fn instant_refund_rejects_wrong_signer() {
    let env = setup();
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).initiate(env.bob.address, TIMELOCK, AMOUNT, hash_secret(secret_of(1)));
    stop_cheat_caller_address(env.htlc);

    let id = order_id(
        hash_secret(secret_of(1)), env.alice.address, env.bob.address, TIMELOCK, AMOUNT, env.htlc,
    );
    // signed by charlie, not the redeemer bob
    let sig = sign_instant_refund(env.charlie, env.htlc, id);
    start_cheat_caller_address(env.htlc, env.alice.address);
    htlc_of(@env).instant_refund(id, sig);
}

// -------------------------------------------------------------------------
// initiate_with_signature
// -------------------------------------------------------------------------

#[test]
fn initiate_with_signature_succeeds() {
    let env = setup();
    let sh = hash_secret(secret_of(5));
    let valid_until: u128 = (BASE_BLOCK + 1000).into();
    let sig = sign_initiate(
        env.alice, env.htlc, env.bob.address, AMOUNT, TIMELOCK, sh, valid_until,
    );

    let locked_before = balance_of(@env, env.htlc);
    // charlie relays alice's signed order; funds come from alice
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env)
        .initiate_with_signature(
            env.alice.address, env.bob.address, TIMELOCK, AMOUNT, sh, valid_until, sig,
        );
    assert!(balance_of(@env, env.htlc) == locked_before + AMOUNT, "funds not locked");
}

#[test]
#[should_panic(expected: "HTLC: invalid initiator signature")]
fn initiate_with_signature_rejects_bad_signature() {
    let env = setup();
    let sh = hash_secret(secret_of(5));
    let valid_until: u128 = (BASE_BLOCK + 1000).into();
    // signed by bob, but claims alice as initiator
    let sig = sign_initiate(env.bob, env.htlc, env.bob.address, AMOUNT, TIMELOCK, sh, valid_until);
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env)
        .initiate_with_signature(
            env.alice.address, env.bob.address, TIMELOCK, AMOUNT, sh, valid_until, sig,
        );
}

#[test]
#[should_panic(expected: "HTLC: Expired signature")]
fn initiate_with_signature_rejects_expired() {
    let env = setup();
    let sh = hash_secret(secret_of(5));
    let valid_until: u128 = (BASE_BLOCK - 1).into(); // already in the past
    let sig = sign_initiate(
        env.alice, env.htlc, env.bob.address, AMOUNT, TIMELOCK, sh, valid_until,
    );
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env)
        .initiate_with_signature(
            env.alice.address, env.bob.address, TIMELOCK, AMOUNT, sh, valid_until, sig,
        );
}

// -------------------------------------------------------------------------
// cross-contract signature replay prevention
// -------------------------------------------------------------------------

#[test]
#[should_panic(expected: "HTLC: invalid initiator signature")]
fn signature_cannot_replay_across_contracts() {
    let env = setup();
    // a second htlc on the same token
    let htlc2 = deploy_htlc(env.token);
    start_cheat_caller_address(env.token, env.alice.address);
    IERC20Dispatcher { contract_address: env.token }.approve(htlc2, AMOUNT * 1000);
    stop_cheat_caller_address(env.token);

    let sh = hash_secret(secret_of(6));
    let valid_until: u128 = (BASE_BLOCK + 1000).into();
    // signature bound to the FIRST htlc
    let sig = sign_initiate(
        env.alice, env.htlc, env.bob.address, AMOUNT, TIMELOCK, sh, valid_until,
    );

    // works on the first contract
    start_cheat_caller_address(env.htlc, env.charlie.address);
    htlc_of(@env)
        .initiate_with_signature(
            env.alice.address, env.bob.address, TIMELOCK, AMOUNT, sh, valid_until, sig.clone(),
        );

    // same signature replayed against the second contract fails
    start_cheat_caller_address(htlc2, env.charlie.address);
    IHTLCDispatcher { contract_address: htlc2 }
        .initiate_with_signature(
            env.alice.address, env.bob.address, TIMELOCK, AMOUNT, sh, valid_until, sig,
        );
}
