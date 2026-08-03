package keeper

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"testing"

	storetypes "cosmossdk.io/store/types"
	"github.com/cosmos/cosmos-sdk/testutil"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/stretchr/testify/require"
	abci "github.com/cometbft/cometbft/abci/types"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func setupOracleKeeper(t *testing.T) (Keeper, sdk.Context) {
	t.Helper()
	storeKey := storetypes.NewKVStoreKey(types.StoreKey)
	tKey := storetypes.NewTransientStoreKey("transient_test")
	ctx := testutil.DefaultContext(storeKey, tKey)
	k := NewKeeper(
		types.ModuleCdc,
		storeKey,
		"authority",
		nil, nil, nil, nil,
		DefaultConfig(),
	)
	return k, ctx
}

func genCustodyKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	return pub, priv
}

func makeSource(sourceID string, pub ed25519.PublicKey, scope string, enabled bool) types.OracleSource {
	return types.OracleSource{
		SourceId: sourceID,
		Kind:     types.OracleSourceKind_ORACLE_SOURCE_KIND_HTTP,
		Endpoint: "https://example.test/" + sourceID,
		Authenticator: &types.CustodyAuthenticator{
			Pubkey:    pub,
			Algorithm: "ed25519",
			Scope:     scope,
		},
		Enabled: enabled,
	}
}

func signAttestation(priv ed25519.PrivateKey, scope, sourceID string, value []byte, height uint64, ts int64) types.OracleAttestation {
	msg := custodyPayload(scope, sourceID, value, height, ts)
	return types.OracleAttestation{
		SourceId:         sourceID,
		Value:            value,
		Height:           height,
		Timestamp:        ts,
		CustodySignature: ed25519.Sign(priv, msg),
	}
}

// ---------------------------------------------------------------------------
// Bundle pack/unpack
// ---------------------------------------------------------------------------

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

func TestOracleBundleEmptyAndNonMagic(t *testing.T) {
	// empty list → nil pack
	packed, err := packOracleBundle(nil)
	require.NoError(t, err)
	require.Nil(t, packed)

	// short / non-magic bytes → nil, no error (not a bundle)
	atts, err := unpackOracleBundle([]byte("x"))
	require.NoError(t, err)
	require.Nil(t, atts)

	atts, err = unpackOracleBundle([]byte("XXXX{}"))
	require.NoError(t, err)
	require.Nil(t, atts)

	// magic + corrupt JSON → error
	_, err = unpackOracleBundle(append([]byte(oracleBundleMagic), []byte("{not-json")...))
	require.Error(t, err)
}

func TestOracleBundleMultiSourceRoundTrip(t *testing.T) {
	atts := []types.OracleAttestation{
		{SourceId: "btc-usd", Value: []byte(`{"p":"1"}`), Height: 10, Timestamp: 100},
		{SourceId: "eth-usd", Value: []byte(`{"p":"2"}`), Height: 11, Timestamp: 101},
		{SourceId: "zec-usd", Value: []byte(`{"p":"3"}`), Height: 12, Timestamp: 102},
	}
	packed, err := packOracleBundle(atts)
	require.NoError(t, err)
	out, err := unpackOracleBundle(packed)
	require.NoError(t, err)
	require.Len(t, out, 3)
	require.Equal(t, "zec-usd", out[2].SourceId)
	require.Equal(t, uint64(12), out[2].Height)
}

// ---------------------------------------------------------------------------
// Vote extension attestation extraction
// ---------------------------------------------------------------------------

func TestVoteExtensionAttestationsProtoField(t *testing.T) {
	att := &types.OracleAttestation{SourceId: "skip-connect", Value: []byte("v")}
	data := types.VoteExtensionHashData{
		Attestations: []*types.OracleAttestation{att},
	}
	out := voteExtensionAttestations(data)
	require.Len(t, out, 1)
	require.Equal(t, "skip-connect", out[0].SourceId)
}

