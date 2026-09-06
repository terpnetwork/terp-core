# v6.1 CosmWasm: what still happens vs what `reply` no longer sees

For contract authors and anyone grepping our CosmWasm stack (polytone, IBC factories, cw-hooks, HashMerchant sudo, smart-account authenticators).

**Events from submessages still occur.** Bank sends, instantiates, executes, staking messages — they still run, they still write state, and they still show up on the **transaction** (explorers, LCD `tx` events, indexers). We did **not** cancel those actions.

What changed: the list copied into the **calling contract’s `reply` entrypoint** (`reply.result.ok.events`) is smaller. Indexers are unchanged.

---

## 1. Submessage `reply` events (the CosmWasm break)

When contract A sends a **SubMsg** to another **wasm** contract (instantiate or execute) and asks for a reply:

| Still in `reply` | No longer in `reply` (but still on the tx) |
|------------------|--------------------------------------------|
| ok / error | Bank `transfer` / coin-spent events |
| `data` (instantiate still puts the new address here) | Staking / gov native events |
| `msg_responses` (protobuf) | Wasmd plumbing: `instantiate`, `execute`, `sudo`, `reply` |
| Events the inner contract emitted as CosmWasm: type **`wasm`** and **`wasm-…`** | Any other event type |

Native SubMsgs (A → bank send as SubMsg) already returned an **empty** event list in `reply`. That is unchanged. Those transfers still happen and still appear on the tx.

### What to search for in our contracts

```text
fn reply(
e.ty == "instantiate"
e.ty == "execute"
e.ty == "transfer"
event.ty == "wasm"
_contract_address
reply.result
SubMsg::reply_always
reply_on_success
```

**Broken pattern** (sample in-tree: `crates/cosmwasm/contracts/ibc-reflect`):

```rust
events.into_iter().find(|e| e.ty == "instantiate")
    .and_then(|ev| ev.attributes.into_iter().find(|a| a.key == "_contract_address"))
```

After v6.1 that `find` is empty. The instantiate **did** run; the address is in **`reply.result.ok.data`** (`MsgInstantiateContractResponse`). Prefer `msg_responses` / `data`. If you need a CosmWasm event, look for type `wasm` (not `instantiate`).

**Usually fine:** contracts that only read `reply.result` ok/err, `data`, or their own `wasm-*` events (polytone-style note/voice, factories that parse protobuf data).

**Tune if true:** any factory, IBC wrapper, or “instantiate then record child address” that parses **event type `instantiate`** from the reply.

### Our inventory to walk

| Surface | Why look |
|---------|----------|
| Polytone (`tests/tsh/polytone`, `tests/interchaintest/contracts/polytone_*.wasm`) | SubMsg instantiate/execute + reply is the product. Confirm they use `data` / CosmWasm events, not `instantiate`/`transfer` in `reply`. |
| IBC reflect / 08-wasm light clients | Same instantiate-callback pattern as `ibc-reflect`. |
| Tokenfactory / clock / any “spawn a child contract” wasm | Child address from reply events. |
| Frontend indexers | **No change** if they subscribe to tx events, not to contract `reply` JSON. |

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

- [ ] Every `fn reply` : does it assume event type `instantiate`, `execute`, or `transfer`?
- [ ] Child contract address: from `data` / `msg_responses`, not from `instantiate` in `reply.events`?
- [ ] Amounts from a nested bank send: from `msg_responses` or a `wasm-*` event the inner contract emitted, not from `transfer` in `reply`?
- [ ] Polytone / IBC spawn paths re-tested after v6.1 (instantiate still records the right address).
- [ ] cw-hooks listeners: OK with “stake succeeded even if we errored”?
- [ ] HashMerchant sudo: stays under the gas cap; missing a callback is acceptable.
- [ ] Indexers: still on **tx events**, not on reply payload.

Upgrade context: `networks/upgrades/v6.1/guide.md`. Code: wasmd `filterWasmReplyEvents` in `crates/zk-wasmd/x/wasm/keeper/msg_dispatcher.go` (emit to EventManager first, then shrink the reply list).
