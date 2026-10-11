# v6.3 CosmWasm reply events

Contract authors and anyone grepping `fn reply`. The code is
`x/wasm/keeper/msg_dispatcher.go`.

## Just enough

A patch should close the bug and leave the rest of the interface alone.
Less is not the goal. More is not the goal. **Just enough** is the line
upstream already drew.

The recognized CosmWasm 0-days are meter, VM, and call-depth bugs
([CWA list](https://github.com/CosmWasm/advisories/blob/main/CWAs/README.md)).
wasmd fixed them by making gas a function of inputs every node can compute:
tx-local instance discount ([#1798](https://github.com/CosmWasm/wasmd/issues/1798) /
[#1987](https://github.com/CosmWasm/wasmd/pull/1987)), consume submessage gas
on panic (CWA-2025-004), IBC setup cost (CWA-2025-005), reply call depth
(CWA-2025-007). None of those delete `instantiate` or `execute` from a
wasm-to-wasm reply.

v6.1 went past that line. `filterWasmReplyEvents` kept only `wasm` and
`wasm-*` in `reply.result.ok.events` for a wasm SubMsg. That broke the
documented factory callback (`e.ty == "instantiate"`, then
`_contract_address`), including in-tree `ibc-reflect`. The events it
dropped are a fixed tuple (address, code id, type). They are not
replica-divergent. Shrinking them did not close the cache 0-day.

v6.3 puts the reply payload back on the upstream fork. It does not undo
the patches that were already the right size.

## What a wasm SubMsg reply contains

When contract A sends a SubMsg whose message is wasm (instantiate or
execute) and asks for a reply, `reply.result.ok` includes:

- wasmd plumbing: `instantiate`, `execute`, `sudo`, `reply`
- contract events: `wasm` and `wasm-…`
- other events that submessage emitted, including bank `transfer` when the child moved coins
- `data` and `msg_responses`

The instantiate address is on the `instantiate` event (`_contract_address`)
and in `MsgInstantiateContractResponse`.

```rust
events.into_iter().find(|e| e.ty == "instantiate")
    .and_then(|ev| ev.attributes.into_iter().find(|a| a.key == "_contract_address"))
```

That works again for a wasm SubMsg. `crates/cosmwasm/contracts/ibc-reflect`
uses it.

SDK `message` events are still dropped. That is event flattening, not the
v6.1 allowlist.

Attribute keys are sorted. The sort runs on the same attribute slice the
transaction `EventManager` holds, which is what upstream wasmd does. Indexers
see those wasm-submessage attributes in sorted key order, on the tx and in
the reply.

`Reply.GasUsed` stays 0. Filling it from the submessage meter would put
cache-dependent gas into the reply JSON.

## What stays empty

A native SubMsg (`Wasm == nil`: bank send, staking, stargate) still returns
an empty event list in `reply`. That is wasmd
[#917](https://github.com/CosmWasm/wasmd/pull/917) (v0.28). Those actions
still run and still appear on the transaction. The ibc-reflect pattern stays
empty for a native bank SubMsg. Read `msg_responses` or `data` there.

Error strings in `reply.result.err` stay redacted to codespace and code
(wasmd #759).

## What we do not change in this correction

- Do not bring back an allowlist that drops `instantiate`, `execute`, `sudo`, or `reply` from a wasm reply.
- Do not empty wasm-to-wasm events to change `ReplyCosts`. Child `wasm-*` events still scale that meter. That is the contract-authored valve. Cap the meter if the size is the problem. Keep the events.
- Do not undo #917. Native reply events stay empty.
- Do not fill `Reply.GasUsed`.
- Do not remove the tx-local instance discount, panic gas consume, IBC setup cost, or reply call-depth cap. Those are the 0-day patches.

Wasm replies are larger than they were under the v6.1 allowlist, by the
plumbing events. The extra bytes are the same on every node. `ReplyCosts`
and the VM's JSON charge see them. That is a deterministic gas change, not
a cache split.
