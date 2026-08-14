package authenticator

import (
	"encoding/json"
	"fmt"

	errorsmod "cosmossdk.io/errors"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
)

// ZkProofAuthenticatorType is the registered type string for a native Path-A
// (or hybrid CGO) ZKP authenticator.
//
// Product default remains CosmwasmAuthenticatorV1 → ZkProof contract until a
// real host verify is registered in app keepers. This Type implements the
// gas-before-verify / RecheckTx skip / fail-closed shape so wiring Path A is a
// single call-site swap (see Authenticate body).
//
// Design: docs/research/ZKPROOF-AUTHENTICATOR-AND-DUAL-FFI.md
// Compose under AllOf with CosmwasmAuthenticator → nullifier gate
// (docs/research/DAO-CEREMONY-NULLIFIER-AUTH.md). Do not store nullifiers here.
const ZkProofAuthenticatorType = "ZkProofAuthenticatorV1"

// DefaultZkProofStaticGas is a conservative ante lower bound when config omits
// static_gas. Path A schedule still applies inside CosmWasm host when used;
// native wire should consume schedule-equivalent gas before crypto.
const DefaultZkProofStaticGas uint64 = 100_000

// ZkProofAuthenticatorConfig is Initialize() JSON (account-authenticator pair config).
type ZkProofAuthenticatorConfig struct {
	// ZkID is the on-chain circuit id consumed by Path A (do_proof_instance_verify).
	ZkID uint64 `json:"zk_id"`
	// PILayout names the expected public-input layout (e.g. vote.delegation.v1).
	PILayout string `json:"pi_layout,omitempty"`
	// StaticGas is the ante lower bound consumed before Authenticate (OD-gas-payer).
	StaticGas uint64 `json:"static_gas,omitempty"`
	// RequirePin fail-closes when production policy demands pin_circuit (OD-pin).
	RequirePin bool `json:"require_pin,omitempty"`
	// MaxProofBytes bounds auth payload proof size (DoS).
	MaxProofBytes uint64 `json:"max_proof_bytes,omitempty"`
}

// ZkProofAuthPayload is JSON carried in AuthenticationRequest.Signature
// (auth data for this authenticator — not necessarily a secp signature).
type ZkProofAuthPayload struct {
	// Proof is Halo2 proof bytes (base64 in JSON).
	Proof []byte `json:"proof"`
	// Instances is public-input byte blob layout for the configured pi_layout.
	// Encoding is product-specific; Path A expects the host layout for zk_id.
	Instances []byte `json:"instances"`
	// CircuitKeyHint optional 72-byte key hint (hex decoded by client into bytes).
	CircuitKeyHint []byte `json:"circuit_key_hint,omitempty"`
}

// ZkProofPathAVerifier is the optional host hook for Path A verify.
// Production: wrap libwasmvm / cosmwasm-vm do_proof_instance_verify.
// Tests: inject a mock. Nil → Authenticate fail-closed after parse/gas/recheck.
type ZkProofPathAVerifier func(ctx sdk.Context, zkID uint64, proof, instances []byte) error

// GlobalPathAVerifier is set by app wiring or tests. Not registered in keepers
// by default (V4: shape + inject point; full keeper registration when host ready).
var GlobalPathAVerifier ZkProofPathAVerifier

// ZkProofAuthenticatorV1 implements Authenticator for ZKP verify-before-accept.
//
// Nullifier spend is never performed here (Track/ConfirmExecution no-op).
type ZkProofAuthenticatorV1 struct {
	config   ZkProofAuthenticatorConfig
	// verifier optional per-instance override; falls back to GlobalPathAVerifier.
	verifier ZkProofPathAVerifier
}

var _ Authenticator = &ZkProofAuthenticatorV1{}

// NewZkProofAuthenticatorV1 returns an uninitialized template for the manager.
func NewZkProofAuthenticatorV1() ZkProofAuthenticatorV1 {
	return ZkProofAuthenticatorV1{}
}

// NewZkProofAuthenticatorV1WithVerifier returns a template with injectible Path A.
func NewZkProofAuthenticatorV1WithVerifier(v ZkProofPathAVerifier) ZkProofAuthenticatorV1 {
	return ZkProofAuthenticatorV1{verifier: v}
}

func (z ZkProofAuthenticatorV1) Type() string {
	return ZkProofAuthenticatorType
}

func (z ZkProofAuthenticatorV1) StaticGas() uint64 {
	if z.config.StaticGas == 0 {
		return DefaultZkProofStaticGas
	}
	return z.config.StaticGas
}

func (z ZkProofAuthenticatorV1) Initialize(config []byte) (Authenticator, error) {
	cfg, err := ParseZkProofAuthenticatorConfig(config)
	if err != nil {
		return nil, err
	}
	z.config = cfg
	return z, nil
}

