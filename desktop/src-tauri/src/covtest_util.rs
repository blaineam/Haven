//! Shared helpers for the coverage test modules: a throwaway data dir per test and an Engine
//! built on it from a fixed seed. Never touches the keyring or the owner's real data dir.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::engine::Engine;
use crate::store::Paths;

static N: AtomicU64 = AtomicU64::new(0);

/// Tests must never put bytes on a real network (push wake, relay HTTP). `netgate::offline()`
/// caches the env once, so set it before the first engine is built.
fn offline_once() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| std::env::set_var("HAVEN_NO_NET", "1"));
}

/// A fresh, empty `Paths` under the OS temp dir (unique per call).
pub fn tmp_paths() -> Paths {
    offline_once();
    let dir = std::env::temp_dir().join(format!(
        "haven-cov-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    Paths { base: dir.clone(), root: dir }
}

/// An engine on a fresh data dir, never started (no network).
pub fn engine(seed_byte: u8) -> (Arc<Engine>, Paths) {
    let paths = tmp_paths();
    let e = Engine::new(paths.clone(), [seed_byte; 32]).expect("engine builds");
    (e, paths)
}

/// Process environment is global, and a few tests must set variables (`HAVEN_QA_SEED_FILE`,
/// `HAVEN_DESKTOP_DATA`, `HAVEN_DEMO`). Take this for the whole of any test that does, so two of
/// them can never interleave their set/remove.
pub static ENV_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());

/// Set `key` for the duration of `f` (under [`ENV_LOCK`]) and restore the previous value after.
pub fn with_env<T>(vars: &[(&str, &str)], f: impl FnOnce() -> T) -> T {
    let _g = ENV_LOCK.lock();
    let saved: Vec<(String, Option<String>)> = vars.iter().map(|(k, _)| (k.to_string(), std::env::var(k).ok())).collect();
    for (k, v) in vars {
        std::env::set_var(k, v);
    }
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
    for (k, old) in saved {
        match old {
            Some(v) => std::env::set_var(&k, v),
            None => std::env::remove_var(&k),
        }
    }
    match out {
        Ok(v) => v,
        Err(e) => std::panic::resume_unwind(e),
    }
}

/// The import-encode bridge keeps one process-wide table of outstanding requests. Tests that raise
/// requests (or answer them wholesale) hold this for their whole body so they cannot answer each
/// other's.
pub static IGENCODE_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());
