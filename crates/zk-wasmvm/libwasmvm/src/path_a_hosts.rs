//! Path A Stwo/Flock hosts: [`zk_cosmwasm_hosts`], not this crate.

#[cfg(test)]
mod tests {
    #[test]
    fn stwo_host_rejects_dstw() {
        zk_cosmwasm_hosts::install();
        let mut p = vec![0u8; 18];
        p[0..4].copy_from_slice(b"DSTW");
        p[4] = 2;
        p[5] = 5;
        assert!(zk_cosmwasm_hosts::stwo::host_verify(&p, &[]).is_err());
    }

    #[test]
    fn flock_host_rejects_digest_stub() {
        zk_cosmwasm_hosts::install();
        let action = [7u8; 128];
        let stub = zk_cosmwasm::prove_flock(&action);
        assert!(zk_cosmwasm_hosts::flock::host_verify(&stub, &action).is_err());
    }

    #[test]
    fn stwo_ssle_roundtrip() {
        zk_cosmwasm_hosts::install();
        let proposer = [0x42u8; 32];
        let (_ticket, proof) = lean_stwo_dummy::prove_ssle(1, 7, &proposer).expect("prove");
        zk_cosmwasm_hosts::stwo::host_verify(&proof, &[])
            .expect("verify via zk-cosmwasm-hosts");
    }
}
