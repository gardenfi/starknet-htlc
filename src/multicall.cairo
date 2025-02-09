use starknet::ContractAddress;


#[starknet::interface]
pub trait IMulticall<TContractState> {
    fn multicall(self : @TContractState,address : ContractAddress,call_data : Array<Array<felt252>>);
}

#[starknet::contract]
mod Multicall {
    use starknet::ContractAddress;
    use starknet::syscalls::call_contract_syscall;
    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    pub impl Multicall of super::IMulticall<ContractState>{
        fn multicall(self : @ContractState, address : ContractAddress , call_data : Array<Array<felt252>>){
            for mut data in call_data{
                let selector = data.pop_front().unwrap();
                call_contract_syscall(
                    address,
                    selector,
                    data.span()
                ).unwrap();
            }
        }
    }
}