//! Shared helpers for the Tier-1 core migration + regression harness.
//!
//! These integration tests exercise the SAME persist/restore + seed-drop/MLS migration surface the
//! app relies on, but ONLY through the crate's public API (no `#[cfg(test)]` internals) — so they run
//! exactly the code a shipped build runs. Everything here is deterministic: fixed 32-byte seeds, fixed
//! timestamps, no wall-clock or RNG in any assertion.

#![allow(dead_code)] // some helpers are used by only one of the two test binaries

use std::path::PathBuf;
use std::sync::Arc;

use haven_ffi::HavenSocial;

/// The engine's built-in default circle id (private `const DEFAULT_CIRCLE` in the crate). Every fresh
/// `HavenSocial` is born with this one circle; the app never renames its id.
pub const DEFAULT_CIRCLE: &str = "default";

/// A fresh primary/legacy engine seeded with `[b; 32]` — the same shape `HavenSocial::new` takes in the
/// in-crate tests, but reachable from an external test crate.
pub fn account(b: u8) -> Arc<HavenSocial> {
    HavenSocial::new(vec![b; 32]).expect("32-byte seed")
}

/// Lowercase-hex → bytes. `my_node_hex()` / `my_device_node_hex()` hand back node ids as hex, and the
/// roster signers want the raw 32 bytes; this is the only decode the harness needs.
pub fn hex_to_bytes(s: &str) -> Vec<u8> {
    data_encoding::HEXLOWER
        .decode(s.as_bytes())
        .unwrap_or_else(|_| panic!("not lowercase hex: {s}"))
}

/// Sign a v1 roster `{account, device}` for the account behind `seed`, install it on `s`, and return the
/// `(list_wire, credentials)` so a peer can `ingest_device_roster` the identical bytes. The public-API
/// twin of the in-crate `install_two_device_roster` helper (built from `sign_device_list` +
/// `issue_device_credential`, which are `pub` in `haven_ffi::multidevice`). Requires `s` to already hold
/// its device identity (`use_device_identity`) so `my_device_bundle()`/`my_device_node_hex()` are real.
pub fn install_two_device_roster(
    s: &HavenSocial,
    seed: [u8; 32],
) -> (Vec<u8>, Vec<Vec<u8>>) {
    let acct_id = hex_to_bytes(&s.my_node_hex());
    let dev_id = hex_to_bytes(&s.my_device_node_hex());
    assert_ne!(acct_id, dev_id, "device identity must be adopted before building its roster");
    let acct_cred =
        haven_ffi::multidevice::issue_device_credential(seed.to_vec(), s.my_bundle(), "primary".into(), 0)
            .unwrap();
    let dev_cred =
        haven_ffi::multidevice::issue_device_credential(seed.to_vec(), s.my_device_bundle(), "device".into(), 1)
            .unwrap();
    let list =
        haven_ffi::multidevice::sign_device_list(seed.to_vec(), 1, 0, vec![acct_id, dev_id], vec![]).unwrap();
    let creds = vec![acct_cred, dev_cred];
    assert!(s.set_my_device_roster(list.clone(), creds.clone()), "own roster installs");
    (list, creds)
}

/// A signed, five-field profile card carrying BOTH the `sd` (seed-drop) and `ml` (MLS) capability markers
/// — running it through a peer's `profile_seed_drop_version` marks the author seed-drop- AND MLS-capable,
/// the capability convergence the migration gate keys off. Mirrors the in-crate `card` helper.
pub fn capability_card(s: &HavenSocial, name: &str) -> Vec<u8> {
    s.my_signed_profile(name.into(), String::new(), String::new(), String::new(), String::new())
}

// ── Fixture files ────────────────────────────────────────────────────────────────────────────────────

/// `core/haven-ffi/tests/fixtures` — resolved from the crate manifest dir so `cargo test` finds it from
/// any working directory.
pub fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join("fixtures")
}

/// Load a committed `*.b64` fixture and base64-decode it to the raw persisted-state bytes.
pub fn load_fixture(name: &str) -> Vec<u8> {
    let path = fixtures_dir().join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("missing fixture {}: {e}\n(run: cargo test -p haven_ffi --test gen_fixtures -- --ignored --nocapture)", path.display()));
    let trimmed: String = text.split_whitespace().collect();
    data_encoding::BASE64
        .decode(trimmed.as_bytes())
        .unwrap_or_else(|e| panic!("fixture {name} is not valid base64: {e}"))
}

/// Write raw persisted-state bytes to a committed `*.b64` fixture (base64, newline-wrapped for a readable
/// diff). Used only by the `gen_fixtures` generator.
pub fn write_fixture(name: &str, bytes: &[u8]) {
    let dir = fixtures_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let b64 = data_encoding::BASE64.encode(bytes);
    let wrapped: String = b64
        .as_bytes()
        .chunks(76)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(dir.join(name), format!("{wrapped}\n")).unwrap();
}
