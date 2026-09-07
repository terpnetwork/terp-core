package cmd

import (
	"strings"
	"testing"
)

func TestDenyPrivateStateSync(t *testing.T) {
	if err := denyPrivateStateSync(true, "statesync"); err == nil {
		t.Fatal("expected error for private + statesync")
	} else if !strings.Contains(err.Error(), "private node cannot use statesync") {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := denyPrivateStateSync(true, "snapshot"); err != nil {
		t.Fatalf("private + snapshot should be allowed: %v", err)
	}
	if err := denyPrivateStateSync(false, "statesync"); err != nil {
		t.Fatalf("public + statesync should be allowed: %v", err)
	}
}

func TestNormalizeSnapshotClass(t *testing.T) {
	cases := map[string]string{
		"":            "light",
		"light":       "light",
		"lightweight": "light",
		"pruned":      "pruned",
		"PRUNED":      "pruned",
		"prune":       "pruned",
	}
	for in, want := range cases {
		if got := normalizeSnapshotClass(in); got != want {
			t.Errorf("normalizeSnapshotClass(%q)=%q want %q", in, got, want)
		}
	}
}

func TestSnapshotJSONCandidates(t *testing.T) {
	light := snapshotJSONCandidates("morocco-1", "light")
	if len(light) == 0 || !strings.Contains(light[0], "snapshot_light.json") {
		t.Fatalf("light catalog should prefer snapshot_light.json, got %v", light)
	}
	pruned := snapshotJSONCandidates("120u-1", "pruned")
	if len(pruned) == 0 || !strings.Contains(pruned[0], "/pruned/snapshot.json") {
		t.Fatalf("pruned catalog should prefer pruned/snapshot.json, got %v", pruned)
	}
	if !strings.Contains(pruned[0], "testnet/120u-1") {
		t.Fatalf("testnet chain should use testnet path, got %v", pruned)
	}
}

func TestDefaultBootstrapConfigPrivateUsesSnapshot(t *testing.T) {
	cfg := DefaultBootstrapConfig()
	if !cfg.PrivateMode {
		t.Fatal("default should be private")
	}
	if cfg.SyncMode != "snapshot" {
		t.Fatalf("default sync-mode should be snapshot (private cannot statesync), got %q", cfg.SyncMode)
	}
	if err := denyPrivateStateSync(cfg.PrivateMode, cfg.SyncMode); err != nil {
		t.Fatalf("defaults must be a valid combo: %v", err)
	}
}
