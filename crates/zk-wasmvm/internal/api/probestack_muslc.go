//go:build linux && muslc && !sys_wasmvm

package api

/*
void __rust_probestack(void) {}
*/
import "C"