func TestVoteExtensionAttestationsLegacyHMOR(t *testing.T) {
	legacy := []types.OracleAttestation{
		{SourceId: "legacy-src", Value: []byte("old"), Height: 7, Timestamp: 99},
	}
	packed, err := packOracleBundle(legacy)
	require.NoError(t, err)

	// proto field empty → fall back to Ics23Proof HMOR
	data := types.VoteExtensionHashData{Ics23Proof: packed}
	out := voteExtensionAttestations(data)
	require.Len(t, out, 1)
	require.Equal(t, "legacy-src", out[0].SourceId)

	// proto field wins over legacy
	protoAtt := &types.OracleAttestation{SourceId: "proto-src", Value: []byte("new")}
	data.Attestations = []*types.OracleAttestation{protoAtt}
	out = voteExtensionAttestations(data)
	require.Len(t, out, 1)
	require.Equal(t, "proto-src", out[0].SourceId)
}

func TestVoteExtensionAttestationsNilEntriesSkipped(t *testing.T) {
	data := types.VoteExtensionHashData{
		Attestations: []*types.OracleAttestation{
			nil,
			{SourceId: "ok", Value: []byte("1")},
			nil,
		},
	}
	out := voteExtensionAttestations(data)
	require.Len(t, out, 1)
	require.Equal(t, "ok", out[0].SourceId)
}

// ---------------------------------------------------------------------------
// Custody payload
// ---------------------------------------------------------------------------

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

func TestCustodyPayloadDomainSeparation(t *testing.T) {
	value := []byte("price")
	// Different scopes → different payloads (prevents cross-scope replay)
	a := custodyPayload("price/oracle", "src-a", value, 1, 100)
	b := custodyPayload("merkle_root", "src-a", value, 1, 100)
	require.NotEqual(t, a, b)

	// Different source IDs → different payloads
	c := custodyPayload("price/oracle", "src-b", value, 1, 100)
	require.NotEqual(t, a, c)

	// Height/timestamp bound (stale replay resistance at custody layer)
	d := custodyPayload("price/oracle", "src-a", value, 2, 100)
	e := custodyPayload("price/oracle", "src-a", value, 1, 101)
	require.NotEqual(t, a, d)
	require.NotEqual(t, a, e)
	require.NotEqual(t, d, e)
}

func TestCustodyPayloadBoundaryValues(t *testing.T) {
	// zero height/timestamp and max-ish values still produce stable digests
	zero := custodyPayload("price/oracle", "src", []byte{0}, 0, 0)
	maxH := custodyPayload("price/oracle", "src", []byte{0}, ^uint64(0), 0)
	negTS := custodyPayload("price/oracle", "src", []byte{0}, 0, -1)
	require.NotEqual(t, zero, maxH)
	require.NotEqual(t, zero, negTS)
	require.Len(t, zero, 32+1+8+8) // domain(32) + value + height + ts
}

// ---------------------------------------------------------------------------
// Aggregate root
// ---------------------------------------------------------------------------

func TestAggregateAttestationRootEmpty(t *testing.T) {
	require.Nil(t, aggregateAttestationRoot(nil))
	require.Nil(t, aggregateAttestationRoot([]types.OracleAttestation{}))
}

func TestAggregateAttestationRootDeterministic(t *testing.T) {
	atts := []types.OracleAttestation{
		{SourceId: "a", Value: []byte("1")},
		{SourceId: "b", Value: []byte("2")},
	}
	r1 := aggregateAttestationRoot(atts)
	r2 := aggregateAttestationRoot(atts)
	require.Equal(t, r1, r2)
	require.Len(t, r1, sha256.Size)

	// order-sensitive today (spec notes missing sort — document behaviour)
	swapped := []types.OracleAttestation{
		{SourceId: "b", Value: []byte("2")},
		{SourceId: "a", Value: []byte("1")},
	}
	require.NotEqual(t, r1, aggregateAttestationRoot(swapped),
		"current aggregate is order-sensitive; sorted domain-separated root is a known gap")
}

// ---------------------------------------------------------------------------
// Source lookup
// ---------------------------------------------------------------------------

func TestFindOracleSourceEnabledOnly(t *testing.T) {
	sources := []types.OracleSource{
		{SourceId: "a", Enabled: true},
		{SourceId: "b", Enabled: false},
	}
	src, ok := findOracleSource(sources, "a")
	require.True(t, ok)
	require.Equal(t, "a", src.SourceId)

	_, ok = findOracleSource(sources, "b")
	require.False(t, ok, "disabled sources must not match")

	_, ok = findOracleSource(sources, "missing")
	require.False(t, ok)
}

