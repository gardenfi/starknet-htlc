//! The SNIP-12 domain separator used by the HTLC contract.
//!
//! Every signed message is hashed together with this domain, which is what stops a
//! signature produced for one chain, one protocol or one revision from being
//! replayed against another.
//!
//! # Examples
//!
//! ```
//! use starknet_htlc::interface::IStructHash;
//! use starknet_htlc::interface::sn_domain::StarknetDomain;
//!
//! let domain = StarknetDomain { name: NAME, version: VERSION, chain_id, revision: 1 };
//! let domain_hash = domain.get_struct_hash();
//! ```

use core::poseidon::poseidon_hash_span;
use crate::interface::IStructHash;

/// The SNIP-12 domain separator.
///
/// All four fields are encoded as `shortstring`, matching the type hash in
/// `STARKNET_DOMAIN_TYPE_HASH`.
#[derive(Hash, Drop, Copy)]
pub struct StarknetDomain {
    /// Protocol name. The HTLC contract uses `'HTLC'`.
    pub name: felt252,
    /// Protocol version. The HTLC contract uses `'2'`.
    pub version: felt252,
    /// Chain ID the signature is valid on, read from the transaction context at
    /// deployment.
    pub chain_id: felt252,
    /// SNIP-12 revision. Always `1`.
    pub revision: felt252,
}

/// SNIP-12 type hash of the `StarknetDomain` struct.
pub const STARKNET_DOMAIN_TYPE_HASH: felt252 = selector!(
    "\"StarknetDomain\"(\"name\":\"shortstring\",\"version\":\"shortstring\",\"chainId\":\"shortstring\",\"revision\":\"shortstring\")",
);

/// Hashes the domain separator into the single felt that prefixes every signed
/// message.
impl StructHashStarknetDomain of IStructHash<StarknetDomain> {
    fn get_struct_hash(self: @StarknetDomain) -> felt252 {
        poseidon_hash_span(
            array![
                STARKNET_DOMAIN_TYPE_HASH,
                *self.name,
                *self.version,
                *self.chain_id,
                *self.revision,
            ]
                .span(),
        )
    }
}
