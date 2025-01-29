#[derive(Drop, starknet::Event)]
pub struct Initiated {
    #[key]
    pub orderID: felt252,
    pub secretHash: [u32; 8],
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct Redeemed {
    #[key]
    pub orderID: felt252,
    pub secretHash: [u32; 8],
    pub secret: Array<u32>,
}

#[derive(Drop, starknet::Event)]
pub struct Refunded {
    #[key]
    pub orderID: felt252,
}
