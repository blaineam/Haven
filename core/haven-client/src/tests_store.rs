//! Behaviour tests for `store.rs`: the LWW stamps, relay-entry lifecycle, kept-story merge,
//! prefs persistence/migration, identity roster and atomic state writes.

use crate::covtest_util::tmp_paths;
use crate::store::*;
use haven_net::cfquicktunnel::FrontDoorMode;

const R1: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const R2: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn story(id: &str, kept_at: Option<u64>, media: &[&str]) -> KeptStory {
    KeptStory {
        id: id.into(),
        body: format!("body {id}"),
        media: media.iter().map(|s| s.to_string()).collect(),
        created_at: 100,
        kept_at,
        music_catalog_id: None,
        music_title: None,
        music_artist: None,
        music_artwork_url: None,
        music_duration_ms: None,
    }
}

fn wire(kept: Vec<KeptStory>, removed: &[(&str, u64)]) -> Vec<u8> {
    let w = KeptStoriesWire { kept, removed: removed.iter().map(|(k, v)| (k.to_string(), *v)).collect() };
    serde_json::to_vec(&w).unwrap()
}

#[test]
fn paths_name_every_file_under_root_or_base() {
    let p = tmp_paths();
    assert_eq!(p.identities_file(), p.base.join("identities.json"));
    assert_eq!(p.state_file(), p.root.join("haven_social_state.bin"));
    assert_eq!(p.prefs_file(), p.root.join("prefs.json"));
    for f in [
        p.scheduled_file(),
        p.instagram_import_file(),
        p.relay_dir(),
        p.media_dir(),
        p.selfsync_state_file(),
        p.selfsync_device_file(),
    ] {
        assert!(f.starts_with(&p.root), "{f:?} lives under the identity root");
    }
}

#[test]
fn relay_short_name_handles_haven_and_s3_ids() {
    assert_eq!(relay_short_name(R1), "Relay · aaaaaaaa…");
    assert_eq!(relay_short_name("s3:my-bucket"), "S3 · my-bucket");
    assert_eq!(relay_short_name("s3:0123456789abcdefXYZ"), "S3 · 0123456789abcdef", "bucket truncated to 16");
    assert_eq!(relay_short_name("ab"), "Relay · ab…", "short ids do not panic");
}

#[test]
fn circle_member_removal_is_last_writer_wins() {
    let mut p = Prefs::default();
    assert!(!p.is_circle_member_removed("c:x"));
    assert!(p.merge_circle_removed_at("c:x", 100), "a remote removal applies");
    assert!(!p.merge_circle_readded_at("c:x", 200), "a newer re-add supersedes it");
    assert!(!p.merge_circle_removed_at("c:x", 150), "an older removal cannot resurrect the removal");
    assert!(p.merge_circle_removed_at("c:x", 300), "a still-newer removal wins again");
    assert_eq!(p.circle_removed_at["c:x"], 300);
    // Equal timestamps: removal needs to be strictly newer.
    assert!(!p.merge_circle_readded_at("c:x", 300), "a tie goes to the re-add");
}

#[test]
fn local_stamps_use_the_clock_and_supersede_older_remote_state() {
    let mut p = Prefs::default();
    p.merge_circle_readded_at("e", 5);
    p.mark_circle_member_removed("e");
    assert!(p.is_circle_member_removed("e"));
    p.mark_circle_member_readded("e");
    assert!(!p.is_circle_member_removed("e"));

    p.mark_contact_removed("c");
    assert!(p.is_contact_removed("c"));
    assert!(p.contact_removed_at["c"] > 1_600_000_000_000, "stamped in ms since epoch");
    assert!(!p.merge_contact_readded_at("c", u64::MAX / 2), "far-future re-add clears the removal");
    p.mark_contact_readded("c");
    assert!(!p.is_contact_removed("c"));
    assert!(p.merge_contact_removed_at("c", u64::MAX - 1));
    assert!(p.is_contact_removed("c"));

    p.mark_circle_deleted("d");
    assert!(p.is_circle_deleted("d"));
    p.mark_circle_recreated("d");
    assert!(!p.is_circle_deleted("d"), "a recreate stamped now is not older than the delete");
    assert!(p.merge_circle_deleted_at("d2", 10));
    assert!(!p.merge_circle_recreated_at("d2", 20));
    assert!(!p.merge_circle_deleted_at("d2", 5), "older delete ignored");
}

