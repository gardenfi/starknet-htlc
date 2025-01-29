#[starknet::contract]
pub mod HTLC {
    use core::num::traits::Zero;
    use starknet::{ContractAddress, get_caller_address, get_block_info, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerWriteAccess,
        StoragePointerReadAccess,
    };
    use core::poseidon::{PoseidonTrait};
    use core::option::OptionTrait;
    use core::traits::{Into, TryInto};
    use core::sha256::compute_sha256_u32_array;
    use core::array::ArrayTrait;
    use alexandria_bytes::utils::BytesDebug;
    use openzeppelin_token::erc20::{ERC20HooksEmptyImpl};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::account::interface::{ISRC6Dispatcher, ISRC6DispatcherTrait};
    use core::hash::{HashStateTrait, HashStateExTrait};
    use crate::interface::{IHTLC, IMessageHash};
    use crate::interface::struct_hash::{
        Initiate, MessageHashInitiate, instantRefund, MessageHashInstantRefund,
    };
    use crate::interface::events::{Initiated, Redeemed, Refunded};
    use core::starknet::event::EventEmitter;


    pub const CHAIN_ID: felt252 = 0x534e5f5345504f4c4941; // SN_SEPOLIA
    pub const NAME: felt252 = 'HTLC';
    pub const VERSION: felt252 = '1';

    pub const INITIATE_TYPE_HASH: felt252 = selector!(
        "\"Initiate\"(\"redeemer\":\"ContractAddress\",\"amount\":\"u256\",\"timelock\":\"u128\",\"secretHash\":\"u128*\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
    );
    pub const U256_TYPE_HASH: felt252 = selector!("\"u256\"(\"low\":\"u128\",\"high\":\"u128\")");

    pub const INSTANT_REFUND_TYPE_HASH: felt252 = selector!(
        "\"instantRefund\"(\"orderID\":\"felt\")",
    );


    #[storage]
    struct Storage {
        pub token: IERC20Dispatcher,
        pub orders: Map::<felt252, Order>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Initiated: Initiated,
        Redeemed: Redeemed,
        Refunded: Refunded,
    }

    #[derive(Drop, Serde, starknet::Store, Debug)]
    pub struct Order {
        is_fulfilled: bool,
        initiator: ContractAddress,
        redeemer: ContractAddress,
        initiated_at: u128,
        timelock: u128,
        amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token: ContractAddress) {
        self.token.write(IERC20Dispatcher { contract_address: token });
    }

    #[abi(embed_v0)]
    pub impl HTLC of IHTLC<ContractState> {
        fn initiate(
            ref self: ContractState,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secretHash: [u32; 8],
        ) {
            self.safe_params(redeemer, timelock, amount);
            let sender = get_caller_address();
            self._initiate(sender, sender, redeemer, timelock, amount, secretHash);
        }

        fn initiateOnBehalf(
            ref self: ContractState,
            initiator: ContractAddress,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secretHash: [u32; 8],
        ) {
            self.safe_params(redeemer, timelock, amount);
            let sender = get_caller_address();
            self._initiate(sender, initiator, redeemer, timelock, amount, secretHash);
        }

        fn initiateWithSignature(
            ref self: ContractState,
            initiator: ContractAddress,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secretHash: [u32; 8],
            signature: (felt252, felt252, bool),
        ) {
            let intiate = Initiate { redeemer, amount, timelock, secretHash };

            let message_hash = intiate.get_message_hash(initiator);
            let (sig_r, sig_s, _) = signature;
            let mut array0 = ArrayTrait::new();
            array0.append(sig_r);
            array0.append(sig_s);

            let is_valid = ISRC6Dispatcher { contract_address: initiator }
                .is_valid_signature(message_hash, array0.clone());
            let is_valid_signature = is_valid == starknet::VALIDATED || is_valid == 1;
            assert!(is_valid_signature, "HTLC: invalid initiator signature");

            self._initiate(initiator, initiator, redeemer, timelock, amount, secretHash);
        }

        fn redeem(ref self: ContractState, orderID: felt252, secret: Array<u32>) {
            let order = self.orders.read(orderID);
            assert(order.redeemer.is_non_zero(), 'HTLC: order not initiated');
            assert(!order.is_fulfilled, 'HTLC: order fulfilled');

            let secretHash = compute_sha256_u32_array(secret.clone(), 0, 0);
            let initiator_address: felt252 = order.initiator.try_into().unwrap();

            assert!(
                self.generate_order_id(CHAIN_ID, secretHash, initiator_address) == orderID,
                "HTLC: incorrect secret",
            );

            let updated_order = Order {
                initiator: order.initiator,
                redeemer: order.redeemer,
                amount: order.amount,
                timelock: order.timelock,
                initiated_at: order.initiated_at,
                is_fulfilled: true,
            };
            self.orders.write(orderID, updated_order);

            self.token.read().transfer(order.redeemer, order.amount);
            self.emit(Event::Redeemed(Redeemed { orderID, secretHash, secret }));
        }

