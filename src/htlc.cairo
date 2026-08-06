//! Implementation of the `HTLC` contract.

/// # HTLC
///
/// Hash Time Locked Contract for cross-chain atomic swaps, by Garden Finance.
///
/// An order locks `amount` of the contract's ERC-20 token against the SHA-256 hash
/// of a secret for `timelock` blocks. Whoever learns the secret can `redeem` the
/// funds to the redeemer; if nobody does, the initiator gets them back via `refund`
/// once the timelock expires. Running one order on each of two chains against the
/// same secret hash is what makes the pair of transfers atomic: redeeming either
/// half reveals the secret needed to redeem the other.
///
/// Orders are keyed by an ID derived from all of their parameters together with the
/// chain ID and this contract's address, so an identical set of parameters can only
/// be initiated once, and an order ID is meaningful on exactly one deployment.
///
/// ## Entrypoints
///
/// Initiation, which locks the funds. These differ only in who funds the order and
/// how the initiator is established:
///
/// * `initiate` - the caller is both the funder and the initiator.
/// * `initiate_on_behalf` - the caller funds an order for a third-party initiator.
/// * `initiate_with_signature` - the initiator funds and authorises the order with a
///   SNIP-12 signature, while a third party submits it.
/// * `initiate_with_destination_data` and
///   `initiate_on_behalf_with_destination_data` - as above, but emitting
///   `InitiatedWithDestinationData` so that opaque destination-chain data travels
///   with the event.
///
/// Settlement, which releases the funds:
///
/// * `redeem` - pays the redeemer, on revealing the secret.
/// * `refund` - pays the initiator, once the timelock has expired.
/// * `instant_refund` - pays the initiator before expiry, with the redeemer's
///   consent.
///
/// # Examples
///
/// ```
/// use starknet_htlc::interface::{IHTLCDispatcher, IHTLCDispatcherTrait};
///
/// let htlc = IHTLCDispatcher { contract_address: htlc_address };
///
/// // The initiator locks 1000 tokens for 100 blocks against the hash of a secret.
/// htlc.initiate(redeemer, 100, 1000, secret_hash);
///
/// // The redeemer claims them by revealing the secret, which publishes it on chain.
/// htlc.redeem(order_id, secret);
/// ```
#[starknet::contract]
pub mod HTLC {
    use core::array::ArrayTrait;
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::Zero;
    use core::option::OptionTrait;
    use core::poseidon::PoseidonTrait;
    use core::sha256::compute_sha256_u32_array;
    use core::traits::{Into, TryInto};
    use openzeppelin::account::interface::{ISRC6Dispatcher, ISRC6DispatcherTrait};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::syscalls::get_execution_info_v2_syscall;
    use starknet::{
        ContractAddress, SyscallResultTrait, get_block_info, get_caller_address,
        get_contract_address,
    };
    use crate::interface::events::{Initiated, InitiatedWithDestinationData, Redeemed, Refunded};
    use crate::interface::struct_hash::{
        Initiate, MessageHashInitiate, MessageHashInstantRefund, instantRefund,
    };
    use crate::interface::{IHTLC, IMessageHash};


    /// Protocol name in the SNIP-12 domain separator.
    pub const NAME: felt252 = 'HTLC';
    /// Protocol version in the SNIP-12 domain separator.
    ///
    /// Bumping this invalidates every signature produced for an earlier version.
    pub const VERSION: felt252 = '2';

    /// SNIP-12 type hash of the `Initiate` message signed for
    /// `initiate_with_signature`.
    pub const INITIATE_TYPE_HASH: felt252 = selector!(
        "\"Initiate\"(\"redeemer\":\"ContractAddress\",\"amount\":\"u256\",\"timelock\":\"u128\",\"secretHash\":\"u128*\",\"verifyingContract\":\"ContractAddress\",\"valid_until\":\"u128\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
    );
    /// SNIP-12 type hash of `u256`, which is hashed as a nested struct of its `low`
    /// and `high` limbs.
    pub const U256_TYPE_HASH: felt252 = selector!("\"u256\"(\"low\":\"u128\",\"high\":\"u128\")");

