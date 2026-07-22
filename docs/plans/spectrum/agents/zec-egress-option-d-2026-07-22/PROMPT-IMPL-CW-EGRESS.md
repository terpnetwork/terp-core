# PROMPT — IMPL CW-EGRESS

Read: ORCHESTRATION.md, DESIGN-ZEC-EGRESS-D.md, HANDOFF.md,  
`cw-headstash` bridge mint dual-path, `cw-private-dex` settle.

**Implement** Terp-side **BridgeEgressBurn**:

1. Preferred: extend `cw-headstash` with `ExecuteMsg::BridgeEgressBurn { statement, proof }` + spent egress ν map + dest equality + mock_verify dual-path (mirror bridge mint).  
   Alt: `cw-private-dex` post-settle msg if cleaner — document choice in STATUS.
2. Instance encoding for future proof_instance_verify (domain-separated).
3. Multitest: burn success, double-burn reject, dest mismatch reject, empty proof under mock reject.
4. Feature `zk-api` path stub like private-dex (fail-closed without mock).

Write `STATUS-IMPL-CW-EGRESS.md`. Update HANDOFF.
