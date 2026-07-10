//! Multi-device **self-sync** for the desktop backend (roadmap D16, Phase 3 — client wiring).
//!
//! Direct port of the iOS `SelfSync.swift` coordinator. Makes a user's OWN devices converge:
//! each device writes a self-encrypted snapshot of its account state to a per-account mailbox
//! slot it owns, and merges its peers' slots. The CRDT itself lives in [`p2pcore::selfsync`]
//! (last-write-wins per key); the relay/S3 only ever holds ciphertext sealed with
//! [`p2pcore::identity::Identity::self_sync_key`] — a key only this account's devices can derive.
//!
//! Scope (must match iOS byte-for-byte cross-platform): PROFILE (name/emoji/bio/link), GLOBAL
//! SETTINGS (retention, host-on-launch), CONTACTS, the BLOCKED list, and CIRCLES (name + member
//! bundles + relay nodes). Profile/setting/blocked/circle values are byte-identical to iOS; the
//! `contact:` value is each platform's own (the Contact structs differ) but stable per-platform.
//!
//! This module holds the **pure** pieces — the device-id, the CRDT key/value mapping, and the
//! deterministic circle encoding. The networked coordinator (`Engine::poll_self_sync`) lives in
//! `engine.rs` because it needs the engine's private transport internals.

use std::collections::BTreeMap;

use crate::store::{Contact, Paths, Prefs};
use haven_ffi::multidevice::{decode_circle_sync, encode_circle_sync};
use haven_ffi::HavenSocial;

/// Load (or first-time generate) this device's stable 32-byte self-sync id. All of a user's
/// devices share the account seed (same node id), so each physical device needs its own id to
/// own a sync slot and to break LWW ties. Random, generated once, stored device-local in the
/// Paths dir (`selfsync-device.bin`), and NEVER synced.
pub fn device_id(paths: &Paths) -> [u8; 32] {
    let path = paths.selfsync_device_file();
    if let Ok(bytes) = std::fs::read(&path) {
        if bytes.len() == 32 {
            let mut id = [0u8; 32];
            id.copy_from_slice(&bytes);
            return id;
        }
    }
    let mut id = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut id);
    let _ = std::fs::write(&path, id);
    id
}

/// Namespaces whose keys are dynamic (set-like) — used to detect LOCAL removals so they
/// propagate as tombstones (unblock, delete contact, leave a circle). Scalar namespaces
/// (`profile:`/`setting:`) are always present, so they're never spuriously removed.
pub const DYNAMIC_PREFIXES: [&str; 3] = ["contact:", "blocked:", "circle:"];

