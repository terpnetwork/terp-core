;; empty_sudo.wat — minimal CosmWasm contract for the Reece #2545 class.
;;
;; instantiate(env, info, msg) returns a normal success ContractResult.
;; sudo(env, msg) returns the literal bytes `{}`.
;;
;; In Go (wasmd keeper via the C API's call_*_raw path), `{}` unmarshals to
;; res != nil, res.Err == "", res.Ok == nil. Unpatched keepers deref
;; res.Ok.Messages and panic; a panic in PreBlocker / staking hooks halts the
;; chain. Patched keepers (res.Ok == nil → ErrVMError) turn it into a
;; miss-callback / failed tx.
;;
;; Hand-rolled-convention notes (learned the hard way):
;; - allocate MUST return a pointer to a 12-byte Region {offset, capacity,
;;   length}, not a raw data pointer — the VM reads the struct to locate
;;   arg data (else ZeroOffset on the first call).
;; - memory must declare NO maximum (host sets it).
;; Verified locally: instantiate → Ok(Response{..empty..}), sudo raw → `{}`.
;;
;; Build: wasm-tools parse empty_sudo.wat -o empty_sudo.wasm
;; The committed empty_sudo.wasm is the artifact the e2e loads.
(module
  ;; NOTE: no maximum on memory — the host sets it (static validation rejects
  ;; a declared max).
  (memory (export "memory") 17)

  (global $bump (mut i32) (i32.const 131072))

  ;; instantiate success response (61 bytes):
  ;; {"ok":{"messages":[],"data":null,"attributes":[],"events":[]}}
  (data (i32.const 65536) "{\"ok\":{\"messages\":[],\"data\":null,\"attributes\":[],\"events\":[]}}")
  ;; sudo empty-object response (2 bytes): {}
  (data (i32.const 66000) "{}")

  ;; Standard CosmWasm allocate: returns a pointer to a 12-byte Region
  ;; {offset, capacity, length} followed by `size` bytes of data space.
  ;; The VM reads this struct (write_memory) to locate the data area.
  (func (export "allocate") (param $size i32) (result i32)
    (local $region i32)
    (local $data i32)
    (global.get $bump)
    (local.set $region)
    (local.set $data (i32.add (local.get $region) (i32.const 12)))
    (global.set $bump (i32.add (local.get $data) (local.get $size)))
    (i32.store (local.get $region) (local.get $data))
    (i32.store (i32.add (local.get $region) (i32.const 4)) (local.get $size))
    (i32.store (i32.add (local.get $region) (i32.const 8)) (local.get $size))
    (local.get $region))

  (func (export "deallocate") (param $ptr i32))

  (func (export "interface_version_8") (result i32)
    (i32.const 0))

  ;; instantiate(env, info, msg) -> Region{offset:1024, capacity:62, length:62}
  (func (export "instantiate") (param i32 i32 i32) (result i32)
    (i32.store (i32.const 67000) (i32.const 65536))
    (i32.store (i32.const 67004) (i32.const 62))
    (i32.store (i32.const 67008) (i32.const 62))
    (i32.const 67000))

  ;; sudo(env, msg) -> Region{offset:2048, capacity:2, length:2}  (the {} case)
  (func (export "sudo") (param i32 i32) (result i32)
    (i32.store (i32.const 67012) (i32.const 66000))
    (i32.store (i32.const 67016) (i32.const 2))
    (i32.store (i32.const 67020) (i32.const 2))
    (i32.const 67012))
)