#[test]
fn profile_and_setting_stamps_default_to_zero_and_advance() {
    let mut p = Prefs::default();
    assert_eq!(p.profile_field_stamp("name"), 0);
    assert_eq!(p.setting_stamp("lowData"), 0);
    p.stamp_profile_field("name");
    p.stamp_setting("lowData");
    assert!(p.profile_field_stamp("name") > 0);
    assert!(p.setting_stamp("lowData") > 0);
    assert_eq!(p.profile_field_stamp("bio"), 0, "stamps are namespaced per field");
}

#[test]
fn media_limit_and_tunnel_defaults_are_finite_not_unlimited() {
    let mut p = Prefs::default();
    assert_eq!(p.relay_media_limits(), (30, 32 * 1024 * 1024 * 1024));
    p.relay_media_max_age_days = Some(0);
    p.relay_media_max_bytes = Some(5);
    assert_eq!(p.relay_media_limits(), (0, 5), "0 explicitly means unlimited");
    assert!(p.auto_tunnel());
    p.relay_auto_tunnel = Some(false);
    assert!(!p.auto_tunnel());
}

#[test]
fn front_door_mode_explicit_beats_legacy_inference() {
    let mut p = Prefs::default();
    assert_eq!(p.front_door_mode(), FrontDoorMode::Auto);
    p.relay_public_url = "https://relay.example".into();
    assert_eq!(p.front_door_mode(), FrontDoorMode::Manual, "URL alone is a manual front door");
    p.relay_cf_tunnel_token = "tok".into();
    assert_eq!(p.front_door_mode(), FrontDoorMode::Bundled, "URL + token is bundled");
    p.relay_front_door = Some("manual".into());
    assert_eq!(p.front_door_mode(), FrontDoorMode::Manual, "explicit mode wins");
    p.relay_front_door = Some("  ".into());
    assert_eq!(p.front_door_mode(), FrontDoorMode::Auto, "blank explicit mode falls through to auto");
}

#[test]
fn relay_entry_lifecycle_activate_http_derp_turn() {
    let mut p = Prefs::default();
    p.ensure_relay_entry(R1, Some("Home"), false, true);
    assert_eq!(p.relay_entries[R1].name, "Home");
    assert!(p.relay_is_active(R1));
    assert!(p.relay_is_active("unknown-relay"), "unknown relays count as active");
    p.ensure_relay_entry(R1, Some(""), false, false);
    assert_eq!(p.relay_entries[R1].name, "Home", "an empty name never clobbers");
    p.ensure_relay_entry("s3:bkt", None, true, true);
    assert!(p.relay_entries["s3:bkt"].is_s3);
    assert_eq!(p.relay_entries["s3:bkt"].name, "S3 · bkt");

    // HTTP interface
    assert!(p.relay_http(R1).is_none());
    assert!(p.set_relay_http(R1, vec!["http://10.0.0.2:8080/".into()], "tok".into()));
    assert!(!p.set_relay_http(R1, vec!["http://10.0.0.2:8080/".into()], "tok".into()), "no-op reports unchanged");
    assert_eq!(p.relay_http(R1).unwrap().1, "tok");
    assert_eq!(p.relay_hex_for_http_url("http://10.0.0.2:8080"), Some(R1.to_string()));
    p.set_relay_http(R2, vec!["http://10.0.0.2:8080".into()], "t2".into());
    assert_eq!(p.relay_hex_for_http_url("http://10.0.0.2:8080/"), Some(R1.to_string()), "lowest hex wins");
    assert_eq!(p.relay_hex_for_http_url("http://nope"), None);
    p.set_relay_http(R2, vec!["http://x".into()], String::new());
    assert!(p.relay_http(R2).is_none(), "an empty token means no usable interface");

    // DERP
    assert!(p.set_relay_derp(R1, " https://derp.example/ "));
    assert!(!p.set_relay_derp(R1, "https://derp.example"));
    assert_eq!(p.all_derp_urls(), vec!["https://derp.example".to_string()]);

    // TURN: only turn:/turns: URLs survive
    assert!(p.set_relay_turn(R1, vec!["turn:h:3478".into(), "http://bad".into(), " turns:h:5349 ".into()], " haven ", " pw "));
    assert!(!p.set_relay_turn(R1, vec!["turn:h:3478".into(), "turns:h:5349".into()], "haven", "pw"));
    let (urls, user, pass) = p.all_turn_ice();
    assert_eq!(urls, vec!["turn:h:3478".to_string(), "turns:h:5349".to_string()]);
    assert_eq!((user.as_str(), pass.as_str()), ("haven", "pw"));

    // Inactive relays drop out of the fabric maps.
    p.relay_entries.get_mut(R1).unwrap().active = false;
    assert!(p.all_derp_urls().is_empty());
    assert!(p.all_turn_ice().0.is_empty());
}

