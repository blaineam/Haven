//! The Haven **client layer**: everything between the sans-IO engine (`haven_ffi::HavenSocial`) and
//! a user interface — the app wire protocol, sync, media, relay policy, and the [`engine::Engine`]
//! that drives them.
//!
//! It began as the desktop app's backend (`desktop/src-tauri`) and is lifted here so the browser
//! build (`haven-web`) links the same code instead of a second implementation. The application
//! around it supplies a runtime ([`rt`]) and a way to reach the user ([`host`]).
//!
//! Every module builds for every target, `wasm32-unknown-unknown` included. What differs per
//! target sits behind five seams, each the real thing natively and a browser equivalent on wasm32:
//!
//! | Seam | Native | Browser |
//! |---|---|---|
//! | [`rt`] — tasks, timers | the host's tokio runtime | the page's event loop |
//! | [`host`] — UI events, notifications | Tauri | page callbacks |
//! | [`fs`] — persistence | `std::fs` | an in-memory tree the page persists |
//! | [`secrets`] — secret store | OS keyring | a reserved corner of [`fs`] |
//! | [`transport`] / [`net`] — node, mailbox, hosting | iroh node + blob ALPN + `haven-net` | relay-only node, HTTPS mailbox, no hosting |
//!
//! See `docs/WEB-PARITY.md`.

// `commands!` walks ~140 function definitions one at a time.
#![recursion_limit = "512"]

pub mod callwire;
pub mod commands;
pub mod engine;
pub mod fs;
pub mod host;
pub mod localmedia;
pub mod mediaholding;
pub mod mediaresume;
pub mod net;
pub mod netgate;
pub mod postgroups;
pub mod preview;
pub mod relayhealth;
pub mod relayintro;
pub mod relayparking;
pub mod relayscope;
pub mod reoptimize;
pub mod roster;
pub mod rt;
pub mod scheduled;
pub mod secret;
pub mod secrets;
pub mod seenjournal;
pub mod selfsync;
pub mod selfsyncrot;
pub mod store;
pub mod transport;
pub mod wire;

#[cfg(any(test, feature = "test-util"))]
pub mod covtest_util;
#[cfg(test)]
mod tests_store;
