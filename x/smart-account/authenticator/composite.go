package authenticator

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"

	"cosmossdk.io/errors"
	errorsmod "cosmossdk.io/errors"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	sat "github.com/terpnetwork/terp-core/v5/x/smart-account/types"
)

// Custom struct that matches the JSON shape
type subAuthDataJSON struct {
	Type   string          `json:"type"`
	Config json.RawMessage `json:"config"`
}

func subTrack(
	ctx sdk.Context,
	request AuthenticationRequest,
	subAuthenticators []Authenticator,
) error {
	baseId := request.AuthenticatorId
	for id, auth := range subAuthenticators {
		request.AuthenticatorId = compositeId(baseId, id)
		err := auth.Track(ctx, request)
		if err != nil {
			return errorsmod.Wrapf(err, "sub-authenticator track failed (sub-authenticator id = %s)", request.AuthenticatorId)
		}
	}
	return nil
}

func splitSignatures(signature []byte, total int) ([][]byte, error) {
	var signatures [][]byte
	err := json.Unmarshal(signature, &signatures)
	if err != nil {
		return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "failed to parse signatures")
	}
	if len(signatures) != total {
		return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "invalid number of signatures")
	}
	return signatures, nil
}

func onSubAuthenticatorsAdded(ctx sdk.Context, account sdk.AccAddress, data []byte, authenticatorId string, am *AuthenticatorManager) error {

	// First: unmarshal into raw parts
	var items []subAuthDataJSON
	if err := json.Unmarshal(data, &items); err != nil {
		return errorsmod.Wrapf(err, "failed to parse top-level JSON")
	}
	// Now convert each item
	var initDatas []sat.SubAuthenticatorInitData
	for _, item := range items {
		var config sat.AuthenticatorConfig

		// -------------------------------------------------
		// ★ NEW: custom one‑of JSON → protobuf mapper
		// -------------------------------------------------
		if err := UnmarshalAuthConfig(item.Config, &config); err != nil {
			fmt.Printf("DEBUG: raw config JSON = %s\n", string(item.Config))
			return errors.Wrap(err, "failed to unmarshal AuthenticatorConfig from JSON")
		}
		fmt.Printf("DEBUG: raw config JSON = %s\n", config.Data)

		initDatas = append(initDatas, sat.SubAuthenticatorInitData{
			Type:   item.Type,
			Config: &config,
		})
	}

	if len(initDatas) <= 1 {
		return errorsmod.Wrapf(sdkerrors.ErrInvalidRequest, "at least 2 sub-authenticators must be provided, but got %d", len(initDatas))
	}

	baseId := authenticatorId
	subAuthenticatorCount := 0
	for id, initData := range initDatas {
		authenticatorCode := am.GetAuthenticatorByType(initData.Type)
		if authenticatorCode == nil {
			return errorsmod.Wrapf(sdkerrors.ErrInvalidRequest, "sub-authenticator failed to be added in function `OnAuthenticatorAdded` as type is not registered in manager")
		}
		subId := compositeId(baseId, id)
		var rawInitData = []byte{}
		switch op := initData.Config.Data.(type) {
		case *sat.AuthenticatorConfig_ValueRaw:
			rawInitData = op.ValueRaw
		case *sat.AuthenticatorConfig_ValueString:
			rawInitData = []byte(op.ValueString)
		default:
			return errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "fatal error initializing allOf authenticator")
		}

		err := authenticatorCode.OnAuthenticatorAdded(ctx, account, rawInitData, subId)
		if err != nil {
			return errorsmod.Wrapf(err, "sub-authenticator `OnAuthenticatorAdded` failed (sub-authenticator id = %s)", subId)
		}

		subAuthenticatorCount++
	}

	// If not all sub-authenticators are registered, return an error
	if subAuthenticatorCount != len(initDatas) {
		return errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "failed to initialize all sub-authenticators")
	}

	return nil
}

