//! # HTLC interfaces
//!
//! The external surface of the HTLC contract: the `IHTLC` entrypoint trait, the
//! events emitted by each entrypoint, and the SNIP-12 hashing traits used to
//! authorise orders with an off-chain signature.
//!
//! # Examples
//!
//! ```
//! use starknet_htlc::interface::{IHTLCDispatcher, IHTLCDispatcherTrait};
//!
//! fn read_order(htlc_address: ContractAddress, order_id: felt252) -> Order {
//!     IHTLCDispatcher { contract_address: htlc_address }.get_order(order_id)
//! }
//! ```

pub mod events;
pub mod sn_domain;
pub mod struct_hash;
use starknet::ContractAddress;
use crate::htlc::HTLC::Order;

/// The external entrypoints of the HTLC contract.
///
/// Every order locks `amount` of the contract's single ERC-20 token against the
/// SHA-256 hash of a secret, for `timelock` blocks. The order is keyed by an ID
/// derived from all of its parameters, so an identical set of parameters can only
/// be initiated once.
///
/// The secret must be generated randomly and hashed with SHA-256, so that the same
/// hash can be used by the non-EVM chain on the other side of the swap.
#[starknet::interface]
pub trait IHTLC<TContractState> {
    /// Returns the address of the ERC-20 token this contract locks.
    ///
    /// # Examples
    ///
    /// ```
    /// let token = htlc.token();
    /// ```
    fn token(self: @TContractState) -> ContractAddress;

    /// Returns the order stored under `order_id`.
    ///
    /// An order that was never initiated is returned zeroed; check that its
    /// `redeemer` is non-zero to tell it apart from a real order.
    ///
    /// # Arguments
    ///
    /// * `order_id` - ID of the order to read.
    ///
    /// # Examples
    ///
    /// ```
    /// let order = htlc.get_order(order_id);
    /// assert!(order.redeemer.is_non_zero(), "order not initiated");
    /// ```
    fn get_order(self: @TContractState, order_id: felt252) -> Order;

    /// Creates an order, with the caller as both the funder and the initiator.
    ///
    /// Transfers `amount` from the caller to this contract and emits `Initiated`.
    /// The caller must have approved this contract for at least `amount`.
    ///
    /// # Arguments
    ///
    /// * `redeemer` - Address allowed to receive the funds on redemption.
    /// * `timelock` - Number of blocks after initiation before a refund is allowed.
    /// * `amount` - Amount of tokens to lock.
    /// * `secret_hash` - SHA-256 hash of the secret, as two big-endian `u128` limbs.
    ///
    /// # Panics
    ///
    /// * If `redeemer` is the zero address.
    /// * If `timelock` or `amount` is zero.
    /// * If the caller is the `redeemer`.
    /// * If an order with these exact parameters already exists.
    /// * If the token transfer from the caller fails.
    ///
    /// # Examples
    ///
    /// ```
    /// // Lock 1000 tokens for 100 blocks.
    /// htlc.initiate(redeemer, 100, 1000, secret_hash);
    /// ```
    fn initiate(
        ref self: TContractState,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secret_hash: [u128; 2],
    );

    /// Creates an order like `initiate`, carrying extra data for the counterparty
    /// chain.
    ///
    /// Behaves exactly like `initiate`, except that it emits
    /// `InitiatedWithDestinationData` instead of `Initiated`. The contract does not
    /// interpret `destination_data`; it is opaque payload for off-chain consumers,
    /// such as the address to pay out to on the destination chain.
    ///
    /// # Arguments
    ///
    /// * `redeemer` - Address allowed to receive the funds on redemption.
    /// * `timelock` - Number of blocks after initiation before a refund is allowed.
    /// * `amount` - Amount of tokens to lock.
    /// * `secret_hash` - SHA-256 hash of the secret, as two big-endian `u128` limbs.
    /// * `destination_data` - Opaque data emitted with the event. It is not part of
    ///   the order ID and is not stored.
    ///
    /// # Panics
    ///
    /// Under the same conditions as `initiate`.
    ///
    /// # Examples
    ///
    /// ```
    /// htlc.initiate_with_destination_data(redeemer, 100, 1000, secret_hash, data);
    /// ```
    fn initiate_with_destination_data(
        ref self: TContractState,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secret_hash: [u128; 2],
        destination_data: Array<felt252>,
    );