/// The current local state as namespaced key → value bytes (no stamps). `prefs` contributes
/// profile/settings/contacts/blocked; `social` contributes the circle structure (name + member
/// bundles + relay nodes pulled from `prefs.relays`).
pub fn current_local(prefs: &Prefs, social: &HavenSocial) -> BTreeMap<String, Vec<u8>> {
    let mut m: BTreeMap<String, Vec<u8>> = BTreeMap::new();

    // Profile (UTF-8 bytes).
    m.insert("profile:name".into(), prefs.profile.name.clone().into_bytes());
    m.insert("profile:emoji".into(), prefs.profile.emoji.clone().into_bytes());
    m.insert("profile:bio".into(), prefs.profile.bio.clone().into_bytes());
    m.insert("profile:link".into(), prefs.profile.link.clone().into_bytes());

    // Global settings. retention as u64 LE (None = 0 = keep all); host-on-launch as a 1-byte flag.
    let retention = prefs.retention_secs.unwrap_or(0);
    m.insert("setting:retention".into(), retention.to_le_bytes().to_vec());
    m.insert("setting:host_on_launch".into(), vec![if prefs.host_on_launch { 1 } else { 0 }]);

    // DM read watermarks — reading a thread on one device clears its badge on the others. JSON map
    // circleId → unix-ms (the iOS/Android wire format), merged per-key MAX on apply: monotonic, so
    // no device can un-read another, and a fresh device's empty map changes nothing. Only published
    // when non-empty so a fresh device can't blank a sibling's map.
    if !prefs.dm_last_read.is_empty() {
        if let Ok(data) = serde_json::to_vec(&prefs.dm_last_read) {
            m.insert("setting:dmLastRead".into(), data);
        }
    }

    // Roster: contacts (full card, deterministic serde) + blocked list (marker).
    for c in &prefs.contacts {
        if let Ok(data) = serde_json::to_vec(c) {
            m.insert(format!("contact:{}", c.id_hex), data);
        }
    }
    for hex in &prefs.blocked {
        m.insert(format!("blocked:{hex}"), vec![1]);
    }

    // Explicit circle severances — LWW per entry: 1 = removed, 0 = deliberately re-added. The 0
    // write is what lets a re-add stick fleet-wide (grow-only removals re-severed a re-added
    // friend on every sibling sync pass). Never inferred from member absence.
    for entry in &prefs.circle_removals {
        m.insert(format!("removal:{entry}"), vec![1]);
    }
    for entry in &prefs.circle_removals_cleared {
        m.insert(format!("removal:{entry}"), vec![0]);
    }

    // Circles: name + member bundles + relay nodes, so another device can reconstruct each circle
    // and seal to every member. Encoded via the shared FFI encoder so the bytes are byte-identical
    // to iOS/Android (it base64's the RAW bundles, sorts members/relays, alphabetical-key JSON).
    for ci in social.circles() {
        // Skip DM pseudo-circles — they reconstruct from the contact pair, not from sync.
        if ci.id.starts_with("dm:") {
            continue;
        }
        let member_bundles = social.circle_member_bundles(ci.id.clone());
        let mut relays: Vec<String> = prefs.relays.get(&ci.id).cloned().unwrap_or_default();
        relays.sort();
        relays.dedup();
        let data = encode_circle_sync(ci.name.clone(), member_bundles, relays);
        if !data.is_empty() {
            m.insert(format!("circle:{}", ci.id), data);
        }
    }

    // Contact device ROSTERS — so a freshly-linked device (e.g. a new PC) learns which device ids to
    // DIAL/seal for each friend directly from a sibling that already knows them, instead of dialing dead
    // account ids and timing out. Keyed by account hex so a newer roster version replaces the old.
    // Additive (never tombstoned); the wire is verified + version-checked in the engine on ingest.
    for r in social.export_contact_rosters() {
        m.insert(format!("roster:{}", r.account_hex), r.wire);
    }

    m
}

/// Decode a stored `setting:host_on_launch` (or any 1-byte bool marker) value.
fn bool_value(v: &[u8]) -> Option<bool> {
    v.first().map(|b| *b == 1)
}