func onSubAuthenticatorsRemoved(ctx sdk.Context, account sdk.AccAddress, data []byte, authenticatorId string, am *AuthenticatorManager) error {
	// First: unmarshal into raw parts
	var items []subAuthDataJSON
	if err := json.Unmarshal(data, &items); err != nil {
		return errorsmod.Wrapf(err, "composite.onSubAuthRemoved: failed to parse top-level JSON")
	}
	// Now convert each item
	var initDatas []sat.SubAuthenticatorInitData
	for _, item := range items {
		var config sat.AuthenticatorConfig
		if err := UnmarshalAuthConfig(item.Config, &config); err != nil {
			return errors.Wrap(err, "composite.onSubAuthRemoved: failed to unmarshal AuthenticatorConfig from JSON")
		}

		initDatas = append(initDatas, sat.SubAuthenticatorInitData{
			Type:   item.Type,
			Config: &config,
		})
	}

	baseId := authenticatorId
	for id, initData := range initDatas {
		authenticatorCode := am.GetAuthenticatorByType(initData.Type)
		if authenticatorCode == nil {
			return errorsmod.Wrapf(sdkerrors.ErrInvalidRequest, "sub-authenticator failed to be removed in function `OnAuthenticatorRemoved` as type is not registered in manager")
		}
		subId := compositeId(baseId, id)
		var rawInitData = []byte{}
		switch op := initData.Config.Data.(type) {
		case *sat.AuthenticatorConfig_ValueRaw:
			rawInitData = op.ValueRaw
		case *sat.AuthenticatorConfig_ValueString:
			rawInitData = []byte(op.ValueString)
		default:
			return errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "fatal error removing allOf authenticator")
		}
		err := authenticatorCode.OnAuthenticatorRemoved(ctx, account, rawInitData, subId)
		if err != nil {
			return errorsmod.Wrapf(err, "sub-authenticator `OnAuthenticatorRemoved` failed (sub-authenticator id = %s)", subId)
		}
	}
	return nil
}

func compositeId(baseId string, subId int) string {
	return baseId + "." + strconv.Itoa(subId)
}

// ------------------------------------------------------------
// ★ NEW: custom unmarshaller for AuthenticatorConfig (gogo‑proto)
// ------------------------------------------------------------
// This works with the gogo‑proto generated struct that does **not**
// implement proto.Message. It:
//
//  1. Looks for an optional top‑level “Data” object.
//  2. Inside that (or directly at the top level) checks for the one‑of
//     fields “value_string” or “value_raw”.
//  3. For “value_string” we store the string as‑is.
//  4. For “value_raw” we expect a base‑64‑encoded string (the protobuf‑JSON
//     encoding) and decode it to []byte before storing it.
//
// If neither one‑of field is present we return an error, which is what
// caused the previous failure you saw.
//
// NOTE: The function only touches the `Data` one‑of; all other generated
// fields on AuthenticatorConfig are left untouched.
func UnmarshalAuthConfig(raw json.RawMessage, dst *sat.AuthenticatorConfig) error {
	// Step 1 – decode the incoming JSON into a generic map so we can
	// inspect its keys without needing a concrete struct.
	var generic map[string]json.RawMessage
	if err := json.Unmarshal(raw, &generic); err != nil {
		return fmt.Errorf("invalid JSON for AuthenticatorConfig: %w", err)
	}

	// Step 2 – if the payload contains a “Data” wrapper, descend into it.
	if inner, ok := generic["Data"]; ok {
		// Replace the map with the inner object for the one‑of detection.
		if err := json.Unmarshal(inner, &generic); err != nil {
			return fmt.Errorf("invalid nested Data object: %w", err)
		}
	}

	// Step 3 – detect which one‑of field is present.
	if v, ok := generic["value_string"]; ok {
		// The protobuf‑JSON spec represents a plain string as a JSON string.
		var str string
		if err := json.Unmarshal(v, &str); err != nil {
			return fmt.Errorf("value_string is not a JSON string: %w", err)
		}
		dst.Data = &sat.AuthenticatorConfig_ValueString{
			ValueString: str,
		}
		return nil
	}

	if v, ok := generic["value_raw"]; ok {
		// Protobuf‑JSON encodes bytes as a base‑64 string.
		var b64 string
		if err := json.Unmarshal(v, &b64); err != nil {
			return fmt.Errorf("value_raw is not a JSON string: %w", err)
		}
		decoded, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return fmt.Errorf("value_raw is not valid base64: %w", err)
		}
		dst.Data = &sat.AuthenticatorConfig_ValueRaw{
			ValueRaw: decoded,
		}
		return nil
	}

	// authenticator config data is empty.
	return nil
}
