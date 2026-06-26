//! C-FFI over Tectonic for iTex (docs/03 §3.7).
//!
//! Two functions: compile LaTeX source → PDF bytes, and free the returned buffer. Hand-written
//! ABI (cbindgen not required for a 2-function surface). The Swift side declares the same two
//! symbols via a module map (see ../include/itex_tectonic.h).
//!
//! Caveat (carried from docs/05 §C): `latex_to_pdf` uses Tectonic's default bundle, fetched over
//! the network on first run and cached. For an offline/iOS build, switch to the V2
//! `tectonic::driver::ProcessingSessionBuilder` with a shipped local bundle + format_cache_path.

use std::os::raw::c_uchar;
use std::ptr;

/// Compile UTF-8 LaTeX `input` (length `input_len`) to PDF.
/// On success returns a heap pointer to the PDF bytes and writes the length to `out_len`;
/// the caller MUST free it with `itex_tectonic_free(ptr, len)`. Returns null on any error.
#[no_mangle]
pub extern "C" fn itex_tectonic_compile(
    input: *const c_uchar,
    input_len: usize,
    out_len: *mut usize,
) -> *mut c_uchar {
    if input.is_null() || out_len.is_null() {
        return ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(input, input_len) };
    let latex = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    match tectonic::latex_to_pdf(latex) {
        Ok(pdf) => {
            // Hand ownership to the caller as raw bytes; reclaim exact (ptr,len,cap) on free.
            let mut boxed = pdf.into_boxed_slice();
            let len = boxed.len();
            let p = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe { *out_len = len };
            p
        }
        Err(_) => {
            unsafe { *out_len = 0 };
            ptr::null_mut()
        }
    }
}

/// Free a buffer returned by `itex_tectonic_compile`.
#[no_mangle]
pub extern "C" fn itex_tectonic_free(ptr: *mut c_uchar, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        let _ = Box::from_raw(std::slice::from_raw_parts_mut(ptr, len));
    }
}