// ---------------------------------------------------------------------------
// Oracle source store
// ---------------------------------------------------------------------------

func TestOracleSourcesStoreRoundTrip(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pub, _ := genCustodyKey(t)

	chainUID := "price-oracle-main"
	sources := []types.OracleSource{
		makeSource("btc-usd", pub, "price/oracle", true),
		makeSource("eth-usd", pub, "price/oracle", true),
	}
	require.NoError(t, k.SetOracleSources(ctx, chainUID, sources))

	got, err := k.GetOracleSources(ctx, chainUID)
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, "btc-usd", got[0].SourceId)
	require.Equal(t, "ed25519", got[0].Authenticator.Algorithm)

	// missing chain
	empty, err := k.GetOracleSources(ctx, "nope")
	require.NoError(t, err)
	require.Nil(t, empty)
}

// ---------------------------------------------------------------------------
// verifyOracleAttestations — corruption / manipulation resistance
// ---------------------------------------------------------------------------

func TestVerifyOracleAttestationsEmptyOK(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	// legacy path: empty attestations always accepted
	require.NoError(t, k.verifyOracleAttestations(ctx, "any", nil))
	require.NoError(t, k.verifyOracleAttestations(ctx, "any", []types.OracleAttestation{}))
}

func TestVerifyOracleAttestationsValidMultiSource(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pubA, privA := genCustodyKey(t)
	pubB, privB := genCustodyKey(t)

	chainUID := "agg-chain"
	scope := "price/oracle"
	require.NoError(t, k.SetOracleSources(ctx, chainUID, []types.OracleSource{
		makeSource("src-a", pubA, scope, true),
		makeSource("src-b", pubB, scope, true),
	}))

	atts := []types.OracleAttestation{
		signAttestation(privA, scope, "src-a", []byte(`{"p":"100"}`), 10, 1700000010),
		signAttestation(privB, scope, "src-b", []byte(`{"p":"200"}`), 10, 1700000010),
	}
	require.NoError(t, k.verifyOracleAttestations(ctx, chainUID, atts))
}

func TestVerifyOracleAttestationsRejectsUnregisteredSource(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pub, priv := genCustodyKey(t)
	scope := "price/oracle"
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		makeSource("legit", pub, scope, true),
	}))

	// attacker injects unregistered source_id (single-source corruption attempt)
	att := signAttestation(priv, scope, "evil-feed", []byte(`{"p":"999999"}`), 1, 1)
	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{att})
	require.Error(t, err)
	require.Contains(t, err.Error(), "unregistered")
}

func TestVerifyOracleAttestationsRejectsDisabledSource(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pub, priv := genCustodyKey(t)
	scope := "price/oracle"
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		makeSource("retired", pub, scope, false),
	}))

	att := signAttestation(priv, scope, "retired", []byte("x"), 1, 1)
	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{att})
	require.Error(t, err)
	require.Contains(t, err.Error(), "unregistered")
}

func TestVerifyOracleAttestationsRejectsBadSignature(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pub, priv := genCustodyKey(t)
	_, evilPriv := genCustodyKey(t)
	scope := "price/oracle"
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		makeSource("src", pub, scope, true),
	}))

	// signed with wrong key
	att := signAttestation(evilPriv, scope, "src", []byte("price"), 5, 50)
	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{att})
	require.Error(t, err)
	require.Contains(t, err.Error(), "custody signature")

	// mutated value after signing (manipulation of payload)
	good := signAttestation(priv, scope, "src", []byte("price"), 5, 50)
	good.Value = []byte("price-hacked")
	err = k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{good})
	require.Error(t, err)
	require.Contains(t, err.Error(), "custody signature")
}