    /// Creates an order funded by the caller on behalf of another initiator.
    ///
    /// The tokens are pulled from the caller, but `initiator` is recorded as the
    /// order's initiator and is therefore who a later refund pays out to. The caller
    /// must have approved this contract for at least `amount`. Emits `Initiated`.
    ///
    /// # Arguments
    ///
    /// * `initiator` - Address recorded as the initiator, and the recipient of any
    ///   refund.
    /// * `redeemer` - Address allowed to receive the funds on redemption.
    /// * `timelock` - Number of blocks after initiation before a refund is allowed.
    /// * `amount` - Amount of tokens to lock.
    /// * `secret_hash` - SHA-256 hash of the secret, as two big-endian `u128` limbs.
    ///
    /// # Panics
    ///
    /// * If `initiator` or `redeemer` is the zero address.
    /// * If `timelock` or `amount` is zero.
    /// * If the caller is the `redeemer`.
    /// * If `initiator` is the `redeemer`.
    /// * If an order with these exact parameters already exists.
    /// * If the token transfer from the caller fails.
    ///
    /// # Examples
    ///
    /// ```
    /// // A solver funds an order that will refund to `initiator`.
    /// htlc.initiate_on_behalf(initiator, redeemer, 100, 1000, secret_hash);
    /// ```
    fn initiate_on_behalf(
        ref self: TContractState,
        initiator: ContractAddress,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secret_hash: [u128; 2],
    );

    /// Creates an order like `initiate_on_behalf`, carrying extra data for the
    /// counterparty chain.
    ///
    /// Behaves exactly like `initiate_on_behalf`, except that it emits
    /// `InitiatedWithDestinationData` instead of `Initiated`.
    ///
    /// # Arguments
    ///
    /// * `initiator` - Address recorded as the initiator, and the recipient of any
    ///   refund.
    /// * `redeemer` - Address allowed to receive the funds on redemption.
    /// * `timelock` - Number of blocks after initiation before a refund is allowed.
    /// * `amount` - Amount of tokens to lock.
    /// * `secret_hash` - SHA-256 hash of the secret, as two big-endian `u128` limbs.
    /// * `destination_data` - Opaque data emitted with the event. It is not part of
    ///   the order ID and is not stored.
    ///
    /// # Panics
    ///
    /// Under the same conditions as `initiate_on_behalf`.
    ///
    /// # Examples
    ///
    /// ```
    /// htlc
    ///     .initiate_on_behalf_with_destination_data(
    ///         initiator, redeemer, 100, 1000, secret_hash, data,
    ///     );
    /// ```
    fn initiate_on_behalf_with_destination_data(
        ref self: TContractState,
        initiator: ContractAddress,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secret_hash: [u128; 2],
        destination_data: Array<felt252>,
    );

    /// Creates an order authorised by the initiator's SNIP-12 signature.
    ///
    /// The tokens are pulled from `initiator` rather than from the caller, so
    /// `initiator` must have approved this contract for at least `amount`. This lets
    /// a third party submit and pay the fee for an order the initiator signed
    /// off-chain. Emits `Initiated`.
    ///
    /// The signature is checked with SRC-6 `is_valid_signature` against the
    /// `Initiate` struct hash, which covers the redeemer, amount, timelock, secret
    /// hash, expiry and this contract's address, so it cannot be replayed against a
    /// different order, a different deployment, or after `valid_until`.
    ///
    /// # Arguments
    ///
    /// * `initiator` - Account that signed the order, and the source of the funds.
    /// * `redeemer` - Address allowed to receive the funds on redemption.
    /// * `timelock` - Number of blocks after initiation before a refund is allowed.
    /// * `amount` - Amount of tokens to lock.
    /// * `secret_hash` - SHA-256 hash of the secret, as two big-endian `u128` limbs.
    /// * `valid_until` - Block number after which the signature is no longer
    ///   accepted.
    /// * `signature` - SNIP-12 signature over the `Initiate` message, produced by
    ///   `initiator`.
    ///
    /// # Panics
    ///
    /// * If `initiator` or `redeemer` is the zero address.
    /// * If `timelock` or `amount` is zero.
    /// * If the current block number is not less than `valid_until`.
    /// * If `signature` is not a valid signature by `initiator` over this order.
    /// * If `initiator` is the `redeemer`.
    /// * If an order with these exact parameters already exists.
    /// * If the token transfer from `initiator` fails.
    ///
    /// # Examples
    ///
    /// ```
    /// htlc
    ///     .initiate_with_signature(
    ///         initiator, redeemer, 100, 1000, secret_hash, valid_until, signature,
    ///     );
    /// ```
    fn initiate_with_signature(
        ref self: TContractState,
        initiator: ContractAddress,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secret_hash: [u128; 2],
        valid_until: u128,
        signature: Array<felt252>,
    );

