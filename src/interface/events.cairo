//! Events emitted by the HTLC contract.
//!
//! Every order produces exactly two events over its lifetime: one at initiation
//! (`Initiated` or `InitiatedWithDestinationData`) and one at settlement (`Redeemed`
//! or `Refunded`). All of them key on `order_id`, so a single order's history can be
//! followed by filtering on that key.
//!
//! # Examples
//!
//! ```
//! use starknet_htlc::interface::events::Redeemed;
//!
//! // Watch for redemptions to learn the secret and settle the other half of a swap.
//! spy.assert_emitted(@array![(htlc_address, Redeemed { order_id, secret_hash, secret })]);
//! ```

/// Emitted when an order is created by `initiate`, `initiate_on_behalf` or
/// `initiate_with_signature`.
#[derive(Drop, starknet::Event)]
pub struct Initiated {
    /// ID of the newly created order.
    #[key]
    pub order_id: felt252,
    /// SHA-256 hash of the secret, as two big-endian `u128` limbs.
    pub secret_hash: [u128; 2],
    /// Amount of tokens locked by the order.
    pub amount: u256,
}

/// Emitted when an order is created by one of the `*_with_destination_data`
/// entrypoints.
///
/// Identical to `Initiated`, plus the opaque `destination_data` supplied by the
/// caller. The contract does not interpret that data, does not store it, and does
/// not include it in the order ID; it is carried here purely for off-chain
/// consumers.
#[derive(Drop, starknet::Event)]
pub struct InitiatedWithDestinationData {
    /// ID of the newly created order.
    #[key]
    pub order_id: felt252,
    /// SHA-256 hash of the secret, as two big-endian `u128` limbs.
    pub secret_hash: [u128; 2],
    /// Amount of tokens locked by the order.
    pub amount: u256,
    /// Opaque payload for the destination chain, passed through unchanged.
    pub destination_data: Array<felt252>,
}

/// Emitted when an order is settled by `redeem`.
///
/// Carries the revealed `secret`, which is what allows the counterparty to settle
/// the other half of the atomic swap.
#[derive(Drop, starknet::Event)]
pub struct Redeemed {
    /// ID of the settled order.
    #[key]
    pub order_id: felt252,
    /// SHA-256 hash of the secret, as two big-endian `u128` limbs.
    pub secret_hash: [u128; 2],
    /// The revealed secret, as eight big-endian `u32` words.
    pub secret: [u32; 8],
}

/// Emitted when an order's funds are returned to its initiator, by either `refund`
/// or `instant_refund`.
#[derive(Drop, starknet::Event)]
pub struct Refunded {
    /// ID of the refunded order.
    #[key]
    pub order_id: felt252,
}
