//! Standalone bindings generator. Run against the compiled library to emit Swift:
//!   cargo run -p haven_ffi --bin uniffi-bindgen -- \
//!     generate --library <path-to-libhaven_ffi.dylib> --language swift --out-dir <dir>
#[cfg(not(target_arch = "wasm32"))]
fn main() {
    uniffi::uniffi_bindgen_main()
}

/// The generator runs on the build host; a browser target has nothing to generate from.
#[cfg(target_arch = "wasm32")]
fn main() {}
