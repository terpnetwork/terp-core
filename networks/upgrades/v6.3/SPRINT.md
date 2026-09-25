# Sprint: v6.3.0 → v7.0.0 (BLAKE3 non-IBC IAVL)

> Dual-halt Cosmovisor pack, same *ops* as v6.1/v6.2, opposite *hasher* outcome.
> Contract: [`HASHER.md`](./HASHER.md). Curator: [`WORKFLOW.md`](./WORKFLOW.md).
> v7: [`../v7.0/WORKFLOW.md`](../v7.0/WORKFLOW.md). Operators: [`../PROVIDERS-v6.3-v7.md`](../PROVIDERS-v6.3-v7.md).

**Start after** morocco-1 v6.1/v6.2 has applied (live height ≥ v6.2). Do not
touch tagged `v6.1.0` / `v6.2.0`.

**Done means:** [`BENCH.md`](./BENCH.md) JSON picked **H** (hybrid) or **F**
(full BLAKE3 + 08-wasm) on RecvPacket gas + round-trip; HASHER.md Bench lock
filled; stranger Firecracker/Wasmer recurate of `v6.3.0`/`v7.0.0`; TSH
post-v6.2 dual-halt; hasher_proof matches the winner; HashMerchant Osmosis
TWAP-BTC confirmed root. Expired TM clients are restored via **gov + 08-wasm**
(F: `Blake3IavlSpec`; H: stock `IavlSpec` or 07-tendermint).

---

## Files this sprint owns

| Path | Role |
|------|------|
| `crates/cosmos/iavl` | IAVL v1 + `HasherOptionForStore` — **committed** |
| `crates/cosmos/store-v2` | store/v2 + `app/iavl/store-v2-hasher.patch` — **committed** |
| `go.mod` | `replace` both onto those paths |
| `app/iavl/store.go` | dual-store `AlgorithmName` (v6.3 vs v7) |
| `app/upgrades/v6_3/` | plan `v6.3`, copy handler, arm `v7` |
| `app/upgrades/v7/` | plan `v7`, drop SHA-256 migratable names |
| `app/keepers/keys.go` | v6.3: append `DestStores()`; v7: dest keys only, no Rename |
| `app/app.go` | register both upgrades (correct binary) |
| `scripts/release/curate_v63.sh` | fail if replaces or `HasherOptionForStore` missing |
| `scripts/release/fresh-vm/releases/v6.3.0.sh` | recurate extras; fail without replaces |
| `scripts/release/fresh-vm/releases/v7.0.0.sh` | same |
| `tests/tsh/upgrade/v63.sh` | snapshot → Cosmovisor v6.3 then v7 |
| `tests/tsh/upgrade/hasher_proof.sh` | raw nodes + bank/ibc proofs per winning variant |
| `crates/ict-rs/examples/hasher_ibc_bench.rs` | H vs F packet e2e (Docker); writes `tests/benchmarks/hasher-ibc/` |
| `x/hashmerchant` + sidecar | Osmosis TWAP BTC oracle source |

---

### Task 1: Put hasher on the tag (the v6.1 miss)

**Files:** `crates/cosmos/iavl`, `crates/cosmos/store-v2`, `go.mod`,
`scripts/release/curate_v63.sh`, `.gitignore` (must **not** ignore
`crates/cosmos/iavl` or `store-v2` if we commit them — today `crates/*` is
ignored except zk-*).

- [ ] **Allowlist in `.gitignore`:** `!crates/cosmos/iavl` and
      `!crates/cosmos/store-v2` (or stop ignoring those paths). If they stay
      gitignored, Docker recurate will miss them again.
- [ ] **Vendor** stock `github.com/cosmos/iavl v1.2.8` that contains
      `HasherOptionForStore` (permissionlessweb/iavl v1 BLAKE3 option), and
      `github.com/cosmos/cosmos-sdk/store/v2 v2.0.0` + apply
      `app/iavl/store-v2-hasher.patch`.
- [ ] **`go.mod` on the branch:**

```
replace github.com/cosmos/iavl => ./crates/cosmos/iavl
replace github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2
```

- [ ] **`curate_v63.sh` fail-closed:**

```sh
grep -q 'github.com/cosmos/iavl => ./crates/cosmos/iavl' go.mod || exit 1
grep -q 'github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2' go.mod || exit 1
grep -q HasherOptionForStore crates/cosmos/store-v2/iavl/store.go || exit 1
grep -q HasherOptionForStore crates/cosmos/iavl/*.go crates/cosmos/iavl/**/*.go || exit 1
```

