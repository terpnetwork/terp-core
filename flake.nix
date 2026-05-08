{
  description = "Terp-Core blockchain dev environment — vanilla & ZK flavors";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # ── Go toolchain ────────────────────────────────────────────────
        # go.mod requires 1.24.3+ (toolchain 1.24.7)
        # nixpkgs tracks latest stable; Go >=1.24 satisfies the requirement.
        goVersion = pkgs.go;

        # ── Rust toolchain (for zk-wasmvm libwasmvm) ───────────────────
        # zk-wasmvm needs nightly for backtrace feature; vanilla doesn't
        # need Rust at all (downloads prebuilt libwasmvm from GitHub).
        rustNightly = pkgs.rust-bin.nightly.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
          targets = [
            "x86_64-unknown-linux-musl"
            "aarch64-unknown-linux-musl"
          ];
        };

        rustStable = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" ];
        };

        # ── Python (for dep-switch.py, dep-scrape.py, etc.) ────────────
        python = pkgs.python312;

        # ── Common packages for both flavors ───────────────────────────
        commonPkgs = with pkgs; [
          # Go
          goVersion
          golangci-lint
          gofumpt

          # Build essentials
          gnumake
          gcc
          pkg-config

          # Proto generation
          buf

          # Python (dep tooling)
          python

          # Cargo tools (dep-switch.py uses cargo-sort)
          cargo-sort

          # Docker (for reproducible builds)
          docker
          docker-buildx

          # Dev utilities
          jq
          curl
          wget
          git
        ];

        # ── Shared shell hook ──────────────────────────────────────────
        commonShellHook = ''
          # Project root for dep-switch.py resolution
          export TERP_CORE_ROOT="$(pwd)"
          export MONOREPO_ROOT="$(cd .. && pwd)"

          # Go workspace — disable to avoid cross-workspace confusion
          export GOWORK=off

          # Make wasmvm findable for CGo
          export CGO_ENABLED=1
        '';

      in {
        formatter = pkgs.nixfmt;

        devShells = {
          # ── Vanilla: standard terpd build ────────────────────────────
          # Uses upstream wasmvm from GitHub releases.
          # No Rust toolchain needed — Go-only dev experience.
          #
          #   nix develop .#vanilla
          #   make build
          #
          vanilla = pkgs.mkShell {
            name = "terp-vanilla";
            buildInputs = commonPkgs;

            shellHook = commonShellHook + ''
              export WASMVM_SOURCE=github
              export TERP_FLAVOR=vanilla

              echo "╔══════════════════════════════════════════╗"
              echo "║  terp-core dev shell (vanilla)           ║"
              echo "║  go:   $(go version | cut -d' ' -f3)              ║"
              echo "║  make build   — build terpd              ║"
              echo "║  make install — install to GOPATH/bin    ║"
              echo "╚══════════════════════════════════════════╝"
            '';
          };

          # ── ZK: zk-circuit flavored terpd build ──────────────────────
          # Uses local zk-wasmvm fork (../zk-wasmvm) with Halo2 proving.
          # Requires Rust nightly for libwasmvm compilation.
          #
          #   nix develop .#zk
          #   make build
          #
          zk = pkgs.mkShell {
            name = "terp-zk";
            buildInputs = commonPkgs ++ [
              rustNightly
            ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.apple-sdk_15
              pkgs.libiconv
            ];

            shellHook = commonShellHook + ''
              export WASMVM_SOURCE=local
              export TERP_FLAVOR=zk

              # Ensure go.mod points to local zk forks
              if ! grep -q '../zk-wasmvm' go.mod 2>/dev/null; then
                echo "⚠  go.mod does not replace wasmvm with ../zk-wasmvm"
                echo "   Run: go mod edit -replace github.com/CosmWasm/wasmvm/v3=../zk-wasmvm"
              fi

              echo "╔══════════════════════════════════════════╗"
              echo "║  terp-core dev shell (ZK)                ║"
              echo "║  go:     $(go version | cut -d' ' -f3)            ║"
              echo "║  rustc:  $(rustc --version | cut -d' ' -f2)              ║"
              echo "║  make build   — build terpd (zk flavor)  ║"
              echo "║  WASMVM_SOURCE=local                     ║"
              echo "╚══════════════════════════════════════════╝"
            '';
          };

          # ── Full: everything for monorepo dev + dep tooling ──────────
          # Includes Rust (for Cargo workspace ops), Python dep tooling,
          # and both flavor capabilities.
          #
          #   nix develop        (or nix develop .#default)
          #   python3 ../_scripts/dep-switch.py --mode zk_local --target all
          #
          default = pkgs.mkShell {
            name = "terp-full";
            buildInputs = commonPkgs ++ [
              rustNightly
            ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.apple-sdk_15
              pkgs.libiconv
            ];

            shellHook = commonShellHook + ''
              export TERP_FLAVOR=full

              # Default to ZK since it's the superset
              export WASMVM_SOURCE=local

              echo "╔══════════════════════════════════════════╗"
              echo "║  terp-core dev shell (full)              ║"
              echo "║  go:     $(go version | cut -d' ' -f3)            ║"
              echo "║  rustc:  $(rustc --version | cut -d' ' -f2)              ║"
              echo "║  python: $(python3 --version | cut -d' ' -f2)                 ║"
              echo "║                                          ║"
              echo "║  Flavors: nix develop .#vanilla          ║"
              echo "║           nix develop .#zk               ║"
              echo "║                                          ║"
              echo "║  Dep tooling:                            ║"
              echo "║    dep-switch --mode local --target all   ║"
              echo "║    dep-switch --mode zk_local --target all║"
              echo "╚══════════════════════════════════════════╝"
            '';
          };
        };
      }
    );
}
