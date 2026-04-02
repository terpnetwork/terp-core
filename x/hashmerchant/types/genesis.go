package types

// DefaultGenesis returns the default genesis state.
func DefaultGenesis() *GenesisState {
	return &GenesisState{
		Params:              DefaultParams(),
		RegisteredChains:    []RegisteredChain{},
		RegisteredContracts: []RegisteredContract{},
		EscrowRecords:       []EscrowRecord{},
		HashRoots:           []HashRoot{},
		PruneEpoch:          0,
	}
}

// Validate performs basic genesis state validation.
func (gs GenesisState) Validate() error {
	if err := gs.Params.Validate(); err != nil {
		return err
	}
	seen := make(map[string]bool)
	for _, c := range gs.RegisteredChains {
		if c.ChainUid == "" {
			return ErrInvalidChainUID.Wrap("genesis chain has empty chain_uid")
		}
		if seen[c.ChainUid] {
			return ErrChainAlreadyExists.Wrapf("duplicate chain_uid %s in genesis", c.ChainUid)
		}
		seen[c.ChainUid] = true
	}
	return nil
}
