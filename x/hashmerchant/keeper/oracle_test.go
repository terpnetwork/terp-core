package keeper

import (
	"crypto/ed25519"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

func TestOracleBundlePackUnpack(t *testing.T) {
	attestations := []types.OracleAttestation{
		{
			SourceId:         "skip-connect",
			Value:            []byte(`{"asset":"BTC","price_usd":"95000.00"}`),
			Height:           1,
			Timestamp:        1700000000,
			CustodySignature: []byte{1, 2, 3},
		},
	}

	packed, err := packOracleBundle(attestations)
	require.NoError(t, err)
	require.NotEmpty(t, packed)
	require.Equal(t, oracleBundleMagic, string(packed[:len(oracleBundleMagic)]))

	unpacked, err := unpackOracleBundle(packed)
	require.NoError(t, err)
	require.Len(t, unpacked, 1)
	require.Equal(t, attestations[0].SourceId, unpacked[0].SourceId)
	require.Equal(t, attestations[0].Value, unpacked[0].Value)
}

func TestVoteExtensionAttestationsProtoField(t *testing.T) {
	att := &types.OracleAttestation{SourceId: "skip-connect", Value: []byte("v")}
	data := types.VoteExtensionHashData{
		Attestations: []*types.OracleAttestation{att},
	}
	out := voteExtensionAttestations(data)
	require.Len(t, out, 1)
	require.Equal(t, "skip-connect", out[0].SourceId)
}

func TestCustodyPayloadVerify(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)

	scope := "price/oracle"
	sourceID := "skip-connect"
	value := []byte(`{"asset":"ZEC","price_usd":"45.00"}`)
	height := uint64(42)
	timestamp := int64(1700000001)

	msg := custodyPayload(scope, sourceID, value, height, timestamp)
	sig := ed25519.Sign(priv, msg)
	pub := priv.Public().(ed25519.PublicKey)

	require.True(t, ed25519.Verify(pub, msg, sig))
}