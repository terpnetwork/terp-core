package authenticator

import (
	"encoding/json"
	"fmt"

	"cosmossdk.io/errors"
	errorsmod "cosmossdk.io/errors"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	sat "github.com/terpnetwork/terp-core/v5/x/smart-account/types"
)

type AllOf struct {
	SubAuthenticators   []Authenticator
	am                  *AuthenticatorManager
	signatureAssignment SignatureAssignment
}

var _ Authenticator = &AllOf{}

func NewAllOf(am *AuthenticatorManager) AllOf {
	return AllOf{
		am:                  am,
		SubAuthenticators:   []Authenticator{},
		signatureAssignment: Single,
	}
}

func NewPartitionedAllOf(am *AuthenticatorManager) AllOf {
	return AllOf{
		am:                  am,
		SubAuthenticators:   []Authenticator{},
		signatureAssignment: Partitioned,
	}
}

func (aoa AllOf) Type() string {
	if aoa.signatureAssignment == Single {
		return "AllOf"
	}
	return "PartitionedAllOf"
}

func (aoa AllOf) StaticGas() uint64 {
	var totalGas uint64
	for _, auth := range aoa.SubAuthenticators {
		totalGas += auth.StaticGas()
	}
	return totalGas
}

func (aoa AllOf) Initialize(config []byte) (Authenticator, error) {
	// Decode the initialization data for each sub-authenticator
	var initDatas []sat.SubAuthenticatorInitData
	var items []subAuthDataJSON
	if err := json.Unmarshal(config, &items); err != nil {
		return nil, errorsmod.Wrapf(err, "failed to parse top-level JSON")
	}

	for _, item := range items {
		var config sat.AuthenticatorConfig
		if err := UnmarshalAuthConfig(item.Config, &config); err != nil {
			fmt.Printf("DEBUG: raw config JSON = %s\n", string(item.Config))
			return nil, errors.Wrap(err, "failed to unmarshal AuthenticatorConfig from JSON")
		}
		fmt.Printf("DEBUG: raw config JSON = %s\n", config.Data)

		initDatas = append(initDatas, sat.SubAuthenticatorInitData{
			Type:   item.Type,
			Config: &config,
		})
	}
	// case *sat.AuthenticatorConfig_ValueRaw:
	// 	fmt.Printf("DEBUG: config.Data type = *sat.AuthenticatorConfig_ValueRaw\n")
	// 	fmt.Printf("DEBUG: ValueRaw (hex) = %x\n", op.ValueRaw)
	// 	fmt.Printf("DEBUG: ValueRaw (string) = %s\n", string(op.ValueRaw))

	// 	if err := json.Unmarshal(op.ValueRaw, &initDatas); err != nil {
	// 		fmt.Printf("DEBUG: JSON unmarshal error: %v\n", err)
	// 		return nil, errorsmod.Wrap(err, "failed to parse sub-authenticators initialization data from raw ValueBytes")
	// 	}

	// 	fmt.Printf("DEBUG: Successfully unmarshaled ValueRaw -> initDatas: %+v\n", initDatas)

	// case *sat.AuthenticatorConfig_ValueString:
	// 	fmt.Printf("DEBUG: config.Data type = *sat.AuthenticatorConfig_ValueString\n")
	// 	fmt.Printf("DEBUG: ValueString = %s\n", op.ValueString)

	// 	rawBytes := []byte(op.ValueString)
	// 	fmt.Printf("DEBUG: ValueString as bytes (hex) = %x\n", rawBytes)
	// 	fmt.Printf("DEBUG: ValueString as bytes (string) = %s\n", string(rawBytes))

	// 	if err := json.Unmarshal(rawBytes, &initDatas); err != nil {
	// 		fmt.Printf("DEBUG: JSON unmarshal error: %v\n", err)
	// 		return nil, errorsmod.Wrap(err, "failed to parse sub-authenticators initialization data from ValueString")
	// 	}

	// 	fmt.Printf("DEBUG: Successfully unmarshaled ValueString -> initDatas: %+v\n", initDatas)

	// case nil:
	// 	fmt.Printf("DEBUG: config.Data is nil\n")
	// 	return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "config.Data is nil")

	// default:
	// 	fmt.Printf("DEBUG: config.Data is of unknown type: %T\n", op)
	// 	return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "fatal error initializing allOf authenticator")
	// }

	if len(initDatas) <= 1 {
		return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "allOf must have at least 2 sub-authenticators")
	}

	for _, initData := range initDatas {
		authenticatorCode := aoa.am.GetAuthenticatorByType(initData.Type)
		raw := initData.Config.GetValueRaw()
		if len(raw) == 0 {
			raw = []byte(initData.Config.GetValueString())
		}
		// transform data into bytes dependent on its type:
		fmt.Printf("DEBUG: initData.Config.GetValueRaw() = %x\n", initData.Config.GetValueRaw())
		fmt.Printf("DEBUG: initData.Config.GetValueString() = %x\n", initData.Config.GetValueString())

		instance, err := authenticatorCode.Initialize(raw)
		if err != nil {
			return nil, errorsmod.Wrapf(err, "failed to initialize sub-authenticator (type = %s)", initData.Type)
		}
		aoa.SubAuthenticators = append(aoa.SubAuthenticators, instance)
	}

	// If not all sub-authenticators are registered, return an error
	if len(aoa.SubAuthenticators) != len(initDatas) {
		return nil, errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "failed to initialize all sub-authenticators")
	}

	return aoa, nil
}