#[test]
fn migrate_relay_entries_fills_gaps_only() {
    let mut p = Prefs::default();
    p.relays.insert("default".into(), vec![R1.into(), "s3:b".into()]);
    p.default_relay = R2.into();
    p.migrate_relay_entries();
    assert_eq!(p.relay_entries.len(), 3);
    assert!(p.relay_entries["s3:b"].is_s3);
    let added = p.relay_entries[R1].added_at_ms;
    p.relay_entries.get_mut(R1).unwrap().name = "Custom".into();
    p.migrate_relay_entries();
    assert_eq!(p.relay_entries[R1].name, "Custom", "existing entries are untouched");
    assert_eq!(p.relay_entries[R1].added_at_ms, added);
}

#[test]
fn active_relay_queries_dedupe_and_skip_inactive() {
    let mut p = Prefs::default();
    p.relays.insert("c1".into(), vec![R1.into(), R2.into()]);
    p.default_relay = R1.into();
    p.migrate_relay_entries();
    assert_eq!(p.active_relays_for("c1"), vec![R1.to_string(), R2.to_string()], "default deduped");
    assert_eq!(p.active_relays_for("other"), vec![R1.to_string()], "default serves every circle");
    p.relay_entries.get_mut(R2).unwrap().active = false;
    assert_eq!(p.active_relays_for("c1"), vec![R1.to_string()]);
    let mut all = p.all_active_relay_hexes();
    all.sort();
    assert_eq!(all, vec![R1.to_string()]);
    // A circle-referenced relay with no entry is still active (defensive fold-in).
    p.relays.insert("c2".into(), vec!["cccc".into()]);
    assert!(p.all_active_relay_hexes().contains(&"cccc".to_string()));
}

#[test]
fn forget_and_readd_resolve_by_last_writer_wins() {
    let mut p = Prefs::default();
    p.ensure_relay_entry(R1, None, false, true);
    p.relay_entries.get_mut(R1).unwrap().added_at_ms = 1_000;

    // A sibling's deletion older than our adoption loses; newer wins.
    assert!(!p.apply_forgotten_tombstone(R1, 0));
    assert!(!p.apply_forgotten_tombstone(R1, 500), "older than our adoption");
    assert!(p.apply_forgotten_tombstone(R1, 2_000));
    assert!(!p.relay_is_active(R1));
    assert!(p.suppressed_relays.contains(&R1.to_string()));
    assert_eq!(p.relay_forgotten_at_ms(R1), 2_000);
    assert!(!p.apply_forgotten_tombstone(R1, 2_000), "already forgotten at that time");

    // A re-add older than our deletion loses; newer wins and clears the suppression.
    assert!(!p.apply_cleared_relay_forget(R1, 0));
    assert!(!p.apply_cleared_relay_forget(R1, 1_500));
    assert!(p.apply_cleared_relay_forget(R1, 3_000));
    assert!(p.suppressed_relays.is_empty());
    assert_eq!(p.relay_cleared_forget_ms(R1), 3_000);
    assert!(!p.apply_cleared_relay_forget(R1, 3_000), "idempotent");
    // And a deletion older than that re-add loses.
    assert!(!p.apply_forgotten_tombstone(R1, 2_500));

    // Local helpers.
    p.relay_stamp_forgot(R1);
    assert!(p.relay_forgotten_at_ms(R1) > 0);
    assert_eq!(p.relay_cleared_forget_ms(R1), 0, "a fresh delete drops the older re-add record");
    assert!(p.relay_clear_forget(R1));
    assert!(!p.relay_clear_forget(R1), "nothing left to clear");
    assert!(p.relay_cleared_forget_ms(R1) > 0);
}