func TestVerifyOracleAttestationsRejectsStaleReplay(t *testing.T) {
	// Replay of a valid signature at a different height/timestamp must fail
	// because height+timestamp are part of the custody payload.
	k, ctx := setupOracleKeeper(t)
	pub, priv := genCustodyKey(t)
	scope := "price/oracle"
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		makeSource("src", pub, scope, true),
	}))

	value := []byte(`{"p":"42"}`)
	origH, origTS := uint64(100), int64(1_700_000_000)
	att := signAttestation(priv, scope, "src", value, origH, origTS)

	// valid at original height
	require.NoError(t, k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{att}))

	// replay with advanced height (stale attestation reuse)
	staleH := att
	staleH.Height = origH + 1
	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{staleH})
	require.Error(t, err)
	require.Contains(t, err.Error(), "custody signature")

	// replay with advanced timestamp
	staleTS := att
	staleTS.Timestamp = origTS + 3600
	err = k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{staleTS})
	require.Error(t, err)
	require.Contains(t, err.Error(), "custody signature")
}

func TestVerifyOracleAttestationsRejectsMissingAuthenticator(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		{
			SourceId:      "naked",
			Enabled:       true,
			Authenticator: nil,
		},
	}))
	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{
		{SourceId: "naked", Value: []byte("v"), Height: 1, Timestamp: 1, CustodySignature: []byte{1}},
	})
	require.Error(t, err)
	require.Contains(t, err.Error(), "missing custody authenticator")
}

func TestVerifyOracleAttestationsRejectsBadAlgorithmAndPubkey(t *testing.T) {
	k, ctx := setupOracleKeeper(t)

	// unsupported algorithm
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		{
			SourceId: "src",
			Enabled:  true,
			Authenticator: &types.CustodyAuthenticator{
				Pubkey:    make([]byte, ed25519.PublicKeySize),
				Algorithm: "secp256k1",
				Scope:     "price/oracle",
			},
		},
	}))
	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{
		{SourceId: "src", Value: []byte("v"), CustodySignature: make([]byte, 64)},
	})
	require.Error(t, err)
	require.Contains(t, err.Error(), "unsupported custody algorithm")

	// bad pubkey length
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		{
			SourceId: "src2",
			Enabled:  true,
			Authenticator: &types.CustodyAuthenticator{
				Pubkey:    []byte{1, 2, 3},
				Algorithm: "ed25519",
				Scope:     "price/oracle",
			},
		},
	}))
	err = k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{
		{SourceId: "src2", Value: []byte("v"), CustodySignature: make([]byte, 64)},
	})
	require.Error(t, err)
	require.Contains(t, err.Error(), "invalid custody pubkey length")
}

func TestVerifyOracleAttestationsPartialCorruptionMultiSource(t *testing.T) {
	// If one of N sources is corrupted, the whole batch fails (no silent majority skip).
	k, ctx := setupOracleKeeper(t)
	pubA, privA := genCustodyKey(t)
	pubB, privB := genCustodyKey(t)
	scope := "price/oracle"
	require.NoError(t, k.SetOracleSources(ctx, "c", []types.OracleSource{
		makeSource("src-a", pubA, scope, true),
		makeSource("src-b", pubB, scope, true),
	}))

	goodA := signAttestation(privA, scope, "src-a", []byte("100"), 1, 1)
	badB := signAttestation(privB, scope, "src-b", []byte("200"), 1, 1)
	badB.Value = []byte("200-CORRUPT")

	err := k.verifyOracleAttestations(ctx, "c", []types.OracleAttestation{goodA, badB})
	require.Error(t, err)
	require.Contains(t, err.Error(), "src-b")
}

// ---------------------------------------------------------------------------
// VerifyVoteExtension handler (chain + custody gate)
// ---------------------------------------------------------------------------

func TestVerifyVoteExtensionAcceptsEmpty(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	handler := k.VerifyVoteExtensionHandler()
	resp, err := handler(ctx, &abci.RequestVerifyVoteExtension{VoteExtension: nil})
	require.NoError(t, err)
	require.Equal(t, abci.ResponseVerifyVoteExtension_ACCEPT, resp.Status)

	resp, err = handler(ctx, &abci.RequestVerifyVoteExtension{VoteExtension: []byte{}})
	require.NoError(t, err)
	require.Equal(t, abci.ResponseVerifyVoteExtension_ACCEPT, resp.Status)
}