func (aoa AllOf) Authenticate(ctx sdk.Context, request AuthenticationRequest) error {
	if len(aoa.SubAuthenticators) == 0 {
		return errorsmod.Wrap(sdkerrors.ErrInvalidRequest, "no sub-authenticators provided")
	}

	var signatures [][]byte
	var err error
	if aoa.signatureAssignment == Partitioned {
		// Partitioned signatures are decoded and passed one by one as the signature of the sub-authenticator
		signatures, err = splitSignatures(request.Signature, len(aoa.SubAuthenticators))
		if err != nil {
			return err
		}
	}

	baseId := request.AuthenticatorId
	for i, auth := range aoa.SubAuthenticators {
		// update the authenticator id to include the sub-authenticator id
		request.AuthenticatorId = compositeId(baseId, i)
		// update the request to include the sub-authenticator signature
		if aoa.signatureAssignment == Partitioned {
			request.Signature = signatures[i]
		}
		if err := auth.Authenticate(ctx, request); err != nil {
			return err
		}
	}
	return nil
}

func (aoa AllOf) Track(ctx sdk.Context, request AuthenticationRequest) error {
	return subTrack(ctx, request, aoa.SubAuthenticators)
}

func (aoa AllOf) ConfirmExecution(ctx sdk.Context, request AuthenticationRequest) error {
	var signatures [][]byte
	var err error
	if aoa.signatureAssignment == Partitioned {
		// Partitioned signatures are decoded and passed one by one as the signature of the sub-authenticator
		signatures, err = splitSignatures(request.Signature, len(aoa.SubAuthenticators))
		if err != nil {
			return err
		}
	}

	baseId := request.AuthenticatorId
	for i, auth := range aoa.SubAuthenticators {
		// update the authenticator id to include the sub-authenticator id
		request.AuthenticatorId = compositeId(baseId, i)
		// update the request to include the sub-authenticator signature
		if aoa.signatureAssignment == Partitioned {
			request.Signature = signatures[i]
		}

		if err := auth.ConfirmExecution(ctx, request); err != nil {
			return err
		}
	}
	return nil
}

func (aoa AllOf) OnAuthenticatorAdded(ctx sdk.Context, account sdk.AccAddress, config []byte, authenticatorId string) error {
	return onSubAuthenticatorsAdded(ctx, account, config, authenticatorId, aoa.am)
}

func (aoa AllOf) OnAuthenticatorRemoved(ctx sdk.Context, account sdk.AccAddress, config []byte, authenticatorId string) error {
	return onSubAuthenticatorsRemoved(ctx, account, config, authenticatorId, aoa.am)
}
