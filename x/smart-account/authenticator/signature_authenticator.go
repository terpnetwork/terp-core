package authenticator

import (
	"encoding/hex"
	"fmt"
	"strings"

	errorsmod "cosmossdk.io/errors"

	"github.com/cosmos/cosmos-sdk/crypto/keys/secp256k1"
	cryptotypes "github.com/cosmos/cosmos-sdk/crypto/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	authante "github.com/cosmos/cosmos-sdk/x/auth/ante"
)

// Compile time type assertion for the SignatureData using the
// SignatureVerification struct
var _ Authenticator = &SignatureVerification{}

const (
	// SignatureVerificationType represents a type of authenticator specifically designed for
	// secp256k1 signature verification.
	SignatureVerificationType = "SignatureVerification"
)

// signature authenticator
type SignatureVerification struct {
	ak     authante.AccountKeeper
	PubKey cryptotypes.PubKey
}

func (sva SignatureVerification) Type() string {
	return SignatureVerificationType
}

func (sva SignatureVerification) StaticGas() uint64 {
	// using 0 gas here. The gas is consumed based on the pubkey type in Authenticate()
	return 0
}

// NewSignatureVerification creates a new SignatureVerification
func NewSignatureVerification(ak authante.AccountKeeper) SignatureVerification {
	return SignatureVerification{ak: ak}
}

// Initialize sets up the public key from the configuration supplied by the account‑authenticator.
// It now accepts three forms:
//
//  1. Raw 33‑byte secp256k1 pubkey  (len == secp256k1.PubKeySize)
//  2. Hex‑encoded string, e.g. "033C6F20200AB3…"
//  3. Cosmos‑SDK string representation, e.g. "PubKeySecp256k1{033C6F20200AB3…}"
func (sva SignatureVerification) Initialize(config []byte) (Authenticator, error) {
	// -------------------------------------------------
	// 1️⃣ Fast‑path – already a raw 33‑byte key.
	// -------------------------------------------------
	if len(config) == secp256k1.PubKeySize {
		sva.PubKey = &secp256k1.PubKey{Key: config}
		fmt.Printf("DEBUG: Initialize sva.PubKey (raw) = %x\n", sva.PubKey.Bytes())
		return sva, nil
	}

	// -------------------------------------------------
	// 2️⃣ Otherwise treat the payload as a string.
	// -------------------------------------------------
	str := strings.TrimSpace(string(config))

	// Strip the Cosmos‑SDK wrapper if present.
	if strings.HasPrefix(str, "PubKeySecp256k1{") && strings.HasSuffix(str, "}") {
		str = strings.TrimPrefix(str, "PubKeySecp256k1{")
		str = strings.TrimSuffix(str, "}")
	}

	// At this point we expect a plain hex string.
	hexStr := str

	// Decode the hex representation into raw bytes.
	pubKeyBytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil, fmt.Errorf("invalid secp256k1 public key (not hex): %x, %x", hexStr, err)
	}
	if len(pubKeyBytes) != secp256k1.PubKeySize {
		return nil, fmt.Errorf(
			"invalid secp256k1 public key size after decoding, expected %d, got %d (key: %x)",
			secp256k1.PubKeySize,
			len(pubKeyBytes),
			pubKeyBytes,
		)
	}

	// -------------------------------------------------
	// 3️⃣ Build the SDK pubkey and store it.
	// -------------------------------------------------
	sva.PubKey = &secp256k1.PubKey{Key: pubKeyBytes}
	fmt.Printf("DEBUG: Initialize sva.PubKey (decoded) = %x\n", sva.PubKey.Bytes())
	return sva, nil
}

// Authenticate takes a SignaturesVerificationData struct and validates
// each signer and signature using signature verification
func (sva SignatureVerification) Authenticate(ctx sdk.Context, request AuthenticationRequest) error {
	// First consume gas for verifying the signature
	params := sva.ak.GetParams(ctx)
	ctx.GasMeter().ConsumeGas(params.SigVerifyCostSecp256k1, "secp256k1 signature verification")
	// after gas consumption continue to verify signatures

	if request.Simulate || ctx.IsReCheckTx() {
		return nil
	}
	if sva.PubKey == nil {
		return errorsmod.Wrap(sdkerrors.ErrInvalidPubKey, "pubkey on not set on account or authenticator")
	}
	fmt.Printf("DEBUG: sva.PubKey: %x\n", sva.PubKey)

	if !sva.PubKey.VerifySignature(request.SignModeTxData.Direct, request.Signature) {
		return errorsmod.Wrapf(
			sdkerrors.ErrUnauthorized,
			"signature verification failed; please verify account number (%d), sequence (%d) and chain-id (%s)",
			request.TxData.AccountNumber,
			request.TxData.AccountSequence,
			request.TxData.ChainID,
		)
	}
	return nil
}

func (sva SignatureVerification) Track(ctx sdk.Context, request AuthenticationRequest) error {
	return nil
}

func (sva SignatureVerification) ConfirmExecution(ctx sdk.Context, request AuthenticationRequest) error {
	return nil
}

func (sva SignatureVerification) OnAuthenticatorAdded(ctx sdk.Context, account sdk.AccAddress, config []byte, authenticatorId string) error {
	if len(config) == secp256k1.PubKeySize {
		return nil
	}

	str := strings.TrimSpace(string(config))
	// Remove the Cosmos‑SDK wrapper if present:
	//   PubKeySecp256k1{<hex>}
	if strings.HasPrefix(str, "PubKeySecp256k1{") && strings.HasSuffix(str, "}") {
		str = strings.TrimPrefix(str, "PubKeySecp256k1{")
		str = strings.TrimSuffix(str, "}")
	}
	// Decode hex → bytes.
	pubKeyBytes, err := hex.DecodeString(str)
	if err != nil {
		return fmt.Errorf("invalid secp256k1 public key (not hex): %q, %w", str, err)
	}

	// -------------------------------------------------
	// 3️⃣ Validate length (33 bytes == 66 hex chars)
	// -------------------------------------------------
	if len(pubKeyBytes) != secp256k1.PubKeySize {
		return fmt.Errorf(
			"invalid secp256k1 public key size, expected %d, got %d. pubkey (hex) = %s",
			secp256k1.PubKeySize,
			len(pubKeyBytes),
			str,
		)
	}
	return nil
}

func (sva SignatureVerification) OnAuthenticatorRemoved(ctx sdk.Context, account sdk.AccAddress, config []byte, authenticatorId string) error {
	return nil
}
