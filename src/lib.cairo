//! # Starknet HTLC
//!
//! A Hash Time Locked Contract (HTLC) for cross-chain atomic swaps, by Garden Finance.
//!
//! An atomic swap is made up of two HTLC orders, one on each chain, both locked
//! against the SHA-256 hash of a single secret. Redeeming either half requires
//! revealing the secret on chain, which lets the counterparty redeem the other half.
//! If the swap is abandoned, each side reclaims its own funds once its timelock
//! expires, so the pair either both settle or both unwind.
//!
//! The crate is organised as:
//!
//! * `htlc` - the `HTLC` contract itself.
//! * `interface` - the `IHTLC` entrypoint trait, the events it emits, and the
//!   SNIP-12 message hashing used for signature-authorised orders.
//!
//! # Examples
//!
//! ```
//! use starknet_htlc::interface::{IHTLCDispatcher, IHTLCDispatcherTrait};
//!
//! let htlc = IHTLCDispatcher { contract_address: htlc_address };
//!
//! // The initiator locks 1000 tokens for 100 blocks against the hash of a secret.
//! htlc.initiate(redeemer, 100, 1000, secret_hash);
//!
//! // The redeemer claims them by revealing the secret.
//! htlc.redeem(order_id, secret);
//! ```
pub mod htlc;
pub mod interface;

#[cfg(test)]
pub mod mocks;
