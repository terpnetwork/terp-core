//go:build linux && !muslc && !sys_wasmvm

// The glibc .so leaves __rust_probestack undefined. Linux go test links
// that .so. The muslc archive defines the symbol, so this stub stays out
// of a muslc link.
package api

/*
void __rust_probestack(void) {}
*/
import "C"
