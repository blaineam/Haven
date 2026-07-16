//! # p2pcore — Haven's portable core
//!
//! This crate is the single source of truth for Haven's security-critical logic.
//! It compiles to:
//!   * a Swift XCFramework (via UniFFI) for the native iOS/macOS apps, and
//!   * a WASM module (via wasm-bindgen) for the static web/Android client.
//!
//! Design principle: **the transport is a dumb, swappable pipe.** The exact same
//! hybrid-post-quantum encrypted payload travels unchanged whether it goes over
//! Bluetooth, local WiFi, or a relay. Adding a transport never touches the crypto;
//! changing the crypto never touches the transport.
//!
//! ## Module map
//! * [`identity`] — a Haven account: a keypair held on-device, no PII. The public
//!   half ([`identity::HavenId`]) is also the routable node id.
//! * [`crypto`]  — hybrid post-quantum KEM (X25519 + ML-KEM-768) and AEAD
//!   (AES-256-GCM). This is what defends relayed ciphertext against
//!   "harvest-now, decrypt-later".
//! * [`link`]    — the reach-me link / QR ticket system (`haven://` and `https://`
//!   forms) with tamper-detection material kept in the URL fragment.
//! * [`transport`] — the path-selector seam: Bluetooth → local WiFi → relay.
//!   Trait-only for now; concrete impls (iroh, CoreBluetooth) land next.
//! * [`mediaref`] — media refs as content addresses, and the check that binds a
//!   blob to the ref a signed post named. Without it, whoever stores the bytes
//!   chooses what a post shows.
//! * [`treekem`] — MLS-style TreeKEM wire formats (stage M0: types + serialization
//!   only, nothing consumes them yet). See `docs/TREEKEM-DESIGN.md`.

pub mod crypto;
pub mod device;
pub mod groupkey;
pub mod identity;
pub mod link;
pub mod mediaref;
pub mod selfsync;
pub mod social;
pub mod transport;
pub mod treekem;

/// One error type for the whole core so the FFI surface stays small.
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("crypto failure: {0}")]
    Crypto(&'static str),
    #[error("malformed link: {0}")]
    BadLink(&'static str),
    #[error("encoding error: {0}")]
    Encoding(&'static str),
}

pub type Result<T> = std::result::Result<T, CoreError>;
