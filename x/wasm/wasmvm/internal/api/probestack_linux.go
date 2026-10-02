//go:build linux && !sys_wasmvm

// Nightly rustc (Path A needs portable_simd) leaves __rust_probestack
// undefined in the glibc .so as well as the muslc .a. The Go/gcc final
// link has no Rust compiler_builtins to provide it, so define the same
// no-op stub muslc already ships. Linux go test links the .so, not muslc.
package api

/*
void __rust_probestack(void) {}
*/
import "C"
