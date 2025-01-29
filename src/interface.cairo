pub mod sn_domain;
pub mod struct_hash;
pub mod events;
use starknet::ContractAddress;

#[starknet::interface]
pub trait IHTLC<TContractState> {
    fn initiate(
        ref self: TContractState,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secretHash: [u32; 8],
    );

    fn initiateOnBehalf(
        ref self: TContractState,
        initiator: ContractAddress,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secretHash: [u32; 8],
    );

    fn initiateWithSignature(
        ref self: TContractState,
        initiator: ContractAddress,
        redeemer: ContractAddress,
        timelock: u128,
        amount: u256,
        secretHash: [u32; 8],
        signature: (felt252, felt252, bool),
    );

    fn redeem(ref self: TContractState, orderID: felt252, secret: Array<u32>);

    fn refund(ref self: TContractState, orderID: felt252);

    fn instantRefund(
        ref self: TContractState, orderID: felt252, signature: (felt252, felt252, bool),
    );
}

pub trait IMessageHash<T> {
    fn get_message_hash(self: @T, signer: ContractAddress) -> felt252;
}

pub trait IStructHash<T> {
    fn get_struct_hash(self: @T) -> felt252;
}
