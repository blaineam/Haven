//! The Haven **client layer**: everything between the sans-IO engine (`haven_ffi::HavenSocial`) and
//! a user interface — the app wire protocol, sync, media, relay policy, and the [`engine::Engine`]
//! that drives them.
//!
//! It began as the desktop app's backend (`desktop/src-tauri`) and is lifted here so the browser
//! build (`haven-web`) links the same code instead of a second implementation. The application
//! around it supplies a runtime ([`rt`]) and a way to reach the user ([`host`]).
//!
//! Two tiers, for now:
//! * modules that build for every target, `wasm32-unknown-unknown` included — no runtime, no
//!   filesystem, no socket;
//! * the engine and its stores, which still touch the disk, the OS keyring and the native node and
//!   are compiled only off wasm32 until those go behind seams too. See `docs/WEB-PARITY.md`.

// ── Every target ─────────────────────────────────────────────────────────────────────────────
pub mod callwire;
pub mod mediaholding;
pub mod relayhealth;
pub mod relayintro;
pub mod relayparking;
pub mod relayscope;
pub mod secret;
pub mod wire;

// ── Native only (for now) ────────────────────────────────────────────────────────────────────
#[cfg(not(target_arch = "wasm32"))]
pub mod engine;
#[cfg(not(target_arch = "wasm32"))]
pub mod host;
#[cfg(not(target_arch = "wasm32"))]
pub mod localmedia;
#[cfg(not(target_arch = "wasm32"))]
pub mod mediaresume;
#[cfg(not(target_arch = "wasm32"))]
pub mod netgate;
#[cfg(not(target_arch = "wasm32"))]
pub mod postgroups;
#[cfg(not(target_arch = "wasm32"))]
pub mod preview;
#[cfg(not(target_arch = "wasm32"))]
pub mod reoptimize;
#[cfg(not(target_arch = "wasm32"))]
pub mod roster;
#[cfg(not(target_arch = "wasm32"))]
pub mod rt;
#[cfg(not(target_arch = "wasm32"))]
pub mod scheduled;
#[cfg(not(target_arch = "wasm32"))]
pub mod seenjournal;
#[cfg(not(target_arch = "wasm32"))]
pub mod selfsync;
#[cfg(not(target_arch = "wasm32"))]
pub mod selfsyncrot;
#[cfg(not(target_arch = "wasm32"))]
pub mod store;

#[cfg(all(not(target_arch = "wasm32"), any(test, feature = "test-util")))]
pub mod covtest_util;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests_store;
