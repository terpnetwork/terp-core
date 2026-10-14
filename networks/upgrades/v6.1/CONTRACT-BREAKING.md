# v6.1 CosmWasm: contract-visible behavior

For contract authors and anyone grepping our CosmWasm stack (polytone, IBC factories, cw-hooks, HashMerchant sudo, smart-account authenticators).

**Events from submessages still occur.** Bank sends, instantiates, executes, staking messages — they still run, they still write state, and they still show up on the **transaction** (explorers, LCD `tx` events, indexers). We did **not** cancel those actions.

The reply-event resolution for this tree is [`../v6.3/REPLY-EVENTS.md`](../v6.3/REPLY-EVENTS.md). v6.1 had narrowed wasm `reply.events` to `wasm` / `wasm-*`. That allowlist is not the current rule. Sections 2 and 3 below are separate v6.1 behavior (cw-hooks, HashMerchant).

---

## 1. Submessage `reply` events

When contract A sends a **SubMsg** to another **wasm** contract (instantiate or execute) and asks for a reply, `reply.result.ok.events` includes:

- wasmd plumbing: `instantiate`, `execute`, `sudo`, `reply`
- contract events: `wasm` and `wasm-…`
- other events that submessage emitted (including bank `transfer` when the child moved coins)

`data` and `msg_responses` are still there. The instantiate address is on the `instantiate` event (`_contract_address`) and in `MsgInstantiateContractResponse`.

SDK `message` events are still dropped (wasmd event flattening). Attribute keys are sorted on the shared slice, so the transaction events from a wasm SubMsg are sorted too. That matches upstream wasmd.

Native SubMsgs (A → bank send as SubMsg, `Wasm == nil`) still return an **empty** event list in `reply`. That is wasmd #917. Those transfers still happen and still appear on the tx.

```rust
events.into_iter().find(|e| e.ty == "instantiate")
    .and_then(|ev| ev.attributes.into_iter().find(|a| a.key == "_contract_address"))
```

That pattern works again for wasm SubMsgs. It stays empty for a native bank SubMsg. `crates/cosmwasm/contracts/ibc-reflect` uses it.

Code: `x/wasm/keeper/msg_dispatcher.go` (`filterEvents`, then empty the reply list only when `msg.Msg.Wasm == nil`). Detail and the “just enough” line: [`../v6.3/REPLY-EVENTS.md`](../v6.3/REPLY-EVENTS.md).

---

## 2. cw-hooks cannot veto staking or gov

Registered staking/gov hook contracts still **run** (sudo, 250k gas default). If they error or run out of gas, the **user’s** delegate / undelegate / vote / create-validator **still succeeds**. The hook is skipped; its writes for that call are not kept.

Hooks are notify-only. You cannot use “hook returns error” to block a stake.

Search:

```text
cw-hooks register
AfterValidator
AfterDelegation
sudo
```

In-tree: `x/cw-hooks/` (module), `x/cw-hooks/keeper/testdata/juno_staking_hooks_example.wasm`. Spec still reads like fire-and-forget (`x/cw-hooks/spec/00_concepts.md`); the veto path is what we removed.

---

## 3. HashMerchant oracle callbacks can be skipped

If you registered a contract for HashMerchant sudo (confirmed oracle root):

- Heavy sudo (over `contract_gas_limit`, default **100663296**) → that callback is **missed**; the root still commits; the chain does not halt.
- Malformed `{}` sudo result → missed callback, not a halt.

`tests/tsh/hashmerchant/contracts/hashmerchant-test` is a normal `sudo` that stores the root — keep it cheap. Do not assume every block’s sudo ran if the contract is huge.

---

## 4. What did **not** change for users

- Ordinary execute / instantiate / migrate / query.
- Tokens actually moving on bank SubMsgs or wasm execute.
- Tx-level events (Keplr, Mintscan, our indexers reading `TxResponse.events`).
- `wasm` / `wasm-*` events you emit from `Response`.
- Gas for the same call should match across nodes (no “first execute after restart is a different fee” as a feature).

---

## 5. Checklist (copy into a review)

- [ ] Wasm SubMsg `fn reply` can read `instantiate` / `execute` again. Native SubMsgs still have an empty event list.
- [ ] Child contract address: `instantiate` / `_contract_address`, or `data` / `msg_responses`.
- [ ] Amounts from a nested bank send inside a **wasm** SubMsg can be on `transfer` in `reply`. A **native** bank SubMsg still has no reply events; use `msg_responses`.
- [ ] Polytone / IBC spawn paths re-tested (ibc-reflect instantiate callback included).
- [ ] cw-hooks listeners: OK with “stake succeeded even if we errored”?
- [ ] HashMerchant sudo: stays under the gas cap; missing a callback is acceptable.
- [ ] Indexers: still on **tx events**, not on reply payload.

Upgrade context: `networks/upgrades/v6.1/guide.md`. Code: `x/wasm/keeper/msg_dispatcher.go`.