- [ ] **Unit:** `go test ./app/iavl/ ./app/iavlv2/ -count=1` — SHA-256 root
      ≠ BLAKE3 root for the same KV.

**Verify:** `git ls-files crates/cosmos/iavl crates/cosmos/store-v2 | head` is
non-empty. `git show HEAD:go.mod` contains both replaces.

---

### Task 2: Dual-store AlgorithmName (v6.3 ELF)

**Files:** `app/iavl/store.go`, `app/iavl/store_test.go`

v6.3 loader: `HasherOptionForStore(key.Name())` must **not** select BLAKE3 for
live `bank` (SHA-256 history). Dest names only.

```go
func AlgorithmName(storeName string) string {
	if _, ok := SHA256Stores[storeName]; ok {
		return "sha256"
	}
	if len(storeName) > 3 && storeName[:3] == "b3-" {
		return "blake3"
	}
	return "sha256" // live migratable history until v7
}
```

- [ ] Tests: `bank`→`sha256`, `b3-bank`→`blake3`, `ibc`→`sha256`,
      `08-wasm`→`sha256`.
- [ ] `SHA256Stores` stays in lockstep with IAVL’s IBC list.

**Verify:** `go test ./app/iavl/ -count=1`.

---

### Task 2b: ict-rs / cw-orch hasher IBC bench (decision gate)

**Files:** [`BENCH.md`](./BENCH.md), `crates/ict-rs/examples/hasher_ibc_bench.rs`,
`crates/ict-rs/ict-rs/src/cosmos/ibc_wasm.rs` (already has
`gov_store_ibc_wasm_lc`), `tests/benchmarks/hasher-ibc/`, two images
`local-zk-hybrid` / `local-zk-blake3`.

Expired 07-tendermint clients are **not** a reason to skip this. Both variants
need new clients; F’s clients are 08-wasm with `Blake3IavlSpec`
(`crates/ics23` `HashOp_BLAKE3`).

- [ ] Build both Docker images from the hasher-on-tag branch (Task 1).
- [ ] **H:** two Terp (or Terp+Gaia) + Hermes; RecvPacket via SHA-256 IAVL
      proofs (07-tendermint or 08-wasm stock spec). Reuse
      `examples/ibc_transfer_e2e.rs`.
- [ ] **F:** same topology; `gov_store_ibc_wasm_lc` of BLAKE3 LC wasm;
      `MsgCreateClient` 08-wasm; RecvPacket via BLAKE3 membership proofs.
      `ICT_MOCK=1` is **not** a pass (`examples/ibc_wasm_lc.rs` says so).
- [ ] N≥20 transfers each way; write JSON (medians: `t_round_trip_ms`,
      `gas_recv_packet`, `gas_update_client`, `proof_bytes_recv`).
- [ ] Fill HASHER.md **Bench lock**. Winner = strictly better (or ≤10% gas
      and not worse round-trip) per BENCH.md. **Stop** v6.3 policy freeze
      until that row is filled.

**Verify:** two JSON files; `jq .median_gas_recv` both set; HASHER.md winner
not `TBD`.

---

### Task 3: Plan v6.3 (copy + arm v7)

**Files:** Create `app/upgrades/v6_3/{constants,upgrades,copy}.go` from
`app/upgrades/v6_1/` (do not edit v6_1). Modify `app/app.go` on
`feat/6.3.0-dev` only. Modify `app/keepers/keys.go`: `append(DestStores())`.

- [ ] `UpgradeName = "v6.3"`.
- [ ] `StoreUpgrades.Added = iavl.DestStores()`.
- [ ] Handler: same KV copy as v6_1; refuse `SHA256Stores`; after copy, arm
      `v7` at `ctx.BlockHeight()+2` with `plan.info` =
      `https://s3.terp.network/upgrades/v7/cosmovisor.json`.
- [ ] Register in `app.go` like v6_1.

**Verify:** `go test ./app/upgrades/v6_3/ -count=1`. Binary `terpd version`
must be `6.3.0` on the tag, not `-dev`.

---

### Task 4: Plan v7 (keepers on dest, drop SHA-256 copies)

**Files:** `app/upgrades/v7/`, `app/keepers/keys.go` on `feat/7.0.0-dev`,
`app/iavl/store.go` (v7 AlgorithmName: migratable live names → blake3).

- [ ] Do **not** `Renamed` onto `bank` (IAVL initialVersion vs history).
- [ ] `GenerateKeys` does **not** mount the old SHA-256 migratable names.
      Mount dest names; map `banktypes.StoreKey` → dest key in keeper wiring.
- [ ] `StoreUpgrades.Deleted` = previous live migratable names.
- [ ] Handler: dest keys must exist; IBC keys unchanged; no further plan.

