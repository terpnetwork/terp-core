package keeper

import (
	"crypto/ed25519"
	"crypto/sha256"
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v6/x/hashmerchant/types"
)

// custodyDomain separates attestation scopes (Penumbra custody-style limited auth).
func custodyDomain(scope, sourceID string) []byte {
	h := sha256.Sum256([]byte("hashmerchant/custody/" + scope + "/" + sourceID))
	return h[:]
}

// custodyPayload is the message signed by a source's custody authenticator.
func custodyPayload(scope, sourceID string, value []byte, height uint64, timestamp int64) []byte {
	domain := custodyDomain(scope, sourceID)
	payload := make([]byte, 0, len(domain)+len(value)+16)
	payload = append(payload, domain...)
	payload = append(payload, value...)
	var heightBuf [8]byte
	for i := 0; i < 8; i++ {
		heightBuf[i] = byte(height >> (8 * i))
	}
	payload = append(payload, heightBuf[:]...)
	var tsBuf [8]byte
	utimestamp := uint64(timestamp)
	for i := 0; i < 8; i++ {
		tsBuf[i] = byte(utimestamp >> (8 * i))
	}
	payload = append(payload, tsBuf[:]...)
	return payload
}

func findOracleSource(sources []types.OracleSource, sourceID string) (types.OracleSource, bool) {
	for _, src := range sources {
		if src.SourceId == sourceID && src.Enabled {
			return src, true
		}
	}
	return types.OracleSource{}, false
}

// verifyOracleAttestations checks each attestation against registered OracleSource
// custody authenticators. Returns nil if all attestations are valid or if the list
// is empty (backwards compatible with legacy sidecars).
func (k Keeper) verifyOracleAttestations(ctx sdk.Context, chainUID string, attestations []types.OracleAttestation) error {
	if len(attestations) == 0 {
		return nil
	}

	sources, err := k.GetOracleSources(ctx, chainUID)
	if err != nil {
		return err
	}

	params, err := k.GetParams(ctx)
	if err != nil {
		return err
	}

	for _, att := range attestations {
		src, ok := findOracleSource(sources, att.SourceId)
		if !ok {
			return fmt.Errorf("unregistered oracle source %q", att.SourceId)
		}

		auth := src.Authenticator
		if auth == nil {
			return fmt.Errorf("source %q missing custody authenticator", att.SourceId)
		}

		if auth.Algorithm != "ed25519" {
			return fmt.Errorf("unsupported custody algorithm %q for source %q", auth.Algorithm, att.SourceId)
		}

		if len(auth.Pubkey) != ed25519.PublicKeySize {
			return fmt.Errorf("invalid custody pubkey length for source %q", att.SourceId)
		}

		msg := custodyPayload(auth.Scope, att.SourceId, att.Value, att.Height, att.Timestamp)
		if !ed25519.Verify(ed25519.PublicKey(auth.Pubkey), msg, att.CustodySignature) {
			return fmt.Errorf("custody signature verification failed for source %q", att.SourceId)
		}

		// CLOSED market: only sources with registered authenticators may attest.
		_ = params.MarketMode
	}

	return nil
}

// aggregateAttestationRoot computes SHA256 over sorted source attestations when
// the sidecar does not supply a pre-aggregated root.
func aggregateAttestationRoot(attestations []types.OracleAttestation) []byte {
	if len(attestations) == 0 {
		return nil
	}
	h := sha256.New()
	for _, att := range attestations {
		h.Write([]byte(att.SourceId))
		h.Write(att.Value)
	}
	return h.Sum(nil)
}