// ParseZkProofAuthenticatorConfig validates config JSON (shared by OnAuthenticatorAdded).
func ParseZkProofAuthenticatorConfig(config []byte) (ZkProofAuthenticatorConfig, error) {
	var cfg ZkProofAuthenticatorConfig
	if len(config) == 0 {
		return cfg, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "ZkProofAuthenticatorV1: empty config")
	}
	if err := json.Unmarshal(config, &cfg); err != nil {
		return cfg, errorsmod.Wrap(err, "ZkProofAuthenticatorV1: parse config")
	}
	if cfg.ZkID == 0 {
		return cfg, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "ZkProofAuthenticatorV1: zk_id required")
	}
	if cfg.MaxProofBytes == 0 {
		cfg.MaxProofBytes = 65536
	}
	return cfg, nil
}

// ParseZkProofAuthPayload decodes auth data from the signature / auth field.
func ParseZkProofAuthPayload(raw []byte) (ZkProofAuthPayload, error) {
	var p ZkProofAuthPayload
	if len(raw) == 0 {
		return p, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "ZkProofAuthenticatorV1: empty auth payload")
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return p, errorsmod.Wrap(err, "ZkProofAuthenticatorV1: parse auth payload")
	}
	if len(p.Proof) == 0 {
		return p, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "ZkProofAuthenticatorV1: proof required")
	}
	if len(p.Instances) == 0 {
		return p, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "ZkProofAuthenticatorV1: instances required")
	}
	return p, nil
}

// Authenticate: gas → (skip if recheck/simulate) → parse → Path A verify → fail-closed.
//
// Path A call site (when GlobalPathAVerifier / z.verifier set):
//
//	verifier(ctx, zk_id, proof, instances)
//
// Until a verifier is injected, fails closed after structural checks so accidental
// registration cannot soft-accept. Does not own nullifier storage.
func (z ZkProofAuthenticatorV1) Authenticate(ctx sdk.Context, request AuthenticationRequest) error {
	// 1) Gas-before-verify (mirror signature_authenticator shape).
	gas := z.StaticGas()
	if gas > 0 {
		ctx.GasMeter().ConsumeGas(gas, "zkproof authenticator static_gas")
	}

	// 2) Skip expensive crypto on Simulate / RecheckTx (nullifier sibling still checks).
	if request.Simulate || ctx.IsReCheckTx() {
		return nil
	}

	// 3) Parse proof + instances from auth data.
	payload, err := ParseZkProofAuthPayload(request.Signature)
	if err != nil {
		return err
	}
	if uint64(len(payload.Proof)) > z.config.MaxProofBytes {
		return errorsmod.Wrapf(
			sdkerrors.ErrInvalidRequest,
			"ZkProofAuthenticatorV1: proof len %d > max %d",
			len(payload.Proof), z.config.MaxProofBytes,
		)
	}

	// 4) OD-pin: require_pin is a policy flag; without host pin probe, fail closed
	// when RequirePin is set and no verifier is available to enforce it.
	verifier := z.verifier
	if verifier == nil {
		verifier = GlobalPathAVerifier
	}
	if verifier == nil {
		return errorsmod.Wrap(
			sdkerrors.ErrUnauthorized,
			fmt.Sprintf(
				"ZkProofAuthenticatorV1 Path A not wired (zk_id=%d layout=%q require_pin=%v): fail-closed — inject GlobalPathAVerifier or CosmWasm Path A contract; see docs/research/ZKPROOF-AUTHENTICATOR-AND-DUAL-FFI.md",
				z.config.ZkID, z.config.PILayout, z.config.RequirePin,
			),
		)
	}

	// 5) Host verify — any miss → error.
	if err := verifier(ctx, z.config.ZkID, payload.Proof, payload.Instances); err != nil {
		return errorsmod.Wrapf(sdkerrors.ErrUnauthorized, "ZkProofAuthenticatorV1 verify failed: %v", err)
	}
	return nil
}

// Track is a no-op: nullifier spend belongs to ceremony module ConfirmExecution path.
func (z ZkProofAuthenticatorV1) Track(ctx sdk.Context, request AuthenticationRequest) error {
	return nil
}

// ConfirmExecution is a no-op: do not write nullifiers in the ZKP authenticator.
func (z ZkProofAuthenticatorV1) ConfirmExecution(ctx sdk.Context, request AuthenticationRequest) error {
	return nil
}

func (z ZkProofAuthenticatorV1) OnAuthenticatorAdded(ctx sdk.Context, account sdk.AccAddress, config []byte, authenticatorId string) error {
	_, err := ParseZkProofAuthenticatorConfig(config)
	return err
}

func (z ZkProofAuthenticatorV1) OnAuthenticatorRemoved(ctx sdk.Context, account sdk.AccAddress, config []byte, authenticatorId string) error {
	return nil
}