func TestVerifyVoteExtensionRejectsMalformed(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	handler := k.VerifyVoteExtensionHandler()
	resp, err := handler(ctx, &abci.RequestVerifyVoteExtension{VoteExtension: []byte("not-proto")})
	require.NoError(t, err)
	require.Equal(t, abci.ResponseVerifyVoteExtension_REJECT, resp.Status)
}

func TestVerifyVoteExtensionRejectsUnregisteredChain(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	handler := k.VerifyVoteExtensionHandler()

	data := types.VoteExtensionHashData{
		ChainUid: "unknown-chain",
		Algo:     "keccak256",
		Root:     []byte{1, 2, 3},
	}
	bz, err := k.cdc.Marshal(&data)
	require.NoError(t, err)

	resp, err := handler(ctx, &abci.RequestVerifyVoteExtension{VoteExtension: bz})
	require.NoError(t, err)
	require.Equal(t, abci.ResponseVerifyVoteExtension_REJECT, resp.Status)
}

func TestVerifyVoteExtensionRejectsCorruptedAttestation(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pub, _ := genCustodyKey(t)
	scope := "price/oracle"
	chainUID := "eth-mainnet"

	require.NoError(t, k.SetRegisteredChain(ctx, types.RegisteredChain{
		ChainUid: chainUID,
		Name:     "Ethereum",
		Enabled:  true,
	}))
	require.NoError(t, k.SetOracleSources(ctx, chainUID, []types.OracleSource{
		makeSource("skip-connect", pub, scope, true),
	}))

	// bad signature under registered chain
	data := types.VoteExtensionHashData{
		ChainUid: chainUID,
		Algo:     "oracle-agg-v1",
		Root:     []byte("root"),
		Attestations: []*types.OracleAttestation{
			{
				SourceId:         "skip-connect",
				Value:            []byte(`{"p":"1"}`),
				Height:           1,
				Timestamp:        1,
				CustodySignature: make([]byte, ed25519.SignatureSize), // invalid sig
			},
		},
	}
	bz, err := k.cdc.Marshal(&data)
	require.NoError(t, err)

	handler := k.VerifyVoteExtensionHandler()
	resp, err := handler(ctx, &abci.RequestVerifyVoteExtension{VoteExtension: bz})
	require.NoError(t, err)
	require.Equal(t, abci.ResponseVerifyVoteExtension_REJECT, resp.Status)
}

func TestVerifyVoteExtensionAcceptsValidCustody(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	pub, priv := genCustodyKey(t)
	scope := "price/oracle"
	chainUID := "eth-mainnet"

	require.NoError(t, k.SetRegisteredChain(ctx, types.RegisteredChain{
		ChainUid: chainUID,
		Name:     "Ethereum",
		Enabled:  true,
	}))
	require.NoError(t, k.SetOracleSources(ctx, chainUID, []types.OracleSource{
		makeSource("skip-connect", pub, scope, true),
	}))

	att := signAttestation(priv, scope, "skip-connect", []byte(`{"p":"95000"}`), 42, 1700000000)
	data := types.VoteExtensionHashData{
		ChainUid:     chainUID,
		Algo:         "oracle-agg-v1",
		Root:         aggregateAttestationRoot([]types.OracleAttestation{att}),
		Attestations: []*types.OracleAttestation{&att},
	}
	bz, err := k.cdc.Marshal(&data)
	require.NoError(t, err)

	handler := k.VerifyVoteExtensionHandler()
	resp, err := handler(ctx, &abci.RequestVerifyVoteExtension{VoteExtension: bz})
	require.NoError(t, err)
	require.Equal(t, abci.ResponseVerifyVoteExtension_ACCEPT, resp.Status)
}

// ---------------------------------------------------------------------------
// ProcessVoteExtensions — quorum / minority manipulation resistance
// ---------------------------------------------------------------------------

