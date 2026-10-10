//! The persisted engine state is written WHOLE on every export, so its encoding is the write volume.
//!
//! App Store disk-write report (2.0.0 b633, iPhone18,2): 50 MB of writes from one
//! `StatePersister.persist` path. `serde_json` rendered every byte field of the state (member
//! bundles, parked envelopes, tree commits/Welcomes, rosters, the profile card) as an array of
//! decimal numbers — ~3.6 bytes per byte, and those fields are nearly the whole file. They are now
//! base64 strings; the decimal form every earlier build wrote still loads.
//!
//! Run:
//!     cd core && cargo test -p haven_ffi --test state_size

mod common;
use common::*;

use std::sync::Arc;

use haven_ffi::HavenSocial;
use serde_json::Value;

/// The REAL 1.0.6 state (decimal byte arrays), loaded under its own identity.
fn engine_with_real_106() -> (Arc<HavenSocial>, Vec<u8>) {
    let legacy = std::fs::read(fixtures_dir().join("real_106_state.bin")).expect("real_106_state.bin present");
    let me = HavenSocial::new([1u8; 32].to_vec()).unwrap();
    assert!(me.use_device_identity([91u8; 32].to_vec()));
    me.import_state(legacy.clone());
    (me, legacy)
}

/// Any JSON array of 16+ integers in 0..=255 — a byte field written in the decimal form.
fn decimal_byte_arrays(v: &Value, path: &str, out: &mut Vec<String>) {
    match v {
        Value::Array(a) => {
            if a.len() >= 16 && a.iter().all(|x| x.as_u64().is_some_and(|n| n <= 255)) {
                out.push(path.to_string());
                return;
            }
            for (i, x) in a.iter().enumerate() {
                decimal_byte_arrays(x, &format!("{path}[{i}]"), out);
            }
        }
        Value::Object(o) => {
            for (k, x) in o {
                decimal_byte_arrays(x, &format!("{path}.{k}"), out);
            }
        }
        _ => {}
    }
}

/// Circles, names, members, events — what a reload must reproduce exactly.
fn content_view(s: &HavenSocial) -> Vec<(String, String, usize, Vec<String>)> {
    s.circles()
        .into_iter()
        .map(|c| {
            let mut ids: Vec<String> = s.feed(c.id.clone(), 10_000_000, None).into_iter().map(|f| f.id).collect();
            ids.sort();
            (c.id, c.name, c.member_count as usize, ids)
        })
        .collect()
}

#[test]
fn exported_state_writes_byte_fields_compactly() {
    let (me, legacy) = engine_with_real_106();
    let out = me.export_state();
    let v: Value = serde_json::from_slice(&out).expect("export is JSON");
    let mut decimal = Vec::new();
    decimal_byte_arrays(&v, "$", &mut decimal);
    assert!(
        decimal.is_empty(),
        "{} byte fields still written as decimal arrays, e.g. {:?}",
        decimal.len(),
        &decimal[..decimal.len().min(5)]
    );
    // 98% of the real 1.0.6 file is decimal byte arrays; base64 lands the same state under half.
    assert!(
        out.len() * 2 < legacy.len(),
        "export is {} bytes for a {}-byte decimal-form state — the same state, barely smaller",
        out.len(),
        legacy.len()
    );
}

#[test]
fn compact_state_reloads_with_exact_fidelity() {
    let (me, _) = engine_with_real_106();
    let compact = me.export_state();
    let back = HavenSocial::new([1u8; 32].to_vec()).unwrap();
    assert!(back.use_device_identity([91u8; 32].to_vec()));
    back.import_state(compact.clone());
    assert_eq!(content_view(&back), content_view(&me));
    // Byte-for-byte: every byte field survived the base64 round trip.
    assert_eq!(learned_view(&back.export_state()), learned_view(&compact));
}

/// The exported state minus what an engine mints for itself on load (its own epoch keys, circle
/// secret, cached commit, rotation stamp) — everything else must survive a reload unchanged.
fn learned_view(state: &[u8]) -> Value {
    let mut v: Value = serde_json::from_slice(state).unwrap();
    for c in v["circles"].as_array_mut().unwrap() {
        let o = c.as_object_mut().unwrap();
        for k in ["my_epoch", "my_epoch_keys", "my_epoch_keys_alt", "my_circle_secret", "cached_commit", "rotated_at"] {
            o.remove(k);
        }
    }
    v
}
