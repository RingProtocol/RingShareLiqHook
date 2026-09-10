# CLAUDE.md — Ring Protocol

- Ring Protocol is a Uniswap V2 forked protocol, the main feature is wrap erc20 token to fewToken. Protocol supports wrap origin token to fewToken or unswap fewToken to origin token.

- wrap unwrap rate always 1:1.
- Any Wrap token are erc-20 with token() method to get origin token.
- All wrap token are registered at FewFactory.
  - 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD
```json
[{"inputs":[{"internalType":"address","name":"origintoken","type":"address"}],"name":"createToken","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"nonpayable","type":"function"}]
```

  - FewWrapToken abi:
```json
  [
    {"inputs":[],
    "name":"token",
    "outputs":[
        {"internalType":"address","name":"","type":"address"}
    ],
    "stateMutability":"view",
    "type":"function"
    },
  {
    "anonymous": false,
    "inputs": [
      {
        "indexed": true,
        "internalType": "address",
        "name": "sender",
        "type": "address"
      },
      {
        "indexed": false,
        "internalType": "uint256",
        "name": "amount",
        "type": "uint256"
      },
      {
        "indexed": true,
        "internalType": "address",
        "name": "to",
        "type": "address"
      }
    ],
    "name": "Unwrap",
    "type": "event"
  },
  {
    "anonymous": false,
    "inputs": [
      {
        "indexed": true,
        "internalType": "address",
        "name": "sender",
        "type": "address"
      },
      {
        "indexed": false,
        "internalType": "uint256",
        "name": "amount",
        "type": "uint256"
      },
      {
        "indexed": true,
        "internalType": "address",
        "name": "to",
        "type": "address"
      }
    ],
    "name": "Wrap",
    "type": "event"
  },
  {
    "inputs": [
      {
        "internalType": "uint256",
        "name": "amount",
        "type": "uint256"
      }
    ],
    "name": "unwrap",
    "outputs": [
      {
        "internalType": "uint256",
        "name": "",
        "type": "uint256"
      }
    ],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [
      {
        "internalType": "uint256",
        "name": "amount",
        "type": "uint256"
      },
      {
        "internalType": "address",
        "name": "to",
        "type": "address"
      }
    ],
    "name": "unwrapTo",
    "outputs": [
      {
        "internalType": "uint256",
        "name": "",
        "type": "uint256"
      }
    ],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [
      {
        "internalType": "uint256",
        "name": "amount",
        "type": "uint256"
      }
    ],
    "name": "wrap",
    "outputs": [
      {
        "internalType": "uint256",
        "name": "",
        "type": "uint256"
      }
    ],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [
      {
        "internalType": "uint256",
        "name": "amount",
        "type": "uint256"
      },
      {
        "internalType": "address",
        "name": "to",
        "type": "address"
      }
    ],
    "name": "wrapTo",
    "outputs": [
      {
        "internalType": "uint256",
        "name": "",
        "type": "uint256"
      }
    ],
    "stateMutability": "nonpayable",
    "type": "function"
  }
]

```

- Amount of Wrap token maybe greater than origin token amount, if underlying token not enough, unwrap will fail.
- Ring teams provides Liquidity.

## Protocol Design
FewWrapToken and FewFactory contract located at: ../../../Product/few-protocol/few-factory/contracts/FewFactory.sol

## Ring Swap Router
Ring product is total like unisswap product stack. Interface needs quote api which is routing-api,
routing-api needs smart-order-router, smart-order-router needs Universal Router, Universal Router needs Ring Swap Router or Ring Swap Factory.

## Ring Swap Factory
Ring Swap Factory is a contract that creates Ring Swap Pools.



# How to increase volume
1. User swap from interface.
2. Ring protocol integrated to other aggregator like 1inch, okx, enso, bitget, openocean, orbs, nordstern, kyber, etc.
3. Ring team also develop a hook in uniswap v4 to make Uniswap v4 routing support Ring Swap Pools.
4. Deploy V4 Pool.(todo)

# Contracts address
https://docs.ring.exchange/contracts/v2/deployments

# Problem
## 1 How to descrease impermanent loss
Pool with dynamic fee.
## 2 How to descrease slippage