        fn refund(ref self: ContractState, orderID: felt252) {
            let order = self.orders.read(orderID);

            assert(order.redeemer.is_non_zero(), 'HTLC: order not initiated');
            assert(!order.is_fulfilled, 'HTLC: order fulfilled');

            let block_info = get_block_info().unbox();
            let current_block = block_info.block_number;
            assert(
                (order.initiated_at + order.timelock) < current_block.into(),
                'HTLC: order not expired',
            );

            let updated_order = Order {
                initiator: order.initiator,
                redeemer: order.redeemer,
                amount: order.amount,
                timelock: order.timelock,
                initiated_at: order.initiated_at,
                is_fulfilled: true,
            };
            self.orders.write(orderID, updated_order);

            let balance = self.token.read().balance_of(order.initiator);
            assert!(balance >= order.amount, "Insufficient balance for transfer");
            self.token.read().transfer(order.initiator, order.amount);

            self.emit(Event::Refunded(Refunded { orderID }));
        }

        fn instantRefund(
            ref self: ContractState, orderID: felt252, signature: (felt252, felt252, bool),
        ) {
            let refund = instantRefund { orderID };

            let order = self.orders.read(orderID);
            let message_hash = refund.get_message_hash(order.redeemer);
            let (sig_r, sig_s, _) = signature;
            let mut array0 = ArrayTrait::new();
            array0.append(sig_r);
            array0.append(sig_s);

            let is_valid = ISRC6Dispatcher { contract_address: order.redeemer }
                .is_valid_signature(message_hash, array0.clone());
            let is_valid_signature = is_valid == starknet::VALIDATED || is_valid == 1;
            assert!(is_valid_signature, "HTLC: invalid redeemer signature");
            assert!(!order.is_fulfilled, "HTLC: order fulfilled");

            let updated_order = Order {
                initiator: order.initiator,
                redeemer: order.redeemer,
                amount: order.amount,
                timelock: order.timelock,
                initiated_at: order.initiated_at,
                is_fulfilled: true,
            };

            self.orders.write(orderID, updated_order);

            let contract_address = get_contract_address();
            let balance = self.token.read().balance_of(contract_address);
            assert!(balance >= order.amount, "HTLC: insufficient contract balance");
            self.token.read().transfer(order.initiator, order.amount);

            self.emit(Event::Refunded(Refunded { orderID }));
        }
    }

    #[generate_trait]
    pub impl InternalFunctions of InternalFunctionsTrait {
        fn _initiate(
            ref self: ContractState,
            funder_: ContractAddress,
            initiator_: ContractAddress,
            redeemer_: ContractAddress,
            timelock_: u128,
            amount_: u256,
            secretHash_: [u32; 8],
        ) {
            assert!(initiator_ != redeemer_, "HTLC: same initiator & redeemer");

            let initiator_address: felt252 = initiator_.try_into().unwrap();
            let orderID = self.generate_order_id(CHAIN_ID, secretHash_, initiator_address);

            let order: Order = self.orders.read(orderID);
            assert!(!order.redeemer.is_non_zero(), "HTLC: duplicate order");

            let block_info = get_block_info().unbox();
            let current_block = block_info.block_number;

            let create_order = Order {
                is_fulfilled: false,
                initiator: initiator_,
                redeemer: redeemer_,
                initiated_at: current_block.into(),
                timelock: timelock_,
                amount: amount_,
            };
            self.orders.write(orderID, create_order);

            let balance = self.token.read().balance_of(funder_);
            assert!(balance >= amount_, "ERC20: Insufficient balance");

            let allowance = self.token.read().allowance(funder_, get_contract_address());
            assert!(allowance >= amount_, "ERC20: insufficient allowance");

            let transfer_result = self
                .token
                .read()
                .transfer_from(funder_, get_contract_address(), amount_);
            assert!(transfer_result, "ERC20: Transfer failed");

            self
                .emit(
                    Event::Initiated(
                        Initiated { orderID, secretHash: secretHash_, amount: amount_ },
                    ),
                );
        }

        fn generate_order_id(
            self: @ContractState, chainId: felt252, secretHash: [u32; 8], initiatorAddress: felt252,
        ) -> felt252 {
            let mut state = PoseidonTrait::new();
            state = state.update(chainId);
            state = state.update_with(secretHash);
            state = state.update(initiatorAddress);
            state.finalize()
        }
    }

    #[generate_trait]
    impl AssertsImpl of AssertsTrait {
        fn safe_params(
            self: @ContractState, redeemer: ContractAddress, timelock: u128, amount: u256,
        ) {
            assert!(redeemer.is_non_zero(), "HTLC: zero address redeemer");
            assert!(timelock > 0, "HTLC: zero timelock");
            assert!(amount > 0, "HTLC: zero amount");
        }
    }
}