    /// SNIP-12 type hash of the `instantRefund` message signed for `instant_refund`.
    pub const INSTANT_REFUND_TYPE_HASH: felt252 = selector!(
        "\"instantRefund\"(\"orderID\":\"felt\",\"verifyingContract\":\"ContractAddress\")",
    );


    /// Contract storage.
    #[storage]
    struct Storage {
        /// The single ERC-20 token every order is denominated in, set at deployment.
        pub token: IERC20Dispatcher,
        /// All orders, keyed by order ID. Unset entries read back zeroed.
        pub orders: Map<felt252, Order>,
        /// Chain ID captured at deployment, used in order IDs and in the SNIP-12
        /// domain separator.
        pub chain_id: felt252,
    }

    /// Events emitted by the contract. See the `interface::events` module.
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Initiated: Initiated,
        Redeemed: Redeemed,
        Refunded: Refunded,
        InitiatedWithDestinationData: InitiatedWithDestinationData,
    }

    /// A single HTLC order.
    ///
    /// An order that was never initiated reads back with every field zeroed, so a
    /// non-zero `redeemer` is what distinguishes a real order from an absent one.
    /// The secret hash is not stored; the order ID commits to it instead.
    #[derive(Drop, Serde, starknet::Store, Debug)]
    pub struct Order {
        /// Block number the order was redeemed or refunded at, or `0` while it is
        /// still open. This is what makes settlement single-use.
        fulfilled_at: u128,
        /// Address that receives the funds on refund.
        initiator: ContractAddress,
        /// Address that receives the funds on redemption.
        redeemer: ContractAddress,
        /// Block number the order was created at.
        initiated_at: u128,
        /// Number of blocks after `initiated_at` before a refund is allowed.
        timelock: u128,
        /// Amount of tokens locked.
        amount: u256,
    }

    /// Deploys the contract for a single ERC-20 token.
    ///
    /// Captures the chain ID from the deploying transaction; every order ID and
    /// SNIP-12 signature is bound to it, so orders and signatures never carry across
    /// chains.
    ///
    /// # Arguments
    ///
    /// * `token` - Address of the ERC-20 token all orders will lock.
    #[constructor]
    fn constructor(ref self: ContractState, token: ContractAddress) {
        let tx_info = get_execution_info_v2_syscall().unwrap_syscall().unbox().tx_info.unbox();
        self.chain_id.write(tx_info.chain_id);
        self.token.write(IERC20Dispatcher { contract_address: token });
    }

    /// The contract's external entrypoints.
    ///
    /// See the `IHTLC` trait for the full documentation of each entrypoint,
    /// including its arguments and the conditions under which it panics.
    #[abi(embed_v0)]
    pub impl HTLC of IHTLC<ContractState> {
        /// Returns the address of the ERC-20 token this contract locks.
        fn token(self: @ContractState) -> ContractAddress {
            self.token.read().contract_address
        }

        /// Returns the order stored under `order_id`, zeroed if there is none.
        fn get_order(self: @ContractState, order_id: felt252) -> Order {
            self.orders.read(order_id)
        }

        /// Creates an order, with the caller as both the funder and the initiator.
        ///
        /// Emits `Initiated`.
        fn initiate(
            ref self: ContractState,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secret_hash: [u128; 2],
        ) {
            self.safe_params(get_caller_address(), redeemer, timelock, amount);
            let sender = get_caller_address();
            let order_id = self._initiate(sender, sender, redeemer, timelock, amount, secret_hash);

            self
                .emit(
                    Event::Initiated(
                        Initiated { order_id, secret_hash: secret_hash, amount: amount },
                    ),
                );
        }

        /// Creates an order like `initiate`, carrying `destination_data` for the
        /// counterparty chain.
        ///
        /// Emits `InitiatedWithDestinationData`.
        fn initiate_with_destination_data(
            ref self: ContractState,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secret_hash: [u128; 2],
            destination_data: Array<felt252>,
        ) {
            self.safe_params(get_caller_address(), redeemer, timelock, amount);
            let sender = get_caller_address();
            let order_id = self._initiate(sender, sender, redeemer, timelock, amount, secret_hash);

            self
                .emit(
                    Event::InitiatedWithDestinationData(
                        InitiatedWithDestinationData {
                            order_id, secret_hash, amount, destination_data,
                        },
                    ),
                );
        }

        /// Creates an order funded by the caller on behalf of `initiator`.
        ///
        /// The caller funds the order but `initiator` is recorded as the initiator,
        /// so a later refund pays out to `initiator`, not to the caller. Emits
        /// `Initiated`.
        fn initiate_on_behalf(
            ref self: ContractState,
            initiator: ContractAddress,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secret_hash: [u128; 2],
        ) {
            self.safe_params(initiator, redeemer, timelock, amount);
            let sender = get_caller_address();
            assert!(sender != redeemer, "HTLC: sender == redeemer");

            let order_id = self
                ._initiate(sender, initiator, redeemer, timelock, amount, secret_hash);

            self
                .emit(
                    Event::Initiated(
                        Initiated { order_id, secret_hash: secret_hash, amount: amount },
                    ),
                );
        }

        /// Creates an order like `initiate_on_behalf`, carrying `destination_data`
        /// for the counterparty chain.
        ///
        /// Emits `InitiatedWithDestinationData`.
        fn initiate_on_behalf_with_destination_data(
            ref self: ContractState,
            initiator: ContractAddress,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secret_hash: [u128; 2],
            destination_data: Array<felt252>,
        ) {
            self.safe_params(initiator, redeemer, timelock, amount);
            let sender = get_caller_address();
            assert!(sender != redeemer, "HTLC: sender == redeemer");

            let order_id = self
                ._initiate(sender, initiator, redeemer, timelock, amount, secret_hash);

            self
                .emit(
                    Event::InitiatedWithDestinationData(
                        InitiatedWithDestinationData {
                            order_id, secret_hash, amount, destination_data,
                        },
                    ),
                );
        }

        /// Creates an order authorised by `initiator`'s SNIP-12 signature.
        ///
        /// The funds come from `initiator` rather than from the caller, so a third
        /// party can submit and pay for an order the initiator signed off-chain.
        /// Emits `Initiated`.
        fn initiate_with_signature(
            ref self: ContractState,
            initiator: ContractAddress,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
            secret_hash: [u128; 2],
            valid_until: u128,
            signature: Array<felt252>,
        ) {
            self.safe_params(initiator, redeemer, timelock, amount);
            let block_info = get_block_info().unbox();
            assert!(block_info.block_number.into() < valid_until, "HTLC: Expired signature");

            let verifying_contract = get_contract_address();
            let initiate = Initiate {
                redeemer,
                amount,
                timelock,
                secretHash: secret_hash,
                verifyingContract: verifying_contract,
                valid_until
            };
            let chain_id = self.chain_id.read();
            let message_hash = initiate.get_message_hash(chain_id, initiator);

            let is_valid = ISRC6Dispatcher { contract_address: initiator }
                .is_valid_signature(message_hash, signature);
            let is_valid_signature = is_valid == starknet::VALIDATED || is_valid == 1;
            assert!(is_valid_signature, "HTLC: invalid initiator signature");

            let order_id = self
                ._initiate(initiator, initiator, redeemer, timelock, amount, secret_hash);

            self.emit(Event::Initiated(Initiated { order_id, secret_hash, amount }));
        }

        /// Settles an order by revealing its secret, paying the funds to the
        /// redeemer.
        ///
        /// The secret is checked by re-deriving the order ID from its SHA-256 hash,
        /// so a wrong secret cannot settle the order. Callable by anyone who knows
        /// the secret, since the funds can only go to the recorded redeemer. Emits
        /// `Redeemed`, which publishes the secret.
        fn redeem(ref self: ContractState, order_id: felt252, secret: [u32; 8]) {
            let order = self.orders.read(order_id);
            assert!(order.redeemer.is_non_zero(), "HTLC: order not initiated");
            assert!(order.fulfilled_at.is_zero(), "HTLC: order fulfilled");

            // Convert [u32; 8] to Array<u32> for SHA256 computation
            let [s0, s1, s2, s3, s4, s5, s6, s7] = secret;
            let secret_array: Array<u32> = array![s0, s1, s2, s3, s4, s5, s6, s7];
            let secret_hash_u32 = compute_sha256_u32_array(secret_array, 0, 0);

            // Convert [u32; 8] SHA256 output to [u128; 2]
            // Each u128 is formed from 4 consecutive u32 values (4 × 32 = 128 bits)
            let [h0, h1, h2, h3, h4, h5, h6, h7] = secret_hash_u32;
            let secret_hash_u128: [u128; 2] = [
                h0.into() * 0x1000000000000000000000000_u128
                    + h1.into() * 0x10000000000000000_u128
                    + h2.into() * 0x100000000_u128
                    + h3.into(),
                h4.into() * 0x1000000000000000000000000_u128
                    + h5.into() * 0x10000000000000000_u128
                    + h6.into() * 0x100000000_u128
                    + h7.into(),
            ];

            let initiator_address: felt252 = order
                .initiator
                .try_into()
                .expect('HTLC: invalid initiator address');
            let redeemer_address: felt252 = order
                .redeemer
                .try_into()
                .expect('HTLC: invalid redeemer address');
            let chain_id = self.chain_id.read();
            assert!(
                self
                    .generate_order_id(
                        chain_id,
                        secret_hash_u128,
                        initiator_address,
                        redeemer_address,
                        order.timelock,
                        order.amount,
                    ) == order_id,
                "HTLC: incorrect secret",
            );

            let block_info = get_block_info().unbox();
            self
                .orders
                .write(order_id, Order { fulfilled_at: block_info.block_number.into(), ..order });

            let transfer_result = self.token.read().transfer(order.redeemer, order.amount);
            assert!(transfer_result, "ERC20: Transfer failed");

            self
                .emit(
                    Event::Redeemed(Redeemed { order_id, secret_hash: secret_hash_u128, secret }),
                );
        }

        /// Returns an expired order's funds to its initiator.
        ///
        /// Callable by anyone once the timelock has passed; the funds always go to
        /// the recorded initiator. Emits `Refunded`.
        fn refund(ref self: ContractState, order_id: felt252) {
            let order = self.orders.read(order_id);

            assert!(order.redeemer.is_non_zero(), "HTLC: order not initiated");
            assert!(order.fulfilled_at.is_zero(), "HTLC: order fulfilled");

            let current_block: u128 = get_block_info().unbox().block_number.into();
            assert!(
                (current_block - order.initiated_at) > order.timelock,
                "HTLC: order not expired",
            );
            self.orders.write(order_id, Order { fulfilled_at: current_block.into(), ..order });

            let transfer_result = self.token.read().transfer(order.initiator, order.amount);
            assert!(transfer_result, "ERC20: Transfer failed");

            self.emit(Event::Refunded(Refunded { order_id }));
        }

        /// Returns an order's funds to its initiator before the timelock expires,
        /// with the redeemer's consent.
        ///
        /// If the caller is the redeemer, `signature` is ignored and may be empty;
        /// otherwise a SNIP-12 signature by the redeemer is required. Emits
        /// `Refunded`.
        fn instant_refund(ref self: ContractState, order_id: felt252, signature: Array<felt252>) {
            let order = self.orders.read(order_id);
            assert!(order.redeemer.is_non_zero(), "HTLC: order not initiated");
            assert!(order.fulfilled_at.is_zero(), "HTLC: order fulfilled");

            let block_info = get_block_info().unbox();
            self
                .orders
                .write(order_id, Order { fulfilled_at: block_info.block_number.into(), ..order });

            let caller = get_caller_address();

            // If caller is not the redeemer, require a valid signature
            if caller != order.redeemer {
                let verifying_contract = get_contract_address();
                let refund = instantRefund {
                    orderID: order_id, verifyingContract: verifying_contract,
                };
                let chain_id = self.chain_id.read();
                let message_hash = refund.get_message_hash(chain_id, order.redeemer);

                let is_valid = ISRC6Dispatcher { contract_address: order.redeemer }
                    .is_valid_signature(message_hash, signature);
                let is_valid_signature = is_valid == starknet::VALIDATED || is_valid == 1;
                assert!(is_valid_signature, "HTLC: invalid redeemer signature");
            }

            let transfer_result = self.token.read().transfer(order.initiator, order.amount);
            assert!(transfer_result, "ERC20: Transfer failed");

            self.emit(Event::Refunded(Refunded { order_id }));
        }
    }

    /// Shared logic behind the entrypoints, not part of the contract's ABI.
    #[generate_trait]
    pub impl InternalFunctions of InternalFunctionsTrait {
        /// Records a new order and pulls its funds in.
        ///
        /// Derives the order ID, rejects a duplicate, writes the order to storage,
        /// and transfers `amount_` from `funder_` to this contract. It does not emit
        /// anything; the calling entrypoint picks and emits the right event.
        ///
        /// Note that the funder and the initiator are separate: the tokens come from
        /// `funder_`, but a refund later pays out to `initiator_`.
        ///
        /// Callers are expected to have validated the parameters with `safe_params`
        /// first; this function does not repeat those checks.
        ///
        /// # Arguments
        ///
        /// * `funder_` - Address the locked tokens are transferred from. Must have
        ///   approved this contract for at least `amount_`.
        /// * `initiator_` - Address recorded as the initiator, and the recipient of
        ///   any refund.
        /// * `redeemer_` - Address allowed to receive the funds on redemption.
        /// * `timelock_` - Number of blocks after initiation before a refund is
        ///   allowed.
        /// * `amount_` - Amount of tokens to lock.
        /// * `secret_hash_` - SHA-256 hash of the secret, as two big-endian `u128`
        ///   limbs.
        ///
        /// # Returns
        ///
        /// The ID of the newly created order.
        ///
        /// # Panics
        ///
        /// * If `initiator_` is the same as `redeemer_`.
        /// * If either address is not a valid `felt252`.
        /// * If an order with these exact parameters already exists.
        /// * If the token transfer from `funder_` fails.
        fn _initiate(
            ref self: ContractState,
            funder_: ContractAddress,
            initiator_: ContractAddress,
            redeemer_: ContractAddress,
            timelock_: u128,
            amount_: u256,
            secret_hash_: [u128; 2],
        ) -> felt252 {
            assert!(initiator_ != redeemer_, "HTLC: same initiator & redeemer");

            let initiator_address: felt252 = initiator_
                .try_into()
                .expect('HTLC: invalid initiator address');
            let redeemer_address: felt252 = redeemer_
                .try_into()
                .expect('HTLC: invalid redeemer address');
            let chain_id = self.chain_id.read();
            let order_id = self
                .generate_order_id(
                    chain_id, secret_hash_, initiator_address, redeemer_address, timelock_, amount_,
                );

            let order: Order = self.orders.read(order_id);
            assert!(!order.redeemer.is_non_zero(), "HTLC: duplicate order");

            let block_info = get_block_info().unbox();
            let current_block = block_info.block_number;

            let create_order = Order {
                fulfilled_at: 0,
                initiator: initiator_,
                redeemer: redeemer_,
                initiated_at: current_block.into(),
                timelock: timelock_,
                amount: amount_,
            };
            self.orders.write(order_id, create_order);

            let transfer_result = self
                .token
                .read()
                .transfer_from(funder_, get_contract_address(), amount_);
            assert!(transfer_result, "ERC20: Transfer failed");

            order_id
        }

        /// Derives an order's ID by Poseidon-hashing all of its parameters.
        ///
        /// Because the ID commits to every parameter, including the secret hash, an
        /// order cannot be created twice with the same inputs and `redeem` can
        /// validate a secret simply by re-deriving the ID from it. Hashing in the
        /// chain ID and this contract's address keeps an ID meaningful on exactly one
        /// deployment.
        ///
        /// Fields are absorbed in the same order as the Solidity implementation:
        /// `chainId`, `secretHash`, `initiator`, `redeemer`, `timelock`, `amount`,
        /// `address(this)`, so both sides of a swap derive matching IDs.
        ///
        /// # Arguments
        ///
        /// * `chain_id` - Chain ID the swap is executing on.
        /// * `secret_hash` - SHA-256 hash of the secret, as two big-endian `u128`
        ///   limbs.
        /// * `initiator_address` - Initiator of the order, as a `felt252`.
        /// * `redeemer_address` - Redeemer of the order, as a `felt252`.
        /// * `timelock` - Number of blocks after initiation before a refund is
        ///   allowed.
        /// * `amount` - Amount of tokens locked.
        ///
        /// # Returns
        ///
        /// The order ID.
        ///
        /// # Panics
        ///
        /// If this contract's address is not a valid `felt252`.
        fn generate_order_id(
            self: @ContractState,
            chain_id: felt252,
            secret_hash: [u128; 2],
            initiator_address: felt252,
            redeemer_address: felt252,
            timelock: u128,
            amount: u256,
        ) -> felt252 {
            let contract_address: felt252 = get_contract_address()
                .try_into()
                .expect('HTLC: invalid contract address');
            let mut state = PoseidonTrait::new();
            state = state.update(chain_id);
            state = state.update_with(secret_hash);
            state = state.update(initiator_address);
            state = state.update(redeemer_address);
            state = state.update(timelock.into());
            state = state.update(amount.low.into());
            state = state.update(amount.high.into());
            state = state.update(contract_address);
            state.finalize()
        }
    }

    /// Parameter validation shared by the initiation entrypoints.
    #[generate_trait]
    impl AssertsImpl of AssertsTrait {
        /// Rejects order parameters that would create an unusable order.
        ///
        /// Checks that neither party is the zero address and that neither the
        /// timelock nor the amount is zero. A zero timelock would make the order
        /// refundable in the same block it was created, defeating the lock.
        ///
        /// This does not check that the initiator and redeemer differ; `_initiate`
        /// enforces that.
        ///
        /// # Arguments
        ///
        /// * `initiator` - Address that would be recorded as the initiator.
        /// * `redeemer` - Address that would be recorded as the redeemer.
        /// * `timelock` - Number of blocks before a refund would be allowed.
        /// * `amount` - Amount of tokens that would be locked.
        ///
        /// # Panics
        ///
        /// * If `redeemer` or `initiator` is the zero address.
        /// * If `timelock` is zero.
        /// * If `amount` is zero.
        #[inline]
        fn safe_params(
            self: @ContractState,
            initiator: ContractAddress,
            redeemer: ContractAddress,
            timelock: u128,
            amount: u256,
        ) {
            assert!(redeemer.is_non_zero(), "HTLC: zero address redeemer");
            assert!(initiator.is_non_zero(), "HTLC: zero address initiator");
            assert!(timelock > 0, "HTLC: zero timelock");
            assert!(amount > 0, "HTLC: zero amount");
        }
    }
}
