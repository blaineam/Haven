//! The Haven **client layer**: everything between the sans-IO engine (`haven_ffi::HavenSocial`) and
//! a user interface that is the same on every platform — the app wire protocol, call signaling
//! frames, and the pure policy behind relay choice and media holding.
//!
//! It began as the desktop app's backend (`desktop/src-tauri`) and is being lifted here module by
//! module so the browser build (`haven-web`) links the same code instead of a second
//! implementation. The rule for anything that moves in: it builds for `wasm32-unknown-unknown`, so
//! it owns no runtime, no filesystem and no socket. See `docs/WEB-PARITY.md`.

pub mod callwire;
pub mod mediaholding;
pub mod relayhealth;
pub mod relayintro;
pub mod relayparking;
pub mod relayscope;
pub mod secret;
pub mod wire;