#[test]
fn set_relay_added_at_only_moves_forward() {
    let mut p = Prefs::default();
    p.ensure_relay_entry(R1, None, false, true);
    p.relay_entries.get_mut(R1).unwrap().added_at_ms = 10_000;
    p.set_relay_added_at(R1, 5);
    assert_eq!(p.relay_added_at_ms(R1), 10_000);
    p.set_relay_added_at(R1, 20_000);
    assert_eq!(p.relay_added_at_ms(R1), 20_000);
    p.set_relay_added_at(R1, 0);
    assert!(p.relay_added_at_ms(R1) > 20_000, "0 means adopt now");
    p.set_relay_added_at("missing", 1); // must not panic
    assert_eq!(p.relay_added_at_ms("missing"), 0);
}

#[test]
fn stale_relays_need_inactive_and_unseen_for_a_week() {
    let mut p = Prefs::default();
    p.ensure_relay_entry(R1, None, false, true);
    p.ensure_relay_entry(R2, None, false, true);
    assert!(p.stale_relay_hexes().is_empty());
    for hex in [R1, R2] {
        let e = p.relay_entries.get_mut(hex).unwrap();
        e.active = false;
        e.last_seen_ms = 1;
    }
    p.relay_mark_seen(R2);
    p.relay_mark_seen("missing"); // no panic
    assert_eq!(p.stale_relay_hexes(), vec![R1.to_string()]);
}

#[test]
fn kept_story_merge_is_per_entry_and_tombstones_cut_both_ways() {
    let mut p = Prefs::default();
    p.pinned_media.clear();
    // Sibling kept A and B.
    let changed = p.merge_kept_stories(&wire(vec![story("A", Some(10), &["m1"]), story("B", Some(10), &["m2"])], &[]));
    assert!(changed);
    assert_eq!(p.kept_stories.len(), 2);
    assert!(p.pinned_media.contains(&"m1".into()) && p.pinned_media.contains(&"m2".into()), "arrival pins media");

    // Same payload again: nothing changes.
    assert!(!p.merge_kept_stories(&wire(vec![story("A", Some(10), &["m1"])], &[])));

    // A newer copy replaces; an older one does not.
    let mut newer = story("A", Some(50), &["m1"]);
    newer.body = "edited".into();
    assert!(p.merge_kept_stories(&wire(vec![newer], &[])));
    assert_eq!(p.kept_stories.iter().find(|k| k.id == "A").unwrap().body, "edited");
    assert!(!p.merge_kept_stories(&wire(vec![story("A", Some(20), &["m1"])], &[])));

    // A tombstone newer than B's keep removes it and releases only unshared media.
    p.kept_stories.push(story("C", Some(10), &["m2"])); // C shares m2 with B
    assert!(p.merge_kept_stories(&wire(vec![], &[("B", 99)])));
    assert!(p.kept_stories.iter().all(|k| k.id != "B"));
    assert!(p.pinned_media.contains(&"m2".into()), "m2 is still needed by C");
    assert!(p.merge_kept_stories(&wire(vec![], &[("C", 99)])));
    assert!(!p.pinned_media.contains(&"m2".into()), "last holder gone, pin released");

    // Re-keeping after the tombstone wins again.
    assert!(p.merge_kept_stories(&wire(vec![story("B", Some(500), &["m2"])], &[])));
    assert!(p.kept_stories.iter().any(|k| k.id == "B"));
    // An entry older than its tombstone is skipped.
    assert!(!p.merge_kept_stories(&wire(vec![story("C", Some(50), &["m9"])], &[])));
    assert!(p.kept_stories.iter().all(|k| k.id != "C"));
    // Garbage payloads are rejected, not panicked on.
    assert!(!p.merge_kept_stories(b"not json"));
}

