# DESIGN — ZEC egress Option D (private bridge)

## 0. Charter

| Field | Value |
|-------|--------|
| **Goal** | Normative interfaces for Terp ZEC-SEAM burn → Zcash dest pay/mint under preauth seal |
| **Decision** | Option D **ACCEPTED** |
| **Lab** | Burn on Terp + inventory/Zakura pay gated by evidence |
| **Prod residual** | Real LC membership + non-mock proof |

## 1. Types (normative)

```rust
/// Domain for egress-spend nullifiers (≠ pool-nf-v0, ≠ deposit-nu-v0, ≠ bridge ingress).
pub const EGRESS_NF_LABEL: &[u8] = b"egress-nf-v0";

/// Public statement for Option D burn on Terp.
pub struct EgressBurnPublic {
    pub asset_id: [u8; 32],          // ZEC registry id
    pub value: u64,
    pub cm_spent: [u8; 32],          // SEAM cm being burned
    pub nullifier: [u8; 32],         // egress domain ν
    pub dest_commitment: [u8; 32],   // MUST equal G4 seal bytes
    pub dest_kind: DestKind,         // Transparent | Shielded
    pub root: [u8; 32],              // membership root (lab stub OK)
    pub source_pool_id: Option<u64>, // if from swap settle
}

pub enum DestKind {
    Transparent,
    Shielded,
}

pub struct EgressBurnWitness {
    pub rcm: [u8; 32],
    pub owner_binding: [u8; 32],     // must equal dest_commitment for corridor
    pub path_position: u64,
}

/// After Terp burn is accepted — authorization for Zcash leg.
pub struct EgressBurnEvidenceV0 {
    pub terp_tx_hash: Option<String>,
    pub burn: EgressBurnPublic,
    pub proof_mode: String,          // "mock_verify_lab" | "zk_api"
    pub settle_receipt_ref: Option<String>,
}

/// Zcash leg result (lab or prod).
pub struct ZecEgressReceiptV0 {
    pub dest_display: String,
    pub dest_owner_binding_hex: String,
    pub dest_kind: DestKind,
    pub zec_txid: Option<String>,
    pub amount_zat: u64,
    pub mode: String,                // "lab_inventory_pay" | "lc_mint" | ...
    pub burn_nullifier_hex: String,  // continuity
}
```

### Nullifier

```text
egress_ν = SHA256(b"egress-nf-v0" ‖ cm_spent ‖ rcm)
```

Must **not** equal swap pool ν or deposit/bridge ingress ν.

### Fail-closed

| Condition | Reject |
|-----------|--------|
| `dest_commitment` ≠ sealed G4 binding | yes |
| `owner_binding` ≠ `dest_commitment` on corridor product | yes |
| value 0 / bad cm / empty proof (non-mock) | yes |
| double egress ν | yes |
| Zcash pay without burn evidence | yes (product) |

## 2. Surfaces

| Layer | Action |
|-------|--------|
| Pure | `validate_egress_burn`, `apply_egress_burn` (ν set + leaf stub) |
| CW | `ExecuteMsg::BridgeEgressBurn { statement, proof }` (prefer **cw-headstash** as bridge router per CLARITY, or private-dex post-settle call) |
| Host | `lab_pay_zec_after_burn(evidence, sealed_dest) → ZecEgressReceiptV0` |
| Harness | after SettleSwap: build burn from settle cm_out → execute burn → lab pay → write receipts |

## 3. Dest kind

Both **Transparent** and **Shielded** allowed.  
`dest_kind` is metadata for Zcash wallet API selection; **binding bytes** remain 32B seal.

## 4. Implementation order

1. Pure types + tests (PURE-EGRESS)  
2. CW burn + multitest (CW-EGRESS)  
3. Zakura/lab pay gated on evidence (ZAKURA-PAY)  
4. Harness join (HARNESS-D)  

## 5. Non-goals this wave

- Full LC light client on Zcash mainnet  
- TZE production  
- Skip/IBC product path  
- Halo2 egress circuit (mock dual-path OK)
