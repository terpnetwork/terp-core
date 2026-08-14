package keeper

import (
	"encoding/json"
	"fmt"

	"github.com/terpnetwork/terp-core/v6/x/hashmerchant/types"
)

const oracleBundleMagic = "HMOR"

// packOracleBundle encodes attestations into the Ics23Proof field using HMOR prefix.
func packOracleBundle(attestations []types.OracleAttestation) ([]byte, error) {
	if len(attestations) == 0 {
		return nil, nil
	}
	bz, err := json.Marshal(struct {
		Attestations []types.OracleAttestation `json:"attestations"`
	}{Attestations: attestations})
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(oracleBundleMagic)+len(bz))
	out = append(out, []byte(oracleBundleMagic)...)
	out = append(out, bz...)
	return out, nil
}

// unpackOracleBundle reads attestations from Ics23Proof if HMOR-prefixed.
func unpackOracleBundle(bz []byte) ([]types.OracleAttestation, error) {
	if len(bz) < len(oracleBundleMagic) {
		return nil, nil
	}
	if string(bz[:len(oracleBundleMagic)]) != oracleBundleMagic {
		return nil, nil
	}
	var bundle struct {
		Attestations []types.OracleAttestation `json:"attestations"`
	}
	if err := json.Unmarshal(bz[len(oracleBundleMagic):], &bundle); err != nil {
		return nil, fmt.Errorf("decode oracle bundle: %w", err)
	}
	return bundle.Attestations, nil
}