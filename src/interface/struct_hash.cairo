//! SNIP-12 message and struct hashing for signature-authorised orders.
//!
//! Two actions can be authorised with an off-chain signature: creating an order
//! (`Initiate`, used by `initiate_with_signature`) and unwinding one early
//! (`instantRefund`, used by `instant_refund`). This module turns each of those into
//! the message hash that SRC-6 `is_valid_signature` is checked against.
//!
//! Struct and field names here are deliberately not snake_case. They are part of the
//! SNIP-12 type strings the signature commits to, so they must match the names the
//! signer's wallet encoded byte for byte.
//!
//! # Examples
//!
//! ```
//! use starknet_htlc::interface::IMessageHash;
//! use starknet_htlc::interface::struct_hash::Initiate;
//!
//! let initiate = Initiate {
//!     redeemer, amount, timelock, secretHash: secret_hash, verifyingContract, valid_until,
//! };
//! let message_hash = initiate.get_message_hash(chain_id, initiator);
//! ```

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use starknet::ContractAddress;
use crate::htlc::HTLC::{
    INITIATE_TYPE_HASH, INSTANT_REFUND_TYPE_HASH, NAME, U256_TYPE_HASH, VERSION,
};
use crate::interface::sn_domain::StarknetDomain;
use crate::interface::{IMessageHash, IStructHash};

/// The order parameters an initiator signs to authorise `initiate_with_signature`.
///
/// Covers every parameter of the order except the chain ID and the initiator, which
/// the message hash supplies through the domain separator and the signer address
/// respectively. Including `verifyingContract` binds the signature to a single HTLC
/// deployment.
#[derive(Drop, Serde, Debug)]
pub struct Initiate {
    /// Address allowed to receive the funds on redemption.
    pub redeemer: ContractAddress,
    /// Amount of tokens to lock.
    pub amount: u256,
    /// Number of blocks after initiation before a refund is allowed.
    pub timelock: u128,
    /// SHA-256 hash of the secret, as two big-endian `u128` limbs.
    pub secretHash: [u128; 2],
    /// Address of the HTLC contract the signature is valid for.
    pub verifyingContract: ContractAddress,
    /// Block number at which signature expires
    pub valid_until: u128
}

/// The message a redeemer signs to let an order be refunded before its timelock
/// expires.
///
/// Naming follows the SNIP-12 type string rather than Cairo convention.
#[derive(Drop, Copy, Hash, Serde, Debug)]
pub struct instantRefund {
    /// ID of the order to refund.
    pub orderID: felt252,
    /// Address of the HTLC contract the signature is valid for.
    pub verifyingContract: ContractAddress,
}

/// Builds the SNIP-12 message hash an initiator signs to authorise an order.
pub impl MessageHashInitiate of IMessageHash<Initiate> {
    fn get_message_hash(self: @Initiate, chain_id: felt252, signer: ContractAddress) -> felt252 {
        let domain = StarknetDomain {
            name: NAME, version: VERSION, chain_id: chain_id, revision: 1,
        };
        let mut state = PoseidonTrait::new();
        state = state.update_with('StarkNet Message');
        state = state.update_with(domain.get_struct_hash());
        state = state.update_with(signer);
        state = state.update_with(self.get_struct_hash());
        state.finalize()
    }
}

/// Hashes the `Initiate` struct, with `amount` and `secretHash` hashed as nested
/// SNIP-12 types.
pub impl StructHashInitiate of IStructHash<Initiate> {
    fn get_struct_hash(self: @Initiate) -> felt252 {
        let mut state = PoseidonTrait::new();
        state = state.update_with(INITIATE_TYPE_HASH);
        state = state.update_with(*self.redeemer);
        state = state.update_with(self.amount.get_struct_hash());
        state = state.update_with(*self.timelock);
        state = state.update_with(self.secretHash.span().get_struct_hash());
        state = state.update_with(*self.verifyingContract);
        state = state.update_with(*self.valid_until);
        state.finalize()
    }
}

/// Hashes a `u256` as the SNIP-12 struct of its `low` and `high` limbs.
pub impl StructHashU256 of IStructHash<u256> {
    fn get_struct_hash(self: @u256) -> felt252 {
        let mut state = PoseidonTrait::new();
        state = state.update_with(U256_TYPE_HASH);
        state = state.update_with(*self);
        state.finalize()
    }
}

/// Hashes a `u128` span as a SNIP-12 array, used for the two limbs of a secret hash.
///
/// Arrays are hashed over their elements alone, with no type hash prefix.
pub impl StructHashSpanU128 of IStructHash<Span<u128>> {
    fn get_struct_hash(self: @Span<u128>) -> felt252 {
        let mut state = PoseidonTrait::new();
        for el in (*self) {
            state = state.update_with(*el);
        }
        state.finalize()
    }
}

/// Builds the SNIP-12 message hash a redeemer signs to authorise an instant refund.
pub impl MessageHashInstantRefund of IMessageHash<instantRefund> {
    fn get_message_hash(
        self: @instantRefund, chain_id: felt252, signer: ContractAddress,
    ) -> felt252 {
        let domain = StarknetDomain {
            name: NAME, version: VERSION, chain_id: chain_id, revision: 1,
        };
        let mut state = PoseidonTrait::new();
        state = state.update_with('StarkNet Message');
        state = state.update_with(domain.get_struct_hash());
        state = state.update_with(signer);
        state = state.update_with(self.get_struct_hash());
        state.finalize()
    }
}

/// Hashes the `instantRefund` struct.
pub impl StructHashInstantRefund of IStructHash<instantRefund> {
    fn get_struct_hash(self: @instantRefund) -> felt252 {
        let mut state = PoseidonTrait::new();
        state = state.update_with(INSTANT_REFUND_TYPE_HASH);
        state = state.update_with(*self.orderID);
        state = state.update_with(*self.verifyingContract);
        state.finalize()
    }
}
