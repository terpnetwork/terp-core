//! Minimal rustc wasm32 guest used as a contract-toolchain fixture.
//! Built with rustc --target wasm32-unknown-unknown (1.87+). memcpy
//! is expected to lower to memory.copy / memory.fill.

#![no_std]
#![no_main]

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

/// Copy `n` bytes. rustc 1.87+ emits bulk-memory ops for this.
#[no_mangle]
pub unsafe extern "C" fn copy_buf(dst: *mut u8, src: *const u8, n: usize) {
    core::ptr::copy_nonoverlapping(src, dst, n);
}

#[no_mangle]
pub unsafe extern "C" fn fill_buf(dst: *mut u8, val: u8, n: usize) {
    core::ptr::write_bytes(dst, val, n);
}
