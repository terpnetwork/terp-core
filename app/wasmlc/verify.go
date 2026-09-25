// Package wasmlc runs cw-ics08-wasm-terp VerifyMembership against IAVL proofs.
// This is the same sudo path 08-wasm uses on a counterparty.
package wasmlc

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmvm "github.com/CosmWasm/wasmvm/v3"
	"github.com/CosmWasm/wasmvm/v3/types"
	ics23 "github.com/cosmos/ics23/go"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
)

const DefaultWasmRel = "crates/terp-rs/artifacts/cw_ics08_wasm_terp.wasm"

// FindWasm walks up from cwd looking for cw_ics08_wasm_terp.wasm.
func FindWasm() (string, error) {
	if p := os.Getenv("WASM_LC"); p != "" {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		p := filepath.Join(dir, DefaultWasmRel)
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("cw_ics08_wasm_terp.wasm not found (set WASM_LC)")
}

// Membership is one IAVL (or chained) existence proof for the wasm LC.
type Membership struct {
	Store  string
	Key    []byte
	Value  []byte
	Proofs []*ics23.CommitmentProof
	Root   []byte // consensus app hash, or IAVL root for a single-layer proof
	Height uint64
}

type instantiatePayload struct {
	ClientState    []byte `json:"client_state"`
	ConsensusState []byte `json:"consensus_state"`
	Checksum       []byte `json:"checksum"`
}

type innerClient struct {
	ChainID      string `json:"chain_id"`
	LatestHeight height `json:"latest_height"`
	HasherMode   string `json:"hasher_mode"`
}

type innerConsensus struct {
	TimestampNs uint64 `json:"timestamp_ns"`
	RootHex     string `json:"root_hex"`
}

type height struct {
	RevisionNumber uint64 `json:"revision_number"`
	RevisionHeight uint64 `json:"revision_height"`
}

type merklePath struct {
	KeyPath [][]byte `json:"key_path"`
}

type verifyMembershipMsg struct {
	Height           height     `json:"height"`
	DelayTimePeriod  uint64     `json:"delay_time_period"`
	DelayBlockPeriod uint64     `json:"delay_block_period"`
	Proof            []byte     `json:"proof"`
	MerklePath       merklePath `json:"merkle_path"`
	Value            []byte     `json:"value"`
}

type sudoVerify struct {
	VerifyMembership *verifyMembershipMsg `json:"verify_membership"`
}

// MarshalIbcMerkleProof encodes repeated ICS-23 CommitmentProofs (IBC MerkleProof).
func MarshalIbcMerkleProof(proofs []*ics23.CommitmentProof) ([]byte, error) {
	if len(proofs) == 1 {
		return proofs[0].Marshal()
	}
	var buf []byte
	for _, p := range proofs {
		bz, err := p.Marshal()
		if err != nil {
			return nil, err
		}
		buf = append(buf, 0x0a)
		buf = appendUvarint(buf, uint64(len(bz)))
		buf = append(buf, bz...)
	}
	return buf, nil
}

func appendUvarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

// Verify runs instantiate + sudo VerifyMembership of the 08-wasm Terp LC.
func Verify(wasm []byte, hasherMode string, m Membership) (checksum []byte, err error) {
	if hasherMode == "" {
		hasherMode = "auto"
	}
	dir, err := os.MkdirTemp("", "wasmlc-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)

	caps := append(wasmkeeper.BuiltInCapabilities(), "cosmwasm_3_0", "bn254", "hash-blake")
	vm, err := wasmvm.NewVM(dir, caps, 32, false, 100)
	if err != nil {
		return nil, fmt.Errorf("wasmvm: %w", err)
	}
	defer vm.Cleanup()

	cs, _, err := vm.StoreCode(wasm, 500_000_000_000)
	if err != nil {
		return nil, fmt.Errorf("store wasm: %w", err)
	}
	checksum = cs

	h := height{RevisionHeight: m.Height}
	if h.RevisionHeight == 0 {
		h.RevisionHeight = 1
	}
	innerC, err := json.Marshal(innerClient{
		ChainID:      "local-1",
		LatestHeight: h,
		HasherMode:   hasherMode,
	})
	if err != nil {
		return checksum, err
	}
	innerS, err := json.Marshal(innerConsensus{
		TimestampNs: 1,
		RootHex:     hex.EncodeToString(m.Root),
	})
	if err != nil {
		return checksum, err
	}
	initBz, err := json.Marshal(instantiatePayload{
		ClientState:    innerC,
		ConsensusState: innerS,
		Checksum:       checksum,
	})
	if err != nil {
		return checksum, err
	}

	store := newMem()
	api := types.GoAPI{
		HumanizeAddress:     func(b []byte) (string, uint64, error) { return "terp1lc", 0, nil },
		CanonicalizeAddress: func(s string) ([]byte, uint64, error) { return []byte("canon"), 0, nil },
		ValidateAddress:     func(s string) (uint64, error) { return 0, nil },
	}
	q := nopQuerier{}
	gm := gasN(0)
	env := types.Env{
		Block:    types.BlockInfo{Height: 1, Time: 1, ChainID: "local-2"},
		Contract: types.ContractInfo{Address: "cosmwasm1lc"},
	}
	info := types.MessageInfo{Sender: "terp1creator"}
	deser := types.UFraction{Numerator: 1, Denominator: 1}

	inst, _, err := vm.Instantiate(cs, env, info, initBz, store, api, q, gm, 500_000_000_000, deser)
	if err != nil {
		return checksum, fmt.Errorf("instantiate LC: %w", err)
	}
	if inst.Err != "" {
		return checksum, fmt.Errorf("instantiate LC: %s", inst.Err)
	}

	proofBz, err := MarshalIbcMerkleProof(m.Proofs)
	if err != nil {
		return checksum, err
	}
	path := merklePath{KeyPath: [][]byte{m.Key}}
	if m.Store != "" && len(m.Proofs) > 1 {
		path.KeyPath = [][]byte{[]byte(m.Store), m.Key}
	}
	sudoBz, err := json.Marshal(sudoVerify{VerifyMembership: &verifyMembershipMsg{
		Height:     h,
		Proof:      proofBz,
		MerklePath: path,
		Value:      m.Value,
	}})
	if err != nil {
		return checksum, err
	}
	out, _, err := vm.Sudo(cs, env, sudoBz, store, api, q, gm, 500_000_000_000, deser)
	if err != nil {
		return checksum, fmt.Errorf("sudo VerifyMembership %s: %w", m.Store, err)
	}
	if out.Err != "" {
		return checksum, fmt.Errorf("sudo VerifyMembership %s: %s", m.Store, out.Err)
	}
	return checksum, nil
}

type gasN uint64

func (g gasN) GasConsumed() uint64 { return uint64(g) }

type nopQuerier struct{}

func (nopQuerier) Query(_ types.QueryRequest, _ uint64) ([]byte, error) {
	return nil, fmt.Errorf("no queries")
}
func (nopQuerier) GasConsumed() uint64 { return 0 }

type memKV struct {
	m map[string][]byte
}

func newMem() *memKV { return &memKV{m: map[string][]byte{}} }

func (s *memKV) Get(key []byte) []byte { return s.m[string(key)] }
func (s *memKV) Set(key, val []byte) {
	s.m[string(key)] = append([]byte(nil), val...)
}
func (s *memKV) Delete(key []byte) { delete(s.m, string(key)) }
func (s *memKV) Iterator(start, end []byte) types.Iterator {
	return newMemIter(s, start, end, false)
}
func (s *memKV) ReverseIterator(start, end []byte) types.Iterator {
	return newMemIter(s, start, end, true)
}

type memIter struct {
	keys []string
	vals [][]byte
	i    int
}

func newMemIter(s *memKV, start, end []byte, rev bool) *memIter {
	var ks []string
	for k := range s.m {
		if start != nil && k < string(start) {
			continue
		}
		if end != nil && k >= string(end) {
			continue
		}
		ks = append(ks, k)
	}
	sort.Strings(ks)
	if rev {
		for i, j := 0, len(ks)-1; i < j; i, j = i+1, j-1 {
			ks[i], ks[j] = ks[j], ks[i]
		}
	}
	it := &memIter{i: 0}
	for _, k := range ks {
		it.keys = append(it.keys, k)
		it.vals = append(it.vals, s.m[k])
	}
	return it
}

func (it *memIter) Domain() ([]byte, []byte) { return nil, nil }
func (it *memIter) Valid() bool              { return it.i >= 0 && it.i < len(it.keys) }
func (it *memIter) Next()                    { it.i++ }
func (it *memIter) Key() []byte              { return []byte(it.keys[it.i]) }
func (it *memIter) Value() []byte            { return it.vals[it.i] }
func (it *memIter) Error() error             { return nil }
func (it *memIter) Close() error             { return nil }

// ExclusiveWasm checks the LC accepts the matching hasher and that Go ics23
// exclusive verify also holds (wrong spec rejected).
//
// IAVL exclusive-verify is always against the IAVL root (proofs[0]). The LC
// VerifyMembership uses m.Root, which is the app hash when proofs are chained
// (IAVL + simple merkle), matching 08-wasm on a counterparty.
func ExclusiveWasm(wasm []byte, m Membership) error {
	if len(m.Proofs) == 0 || m.Proofs[0].GetExist() == nil {
		return fmt.Errorf("%s: missing IAVL existence proof", m.Store)
	}
	iavlRoot, err := m.Proofs[0].GetExist().Calculate()
	if err != nil {
		return err
	}
	if err := iavl.VerifyExclusive(m.Store, iavlRoot, m.Proofs[0], m.Key, m.Value); err != nil {
		return err
	}
	_, err = Verify(wasm, "auto", m)
	return err
}