func TestProcessVoteExtensionsQuorumConfirmsRoot(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	require.NoError(t, k.SetParams(ctx, types.DefaultParams())) // quorum 0.667

	chainUID := "eth-mainnet"
	algo := "keccak256"
	rootBytes := []byte("good-root")

	mkVE := func(root []byte) []byte {
		data := types.VoteExtensionHashData{
			ChainUid:      chainUID,
			Algo:          algo,
			Root:          root,
			ForeignHeight: 100,
		}
		bz, err := k.cdc.Marshal(&data)
		require.NoError(t, err)
		return bz
	}

	// 70 + 30 = 100 total power; good root has 70 >= 66.7 → confirmed
	ext := abci.ExtendedCommitInfo{
		Votes: []abci.ExtendedVoteInfo{
			{Validator: abci.Validator{Power: 70}, VoteExtension: mkVE(rootBytes)},
			{Validator: abci.Validator{Power: 30}, VoteExtension: mkVE([]byte("evil-root"))},
		},
	}
	require.NoError(t, k.ProcessVoteExtensions(ctx, ext))

	got, err := k.GetHashRoot(ctx, chainUID, algo)
	require.NoError(t, err)
	require.Equal(t, rootBytes, got.Root)
	require.Equal(t, uint64(100), got.Height)
}

func TestProcessVoteExtensionsRejectsMinorityManipulation(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	require.NoError(t, k.SetParams(ctx, types.DefaultParams()))

	chainUID := "eth-mainnet"
	algo := "keccak256"

	mkVE := func(root []byte) []byte {
		data := types.VoteExtensionHashData{ChainUid: chainUID, Algo: algo, Root: root, ForeignHeight: 1}
		bz, err := k.cdc.Marshal(&data)
		require.NoError(t, err)
		return bz
	}

	// minority only (30 < 66.7 of 100) — nothing written
	ext := abci.ExtendedCommitInfo{
		Votes: []abci.ExtendedVoteInfo{
			{Validator: abci.Validator{Power: 30}, VoteExtension: mkVE([]byte("manipulated"))},
			{Validator: abci.Validator{Power: 70}, VoteExtension: nil}, // empty extensions ignored
		},
	}
	require.NoError(t, k.ProcessVoteExtensions(ctx, ext))

	_, err := k.GetHashRoot(ctx, chainUID, algo)
	require.Error(t, err)
}

// ---------------------------------------------------------------------------
// Gas / micro-benchmarks (task acceptance item 5)
// ---------------------------------------------------------------------------

func BenchmarkPackUnpackOracleBundle(b *testing.B) {
	atts := make([]types.OracleAttestation, 8)
	for i := range atts {
		atts[i] = types.OracleAttestation{
			SourceId:  fmt.Sprintf("src-%d", i),
			Value:     []byte(fmt.Sprintf(`{"p":"%d"}`, i*1000)),
			Height:    uint64(i + 1),
			Timestamp: int64(1_700_000_000 + i),
		}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		packed, err := packOracleBundle(atts)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := unpackOracleBundle(packed); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkAggregateAttestationRoot(b *testing.B) {
	atts := make([]types.OracleAttestation, 16)
	for i := range atts {
		atts[i] = types.OracleAttestation{
			SourceId: fmt.Sprintf("source-%02d", i),
			Value:    []byte(fmt.Sprintf("value-%d", i)),
		}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = aggregateAttestationRoot(atts)
	}
}

func BenchmarkCustodyPayloadSignVerify(b *testing.B) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		b.Fatal(err)
	}
	pub := priv.Public().(ed25519.PublicKey)
	value := []byte(`{"asset":"BTC","price_usd":"95000.00"}`)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		msg := custodyPayload("price/oracle", "skip-connect", value, uint64(i), int64(i))
		sig := ed25519.Sign(priv, msg)
		if !ed25519.Verify(pub, msg, sig) {
			b.Fatal("verify failed")
		}
	}
}

// ensure JSON source store still works with full authenticator fields (regression)
func TestOracleSourceJSONMarshalShape(t *testing.T) {
	pub, _ := genCustodyKey(t)
	src := makeSource("btc-usd", pub, "price/oracle", true)
	bz, err := json.Marshal([]types.OracleSource{src})
	require.NoError(t, err)
	var out []types.OracleSource
	require.NoError(t, json.Unmarshal(bz, &out))
	require.Len(t, out, 1)
	require.Equal(t, pub, ed25519.PublicKey(out[0].Authenticator.Pubkey))
}
