export const ABI = [
  {
    type: "impl",
    name: "HTLC",
    interface_name: "starknet_htlc::htlc::IHTLC",
  },
  {
    type: "struct",
    name: "core::integer::u256",
    members: [
      {
        name: "low",
        type: "core::integer::u128",
      },
      {
        name: "high",
        type: "core::integer::u128",
      },
    ],
  },
  {
    type: "struct",
    name: "core::byte_array::ByteArray",
    members: [
      {
        name: "data",
        type: "core::array::Array::<core::bytes_31::bytes31>",
      },
      {
        name: "pending_word",
        type: "core::felt252",
      },
      {
        name: "pending_word_len",
        type: "core::integer::u32",
      },
    ],
  },
  {
    type: "enum",
    name: "core::result::Result::<(), core::felt252>",
    variants: [
      {
        name: "Ok",
        type: "()",
      },
      {
        name: "Err",
        type: "core::felt252",
      },
    ],
  },
  {
    type: "interface",
    name: "starknet_htlc::htlc::IHTLC",
    items: [
      {
        type: "function",
        name: "initiate",
        inputs: [
          {
            name: "redeemer",
            type: "core::starknet::contract_address::ContractAddress",
          },
          {
            name: "timelock",
            type: "core::integer::u64",
          },
          {
            name: "amount",
            type: "core::integer::u256",
          },
          {
            name: "secretHash",
            type: "core::byte_array::ByteArray",
          },
        ],
        outputs: [
          {
            type: "core::result::Result::<(), core::felt252>",
          },
        ],
        state_mutability: "external",
      },
      {
        type: "function",
        name: "redeem",
        inputs: [
          {
            name: "orderID",
            type: "[core::integer::u32; 8]",
          },
          {
            name: "secret",
            type: "core::byte_array::ByteArray",
          },
        ],
        outputs: [],
        state_mutability: "external",
      },
      {
        type: "function",
        name: "test",
        inputs: [
          {
            name: "secretHash",
            type: "core::byte_array::ByteArray",
          },
        ],
        outputs: [],
        state_mutability: "external",
      },
    ],
  },
  {
    type: "constructor",
    name: "constructor",
    inputs: [
      {
        name: "token",
        type: "core::starknet::contract_address::ContractAddress",
      },
    ],
  },
  {
    type: "event",
    name: "starknet_htlc::htlc::HTLC::Initiated",
    kind: "struct",
    members: [
      {
        name: "orderID",
        type: "[core::integer::u32; 8]",
        kind: "key",
      },
      {
        name: "secretHash",
        type: "core::byte_array::ByteArray",
        kind: "data",
      },
      {
        name: "amount",
        type: "core::integer::u256",
        kind: "data",
      },
    ],
  },
  {
    type: "event",
    name: "starknet_htlc::htlc::HTLC::Redeemed",
    kind: "struct",
    members: [
      {
        name: "orderID",
        type: "[core::integer::u32; 8]",
        kind: "key",
      },
      {
        name: "secretHash",
        type: "core::felt252",
        kind: "data",
      },
      {
        name: "secret",
        type: "core::byte_array::ByteArray",
        kind: "data",
      },
    ],
  },
  {
    type: "event",
    name: "starknet_htlc::htlc::HTLC::Refunded",
    kind: "struct",
    members: [
      {
        name: "orderID",
        type: "[core::integer::u32; 8]",
        kind: "key",
      },
    ],
  },
  {
    type: "event",
    name: "starknet_htlc::htlc::HTLC::Event",
    kind: "enum",
    variants: [
      {
        name: "Initiated",
        type: "starknet_htlc::htlc::HTLC::Initiated",
        kind: "nested",
      },
      {
        name: "Redeemed",
        type: "starknet_htlc::htlc::HTLC::Redeemed",
        kind: "nested",
      },
      {
        name: "Refunded",
        type: "starknet_htlc::htlc::HTLC::Refunded",
        kind: "nested",
      },
    ],
  },
] as const;
