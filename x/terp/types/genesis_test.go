package types_test

import (
	"testing"

	"github.com/terpnetwork/terp-core/x/terp/types"
	"github.com/stretchr/testify/require"
)

func TestGenesisState_Validate(t *testing.T) {
	for _, tc := range []struct {
		desc     string
		genState *types.GenesisState
		valid    bool
	}{
		{
			desc:     "default is valid",
			genState: types.DefaultGenesis(),
			valid:    true,
		},
		{
			desc: "valid genesis state",
			genState: &types.GenesisState{
				TerpidList: []types.Terpid{
					{
						Id: 0,
					},
					{
						Id: 1,
					},
				},
				TerpidCount: 2,
				SupplychainList: []types.Supplychain{
					{
						Id: 0,
					},
					{
						Id: 1,
					},
				},
				SupplychainCount: 2,
				// this line is used by starport scaffolding # types/genesis/validField
			},
			valid: true,
		},
		{
			desc: "duplicated terpid",
			genState: &types.GenesisState{
				TerpidList: []types.Terpid{
					{
						Id: 0,
					},
					{
						Id: 0,
					},
				},
			},
			valid: false,
		},
		{
			desc: "invalid terpid count",
			genState: &types.GenesisState{
				TerpidList: []types.Terpid{
					{
						Id: 1,
					},
				},
				TerpidCount: 0,
			},
			valid: false,
		},
		{
			desc: "duplicated supplychain",
			genState: &types.GenesisState{
				SupplychainList: []types.Supplychain{
					{
						Id: 0,
					},
					{
						Id: 0,
					},
				},
			},
			valid: false,
		},
		{
			desc: "invalid supplychain count",
			genState: &types.GenesisState{
				SupplychainList: []types.Supplychain{
					{
						Id: 1,
					},
				},
				SupplychainCount: 0,
			},
			valid: false,
		},
		// this line is used by starport scaffolding # types/genesis/testcase
	} {
		t.Run(tc.desc, func(t *testing.T) {
			err := tc.genState.Validate()
			if tc.valid {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
			}
		})
	}
}