**Verify:** unit test that `GetKey("ibc")` still SHA-256 store; bank keeper
uses dest key; `GetKey("bank")` is nil or aliased as documented.

---

### Task 5: Proof harness (hasher actually used)

**Files:** `tests/tsh/upgrade/hasher_proof.sh`, optional
`cmd/terpd` debug query.

After v6.3 (before v7) and again after v7:

```sh
# 1) roots: dest bank root != live bank root (v6.3 only)
# 2) raw node: first inner hash of dest bank is NOT sha256(left||right)
# 3) bank membership proof verifies with BLAKE3, fails SHA-256
# 4) ibc or 08-wasm membership proof verifies with SHA-256, fails BLAKE3
```

- [ ] Script exits 0 only if all four hold.
- [ ] Hook from `make tsh-upgrade-v63` after dual halt.

**08-wasm demo:** existing 08-wasm client on the snapshot (or ICT fixture):
inclusion proof of a client/consensus state against store `08-wasm` using
ICS-23 SHA-256. Same node: bank balance proof using BLAKE3. One binary, two
algos.

**Verify:** TSH log matches Bench lock: hybrid
`OK hasher bank=blake3 ibc=sha256`; full
`OK hasher bank=blake3 ibc=blake3` and 08-wasm RecvPacket still succeeds.

---

### Task 6: HashMerchant Osmosis TWAP BTC

**Files:** `x/hashmerchant/spec/12_osmosis_twap_btc.md` (short), keeper
oracle source registration, sidecar config under `tools/hashmerchant-support/`
(or existing sidecar).

- [ ] `chain_uid` e.g. `osmosis-1`. Source `twap/btc` (Osmosis pool TWAP
      query — sidecar reads Osmosis RPC; consensus only sees custody-signed
      bytes + voting power).
- [ ] Optional: 08-wasm light client of Osmosis **root** as a second source
      (`lc/app-hash`). TWAP attestation must not be confused with that root
      (spec 10 Path B vs modular oracle).
- [ ] After ⅔ attestations: `query hashmerchant confirmed-root` (or equivalent)
      shows the TWAP commitment. A consumer query returns BTC price bytes.

This does **not** prove IAVL BLAKE3. It proves the oracle ingress the sprint
asked for, on a node that already passed Task 5.

**Verify:** ict-rs or local net: one confirmed TWAP update; fail if sidecar
is down (no silent zero).

---

### Task 7: Same release workflow as v6.1/v6.2

**Files:** `networks/upgrades/v6.3/{ARTIFACT_LOCK,cosmovisor.json,binaries.json,draft_proposal.json,guide.md}`
(fill hashes **after** recurate). Same under `networks/upgrades/v7/`.
`scripts/release/fresh-vm/releases/v6.3.0.sh`, `v7.0.0.sh`.

- [ ] `v6.3.0.sh` / `v7.0.0.sh`: fetch ibc-hooks tarball; rebuild muslc;
      **fail** if tag `go.mod` lacks iavl/store-v2 replaces.
- [ ] `FIRECRACKER_SSH` + `WASMER_SSH` `GUESTS=firecracker,wasmer TAG=v6.3.0`
      then `TAG=v7.0.0`. Overlapping ELF hashes match S3 **and** each other.
- [ ] Cosmovisor JSON never `file://`. Plan dirs `upgrades/v6.3` and
      `upgrades/v7`.
- [ ] Heights measured from RPC after v6.2; not invented.

**Verify:** `curate_v63.sh` exit 0; fresh-vm OK; `sha256sum -c sha256sum.txt`.

---

### Task 8: Docs / comms

**Files:** `websites/terp-docs/src/pages/guides/validators/release-verification.mdx`
(add v6.3/v7 hasher confirmation). Validator `guide.md` when packs exist.

- [ ] State in one sentence: non-IBC IAVL is BLAKE3 after **v7**; IBC stays
      SHA-256; v6.1/v6.2 did not do this.
- [ ] Link hasher_proof.sh as how we know.

---

## Locked non-goals

- Do not flip `DefaultOptions` to BLAKE3.
- Do not retag v6.1.0 / v6.2.0.
- Do not `Renamed` dest onto `bank`.
- Do not treat HashMerchant TWAP as hasher proof.
- Do not broadcast, upload S3, or set halt height until Tasks 1–5 pass on 120u-1.

## Order

`1 → 2 → 2b (bench JSON + HASHER lock) → 3 → 5 (v6.3 only) → 4 → 5 (dual-halt) → 6 → 7 → 8`

Do not implement v6.3 copy-of-IBC vs leave-IBC until 2b names a winner.
