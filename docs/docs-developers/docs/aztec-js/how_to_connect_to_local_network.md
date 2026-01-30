---
title: Connect to Local Network
tags: [local_network, connection, wallet]
sidebar_position: 1
description: Connect your application to the Aztec local network and interact with accounts.
---

This guide shows you how to connect your application to the Aztec local network and interact with the network.

## Prerequisites

- Running Aztec local network (see [Quickstart](../../getting_started_on_local_network.md)) on port 8080
- Node.js installed
- TypeScript project set up

## Install dependencies

```bash
yarn add @aztec/aztec.js@#include_version_without_prefix @aztec/test-wallet@#include_version_without_prefix
```

## Connect to the network

Create a node client and TestWallet to interact with the local network:

#include_code connect_to_network /docs/examples/ts/aztecjs_connection/index.ts typescript

`TestWallet` is a development wallet that handles account management and transaction signing locally, suitable for testing and development.

### Verify the connection

Get node information to confirm your connection:

#include_code verify_connection /docs/examples/ts/aztecjs_connection/index.ts typescript

### Load pre-funded accounts

The local network has accounts pre-funded with fee juice to pay for gas. Register them in your wallet:

#include_code load_accounts /docs/examples/ts/aztecjs_connection/index.ts typescript

These accounts are pre-funded with fee juice (the native gas token) at genesis, so you can immediately send transactions without needing to bridge funds from L1.

### Check fee juice balance

Verify that an account has fee juice for transactions:

#include_code check_fee_juice /docs/examples/ts/aztecjs_connection/index.ts typescript

## Next steps

- [Create an account](./how_to_create_account.md) - Deploy new accounts on the network
- [Deploy a contract](./how_to_deploy_contract.md) - Deploy your smart contracts
- [Send transactions](./how_to_send_transaction.md) - Execute contract functions
