//! Multi-device **self-sync** for the desktop backend (roadmap D16, Phase 3 — client wiring).
//!
//! Direct port of the iOS `SelfSync.swift` coordinator. Makes a user's OWN devices converge:
//! each device writes a self-encrypted snapshot of its account state to a per-account mailbox
//! slot it owns, and merges its peers' slots. The CRDT itself lives in [`haven_p2p::selfsync`]
//! (last-write-wins per key); the relay/S3 only ever holds ciphertext sealed with
//! [`haven_p2p::identity::Identity::self_sync_key`] — a key only this account's devices can derive.
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

    // Profile (UTF-8 bytes). Only broadcast NON-EMPTY scalars: a fresh/empty device must never stamp a
    // blank value that then wins last-writer-wins and REVERTS a sibling's real profile (absence is not
    // authoritative). Mirrors iOS SelfSync.currentLocal.
    if !prefs.profile.name.is_empty() {
        m.insert("profile:name".into(), prefs.profile.name.clone().into_bytes());
    }
    if !prefs.profile.emoji.is_empty() {
        m.insert("profile:emoji".into(), prefs.profile.emoji.clone().into_bytes());
    }
    if !prefs.profile.bio.is_empty() {
        m.insert("profile:bio".into(), prefs.profile.bio.clone().into_bytes());
    }
    if !prefs.profile.link.is_empty() {
        m.insert("profile:link".into(), prefs.profile.link.clone().into_bytes());
    }
    // Profile photo (small base64 image) — so a freshly-linked device gets the avatar too, not just
    // the name/bio. Mirrors iOS SelfSync `profile:avatar`.
    if !prefs.profile.avatar.is_empty() {
        m.insert("profile:avatar".into(), prefs.profile.avatar.clone().into_bytes());
    }
    // LWW timestamps per profile field — so two of my devices resolve a profile edit by WHO EDITED LAST,
    // not who synced last (the endless profile ping-pong). See store::Prefs::profile_field_ts.
    for field in ["name", "emoji", "bio", "link", "avatar"] {
        let ts = prefs.profile_field_stamp(field);
        if ts > 0 {
            m.insert(format!("profile-at:{field}"), ts.to_le_bytes().to_vec());
        }
    }

    // Global settings. retention as u64 LE (None = 0 = keep all); host-on-launch as a 1-byte flag.
    let retention = prefs.retention_secs.unwrap_or(0);
    m.insert("setting:retention".into(), retention.to_le_bytes().to_vec());
    // …and the CROSS-PLATFORM shape iOS/Android publish: `setting:retentionDays` as Int32 LE DAYS.
    // The legacy `setting:retention` (u64 LE seconds) was a desktop-only key the phones never read,
    // so a retention change made here silently never reached them (and theirs never landed here) —
    // the key mismatch. Both are emitted; `retentionDays` is preferred on apply.
    let retention_days = (retention / 86_400) as i32;
    m.insert("setting:retentionDays".into(), retention_days.to_le_bytes().to_vec());
    m.insert("setting:host_on_launch".into(), vec![if prefs.host_on_launch { 1 } else { 0 }]);
    // LWW timestamps for the synced settings — so two devices resolve a settings change by WHO CHANGED it
    // last, not who synced last (the same ping-pong that hit profiles). See store::Prefs::setting_ts.
    for key in ["retention", "host_on_launch"] {
        let ts = prefs.setting_stamp(key);
        if ts > 0 {
            m.insert(format!("setting-at:{key}"), ts.to_le_bytes().to_vec());
        }
    }
    // The retention stamp under the key iOS/Android read it from (their `tsKeyRet` is the literal
    // UserDefaults key), so a change made here wins/loses LWW correctly on the phones too.
    let ret_ts = prefs.setting_stamp("retention");
    if ret_ts > 0 {
        m.insert("setting-at:haven.retentionDays".into(), ret_ts.to_le_bytes().to_vec());
    }

    // Pinned DM conversations (ordered) sync across my devices, last-writer-wins. Only broadcast
    // when non-empty so a fresh device can't blank a sibling's pins (absence ≠ authoritative).
    if !prefs.pinned_dms.is_empty() {
        m.insert("setting:pinnedDMs".into(), prefs.pinned_dms.join("\n").into_bytes());
    }

    // Activity-list read watermark — per-key MAX on apply (monotonic, same rule as dmLastRead), so
    // opening the bell on one device clears the badge on the others. 8-byte LE ms.
    if prefs.activity_seen_at > 0 {
        m.insert("setting:activitySeenAt".into(), prefs.activity_seen_at.to_le_bytes().to_vec());
    }

    // DM read watermarks — reading a thread on one device clears its badge on the others. JSON map
    // circleId → unix-ms (the iOS/Android wire format), merged per-key MAX on apply: monotonic, so
    // no device can un-read another, and a fresh device's empty map changes nothing. Only published
    // when non-empty so a fresh device can't blank a sibling's map.
    if !prefs.dm_last_read.is_empty() {
        if let Ok(data) = serde_json::to_vec(&prefs.dm_last_read) {
            m.insert("setting:dmLastRead".into(), data);
        }
    }

    // Stories kept to my profile. Carries its OWN per-entry timestamps and tombstones INSIDE the
    // payload, so it merges rather than last-writer-wins: keeping story A on my phone and story B
    // here must end with BOTH kept, and un-keeping must not be undone by a sibling's stale copy.
    // Only published when non-empty so a fresh device can't blank a sibling's collection.
    if !prefs.kept_stories.is_empty() || !prefs.kept_stories_removed.is_empty() {
        if let Ok(data) = serde_json::to_vec(&crate::store::KeptStoriesWire {
            kept: prefs.kept_stories.clone(),
            removed: prefs.kept_stories_removed.clone(),
        }) {
            m.insert("setting:keptStories".into(), data);
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

    // Contact removals — LWW by timestamp (contacts sync additive-only, so a delete needs an explicit
    // newest-wins tombstone to stick fleet-wide). 8-byte LE ms per hex. Mirrors iOS.
    for (hex, ms) in &prefs.contact_removed_at {
        m.insert(format!("contact-removed:{hex}"), ms.to_le_bytes().to_vec());
    }
    for (hex, ms) in &prefs.contact_readded_at {
        m.insert(format!("contact-readd:{hex}"), ms.to_le_bytes().to_vec());
    }
    // Whole-circle / DM deletions — LWW, so deleting a DM/circle on one device deletes it on all of them
    // instead of a sibling's `circle:` record re-creating it. 8-byte LE ms per circle id. Mirrors iOS.
    for (id, ms) in &prefs.circle_deleted_at {
        m.insert(format!("circle-deleted:{id}"), ms.to_le_bytes().to_vec());
    }
    for (id, ms) in &prefs.circle_recreated_at {
        m.insert(format!("circle-recreated:{id}"), ms.to_le_bytes().to_vec());
    }

    // Explicit circle severances — LWW by TIMESTAMP so a fresh removal beats a stale re-add and vice
    // versa (the fix for "removals don't sync / re-adds get re-severed"). Two distinct keys carry their
    // own 8-byte LE ms, resolved newest-wins on apply. Also still emit the legacy `removal:` = 1/0
    // (derived from the current verdict) so a pre-LWW sibling keeps converging during the rollout — those
    // carry no time, so a new build treats them as ts=1 and they never override a real write.
    for (entry, ms) in &prefs.circle_removed_at {
        m.insert(format!("circle-removed:{entry}"), ms.to_le_bytes().to_vec());
    }
    for (entry, ms) in &prefs.circle_readded_at {
        m.insert(format!("circle-readd:{entry}"), ms.to_le_bytes().to_vec());
    }
    let mut removal_keys: std::collections::BTreeSet<&String> = prefs.circle_removed_at.keys().collect();
    removal_keys.extend(prefs.circle_readded_at.keys());
    for entry in removal_keys {
        // legacy compat: 1 = currently removed, 0 = currently re-added (newest verdict).
        let val = if prefs.is_circle_member_removed(entry) { 1u8 } else { 0u8 };
        m.insert(format!("removal:{entry}"), vec![val]);
    }

    // Relay DELETIONS + RE-ADDS — LWW per relay across my own devices. Deleting a relay on one device
    // must drop it on all of them (and stop a sibling re-announcing it), and a stale re-add must NOT
    // resurrect a relay the user has since deleted. `relay-removal:<hex>` carries the 8-byte forget ms;
    // `relay-readd:<hex>` carries the 8-byte re-add ms (its OWN timestamp, NOT a bare 0). On apply the
    // newest of the two wins per relay. Mirrors iOS SelfSync `relay-removal:` / `relay-readd:`.
    for (hex, ms) in &prefs.forgot_at_relays {
        m.insert(format!("relay-removal:{hex}"), ms.to_le_bytes().to_vec());
    }
    for (hex, ms) in &prefs.cleared_relay_forgets {
        m.insert(format!("relay-readd:{hex}"), ms.to_le_bytes().to_vec());
    }

    // Circles: name + member bundles + relay nodes, so another device can reconstruct each circle
    // and seal to every member. Encoded via the shared FFI encoder so the bytes are byte-identical
    // to iOS/Android (it base64's the RAW bundles, sorts members/relays, alphabetical-key JSON).
    // Switch-Flip 1.0.7 §2: carry the circle CREATOR (authority root) along this AUTHENTICATED
    // circle-sync record so another of my devices / a shared-circle peer can pin it. I only assert it
    // for circles I OWN (the ones I created + the default "My Circle"); nil otherwise — the real
    // creator's own export carries it, and absence never fabricates a creator.
    let my_creator: Option<Vec<u8>> = {
        let hex = social.my_node_hex();
        if hex.len() == 64 {
            (0..32).map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()).collect()
        } else {
            None
        }
    };
    for ci in social.circles() {
        // DM pseudo-circles are INCLUDED (iOS/Android parity): a DM's structure does reconstruct
        // from the contact pair, but only once THIS device knows the partner — a freshly-linked
        // device doesn't, so skipping them here left its Messages tab empty until every partner
        // happened to re-handshake. The `circle:` record carries the pair's bundles either way.
        // Don't re-broadcast a circle the user DELETED (LWW): its `circle-deleted:` record carries the
        // deletion, and re-emitting the `circle:` row would fight it every sync.
        if prefs.is_circle_deleted(&ci.id) {
            continue;
        }
        let member_bundles = social.circle_member_bundles(ci.id.clone());
        let mut relays: Vec<String> = prefs.relays.get(&ci.id).cloned().unwrap_or_default();
        relays.sort();
        relays.dedup();
        let creator = if prefs.created_circles.iter().any(|c| c == &ci.id) || ci.id == "default" {
            my_creator.clone()
        } else {
            None
        };
        let data = encode_circle_sync(ci.name.clone(), member_bundles, relays, creator);
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
    // My OWN device roster — fixes the own-device bootstrap deadlock (a sibling device that's never
    // nearby and shares no relay never learned THIS device's id, so its relay rejected us with ERR
    // forbidden and our relay-deletion tombstones never propagated). Shares the roster: namespace so
    // the ingest loop union-merges our device id into the sibling's own-account list.
    for r in social.export_own_roster() {
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

    // Read an 8-byte LE ms timestamp for a key (0 if absent / malformed).
    let ts_of = |key: &str| -> u64 {
        get(key)
            .filter(|v| v.len() == 8)
            .map(|v| {
                let mut a = [0u8; 8];
                a.copy_from_slice(v);
                u64::from_le_bytes(a)
            })
            .unwrap_or(0)
    };

    // Profile fields are LAST-WRITER-WINS by per-field timestamp — a remote value is applied only if it
    // was edited MORE RECENTLY than our local one (ends the endless ping-pong where two devices each
    // thought "my non-empty value wins"). An untimestamped legacy value maps to ts=1 (barely > 0) ONLY to
    // SEED an empty local field; it never overwrites a non-empty local. A real local edit (ts=now) always
    // wins over this. Mirrors iOS SelfSync.applyLocal.
    for (field, local_val) in [
        ("name", &prefs.profile.name.clone()),
        ("emoji", &prefs.profile.emoji.clone()),
        ("bio", &prefs.profile.bio.clone()),
        ("link", &prefs.profile.link.clone()),
    ] {
        let Some(v) = get(&format!("profile:{field}")) else { continue };
        let Ok(s) = std::str::from_utf8(v) else { continue };
        // emoji always has a default, so an empty remote never applies (only a timestamped remote overrides).
        if field == "emoji" && s.is_empty() {
            continue;
        }
        let local_ts = prefs.profile_field_stamp(field);
        let mut ts = ts_of(&format!("profile-at:{field}"));
        if ts == 0 && local_ts == 0 && local_val.is_empty() && !s.is_empty() {
            ts = 1; // seed an empty local field from a legacy (untimestamped) sibling
        }
        if ts > local_ts && s != local_val.as_str() {
            match field {
                "name" => prefs.profile.name = s.to_string(),
                "emoji" => prefs.profile.emoji = s.to_string(),
                "bio" => prefs.profile.bio = s.to_string(),
                "link" => prefs.profile.link = s.to_string(),
                _ => {}
            }
            prefs.profile_field_ts.insert(field.to_string(), ts);
            changed = true;
        }
    }
    // Avatar rides the same per-field LWW as the text fields (base64 payload, so it's handled
    // outside the loop above rather than growing a String clone of a photo per pass).
    if let Some(v) = get("profile:avatar") {
        if let Ok(s) = std::str::from_utf8(v) {
            let local_ts = prefs.profile_field_stamp("avatar");
            let mut ts = ts_of("profile-at:avatar");
            if ts == 0 && local_ts == 0 && prefs.profile.avatar.is_empty() && !s.is_empty() {
                ts = 1; // seed an avatar-less local from a legacy (untimestamped) sibling
            }
            if ts > local_ts && s != prefs.profile.avatar {
                prefs.profile.avatar = s.to_string();
                prefs.profile_field_ts.insert("avatar".into(), ts);
                changed = true;
            }
        }
    }

    // Settings are LWW by per-key timestamp — same fix as profiles. A remote value only wins if it was
    // changed more recently than ours; an untimestamped legacy record (old peer) maps to ts=1 so it seeds
    // a never-touched device but can never overwrite a real local edit. Mirrors iOS SelfSync.applyLocal.
    let setting_ts_of = |key: &str| -> u64 {
        let t = ts_of(&format!("setting-at:{key}"));
        if t == 0 {
            1
        } else {
            t
        }
    };
    // Retention: PREFER the cross-platform `setting:retentionDays` (Int32 LE days — what iOS and
    // Android publish) and only fall back to the legacy desktop-only `setting:retention` (u64 LE
    // seconds) when a fleet has no modern writer yet. Reading only the legacy key was the mismatch
    // that kept a phone's retention change from ever landing here. The stamp is the max of the
    // desktop key and the phones' `setting-at:haven.retentionDays`.
    {
        let want: Option<Option<u64>> = if let Some(v) = get("setting:retentionDays") {
            (v.len() == 4).then(|| {
                let mut a = [0u8; 4];
                a.copy_from_slice(v);
                let days = i32::from_le_bytes(a);
                if days <= 0 { None } else { Some(days as u64 * 86_400) }
            })
        } else if let Some(v) = get("setting:retention") {
            (v.len() == 8).then(|| {
                let mut a = [0u8; 8];
                a.copy_from_slice(v);
                let n = u64::from_le_bytes(a);
                if n == 0 { None } else { Some(n) }
            })
        } else {
            None
        };
        if let Some(want) = want {
            let ts = setting_ts_of("retention").max(ts_of("setting-at:haven.retentionDays"));
            if ts > prefs.setting_stamp("retention") && want != prefs.retention_secs {
                prefs.retention_secs = want;
                prefs.setting_ts.insert("retention".into(), ts);
                changed = true;
            }
        }
    }
    if let Some(v) = get("setting:host_on_launch") {
        if let Some(b) = bool_value(v) {
            let ts = setting_ts_of("host_on_launch");
            if ts > prefs.setting_stamp("host_on_launch") && b != prefs.host_on_launch {
                prefs.host_on_launch = b;
                prefs.setting_ts.insert("host_on_launch".into(), ts);
                changed = true;
            }
        }
    }
    // Pinned DMs from my other devices — last-writer-wins wholesale (the value is one small ordered
    // list, so per-entry merging would just interleave two orders nobody chose). Mirrors iOS
    // `DMPinStore.applySynced`.
    if let Some(v) = get("setting:pinnedDMs") {
        if let Ok(s) = std::str::from_utf8(v) {
            let ids: Vec<String> =
                s.split('\n').filter(|l| !l.is_empty()).take(6).map(str::to_string).collect();
            if !ids.is_empty() && ids != prefs.pinned_dms {
                prefs.pinned_dms = ids;
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
    // Activity-list read watermark: per-key MAX (monotonic — a device can only mark MORE read, and
    // a fresh device's 0 changes nothing), same rule as dmLastRead.
    {
        let ts = ts_of("setting:activitySeenAt");
        if ts > prefs.activity_seen_at {
            prefs.activity_seen_at = ts;
            changed = true;
        }
    }

    // Kept stories: per-entry LWW with tombstones, resolved inside the merge (which also pins the
    // media of newly-arrived entries, or a story kept on a sibling would sync in and then be
    // reclaimed by this device's cleanup sweeps).
    if let Some(v) = get("setting:keptStories") {
        if prefs.merge_kept_stories(v) {
            changed = true;
        }
    }

    // Contact removals — LWW by timestamp, applied BEFORE the upsert so a removed contact is tombstoned
    // and the upsert refuses to resurrect them (contacts are otherwise additive-only, which is exactly
    // why deletes never stuck on a multi-device account). Newest of removed-vs-readd wins per hex.
    // Mirrors iOS SelfSync.applyLocal.
    {
        let mut removed_ms: BTreeMap<String, u64> = BTreeMap::new();
        let mut readd_ms: BTreeMap<String, u64> = BTreeMap::new();
        for (k, v) in entries {
            if v.len() != 8 {
                continue;
            }
            let mut a = [0u8; 8];
            a.copy_from_slice(v);
            let n = u64::from_le_bytes(a);
            if let Some(hex) = k.strip_prefix("contact-removed:") {
                if !hex.is_empty() {
                    let e = removed_ms.entry(hex.to_string()).or_insert(0);
                    *e = (*e).max(n);
                }
            } else if let Some(hex) = k.strip_prefix("contact-readd:") {
                if !hex.is_empty() {
                    let e = readd_ms.entry(hex.to_string()).or_insert(0);
                    *e = (*e).max(n);
                }
            }
        }
        let mut hexes: std::collections::BTreeSet<String> = removed_ms.keys().cloned().collect();
        hexes.extend(readd_ms.keys().cloned());
        for hex in hexes {
            let rem = removed_ms.get(&hex).copied().unwrap_or(0);
            let readd = readd_ms.get(&hex).copied().unwrap_or(0);
            if rem >= readd && rem > 0 {
                if prefs.merge_contact_removed_at(&hex, rem) {
                    let before = prefs.contacts.len();
                    prefs.contacts.retain(|c| c.id_hex != hex);
                    if prefs.contacts.len() != before {
                        changed = true;
                    }
                }
            } else if readd > 0 {
                prefs.merge_contact_readded_at(&hex, readd);
            }
        }
    }

    // Contacts: upsert everyone present that isn't tombstone-removed.
    let mut want_contacts: BTreeMap<String, Contact> = BTreeMap::new();
    for (k, v) in entries {
        if let Some(_id) = k.strip_prefix("contact:") {
            if let Ok(c) = serde_json::from_slice::<Contact>(v) {
                want_contacts.insert(c.id_hex.clone(), c);
            }
        }
    }
    // Upsert (a removed contact must not be resurrected by sync).
    for c in want_contacts.values() {
        if prefs.is_contact_removed(&c.id_hex) {
            continue;
        }
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

    // Circle severances synced from our other devices — resolved by LAST-WRITER-WINS on timestamps, so a
    // fresh removal beats a stale re-add and a fresh re-add beats an old removal. Gather both sides from
    // the timestamped keys (plus legacy `removal:` = 1/0 mapped to ts=1 so it loses to any real write),
    // pick the newest per key, then apply — set/lift the removal to match. This is the fix for "removals
    // don't sync to my other device" AND the older "a sibling re-severs a re-added friend": the newest
    // human action always wins, never a stale record. Mirrors iOS SelfSync.applyLocal.
    {
        let mut removed_ms: BTreeMap<String, u64> = BTreeMap::new();
        let mut readd_ms: BTreeMap<String, u64> = BTreeMap::new();
        for (k, v) in entries {
            if let Some(entry) = k.strip_prefix("circle-removed:") {
                if v.len() == 8 {
                    let mut a = [0u8; 8];
                    a.copy_from_slice(v);
                    let e = removed_ms.entry(entry.to_string()).or_insert(0);
                    *e = (*e).max(u64::from_le_bytes(a));
                }
            } else if let Some(entry) = k.strip_prefix("circle-readd:") {
                if v.len() == 8 {
                    let mut a = [0u8; 8];
                    a.copy_from_slice(v);
                    let e = readd_ms.entry(entry.to_string()).or_insert(0);
                    *e = (*e).max(u64::from_le_bytes(a));
                }
            } else if let Some(entry) = k.strip_prefix("removal:") {
                // legacy pre-LWW record → ts=1 (loses to any real timestamped write).
                if v.first() == Some(&1) {
                    let e = removed_ms.entry(entry.to_string()).or_insert(0);
                    *e = (*e).max(1);
                } else if v.first() == Some(&0) {
                    let e = readd_ms.entry(entry.to_string()).or_insert(0);
                    *e = (*e).max(1);
                }
            }
        }
        let mut keys: std::collections::BTreeSet<String> = removed_ms.keys().cloned().collect();
        keys.extend(readd_ms.keys().cloned());
        for entry in keys {
            let (cid, hex) = match entry.split_once('|') {
                Some((c, h)) if !c.is_empty() && !h.is_empty() => (c.to_string(), h.to_string()),
                _ => continue,
            };
            let rem = removed_ms.get(&entry).copied().unwrap_or(0);
            let readd = readd_ms.get(&entry).copied().unwrap_or(0);
            if rem >= readd && rem > 0 {
                // Newest verdict is REMOVED. Merge the removal ts + apply the engine tombstone.
                let was = prefs.is_circle_member_removed(&entry);
                if prefs.merge_circle_removed_at(&entry, rem) {
                    social.remove_from_circle(cid, hex);
                    if !was {
                        changed = true;
                    }
                }
            } else if readd > 0 {
                // Newest verdict is RE-ADDED. Merge the re-add ts AND lift the ENGINE tombstone —
                // the tombstone otherwise keeps rejecting the member's events on this device even
                // though the client guard is clear, so a re-add made on the phone looked applied
                // here while their posts silently never ingested. The member's bundle comes back
                // via the additive `circle:` record. Parity with SelfSync.swift (clearCircleRemoval
                // on the re-add verdict).
                let was = prefs.is_circle_member_removed(&entry);
                if !prefs.merge_circle_readded_at(&entry, readd) {
                    social.clear_circle_removal(cid, hex); // newest is a re-add → lift tombstone
                }
                if was && !prefs.is_circle_member_removed(&entry) {
                    changed = true;
                }
            }
        }
    }

    // Relay delete vs re-add from any of my devices, resolved by LWW on the SEMANTIC timestamp (delete
    // time vs re-add time) — NOT by which device synced last. Gather both sides (max per relay), newest
    // wins. Applied BEFORE the circle: records below (which re-add a circle's relays), so a relay whose
    // newest verdict is "deleted" lands in suppressed_relays and the circle loop then skips it. A legacy
    // `relay-removal:<hex>` = 0 (old bare CLEAR) decodes to del=0/readd=0 → ignored, which is exactly
    // right. Mirrors iOS SelfSync relay LWW + applyForgottenTombstone / applyClearedRelayForget.
    {
        let mut removal_ms: BTreeMap<String, u64> = BTreeMap::new();
        let mut readd_ms: BTreeMap<String, u64> = BTreeMap::new();
        for (k, v) in entries {
            if v.len() != 8 {
                continue;
            }
            let mut a = [0u8; 8];
            a.copy_from_slice(v);
            let n = u64::from_le_bytes(a);
            if let Some(hex) = k.strip_prefix("relay-removal:") {
                if !hex.is_empty() {
                    let e = removal_ms.entry(hex.to_string()).or_insert(0);
                    *e = (*e).max(n);
                }
            } else if let Some(hex) = k.strip_prefix("relay-readd:") {
                if !hex.is_empty() {
                    let e = readd_ms.entry(hex.to_string()).or_insert(0);
                    *e = (*e).max(n);
                }
            }
        }
        let mut hexes: std::collections::BTreeSet<String> = removal_ms.keys().cloned().collect();
        hexes.extend(readd_ms.keys().cloned());
        for hex in hexes {
            let del = removal_ms.get(&hex).copied().unwrap_or(0);
            let readd = readd_ms.get(&hex).copied().unwrap_or(0);
            if del > readd {
                if prefs.apply_forgotten_tombstone(&hex, del) {
                    changed = true;
                }
            } else if readd > 0 && prefs.apply_cleared_relay_forget(&hex, readd) {
                changed = true;
            }
        }
    }

    // Whole-circle / DM deletions — LWW, applied BEFORE the circle: upsert. A deletion newer than any
    // re-creation deletes the circle locally too (so deleting a DM on one device deletes it on all of
    // them); the `circle:` loop then skips re-creating anything still tombstone-deleted. Mirrors iOS.
    {
        let mut deleted_ms: BTreeMap<String, u64> = BTreeMap::new();
        let mut recreated_ms: BTreeMap<String, u64> = BTreeMap::new();
        for (k, v) in entries {
            if v.len() != 8 {
                continue;
            }
            let mut a = [0u8; 8];
            a.copy_from_slice(v);
            let n = u64::from_le_bytes(a);
            if let Some(id) = k.strip_prefix("circle-deleted:") {
                if !id.is_empty() {
                    deleted_ms.insert(id.to_string(), n);
                }
            } else if let Some(id) = k.strip_prefix("circle-recreated:") {
                if !id.is_empty() {
                    recreated_ms.insert(id.to_string(), n);
                }
            }
        }
        let mut ids: std::collections::BTreeSet<String> = deleted_ms.keys().cloned().collect();
        ids.extend(recreated_ms.keys().cloned());
        for id in ids {
            let del = deleted_ms.get(&id).copied().unwrap_or(0);
            let rec = recreated_ms.get(&id).copied().unwrap_or(0);
            if del >= rec && del > 0 {
                let was = prefs.is_circle_deleted(&id);
                if prefs.merge_circle_deleted_at(&id, del) {
                    if social.circles().iter().any(|c| c.id == id) {
                        social.leave_circle(id.clone());
                        changed = true;
                    } else if !was {
                        changed = true;
                    }
                }
            } else if rec > 0 {
                prefs.merge_circle_recreated_at(&id, rec);
            }
        }
    }

    // Circles: reconstruct each synced circle — create it + register every member's bundle so this
    // device can seal to them, and record its relay mailbox(es). STRICTLY ADDITIVE (no absence-based
    // member-prune or circle-leave — that wiped accounts on a freshly-restored device).
    let existing: Vec<(String, String)> =
        social.circles().into_iter().map(|c| (c.id, c.name)).collect();
    for (k, v) in entries {
        let Some(id) = k.strip_prefix("circle:") else { continue };
        // Don't RESURRECT a circle/DM the user deleted (LWW): a sibling still listing it must not
        // re-create it every sync. A newer re-creation (merged above) lifts this.
        if prefs.is_circle_deleted(id) {
            continue;
        }
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
        // Switch-Flip 1.0.7 §2: pin the CREATOR carried on this authenticated circle-sync record (the
        // "learned out-of-band" path). set_circle_creator is DEFINITION-bound — it overrides any weakly
        // TOFU'd creator and can't be dislodged by a later disagreeing admin grant.
        if let Some(creator) = &cs.creator {
            if creator.len() == 32 {
                social.set_circle_creator(id.to_string(), hex::encode(creator));
            }
        }
        // Register every synced member bundle so this device can seal to them. ADDITIVE — we never
        // remove a member just because a peer's record doesn't list them — but we DO skip anyone we've
        // explicitly severed (anti-reinflation), by the LWW removal verdict.
        for bundle in &cs.member_bundles {
            let node_hex = haven_p2p::identity::HavenId::from_bytes(bundle)
                .ok()
                .map(|hid| hex::encode(hid.node_id_bytes()))
                .unwrap_or_default();
            if !node_hex.is_empty()
                && prefs.is_circle_member_removed(&format!("{id}|{}", node_hex.to_lowercase()))
            {
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
        // No creator (legacy) → byte-identical to the pre-§2 encoding (skip-if-none).
        let bytes = encode_circle_sync("Home".into(), bundles.clone(), vec!["node1".into()], None);
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
