//! Standalone bindings generator. Run against the compiled library to emit Swift:
//!   cargo run -p haven_ffi --bin uniffi-bindgen -- \
//!     generate --library <path-to-libhaven_ffi.dylib> --language swift --out-dir <dir>
fn main() {
    uniffi::uniffi_bindgen_main()
}