/// Apply a converged `AccountState` back into the local stores. Mutates `prefs` + `social`
/// in place, and ONLY where a value actually differs (avoid churn / feedback loops). Returns
/// `true` if anything local changed (so the caller persists + emits `haven:changed`).
///
/// `entries` is the converged state's live `(key, value)` pairs (already collected so the caller
/// can drop the borrow on the CRDT before locking the prefs/social mutexes).
pub fn apply_local(
    entries: &[(String, Vec<u8>)],
    prefs: &mut Prefs,
    social: &HavenSocial,
) -> bool {
    let mut changed = false;

    // Helper closures over `entries`.
    let get = |key: &str| -> Option<&[u8]> {
        entries.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_slice())
    };

    // Profile (UTF-8).
    macro_rules! apply_str {
        ($key:expr, $field:expr) => {
            if let Some(v) = get($key) {
                if let Ok(s) = std::str::from_utf8(v) {
                    if s != $field {
                        $field = s.to_string();
                        changed = true;
                    }
                }
            }
        };
    }
    apply_str!("profile:name", prefs.profile.name);
    apply_str!("profile:emoji", prefs.profile.emoji);
    apply_str!("profile:bio", prefs.profile.bio);
    apply_str!("profile:link", prefs.profile.link);

    // Settings.
    if let Some(v) = get("setting:retention") {
        if v.len() == 8 {
            let mut a = [0u8; 8];
            a.copy_from_slice(v);
            let n = u64::from_le_bytes(a);
            let want = if n == 0 { None } else { Some(n) };
            if want != prefs.retention_secs {
                prefs.retention_secs = want;
                changed = true;
            }
        }
    }
    if let Some(v) = get("setting:host_on_launch") {
        if let Some(b) = bool_value(v) {
            if b != prefs.host_on_launch {
                prefs.host_on_launch = b;
                changed = true;
            }
        }
    }
    // DM read watermarks from my other devices: per-key MAX merge (monotonic — always safe).
    if let Some(v) = get("setting:dmLastRead") {
        if let Ok(m) = serde_json::from_slice::<BTreeMap<String, u64>>(v) {
            for (k, ts) in m {
                if ts > prefs.dm_last_read.get(&k).copied().unwrap_or(0) {
                    prefs.dm_last_read.insert(k, ts);
                    changed = true;
                }
            }
        }
    }

    // Contacts: upsert everything present; drop locals the converged state no longer has
    // (a contact deleted on another device propagated as a tombstone).
    let mut want_contacts: BTreeMap<String, Contact> = BTreeMap::new();
    for (k, v) in entries {
        if let Some(_id) = k.strip_prefix("contact:") {
            if let Ok(c) = serde_json::from_slice::<Contact>(v) {
                want_contacts.insert(c.id_hex.clone(), c);
            }
        }
    }
    // Upsert.
    for c in want_contacts.values() {
        match prefs.contacts.iter_mut().find(|x| x.id_hex == c.id_hex) {
            Some(existing) => {
                if existing.name != c.name || existing.verify_hex != c.verify_hex {
                    existing.name = c.name.clone();
                    existing.verify_hex = c.verify_hex.clone();
                    changed = true;
                }
            }
            None => {
                prefs.contacts.push(c.clone());
                changed = true;
            }
        }
    }
    // ADDITIVE ONLY — never drop a contact a peer simply doesn't list. Absence-based removal made a
    // freshly-restored (empty) device wipe the primary's contacts/circles/posts (the iOS/Android
    // data-loss bug). Real deletions must propagate as explicit records, not be inferred from absence.

    // Blocked list: reconcile both directions.
    let mut want_blocked: Vec<String> = entries
        .iter()
        .filter_map(|(k, _)| k.strip_prefix("blocked:").map(|h| h.to_string()))
        .collect();
    want_blocked.sort();
    want_blocked.dedup();
    // Add the missing.
    for hex in &want_blocked {
        if !prefs.blocked.contains(hex) {
            prefs.blocked.push(hex.clone());
            changed = true;
        }
    }
    // Remove the extra.
    let before = prefs.blocked.len();
    prefs.blocked.retain(|h| want_blocked.contains(h));
    if prefs.blocked.len() != before {
        changed = true;
    }

    // Contact rosters synced from another of our devices → ingest so THIS device can also dial + seal to
    // each friend's CURRENT devices (verified against the account bundle carried inside the wire). This is
    // what lets a freshly-linked PC reach friends it never contacted directly — it inherits their device
    // ids from a sibling. Idempotent + version-checked in the engine, so a stale roster can't roll back.
    for (k, v) in entries {
        if k.starts_with("roster:") {
            let _ = social.ingest_roster_wire(v.clone());
        }
    }

    // Explicit circle severances synced from our other devices: value 1 → record locally so the
    // member isn't re-registered below + apply the removal to the circle here too. Value 0 → the
    // removal was deliberately CLEARED (re-added) on another device: un-ban locally and never
    // re-sever; the member bundle comes back via the additive circle: record.
    for (k, v) in entries {
        let Some(entry) = k.strip_prefix("removal:") else { continue };
        if v.first() == Some(&0) {
            if prefs.circle_removals.iter().any(|e| e == entry) {
                prefs.circle_removals.retain(|e| e != entry);
                if !prefs.circle_removals_cleared.iter().any(|e| e == entry) {
                    prefs.circle_removals_cleared.push(entry.to_string());
                }
                changed = true;
            }
            continue;
        }
        if !prefs.circle_removals.iter().any(|e| e == entry) {
            prefs.circle_removals.push(entry.to_string());
            prefs.circle_removals_cleared.retain(|e| e != entry);
            changed = true;
        }
        if let Some((cid, hex)) = entry.split_once('|') {
            social.remove_from_circle(cid.to_string(), hex.to_string());
        }
    }

    // Circles: reconstruct each synced circle — create it + register every member's bundle so this
    // device can seal to them, and record its relay mailbox(es). STRICTLY ADDITIVE (no absence-based
    // member-prune or circle-leave — that wiped accounts on a freshly-restored device).
    let existing: Vec<(String, String)> =
        social.circles().into_iter().map(|c| (c.id, c.name)).collect();
    for (k, v) in entries {
        let Some(id) = k.strip_prefix("circle:") else { continue };
        let Some(cs) = decode_circle_sync(v.clone()) else { continue };
        match existing.iter().find(|(cid, _)| cid == id) {
            None => {
                social.create_circle(id.to_string(), cs.name.clone());
                changed = true;
            }
            Some((_, cur_name)) => {
                if *cur_name != cs.name {
                    social.rename_circle(id.to_string(), cs.name.clone());
                    changed = true;
                }
            }
        }
        // Register every synced member bundle so this device can seal to them. ADDITIVE — we never
        // remove a member just because a peer's record doesn't list them — but we DO skip anyone we've
        // explicitly severed (anti-reinflation).
        let prefix = format!("{id}|");
        let removed_here: Vec<String> = prefs
            .circle_removals
            .iter()
            .filter_map(|e| e.strip_prefix(&prefix).map(|h| h.to_string()))
            .collect();
        for bundle in &cs.member_bundles {
            let node_hex = p2pcore::identity::HavenId::from_bytes(bundle)
                .ok()
                .map(|hid| hex::encode(hid.node_id_bytes()))
                .unwrap_or_default();
            if !node_hex.is_empty() && removed_here.iter().any(|h| h == &node_hex) {
                continue; // severed — never re-add
            }
            let _ = social.add_contact_bundle(id.to_string(), bundle.clone());
        }
        if !cs.relays.is_empty() {
            let suppressed = prefs.suppressed_relays.clone();
            let list = prefs.relays.entry(id.to_string()).or_default();
            for node in &cs.relays {
                if !list.contains(node) && !suppressed.contains(node) {
                    list.push(node.clone());
                    changed = true;
                }
            }
        }
    }
    // (No absence-based circle leaving — a circle missing from a peer's slot is NOT a signal to leave
    // it; that destroyed accounts on a freshly-restored device. Explicit leave is intentional only.)
    let _ = &existing;

    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_circle_encoder_is_deterministic_and_alphabetical_and_round_trips() {
        // The desktop now defers to the shared FFI encoder for byte-parity with iOS/Android.
        // Raw bundle bytes (the encoder base64's them itself): 0xAA0001 -> "qgAB", 0x000102 -> "AAEC".
        let bundles = vec![vec![0xAAu8, 0x00, 0x01], vec![0x00u8, 0x01, 0x02]];
        let bytes = encode_circle_sync("Home".into(), bundles.clone(), vec!["node1".into()]);
        let json = String::from_utf8(bytes.clone()).unwrap();
        // Alphabetical keys, sorted base64 members ("AAEC" < "qgAB"), matching iOS sortedKeys.
        assert_eq!(json, r#"{"members":["AAEC","qgAB"],"name":"Home","relays":["node1"]}"#);
        // Round-trips back to the same raw bundle bytes (order-independent set membership).
        let rec = decode_circle_sync(bytes).unwrap();
        assert_eq!(rec.name, "Home");
        assert_eq!(rec.relays, vec!["node1".to_string()]);
        assert!(rec.member_bundles.contains(&bundles[0]));
        assert!(rec.member_bundles.contains(&bundles[1]));
    }

    #[test]
    fn dynamic_prefixes_cover_contact_blocked_and_circle() {
        assert!(DYNAMIC_PREFIXES.contains(&"contact:"));
        assert!(DYNAMIC_PREFIXES.contains(&"blocked:"));
        assert!(DYNAMIC_PREFIXES.contains(&"circle:"));
    }
}