#[test]
fn kept_story_falls_back_to_created_at_when_kept_at_absent() {
    let mut p = Prefs::default();
    p.kept_stories_removed.insert("S".into(), 150);
    // created_at = 100 < tombstone 150, so the legacy (no kept_at) entry is dropped.
    assert!(!p.merge_kept_stories(&wire(vec![story("S", None, &[])], &[])));
    assert!(p.kept_stories.is_empty());
}

#[test]
fn kept_tombstones_are_bounded() {
    let mut p = Prefs::default();
    for i in 0..500u64 {
        p.kept_stories_removed.insert(format!("t{i}"), i);
    }
    p.trim_kept_tombstones();
    assert_eq!(p.kept_stories_removed.len(), 500, "at the bound nothing is dropped");
    p.kept_stories_removed.insert("newest".into(), 10_000);
    p.trim_kept_tombstones();
    assert_eq!(p.kept_stories_removed.len(), 250);
    assert!(p.kept_stories_removed.contains_key("newest"), "the newest tombstones survive");
    assert!(!p.kept_stories_removed.contains_key("t0"), "the oldest are shed");
}

#[test]
fn kept_story_json_is_camel_case_and_skips_absent_options() {
    let s = story("A", None, &[]);
    let v = serde_json::to_value(&s).unwrap();
    assert!(v.get("createdAt").is_some());
    assert!(v.get("keptAt").is_none() && v.get("musicTitle").is_none(), "absent optionals are skipped like Swift");
    let back: KeptStory = serde_json::from_value(v).unwrap();
    assert_eq!(back, s);
}

#[test]
fn prefs_load_round_trips_and_defaults_when_missing_or_corrupt() {
    let paths = tmp_paths();
    let fresh = Prefs::load(&paths);
    assert!(fresh.dm_read_seeded_at > 0, "first load stamps and persists the unread seed");
    assert!(paths.prefs_file().exists());

    let mut p = Prefs::load(&paths);
    p.profile.name = "Ada".into();
    p.pinned_dms = vec!["dm1".into()];
    p.save(&paths).unwrap();
    let q = Prefs::load(&paths);
    assert_eq!(q.profile.name, "Ada");
    assert_eq!(q.pinned_dms, vec!["dm1".to_string()]);
    assert_eq!(q.dm_read_seeded_at, p.dm_read_seeded_at, "the seed is stable across loads");

    std::fs::write(paths.prefs_file(), b"{ not json").unwrap();
    let c = Prefs::load(&paths);
    assert!(c.profile.name.is_empty(), "corrupt prefs fall back to defaults instead of crashing");
}

#[test]
fn prefs_load_migrates_legacy_shapes() {
    let paths = tmp_paths();
    let legacy = serde_json::json!({
        "relay_nodes": { "default": R1 },
        "relays": { "default": [R1] },
        "suppressed_relays": [R2],
        "circle_removals": ["c:gone"],
        "circle_removals_cleared": ["c:back"],
        "dm_read_seeded_at": 5
    });
    std::fs::write(paths.prefs_file(), serde_json::to_vec(&legacy).unwrap()).unwrap();
    let p = Prefs::load(&paths);
    assert_eq!(p.relays["default"], vec![R1.to_string()], "legacy single relay folds in without duplicating");
    assert!(p.relay_nodes.is_empty());
    assert!(p.relay_entries.contains_key(R1));
    assert!(p.forgot_at_relays.contains_key(R2), "pre-timestamp deletions get stamped");
    assert_eq!(p.circle_removed_at["c:gone"], 1);
    assert_eq!(p.circle_readded_at["c:back"], 1);
    assert!(!p.is_circle_member_removed("c:back"));
    assert_eq!(p.dm_read_seeded_at, 5, "an existing unread seed is kept");
    // The migration of deletions is persisted.
    let on_disk: serde_json::Value = serde_json::from_slice(&std::fs::read(paths.prefs_file()).unwrap()).unwrap();
    assert!(on_disk["forgot_at_relays"].get(R2).is_some());
}