    /// Settles an order by revealing its secret, paying the funds to the redeemer.
    ///
    /// Callable by anyone who knows the secret, not just the redeemer, since the
    /// funds can only ever go to the redeemer recorded on the order. Revealing the
    /// secret on chain is what lets the counterparty settle the other half of the
    /// swap. Emits `Redeemed`, which carries the secret.
    ///
    /// The secret is validated by re-deriving the order ID from its SHA-256 hash and
    /// comparing it against `order_id`, so a wrong secret cannot settle the order.
    ///
    /// # Arguments
    ///
    /// * `order_id` - ID of the order to settle.
    /// * `secret` - The 256-bit secret, as eight big-endian `u32` words.
    ///
    /// # Panics
    ///
    /// * If the order was never initiated.
    /// * If the order was already redeemed or refunded.
    /// * If `secret` does not hash to the order's secret hash.
    ///
    /// # Examples
    ///
    /// ```
    /// htlc.redeem(order_id, [0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8]);
    /// ```
    fn redeem(ref self: TContractState, order_id: felt252, secret: [u32; 8]);

    /// Returns an expired order's funds to its initiator.
    ///
    /// Callable by anyone once `timelock` blocks have passed since initiation; the
    /// funds always go to the order's initiator. Emits `Refunded`.
    ///
    /// # Arguments
    ///
    /// * `order_id` - ID of the order to refund.
    ///
    /// # Panics
    ///
    /// * If the order was never initiated.
    /// * If the order was already redeemed or refunded.
    /// * If the timelock has not expired yet.
    ///
    /// # Examples
    ///
    /// ```
    /// htlc.refund(order_id);
    /// ```
    fn refund(ref self: TContractState, order_id: felt252);

    /// Returns an order's funds to its initiator before the timelock expires, with
    /// the redeemer's consent.
    ///
    /// Used to unwind a swap cooperatively rather than waiting out the timelock. If
    /// the caller is the redeemer, `signature` is ignored and may be empty;
    /// otherwise a SNIP-12 signature by the redeemer is required. The funds always
    /// go to the order's initiator. Emits `Refunded`.
    ///
    /// # Arguments
    ///
    /// * `order_id` - ID of the order to refund.
    /// * `signature` - SNIP-12 signature over the `instantRefund` message, produced
    ///   by the order's redeemer. May be empty when the caller is the redeemer.
    ///
    /// # Panics
    ///
    /// * If the order was never initiated.
    /// * If the order was already redeemed or refunded.
    /// * If the caller is not the redeemer and `signature` is not a valid signature
    ///   by the redeemer over this order.
    ///
    /// # Examples
    ///
    /// ```
    /// // Called by the redeemer, no signature needed.
    /// htlc.instant_refund(order_id, array![]);
    ///
    /// // Called by anyone else, with the redeemer's signature.
    /// htlc.instant_refund(order_id, signature);
    /// ```
    fn instant_refund(ref self: TContractState, order_id: felt252, signature: Array<felt252>);
}

/// Computes the SNIP-12 message hash a signer signs to authorise an action.
///
/// The hash binds the struct's contents to the `StarknetDomain` of this contract
/// (name, version, chain ID and revision) and to the signer's address, so a
/// signature cannot be replayed on another chain, another contract, or by another
/// account.
///
/// # Examples
///
/// ```
/// let message_hash = initiate.get_message_hash(chain_id, initiator);
/// let is_valid = ISRC6Dispatcher { contract_address: initiator }
///     .is_valid_signature(message_hash, signature);
/// ```
pub trait IMessageHash<T> {
    /// Returns the SNIP-12 message hash of `self` for `signer` on `chain_id`.
    ///
    /// # Arguments
    ///
    /// * `chain_id` - Chain ID to bind the signature to.
    /// * `signer` - Address of the account expected to have signed the message.
    ///
    /// # Returns
    ///
    /// The message hash to pass to SRC-6 `is_valid_signature`.
    fn get_message_hash(self: @T, chain_id: felt252, signer: ContractAddress) -> felt252;
}

/// Computes the SNIP-12 struct hash of a type.
///
/// Implemented for each type that appears in a signed message, including the nested
/// types (`u256`, `Span<u128>`) that SNIP-12 hashes as structs in their own right.
///
/// # Examples
///
/// ```
/// let struct_hash = initiate.get_struct_hash();
/// ```
pub trait IStructHash<T> {
    /// Returns the Poseidon struct hash of `self`, prefixed with its type hash.
    ///
    /// # Returns
    ///
    /// The struct hash, for use as a component of a SNIP-12 message hash.
    fn get_struct_hash(self: @T) -> felt252;
}