#[test]
fn identities_roster_rules() {
    let paths = tmp_paths();
    let mut ids = Identities::load(&paths);
    assert!(ids.is_empty());
    ids.add("aa", "Me");
    ids.add("aa", "dup");
    ids.add("bb", "Alt");
    assert_eq!(ids.items.len(), 2, "duplicate add is a no-op");
    assert_eq!(ids.active, "aa", "first identity becomes active");
    assert_eq!(ids.find("aa").unwrap().dir, "", "first identity keeps the legacy root");
    assert_eq!(ids.find("bb").unwrap().dir, "identities/bb");
    assert_eq!(ids.active_entry().unwrap().label, "Me");
    assert!(ids.remove("aa").is_none(), "the active identity cannot be removed");
    assert!(ids.remove("zz").is_none());
    assert!(ids.set_active("bb") && !ids.set_active("zz"));
    assert!(ids.rename("aa", "Primary") && !ids.rename("zz", "x"));
    ids.save(&paths).unwrap();
    let back = Identities::load(&paths);
    assert_eq!(back, ids);
    let mut back = back;
    assert_eq!(back.remove("aa"), Some(String::new()), "removal returns the data subdir to delete");
    std::fs::write(paths.identities_file(), b"garbage").unwrap();
    assert!(Identities::load(&paths).is_empty());
}

#[test]
fn state_blob_round_trips_atomically() {
    let paths = tmp_paths();
    assert!(read_state(&paths).is_none());
    write_state(&paths, b"one").unwrap();
    write_state(&paths, b"two-longer").unwrap();
    assert_eq!(read_state(&paths).unwrap(), b"two-longer");
    let leftovers: Vec<_> = std::fs::read_dir(&paths.root)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().contains("tmp-write"))
        .collect();
    assert!(leftovers.is_empty(), "no temp file left beside the state");
    remove_if_exists(&paths.state_file());
    remove_if_exists(&paths.state_file()); // second call is harmless
    assert!(read_state(&paths).is_none());
}

#[test]
fn qa_seed_file_override_accepts_prefixed_and_bare_base64() {
    let _env = crate::covtest_util::ENV_LOCK.lock();
    // Only this test touches HAVEN_QA_SEED_FILE; B64 is left unset so the file path is exercised.
    use base64::Engine as _;
    let paths = tmp_paths();
    let b64 = base64::engine::general_purpose::STANDARD.encode([9u8; 32]);
    let f = paths.root.join("seed.txt");
    std::env::remove_var("HAVEN_QA_SEED_B64");
    std::fs::write(&f, format!("haven-seed:{b64}\n")).unwrap();
    std::env::set_var("HAVEN_QA_SEED_FILE", &f);
    assert_eq!(qa_seed_override().unwrap(), Some([9u8; 32]));
    assert_eq!(load_seed().unwrap(), Some([9u8; 32]), "load_seed prefers the override and never opens the keyring");
    std::fs::write(&f, &b64).unwrap();
    assert_eq!(qa_seed_override().unwrap(), Some([9u8; 32]));
    std::fs::write(&f, base64::engine::general_purpose::STANDARD.encode([1u8; 7])).unwrap();
    assert!(qa_seed_override().is_err(), "a wrong-length seed is an error, not a silent new identity");
    std::fs::write(&f, "   ").unwrap();
    assert_eq!(qa_seed_override().unwrap(), None);
    std::env::remove_var("HAVEN_QA_SEED_FILE");
    assert_eq!(qa_seed_override().unwrap(), None);
}
